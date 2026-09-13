# What the dashboard shows. This file is the dashboard.
#
# Every panel is one entry - a name, a tab, a label, the table it reads and how
# to draw it - so adding a panel is adding an entry. A panel names one of the
# study package's S_* tables and the renderer works the rest out from
# TABLE_SPEC.
#
# The switch is SHOW_<NAME>, from the environment. Anything but TRUE or FALSE
# stops startup: a typo that drops a panel silently leaves a page that still
# renders, with nobody able to see what is missing.

PANEL_RENDER <- c("table", "kpi", "bar", "km", "delta", "flow", "funnel",
                  "check", "sequence")

# A panel reads either what this package wrote or what the LOT build wrote.
# The difference is not cosmetic: a study scenario records which LOT run it
# read, several scenarios normally share one, and a LOT panel therefore
# describes a scenario's lineage rather than the scenario.
PANEL_SOURCE <- c("study", "lot")

PANELS <- list(
  list(name = "provenance", tab = "Overview", render = "table",
       label = "What produced these numbers",
       table = "S_RUN_METADATA",
       note = paste("The run behind every number on this page: which cohorts,",
                    "which modules, which LOT run, and its answer to each open",
                    "question.")),

  list(name = "headline", tab = "Overview", render = "kpi",
       label = "Cohort sizes", table = "S_ATTRITION"),

  list(name = "attrition", tab = "Overview", render = "funnel",
       label = "Attrition, criterion by criterion", table = "S_ATTRITION",
       note = paste("One step per criterion, in the order the package applies",
                    "them. N_LOST is what that step removed, not what failed",
                    "it - a patient failing two criteria is lost at the first.")),

  list(name = "demographics", tab = "Cohort", render = "table",
       label = "Baseline demographics", table = "S_DEMOGRAPHICS"),

  list(name = "comorbidity", tab = "Cohort", render = "table",
       label = "Charlson comorbidity", table = "S_COMORBIDITY"),

  list(name = "periods", tab = "Cohort", render = "table",
       label = "Baseline and follow-up", table = "S_PERIODS"),

  list(name = "safety_rates", tab = "Safety", render = "bar",
       label = "Key safety events", table = "S_SAFETY_RATES",
       note = paste("Rates per 1,000 person-years. A chronic condition is",
                    "counted once and patients with it before the window are",
                    "out of both the numerator and the denominator; an acute",
                    "one is counted again after a 30-day washout.")),

  list(name = "safety_table", tab = "Safety", render = "table",
       label = "Key safety events, as a table", table = "S_SAFETY_RATES"),

  list(name = "hcru_rates", tab = "HCRU", render = "bar",
       label = "Hospitalisation, length of stay and ED visits",
       table = "S_HCRU_RATES",
       note = paste("Which route decides that a stay is MM-related is open",
                    "question Q27, and the two answers differ by a factor of",
                    "two. It is a scenario setting, not a filter - compare two",
                    "runs to see it.")),

  list(name = "hcru_table", tab = "HCRU", render = "table",
       label = "HCRU, as a table", table = "S_HCRU_RATES"),

  list(name = "malignancy_rates", tab = "Malignancy", render = "bar",
       label = "Secondary malignancies", table = "S_MALIGNANCY_RATES"),

  list(name = "malignancy_table", tab = "Malignancy", render = "table",
       label = "Secondary malignancies, as a table",
       table = "S_MALIGNANCY_RATES"),

  list(name = "tte_km", tab = "Outcomes", render = "km",
       label = "TTNT, TTD and overall survival", table = "S_TTE",
       note = paste("Only patients with at least three months of potential",
                    "follow-up, or who died inside it, are in the analysis",
                    "set. OS in claims is death of any cause.")),

  list(name = "tte_table", tab = "Outcomes", render = "table",
       label = "Endpoints, as a table", table = "S_TTE"),

  list(name = "patterns", tab = "Patterns", render = "bar",
       label = "Regimen categories by line", table = "S_PATTERNS"),

  list(name = "tx_attrition", tab = "Patterns", render = "bar",
       label = "What happened on each line", table = "S_TX_ATTRITION"),

  list(name = "switch", tab = "Patterns", render = "flow",
       label = "Regimen transitions", table = "S_SWITCH"),

  list(name = "compare", tab = "Compare", render = "delta",
       label = "One scenario against another", table = NA_character_,
       note = paste("Pick two runs. The settings that differ are listed, and",
                    "every measure is shown under both with the difference.")),

  list(name = "settings", tab = "Compare", render = "table",
       label = "Every open question, and where it is answered",
       table = NA_character_),

  # --- the LOT engine ------------------------------------------------------
  #
  # These describe the run this scenario READ, not the scenario. Scenarios
  # sharing a LOT run show identical numbers here, which is the truth: none of
  # this package's open questions changes how a line is counted.

  list(name = "lot_provenance", tab = "LOT engine", render = "table",
       source = "lot", label = "The LOT run these lines came from",
       table = "LOT_RUN_METADATA",
       note = paste("Every study scenario names the LOT run it read. Two",
                    "scenarios sharing one rest on the same lines.")),

  list(name = "lot_attrition", tab = "LOT engine", render = "funnel",
       source = "lot", label = "LOT funnel: cohort to study population",
       table = "LOT_ATTRITION",
       note = paste("Starts where the cohort funnel ends. Rows marked",
                    "'progression' remove nobody - they count who reached a",
                    "later line - and 'reconciliation' rows re-derive what the",
                    "cohort build already established, so a drop there means",
                    "the two scans disagree.")),

  list(name = "lot_lines", tab = "LOT engine", render = "bar",
       source = "lot", label = "Lines built, by line number",
       table = "LOT_LONG_FINAL"),

  # Line against the next line. The per-line panels cannot show that a
  # line ending by running out was followed the next day by an allograft
  # line, or that a CAR-T consolidation end has no CAR-T start behind it;
  # these can. The `view` names which of the three line-to-line views
  # (R/aggregate.R, lot_sequence_view) the panel draws.
  list(name = "lot_end_to_start", tab = "LOT engine", render = "sequence",
       source = "lot", label = "How a line ended, against how the next one opened",
       table = "LOT_LONG_FINAL", view = "end_to_start",
       note = paste("One row per pair of consecutive lines of one patient:",
                    "the reason line n ended, and what opened line n+1.",
                    "A DISCONTINUATION followed by a transplant-opened line,",
                    "or a CART_INIT end not followed by a CART start, is a",
                    "pair to question. Pick a line in the sidebar to see",
                    "the pairs from that line only.")),
  list(name = "lot_sequences", tab = "LOT engine", render = "sequence",
       source = "lot", label = "The commonest line sequences",
       table = "LOT_LONG_FINAL", view = "sequences",
       note = paste("What opened each of a patient's lines, in order, as one",
                    "sequence per patient - MED > SCT_AUTO > MED is a",
                    "medication first line, a transplant-opened second and",
                    "a new agent third. Rare sequences are folded into one",
                    "row.")),
  list(name = "lot_regimen_pairs", tab = "LOT engine", render = "sequence",
       source = "lot", label = "Regimen of a line, against the regimen of the next",
       table = "LOT_LONG_FINAL", view = "regimen",
       note = paste("The agents of line n beside the agents of line n+1, for",
                    "the pairs common enough to show. A regimen returning in",
                    "full one line later is the fold-in and re-challenge",
                    "rules at work, and this is where to look at them.")),

  list(name = "lot_start_types", tab = "LOT engine", render = "bar",
       source = "lot", label = "What opened each line", table = "LOT_LONG_FINAL",
       by = "LOT_START_TYPE",
       note = paste("A line opens on a new agent (MED), a qualifying",
                    "transplant, or CAR-T. The transplant and CAR-T types are",
                    "the ones the protocol names as starting a subsequent",
                    "line.")),

  list(name = "lot_end_reasons", tab = "LOT engine", render = "bar",
       source = "lot", label = "How each line ended", table = "LOT_LONG_FINAL",
       by = "LOT_BASE_END_REASON"),

  list(name = "lot_table", tab = "LOT engine", render = "table",
       source = "lot", label = "Lines, as a table", table = "LOT_LONG_FINAL"),

  list(name = "lot_face_validity", tab = "LOT validation", render = "check",
       source = "lot", label = "Face validity", table = "LOT_FACE_VALIDITY",
       note = paste("Each check records what it found and the range expected.",
                    "A value outside its range is a LOOK, not a failure - the",
                    "number is the point, not the verdict. No value is not a",
                    "pass.")),

  list(name = "lot_qc", tab = "LOT validation", render = "check",
       source = "lot", label = "QC checks", table = "LOT_QC_SUMMARY"),

  list(name = "lot_status", tab = "LOT validation", render = "table",
       source = "lot", label = "Build status", table = "LOT_BUILD_STATUS",
       note = paste("A run this package would read has to be 'complete' and",
                    "carry no contract deviation. The study package refuses",
                    "one that is not, so a scenario existing at all means this",
                    "passed when it was built.")),

  list(name = "lot_before_after", tab = "LOT validation", render = "table",
       source = "lot", label = "Before and after the line criteria",
       table = "LOT_LONG",
       note = paste("LOT_LONG is the same table before the line criteria.",
                    "A truncate criterion makes the two hold different",
                    "patients, so a panel drawn on it describes people the",
                    "study excluded - which is why it is only here, where the",
                    "comparison is the point."))
)

