#!/usr/bin/env Rscript
# Validate the per-tumor LOT contracts. Base R only, so it runs anywhere the
# repo's other offline suites run.
#
#   Rscript validate_contracts.R             # validate every contracts/*.yaml
#   Rscript validate_contracts.R --selftest  # prove the checks can fail
#
# Exit 1 on any failure, with the contract and the check named.

args <- commandArgs(trailingOnly = TRUE)
SELF <- file.path(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)[1])))
CONTRACT_DIR <- normalizePath(file.path(SELF, "..", "contracts"))

# ---- A parser for the schema's YAML subset -------------------------------
# Two-space indents, `key: value`, `key:` opening a map, `- item` scalar list
# entries, {} / [] explicit empties, full-line comments. Nothing else - the
# schema promises no anchors, inline maps, or quoting, so a tiny parser can be
# exact instead of a big one being approximate.

.coerce <- function(v) {
  if (v == "true") return(TRUE)
  if (v == "false") return(FALSE)
  if (v == "{}") return(structure(list(), names = character(0)))
  if (v == "[]") return(character(0))
  if (grepl("^-?[0-9]+$", v)) return(as.integer(v))
  v
}

set_path <- function(root, path, value) {
  if (length(path) == 1L) { root[[path]] <- value; return(root) }
  head <- path[[1]]
  if (is.null(root[[head]])) root[[head]] <- structure(list(), names = character(0))
  root[[head]] <- set_path(root[[head]], path[-1], value)
  root
}

get_path <- function(root, path) {
  for (p in path) {
    if (!is.list(root) || is.null(root[[p]])) return(NULL)
    root <- root[[p]]
  }
  root
}

parse_contract <- function(lines) {
  root <- structure(list(), names = character(0))
  path <- character(0)   # key path per open depth
  for (i in seq_along(lines)) {
    raw <- lines[[i]]
    if (!nzchar(trimws(raw)) || grepl("^\\s*#", raw)) next
    ind <- nchar(raw) - nchar(sub("^ *", "", raw))
    if (ind %% 2 != 0)
      stop("line ", i, ": indentation is not a multiple of two spaces")
    depth <- ind / 2
    txt <- trimws(raw)
    if (startsWith(txt, "- ")) {
      # list item under the map key at `depth` (the key sits one level up)
      if (depth < 1 || length(path) < depth)
        stop("line ", i, ": list item with no owning key")
      owner <- path[seq_len(depth)]
      cur <- get_path(root, owner)
      if (is.null(cur) || (is.list(cur) && length(cur) == 0)) cur <- character(0)
      if (!is.character(cur))
        stop("line ", i, ": list item under a key that already holds a map")
      root <- set_path(root, owner, c(cur, substring(txt, 3)))
    } else if (grepl("^[A-Za-z_][A-Za-z0-9_]*:( |$)", txt)) {
      key <- sub(":.*$", "", txt)
      val <- trimws(sub("^[A-Za-z_][A-Za-z0-9_]*:", "", txt))
      if (length(path) < depth)
        stop("line ", i, ": indented deeper than any open key")
      path <- c(path[seq_len(depth)], key)
      if (nzchar(val)) root <- set_path(root, path, .coerce(val))
      else root <- set_path(root, path, structure(list(), names = character(0)))
    } else {
      stop("line ", i, ": not in the schema subset: ", txt)
    }
  }
  root
}

# ---- Checks ---------------------------------------------------------------

KNOWN_REASONS <- c("SCT_ALLO", "SCT_CART", "SCT_AUTO", "CART_INIT", "MED_ADD",
                   "DEATH", "DISCONTINUATION", "STUDY_END")
REQUIRED_TOP  <- c("tumor", "contract_version", "status", "provenance",
                   "observation", "episodes", "drug_roles", "equivalence",
                   "lines", "advancement", "event_streams", "boundary_labels",
                   "criteria", "expectations")

is_posint <- function(x) is.integer(x) && length(x) == 1L && !is.na(x) && x > 0

