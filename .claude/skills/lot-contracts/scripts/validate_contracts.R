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

# The myeloma pin: this contract IS the engine's shipped behavior, so these
# values must match Jul 28/lot/engine's defaults. Change the engine and this table in
# the same commit, or the validator - correctly - refuses.
MYELOMA_PIN <- list(
  c("observation", "censor_at_disenrollment") , FALSE,
  c("episodes", "medical_day_supply")         , 28L,
  c("episodes", "pharmacy_missing_day_supply"), 28L,
  c("episodes", "map_discon_gap_days")        , 90L,
  c("lines", "max_lot")                       , 5L,
  c("lines", "regimen_window_days_line1")     , 60L,
  c("lines", "regimen_window_days_later")     , 30L,
  c("advancement", "same_regimen_gap_days")   , "none",
  c("event_streams", "AUTO", "claim_window_days")   , 13L,
  c("event_streams", "AUTO", "merge_gap_days")      , 60L,
  c("event_streams", "AUTO", "tandem_max_gap_days") , 180L,
  c("event_streams", "CART", "consolidation_days")  , 45L,
  c("event_streams", "CART", "bridging_med_add_days"), 45L,
  c("event_streams", "ALLO", "line_span")     , "single_day",
  c("drug_roles", "supportive_classes")       , "STEROID",
  c("lines", "end_priority") ,
    c("SCT_ALLO", "SCT_CART", "SCT_AUTO", "CART_INIT", "MED_ADD",
      "DEATH", "DISCONTINUATION", "STUDY_END")
)

check_myeloma_pin <- function(doc) {
  bad <- character(0)
  for (i in seq(1, length(MYELOMA_PIN), by = 2)) {
    path <- MYELOMA_PIN[[i]]; want <- MYELOMA_PIN[[i + 1]]
    got <- get_path(doc, path)
    if (!identical(got, want))
      bad <- c(bad, paste0(paste(path, collapse = "."), ": contract says '",
                           paste(got, collapse = " "), "', engine ships '",
                           paste(want, collapse = " "), "'"))
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
    bad <- c(bad, check_myeloma_pin(doc))
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