PANEL_TABS <- function(panels = PANELS)
  unique(vapply(panels, `[[`, character(1), "tab"))

# SHOW_<NAME> decides whether a panel is offered. Unset means shown.
panel_enabled <- function(p) {
  v <- toupper(trimws(Sys.getenv(paste0("SHOW_", toupper(p$name)), unset = "")))
  if (!nzchar(v)) return(TRUE)
  if (!v %in% c("TRUE", "FALSE"))
    stop("DASHBOARD ERROR: SHOW_", toupper(p$name), "='", v,
         "' is neither TRUE nor FALSE. A panel dropped by a typo is invisible ",
         "on the page, so this stops instead.", call. = FALSE)
  identical(v, "TRUE")
}

# The panels a run can actually draw: enabled, and reading a table this
# scenario's modules wrote. A panel whose table is missing is REPORTED, not
# hidden - "the safety module did not run" is a thing a viewer needs to know,
# and a silently absent tab does not say it.
resolve_panels <- function(scenario, panels = PANELS, src = NULL) {
  # Several LOT panels read one table; whether it can be reached is asked
  # once per table per resolve, not once per panel.
  reached <- new.env(parent = emptyenv())
  lot_reachable <- function(table) {
    if (is.null(reached[[table]]))
      reached[[table]] <- !is.null(src) && isTRUE(tryCatch({
        got <- read_lot_table(src, scenario, table)
        !is.null(got) && nrow(got) > 0
      }, error = function(e) FALSE))
    reached[[table]]
  }
  lapply(Filter(panel_enabled, panels), function(p) {
    p$source <- p$source %||% "study"
    if (is.na(p$table)) { p$available <- TRUE; return(p) }
    # A LOT panel does not depend on which modules this package ran. It depends
    # on the scenario naming a LOT run, and on this source being able to reach
    # that run's tables. Both failures are reported, and they are different:
    # "no LOT run recorded" is a lineage problem, "not exported" is a
    # deployment one.
    if (identical(p$source, "lot")) {
      if (!nzchar(scenario$lot_run_id %||% "")) {
        p$available <- FALSE
        p$why <- paste("This scenario records no LOT run, so there are no",
                       "lines to describe. A run built over an unproven",
                       "lineage reads as 'unproven' here.")
        return(p)
      }
      p$available <- lot_reachable(p$table)
      p$why <- if (p$available) "" else sprintf(
        paste("LOT run '%s' is recorded, but %s could not be read from this",
              "source. For a snapshot, jobs/build_scenarios.R exports LOT",
              "tables to lot/<run id>/; for the warehouse, set",
              "DASH_LOT_PREFIX."),
        scenario$lot_run_id, p$table)
      return(p)
    }
    # A study table: the same verdict the reader gives, in the same words -
    # reported, not hidden. The metadata panel always shows, because what the
    # run set out to do is exactly what a viewer needs to see.
    st <- scenario_table_status(scenario, p$table)
    p$available <- st$ok
    p$why <- st$why
    p
  })
}