check_contract <- function(doc, raw_text, fname) {
  bad <- character(0)
  say <- function(...) bad <<- c(bad, paste0(...))

  miss <- setdiff(REQUIRED_TOP, names(doc))
  if (length(miss)) { say("missing sections: ", paste(miss, collapse = ", ")); return(bad) }

  if (!doc$status %in% c("baseline_extracted", "draft", "reviewed"))
    say("status '", doc$status, "' is not baseline_extracted / draft / reviewed")
  if (!is_posint(doc$contract_version)) say("contract_version must be a positive integer")
  for (f in c("source", "reviewed_by", "notes"))
    if (is.null(doc$provenance[[f]])) say("provenance.", f, " is missing")

  if (!is.logical(get_path(doc, c("observation", "censor_at_disenrollment"))))
    say("observation.censor_at_disenrollment must be true or false")
  for (f in c("medical_day_supply", "pharmacy_missing_day_supply", "map_discon_gap_days"))
    if (!is_posint(doc$episodes[[f]])) say("episodes.", f, " must be a positive integer")

  # Drug roles: the taxonomy, each class in at most one role. TBD entries are
  # placeholders, not classes, and cannot collide.
  dr <- doc$drug_roles
  if (!identical(dr$default_role, "line_defining"))
    say("drug_roles.default_role must be line_defining")
  role_sets <- list(supportive = dr$supportive_classes,
                    backbone = dr$backbone_classes,
                    maintenance = dr$maintenance_classes)
  for (nm in names(role_sets))
    if (is.null(role_sets[[nm]]) || !is.character(role_sets[[nm]]))
      say("drug_roles.", nm, "_classes must be a list (possibly [])")
  real <- lapply(role_sets, function(v) if (is.character(v)) v[!grepl("^TBD", v)] else character(0))
  dup <- Reduce(intersect, Filter(length, real))
  if (length(Filter(length, real)) > 1 && length(dup))
    say("a class carries two roles: ", paste(dup, collapse = ", "))

  adv <- doc$advancement
  if (!is.logical(adv$new_agent)) say("advancement.new_agent must be true or false")
  if (!is.logical(adv$drop_based)) say("advancement.drop_based must be true or false")
  g <- adv$same_regimen_gap_days
  if (!(identical(g, "none") || is_posint(g)))
    say("advancement.same_regimen_gap_days must be 'none' or a positive integer")

  ln <- doc$lines
  if (!is_posint(ln$max_lot) || ln$max_lot > 9L) say("lines.max_lot must be 1..9")
  for (f in c("regimen_window_days_line1", "regimen_window_days_later"))
    if (!is_posint(ln[[f]])) say("lines.", f, " must be a positive integer")
  # How much observation has to follow a run-out before it counts as a
  # discontinuation, and whether seeing the patient again counts instead. Both
  # are axes, not defaults: a tumor whose treatment is continuous and one dosed
  # every three weeks do not wait the same length of time to call a stop a stop.
  # `none` is the explicit off - any run-out is a discontinuation.
  d <- ln$discon_confirm_days
  if (!(identical(d, "none") || is_posint(d) || (is.character(d) && grepl("^TBD", d))))
    say("lines.discon_confirm_days must be 'none', a positive integer, or a TBD")
  r <- ln$discon_confirmed_by_return
  if (!(is.logical(r) || (is.character(r) && grepl("^TBD", r))))
    say("lines.discon_confirmed_by_return must be true, false, or a TBD")
  if (identical(d, "none") && isTRUE(r))
    say("lines.discon_confirmed_by_return is set with no confirmation window - ",
        "with discon_confirm_days 'none' every run-out already counts, so a ",
        "return confirms nothing")
  ep <- ln$end_priority
  if (!is.character(ep) || !length(ep)) say("lines.end_priority is missing")
  else {
    if (anyDuplicated(ep)) say("lines.end_priority repeats a reason")
    unknown <- setdiff(ep, KNOWN_REASONS)
    if (length(unknown)) say("lines.end_priority has unknown reasons: ", paste(unknown, collapse = ", "))
    core <- c("DEATH", "DISCONTINUATION", "STUDY_END")
    if (!all(core %in% ep))
      say("lines.end_priority must include ", paste(setdiff(core, ep), collapse = ", "))
  }
  if (!is.character(ln$line1_start_events) || !length(ln$line1_start_events))
    say("lines.line1_start_events must name at least one event type")
  stream_names <- names(doc$event_streams)
  if (is.character(ln$line1_start_events)) {
    unknown <- setdiff(ln$line1_start_events, c("MED", stream_names))
    if (length(unknown))
      say("lines.line1_start_events names undeclared types: ", paste(unknown, collapse = ", "))
  }

  for (s in stream_names) {
    st <- doc$event_streams[[s]]
    if (!identical(st$line_span, "regimen") && !identical(st$line_span, "single_day"))
      say("event_streams.", s, ".line_span must be regimen or single_day")
    for (f in c("may_start_line1", "may_start_later_lines"))
      if (!is.logical(st[[f]])) say("event_streams.", s, ".", f, " must be true or false")
    for (f in intersect(c("claim_window_days", "merge_gap_days", "tandem_max_gap_days",
                          "consolidation_days", "bridging_med_add_days"), names(st)))
      if (!is_posint(st[[f]])) say("event_streams.", s, ".", f, " must be a positive integer")
  }

  for (l in names(doc$boundary_labels)) {
    lb <- doc$boundary_labels[[l]]
    for (f in c("from_event", "to_event", "note"))
      if (!is.character(lb[[f]]) || !nzchar(lb[[f]])) say("boundary_labels.", l, ".", f, " is missing")
    for (f in grep("_min_days$", names(lb), value = TRUE))
      if (!is_posint(lb[[f]])) say("boundary_labels.", l, ".", f, " must be a positive integer")
  }

  for (cn in names(doc$criteria))
    if (!is.logical(doc$criteria[[cn]]$enabled)) say("criteria.", cn, ".enabled must be true or false")

  # Status semantics: a draft is unreviewed by definition; a reviewed contract
  # has a reviewer and no TBD left; the baseline label is the myeloma pin's.
  has_tbd <- any(grepl("TBD", raw_text, fixed = TRUE))
  reviewers <- doc$provenance$reviewed_by
  reviewed_empty <- is.character(reviewers) && length(reviewers) == 0 ||
                    (is.list(reviewers) && length(reviewers) == 0)
  if (identical(doc$status, "draft") && !reviewed_empty)
    say("status draft but reviewed_by is non-empty - either it was reviewed or it was not")
  if (identical(doc$status, "reviewed") && reviewed_empty)
    say("status reviewed but reviewed_by is empty")
  if (identical(doc$status, "reviewed") && has_tbd)
    say("status reviewed but the file still contains TBD entries")
  if (identical(doc$status, "baseline_extracted") && !identical(doc$tumor, "multiple_myeloma"))
    say("baseline_extracted is reserved for the contract pinned to the engine")
  bad
}

