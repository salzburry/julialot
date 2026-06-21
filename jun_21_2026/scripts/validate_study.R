#!/usr/bin/env Rscript
# validate_study.R
# Validate a study definition: closed base+delta cross-rules + the gate DAG.
# Pure R (+ lib.R + yaml). Local-runnable; emits the resolved gate-set artifact.

if (!exists(".lotlib")) source(local({ .find_lib <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) { p <- file.path(dirname(sub("^--file=", "", fa[1])), "lib.R"); if (file.exists(p)) return(p) }
  for (p in c("scripts/lib.R", "lib.R")) if (file.exists(p)) return(p); stop("lib.R not found") }; .find_lib() }))

load_registry <- function(path) read_yaml_file(path)
load_all_studies <- function(dir) {
  files <- list.files(dir, pattern = "\\.ya?ml$", full.names = TRUE)
  st <- lapply(files, read_yaml_file)
  setNames(st, vapply(st, function(s) s$id, character(1)))
}
.params_of <- function(x) if (is.list(x)) x else list()   # TRUE -> no params

# Recursively resolve a study's gate set (gate -> params). Returns
# list(resolved, errors, warnings).
resolve_study <- function(study, studies, registry, seen = character(0), strict = FALSE) {
  errors <- character(0); warnings <- character(0)
  reg <- registry$gates
  g <- study$gates %||% list()
  add <- g$add %||% list(); override <- g$override %||% list()
  disable <- unlist(g$disable %||% list())

  base_resolved <- list()
  if (!is.null(study$base)) {
    if (study$id %in% seen) { errors <- c(errors, "inheritance cycle detected");
      return(list(resolved = list(), errors = errors, warnings = warnings)) }
    bid <- study$base$id
    if (is.null(bid) || !(bid %in% names(studies)))
      errors <- c(errors, sprintf("base study '%s' not found", bid %||% "NA"))
    else {
      br <- resolve_study(studies[[bid]], studies, registry, c(seen, study$id), strict)
      base_resolved <- br$resolved; errors <- c(errors, br$errors); warnings <- c(warnings, br$warnings)
      # base pin: in strict mode an unpinned/TBD hash blocks; a non-TBD hash is
      # always verified against the actual base, not merely accepted.
      exp_hash <- content_hash(paste(deparse(studies[[bid]]), collapse = ""))
      given <- study$base$hash
      if (is.null(given) || given == "TBD") {
        msg <- sprintf("base '%s' hash unpinned (TBD); pin to: %s", bid, exp_hash)
        if (strict) errors <- c(errors, msg) else warnings <- c(warnings, msg)
      } else if (!(given %in% c(exp_hash, substr(exp_hash, 1, 16)))) {
        errors <- c(errors, sprintf("base '%s' hash mismatch: pinned '%s', actual '%s'", bid, given, exp_hash))
      }
      if (!is.null(study$base$version) &&
          !identical(as.character(study$base$version), as.character(studies[[bid]]$version)))
        errors <- c(errors, sprintf("base '%s' version pinned '%s' != actual '%s'",
                    bid, study$base$version, studies[[bid]]$version))
    }
  } else {
    if (length(override)) errors <- c(errors, "base study must not use gates.override")
    if (length(disable)) errors <- c(errors, "base study must not use gates.disable")
  }

  # cross-rules on the delta
  inh <- names(base_resolved)
  dup <- intersect(names(add), inh)
  if (length(dup)) errors <- c(errors, sprintf("gates.add duplicates inherited gate(s): %s", paste(dup, collapse = ", ")))
  bad_ovr <- setdiff(names(override), inh)
  if (length(bad_ovr)) errors <- c(errors, sprintf("gates.override references non-inherited gate(s): %s", paste(bad_ovr, collapse = ", ")))
  bad_dis <- setdiff(disable, inh)
  if (length(bad_dis)) errors <- c(errors, sprintf("gates.disable references non-inherited gate(s): %s", paste(bad_dis, collapse = ", ")))
  both <- intersect(disable, names(override))
  if (length(both)) errors <- c(errors, sprintf("gate(s) both disabled and overridden: %s", paste(both, collapse = ", ")))

  # FALSE is invalid in add/override (it would enable the gate with empty params);
  # use gates.disable to turn off an inherited gate.
  is_false <- function(x) is.logical(x) && length(x) == 1 && !x
  ff_add <- names(add)[vapply(add, is_false, logical(1))]
  ff_ovr <- names(override)[vapply(override, is_false, logical(1))]
  if (length(ff_add)) errors <- c(errors, sprintf("gates.add: 'false' invalid (use disable): %s", paste(ff_add, collapse = ", ")))
  if (length(ff_ovr)) errors <- c(errors, sprintf("gates.override: 'false' invalid: %s", paste(ff_ovr, collapse = ", ")))

  # build resolved
  resolved <- base_resolved
  for (nm in names(add)) resolved[[nm]] <- .params_of(add[[nm]])
  for (nm in names(override)) resolved[[nm]] <- modifyList(resolved[[nm]] %||% list(), .params_of(override[[nm]]))
  for (nm in disable) resolved[[nm]] <- NULL

  # Every resolved gate must exist in the registry; params are COMPLETED with the
  # registry defaults (so the resolved artifact is explicit + reproducible), then
  # conformed: unknown params, missing-required (no default), type, numeric range.
  for (nm in names(resolved)) {
    if (!(nm %in% names(reg))) { errors <- c(errors, sprintf("unknown gate '%s' (not in registry)", nm)); next }
    pspec <- reg[[nm]]$params %||% list()
    unknown <- setdiff(names(resolved[[nm]]), names(pspec))
    if (length(unknown)) errors <- c(errors, sprintf("gate '%s' has unknown param(s): %s", nm, paste(unknown, collapse = ", ")))
    for (pn in names(pspec)) if (!(pn %in% names(resolved[[nm]]))) {   # fill defaults / require
      if (!is.null(pspec[[pn]]$default)) resolved[[nm]][[pn]] <- pspec[[pn]]$default
      else if (isTRUE(pspec[[pn]]$required))
        errors <- c(errors, sprintf("gate '%s' missing required param '%s' (no default)", nm, pn))
    }
    for (pn in intersect(names(resolved[[nm]]), names(pspec))) {
      v <- resolved[[nm]][[pn]]; ps <- pspec[[pn]]; ty <- ps$type %||% "any"
      okty <- switch(ty,
        integer = is.numeric(v) && length(v) == 1 && v == as.integer(v),
        boolean = is.logical(v) && length(v) == 1,
        TRUE)
      if (!isTRUE(okty)) {
        errors <- c(errors, sprintf("gate '%s' param '%s' expected %s, got '%s'", nm, pn, ty, paste(v, collapse = ",")))
        next
      }
      if (is.numeric(v) && length(v) == 1) {            # declared numeric bounds
        if (!is.null(ps$min) && v < ps$min)
          errors <- c(errors, sprintf("gate '%s' param '%s' = %s below min %s", nm, pn, v, ps$min))
        if (!is.null(ps$max) && v > ps$max)
          errors <- c(errors, sprintf("gate '%s' param '%s' = %s above max %s", nm, pn, v, ps$max))
      }
    }
  }
  list(resolved = resolved, errors = unique(errors), warnings = unique(warnings))
}

