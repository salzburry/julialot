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

  # build resolved
  resolved <- base_resolved
  for (nm in names(add)) resolved[[nm]] <- .params_of(add[[nm]])
  for (nm in names(override)) resolved[[nm]] <- modifyList(resolved[[nm]] %||% list(), .params_of(override[[nm]]))
  for (nm in disable) resolved[[nm]] <- NULL

  # every resolved gate must exist in the registry; params must conform
  for (nm in names(resolved)) {
    if (!(nm %in% names(reg))) { errors <- c(errors, sprintf("unknown gate '%s' (not in registry)", nm)); next }
    declared <- names(reg[[nm]]$params %||% list())
    unknown <- setdiff(names(resolved[[nm]]), declared)
    if (length(unknown)) errors <- c(errors, sprintf("gate '%s' has unknown param(s): %s", nm, paste(unknown, collapse = ", ")))
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
  edges <- list()
  for (gn in gates) {
    dep <- unlist(registry$gates[[gn]]$depends_on %||% list())
    bad <- setdiff(dep, nodes)
    if (length(bad)) errors <- c(errors, sprintf("gate '%s' depends on unknown node(s): %s", gn, paste(bad, collapse = ", ")))
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

validate_study <- function(study_path, registry_path, studies_dir, strict = FALSE) {
  registry <- load_registry(registry_path)
  studies <- load_all_studies(studies_dir)
  study <- read_yaml_file(study_path)
  r <- resolve_study(study, studies, registry, strict = strict)
  dag_err <- if (length(r$errors) == 0) validate_dag(r$resolved, registry) else character(0)
  list(id = study$id, errors = c(r$errors, dag_err), warnings = r$warnings,
       resolved = r$resolved)
}

report_study <- function(res) {
  cat(sprintf("== study %s ==\n", res$id))
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
  sp <- a[1] %||% "studies/ndmm.yml"
  ok <- report_study(validate_study(sp, "cohort/gates/registry.yml", "studies"))
  quit(status = if (ok) 0 else 1)
}