# ---- The engine binding --------------------------------------------------
#
# The myeloma contract IS the engine's shipped behavior, so the pin has to be a
# COMPARISON against the engine, not a copy of it. A hand-written table of the
# values the engine is believed to ship cannot notice the engine moving: it
# validates clean against itself while settings are added to CONTRACT.
#
# So: read CONTRACT out of the engine, bind each rule-bearing key to the
# contract field that carries it, and require every key to be accounted for.
# A new engine setting fails this file until someone decides whether it is a
# contract axis - which is the point.

# STUDY_FOLDER so this tracks the folder the gate is pointed at, rather than
# only ever the one that happens to be checked in under that name today.
ENGINE_FILE <- normalizePath(
  file.path(SELF, "..", "..", "..", "..",
            Sys.getenv("STUDY_FOLDER", unset = "Jul 28"),
            "lot", "engine", "R", "build_lot.R"), mustWork = FALSE)

# CONTRACT is a flat `key = value,` list of scalars, so a small reader is exact.
engine_contract <- function(path = ENGINE_FILE) {
  if (!file.exists(path))
    stop("cannot read the engine at ", path,
         " - the pin compares against it and cannot be skipped")
  src <- readLines(path, warn = FALSE)
  i <- grep("^CONTRACT <- list\\(", src)
  if (length(i) != 1L)
    stop("expected exactly one `CONTRACT <- list(` in ", path,
         ", found ", length(i))
  j <- grep("^\\)\\s*$", src); j <- j[j > i[1]][1]
  if (is.na(j)) stop("CONTRACT list in ", path, " is not closed")
  blk <- src[(i[1] + 1):(j - 1)]
  blk <- blk[!grepl("^\\s*#", blk)]
  blk <- blk[nzchar(trimws(blk))]
  out <- structure(list(), names = character(0))
  for (l in blk) {
    m <- regmatches(l, regexec("^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(.*?),?\\s*$", l))[[1]]
    if (length(m) != 3L)
      stop("cannot read this CONTRACT line: ", trimws(l))
    k <- m[[2]]; v <- trimws(m[[3]])
    out[[k]] <-
      if (identical(v, "TRUE")) TRUE
      else if (identical(v, "FALSE")) FALSE
      else if (grepl("^-?[0-9]+L$", v)) as.integer(sub("L$", "", v))
      else if (grepl("^-?[0-9]+$", v)) as.integer(v)
      else if (grepl('^".*"$', v)) substr(v, 2, nchar(v) - 1)
      else stop("cannot read the value of CONTRACT$", k, ": ", v)
  }
  out
}