# DAG: each resolved gate's depends_on must resolve to a known stage or gate;
# detect cycles via topological sort over (stages + gates).
validate_dag <- function(resolved, registry) {
  errors <- character(0)
  stages <- unlist(registry$stages)
  gates <- names(resolved)
  nodes <- c(stages, gates)
  # phase ordering + the phase at which each stage becomes available, so a gate
  # cannot depend on a stage produced later than its own phase.
  PHASE <- c(pre_lot = 1L, post_lot1 = 2L, post_lot_long = 3L, study_period = 4L)
  STAGE_AT <- c(index_date = 1L, lot1_start = 2L, lot_long = 3L)
  gate_phase <- function(gn) unname(PHASE[registry$gates[[gn]]$phase %||% "pre_lot"])
  edges <- list()
  for (gn in gates) {
    ph <- registry$gates[[gn]]$phase %||% "pre_lot"
    gph <- unname(PHASE[ph])
    if (is.na(gph))                                   # unknown phase name is not silently allowed
      errors <- c(errors, sprintf("gate '%s' has unknown phase '%s' (not in {%s})",
                  gn, ph, paste(names(PHASE), collapse = ", ")))
    dep <- unlist(registry$gates[[gn]]$depends_on %||% list())
    bad <- setdiff(dep, nodes)
    if (length(bad)) errors <- c(errors, sprintf("gate '%s' depends on unknown node(s): %s", gn, paste(bad, collapse = ", ")))
    # phase feasibility applies to BOTH stage and gate dependencies: a dependency
    # must not be produced in a LATER phase than the gate that needs it.
    for (d in intersect(dep, names(STAGE_AT)))
      if (!is.na(gph) && STAGE_AT[[d]] > gph)
        errors <- c(errors, sprintf("gate '%s' (phase %s) depends on stage '%s' not produced until a later phase",
                    gn, ph, d))
    for (d in intersect(dep, gates)) {                # gate -> gate phase feasibility
      dph <- gate_phase(d)
      if (!is.na(gph) && !is.na(dph) && dph > gph)
        errors <- c(errors, sprintf("gate '%s' (phase %s) depends on gate '%s' in a later phase (%s)",
                    gn, ph, d, registry$gates[[d]]$phase %||% "pre_lot"))
    }
    edges[[gn]] <- intersect(dep, nodes)
  }
  # Kahn's algorithm for cycle detection (stages have no deps)
  indeg <- setNames(integer(length(nodes)), nodes)
  for (gn in names(edges)) for (d in edges[[gn]]) indeg[gn] <- indeg[gn] + 1L
  q <- names(indeg)[indeg == 0]; visited <- 0L
  while (length(q)) {
    n <- q[1]; q <- q[-1]; visited <- visited + 1L
    for (gn in names(edges)) if (n %in% edges[[gn]]) {
      indeg[gn] <- indeg[gn] - 1L; if (indeg[gn] == 0) q <- c(q, gn)
    }
  }
  if (visited < length(nodes)) errors <- c(errors, "gate dependency graph has a cycle")
  errors
}

# Clinical approval is a SEPARATE axis from structural validity: a study can be
# structurally strict-valid yet still DRAFT (not cleared for production). The
# state is machine-readable so it cannot be conflated. `approved` is not just a
# label - it must carry an auditable signer + date, else the claim is rejected.
# By default a draft only WARNS; a release gate passes require_approved=TRUE to
# make draft BLOCKING (fail-closed for production).
APPROVAL_STATES <- c("draft", "approved")
validate_approval <- function(obj, label, require_approved = FALSE) {
  errors <- character(0); warnings <- character(0)
  ap <- obj$approval %||% list()
  status <- tolower(trimws(as.character(ap$status %||% "draft")))
  if (!(status %in% APPROVAL_STATES))
    errors <- c(errors, sprintf("%s: approval.status '%s' not in {%s}",
                label, status, paste(APPROVAL_STATES, collapse = ", ")))
  if (status == "approved") {
    if (!nzchar(trimws(as.character(ap$signed_off_by %||% ""))))
      errors <- c(errors, sprintf("%s: approval.status=approved requires signed_off_by", label))
    sod <- trimws(as.character(ap$signed_off_date %||% ""))
    if (!nzchar(sod))
      errors <- c(errors, sprintf("%s: approval.status=approved requires signed_off_date", label))
    else if (!is_iso_date(sod))                       # not just non-blank: a real ISO date
      errors <- c(errors, sprintf("%s: approval.signed_off_date '%s' is not an ISO (YYYY-MM-DD) date", label, sod))
  } else {
    msg <- sprintf("%s is %s - NOT cleared for production (clinical sign-off pending)", label, status)
    if (require_approved) errors <- c(errors, msg) else warnings <- c(warnings, msg)
  }
  list(errors = errors, warnings = warnings, status = status)
}

# The inheritance chain: this study + every base it derives from (current first).
study_chain <- function(study, studies, seen = character(0)) {
  if (is.null(study)) return(list())
  chain <- list(study)
  bid <- study$base$id
  if (!is.null(bid) && !(bid %in% seen) && bid %in% names(studies))
    chain <- c(chain, study_chain(studies[[bid]], studies, c(seen, study$id %||% "")))
  chain
}