# contract path  <-  engine key, with an optional transform of the engine value.
# `to` turns what the engine ships into what the contract writes.
BINDING <- list(
  list(path = c("observation", "censor_at_disenrollment"), key = "censor_at_disenrollment"),
  list(path = c("episodes", "medical_day_supply"),         key = "medical_day_supply"),
  list(path = c("episodes", "map_discon_gap_days"),        key = "map_discon_gap_days"),
  list(path = c("lines", "max_lot"),                       key = "max_lot"),
  list(path = c("lines", "regimen_window_days_line1"),     key = "induction_window_days"),
  list(path = c("lines", "regimen_window_days_later"),     key = "lot_n_induction_window_days"),
  list(path = c("lines", "discon_confirm_days"),           key = "lot_discon_confirm_days"),
  list(path = c("event_streams", "AUTO", "claim_window_days"),    key = "sct_auto_window_days"),
  list(path = c("event_streams", "AUTO", "merge_gap_days"),       key = "sct_auto_gap_days"),
  list(path = c("event_streams", "AUTO", "tandem_max_gap_days"),  key = "sct_tandem_days"),
  list(path = c("event_streams", "CART", "consolidation_days"),   key = "cart_consolidation_days"),
  list(path = c("event_streams", "CART", "bridging_med_add_days"), key = "cart_consolidation_days"),
  list(path = c("event_streams", "CART", "induction_absorbed"),   key = "apply_cart_induction_rule"),
  list(path = c("advancement", "returning_agent_requires_discontinuation"),
       key = "returning_agent_requires_discontinuation"),
  list(path = c("event_streams", "ALLO", "line_span"),            key = "allo_lot_span"),
  list(path = c("criteria", "no_belantamab", "enabled"),          key = "apply_no_belantamab"),
  # Blank is the contract algorithm - the gap-advancement rule is off - which
  # the contract writes as `none` on the advancement axis.
  list(path = c("advancement", "same_regimen_gap_days"), key = "apply_melp_rule",
       to = function(v) if (identical(v, "")) "none" else NULL)
)

# Engine settings that are deliberately NOT contract axes, each with the reason.
# Anything not here and not in BINDING fails the completeness check below.
NOT_AN_AXIS <- c(
  catalog = "deployment: which catalog the run reads",
  cdm_schema = "deployment: which CDM schema the run reads",
  codelist_dir = "deployment: where the code lists are mounted",
  dsn = "deployment: the ODBC data source",
  tbl_medical = "deployment: CDM table name",
  tbl_med_proc = "deployment: CDM table name",
  tbl_med_diag = "deployment: CDM table name",
  tbl_rx = "deployment: CDM table name",
  use_quarterly_tables = "deployment: which physical CDM tables the vintage offers",
  belantamab_med_abbr = "code-list spelling of the criterion drug, not a rule",
  melp_med_abbr = "parameter of the gap-advancement prototype, inert while it is off",
  melp_exposure_days = "parameter of the gap-advancement prototype, inert while it is off",
  melp_restart_days = "parameter of the gap-advancement prototype, inert while it is off",
  melp_advance_days = "parameter of the gap-advancement prototype, inert while it is off",
  melp_sct_days = "parameter of the gap-advancement prototype, inert while it is off"
)

# Every engine setting is either bound to a contract field or explicitly not an
# axis. This is the check that was missing: a setting added to CONTRACT with no
# decision recorded here stops the validator instead of passing unnoticed.
check_binding_complete <- function(eng = engine_contract()) {
  bound <- vapply(BINDING, function(b) b$key, character(1))
  known <- unique(c(bound, names(NOT_AN_AXIS)))
  new <- setdiff(names(eng), known)
  gone <- setdiff(known, names(eng))
  bad <- character(0)
  if (length(new))
    bad <- c(bad, paste0("the engine ships CONTRACT setting(s) this skill does not ",
                         "account for: ", paste(new, collapse = ", "),
                         ". Bind each to a contract field in BINDING, or record ",
                         "why it is not a contract axis in NOT_AN_AXIS."))
  if (length(gone))
    bad <- c(bad, paste0("this skill binds engine setting(s) the engine no longer ",
                         "ships: ", paste(gone, collapse = ", "),
                         ". Remove them, or the pin is checking nothing."))
  bad
}

check_myeloma_pin <- function(doc, eng = engine_contract()) {
  bad <- character(0)
  for (b in BINDING) {
    if (is.null(eng[[b$key]])) {
      bad <- c(bad, paste0(paste(b$path, collapse = "."),
                           ": bound to CONTRACT$", b$key, ", which the engine does not ship"))
      next
    }
    want <- if (is.null(b$to)) eng[[b$key]] else b$to(eng[[b$key]])
    if (is.null(want)) {
      bad <- c(bad, paste0(paste(b$path, collapse = "."), ": CONTRACT$", b$key,
                           " is '", eng[[b$key]], "', which this binding cannot ",
                           "express as a contract value"))
      next
    }
    got <- get_path(doc, b$path)
    if (!identical(got, want))
      bad <- c(bad, paste0(paste(b$path, collapse = "."), ": contract says '",
                           paste(got, collapse = " "), "', engine ships '",
                           paste(want, collapse = " "), "'"))
  }
  # Not bound to a single setting, but still the engine's shipped behavior.
  fixed <- list(
    list(path = c("episodes", "pharmacy_missing_day_supply"), want = 28L),
    list(path = c("drug_roles", "supportive_classes"), want = "STEROID"),
    list(path = c("lines", "end_priority"),
         want = c("SCT_ALLO", "SCT_CART", "SCT_AUTO", "CART_INIT", "MED_ADD",
                  "DEATH", "DISCONTINUATION", "STUDY_END")),
    list(path = c("lines", "discon_confirmed_by_return"), want = TRUE)
  )
  for (f in fixed) {
    got <- get_path(doc, f$path)
    if (!identical(got, f$want))
      bad <- c(bad, paste0(paste(f$path, collapse = "."), ": contract says '",
                           paste(got, collapse = " "), "', engine ships '",
                           paste(f$want, collapse = " "), "'"))
  }
  bad
}