# Closed-schema conformance: the runtime validator and study.schema.json must be
# ONE contract, not two. Enforce the schema's top-level `required` + (when
# additionalProperties:false) reject any undeclared top-level key. (Deep JSON
# Schema is left to a dedicated validator; this keeps the two from diverging - a
# study key the schema does not know about, like an undeclared `approval`, fails.)
validate_study_schema <- function(study, schema_path) {
  schema <- tryCatch(read_json_file(schema_path), error = function(e) NULL)
  if (is.null(schema)) return(sprintf("could not read study schema (%s)", schema_path))
  errors <- character(0)
  props <- names(schema$properties %||% list())
  miss <- setdiff(unlist(schema$required %||% list()), names(study))
  if (length(miss)) errors <- c(errors, sprintf("schema: missing required key(s): %s", paste(miss, collapse = ", ")))
  if (isFALSE(schema$additionalProperties)) {
    extra <- setdiff(names(study), props)
    if (length(extra)) errors <- c(errors, sprintf("schema: undeclared top-level key(s) (closed schema): %s", paste(extra, collapse = ", ")))
  }
  errors
}

validate_study <- function(study_path, registry_path, studies_dir, strict = FALSE,
                           require_approved = FALSE,
                           schema_path = "contracts/study.schema.json") {
  registry <- load_registry(registry_path)
  studies <- load_all_studies(studies_dir)
  study <- read_yaml_file(study_path)
  r <- resolve_study(study, studies, registry, strict = strict)
  dag_err <- if (length(r$errors) == 0) validate_dag(r$resolved, registry) else character(0)
  sch_err <- if (file.exists(schema_path)) validate_study_schema(study, schema_path) else character(0)
  # Approval is validated for the WHOLE inheritance chain + the registry: a
  # release run cannot be cleared while any inherited base (or the registry) is
  # still draft. Every approval is recorded in the resolved artifact.
  ap_errors <- character(0); ap_warnings <- character(0); approvals <- list()
  for (st in study_chain(study, studies)) {
    a <- validate_approval(st, sprintf("study '%s'", st$id %||% "?"), require_approved)
    ap_errors <- c(ap_errors, a$errors); ap_warnings <- c(ap_warnings, a$warnings)
    approvals[[st$id %||% sprintf("?%d", length(approvals) + 1L)]] <- a$status
  }
  ap_r <- validate_approval(registry, "gate registry", require_approved)
  list(id = study$id,
       errors = c(r$errors, dag_err, sch_err, ap_errors, ap_r$errors),
       warnings = c(r$warnings, ap_warnings, ap_r$warnings),
       approval = approvals[[study$id %||% "?1"]] %||% "draft",
       chain_approvals = approvals, registry_approval = ap_r$status,
       resolved = r$resolved)
}

report_study <- function(res) {
  cat(sprintf("== study %s (approval: %s) ==\n", res$id, res$approval %||% "?"))
  for (w in res$warnings) cat("  WARN: ", w, "\n")
  for (e in res$errors)  cat("  ERROR:", e, "\n")
  if (!length(res$errors)) {
    cat("  OK - resolved gates:\n")
    for (nm in names(res$resolved)) {
      p <- res$resolved[[nm]]
      cat(sprintf("    - %s%s\n", nm,
          if (length(p)) paste0(" { ", paste(names(p), unlist(p), sep = "=", collapse = ", "), " }") else ""))
    }
  }
  invisible(!length(res$errors))
}

if (sys.nframe() == 0 && !interactive()) {
  a <- commandArgs(trailingOnly = TRUE)
  strict <- !("--no-strict" %in% a)          # strict (fail-closed) is the DEFAULT
  require_approved <- "--require-approved" %in% a   # release gate: draft -> BLOCK
  pos <- a[!grepl("^--", a)]
  sp <- if (length(pos)) pos[1] else "studies/ndmm.yml"
  res <- validate_study(sp, "cohort/gates/registry.yml", "studies",
                        strict = strict, require_approved = require_approved)
  ok <- report_study(res)
  emit <- a[which(a == "--emit") + 1L]
  if (ok && length(emit) && !is.na(emit[1]))     # emit the resolved gate-set artifact
    writeLines(jsonlite::toJSON(res$resolved, auto_unbox = TRUE, pretty = TRUE), emit[1])
  quit(status = if (ok) 0L else 1L)
}