validate_file <- function(f) {
  raw <- readLines(f, warn = FALSE)
  doc <- tryCatch(parse_contract(raw), error = function(e)
    return(structure(conditionMessage(e), class = "parse_error")))
  if (inherits(doc, "parse_error"))
    return(paste0("does not parse: ", unclass(doc)))
  bad <- check_contract(doc, raw, basename(f))
  if (identical(doc$tumor, "multiple_myeloma"))
    bad <- c(bad, check_binding_complete(), check_myeloma_pin(doc))
  bad
}

# ---- Self-test: the checks have to be able to fail ------------------------

selftest <- function() {
  base <- readLines(file.path(CONTRACT_DIR, "multiple_myeloma.yaml"), warn = FALSE)
  cases <- list(
    list(name = "a ladder missing DEATH is refused",
         text = base[!grepl("^    - DEATH$", base)]),
    list(name = "a drifted engine value is refused by the pin",
         text = sub("regimen_window_days_line1: 60", "regimen_window_days_line1: 42", base)),
    list(name = "an axis the engine gained and the contract lacks is refused",
         text = base[!grepl("^  discon_confirm_days: ", base)]),
    list(name = "...and so is one the contract states differently",
         text = sub("discon_confirmed_by_return: true",
                    "discon_confirmed_by_return: false", base)),
    list(name = "reviewed status with TBD content is refused",
         text = sub("^status: draft$", "status: reviewed",
                    readLines(file.path(CONTRACT_DIR, "ovarian.yaml"), warn = FALSE)))
  )
  fails <- 0L
  for (cs in cases) {
    doc <- parse_contract(cs$text)
    bad <- check_contract(doc, cs$text, "selftest")
    if (identical(doc$tumor, "multiple_myeloma")) bad <- c(bad, check_myeloma_pin(doc))
    ok <- length(bad) > 0
    cat(sprintf("  %s %s\n", if (ok) "ok   " else "FAIL ", cs$name))
    if (!ok) fails <- fails + 1L
  }
  # The completeness check answers to the engine rather than to a contract
  # file, so it is planted against a stand-in engine rather than a stand-in
  # contract: a CONTRACT that ships a setting no binding mentions.
  tmp <- tempfile(fileext = ".R")
  writeLines(c("CONTRACT <- list(", "  max_lot = 5L,",
               "  a_setting_nobody_decided_about = 7L", ")"), tmp)
  planted <- tryCatch(check_binding_complete(engine_contract(tmp)),
                      error = function(e) conditionMessage(e))
  hit <- any(grepl("a_setting_nobody_decided_about", planted, fixed = TRUE))
  cat(sprintf("  %s %s\n", if (hit) "ok   " else "FAIL ",
              "an engine setting bound to nothing is refused"))
  if (!hit) fails <- fails + 1L
  # ...and the mirror: a binding pointing at a setting the engine dropped.
  gone <- any(grepl("no longer", planted, fixed = TRUE))
  cat(sprintf("  %s %s\n", if (gone) "ok   " else "FAIL ",
              "...as is a binding the engine no longer ships"))
  if (!gone) fails <- fails + 1L
  unlink(tmp)
  if (fails) { cat(fails, "self-test case(s) did not fail as they must\n"); quit(status = 1L) }
  cat("self-test: every planted violation was caught\n")
}

# ---- Main -----------------------------------------------------------------

if ("--selftest" %in% args) { selftest(); quit(status = 0L) }

files <- list.files(CONTRACT_DIR, pattern = "\\.yaml$", full.names = TRUE)
if (!length(files)) { cat("no contracts found in ", CONTRACT_DIR, "\n"); quit(status = 1L) }
total_bad <- 0L
for (f in files) {
  bad <- validate_file(f)
  if (length(bad)) {
    total_bad <- total_bad + length(bad)
    cat("FAIL ", basename(f), "\n"); for (b in bad) cat("   - ", b, "\n")
  } else {
    cat("ok   ", basename(f), "\n")
  }
}
if (total_bad) { cat("\n", total_bad, " problem(s)\n", sep = ""); quit(status = 1L) }
cat("\nall contracts valid\n")
