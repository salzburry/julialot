# What the dashboard shows. This file is the dashboard.
#
# Same shape as reporting/dashboard/R/sections.R: every panel is one entry - a
# name, a tab, a label, the table it reads and how to draw it. Adding a panel
# is adding an entry. The difference is what a panel reads: there it is SQL
# against a finished LOT run, here it is one of the study package's own S_*
# tables, so the panel says which table and the renderer works out the rest
# from TABLE_SPEC.
#
# The switch is SHOW_<NAME>, from the environment. Anything but TRUE or FALSE
# stops startup: a typo that drops a panel silently is worse than a halt,
# because the page still renders and nobody can see what is missing.

PANEL_RENDER <- c("table", "kpi", "bar", "km", "delta", "flow", "funnel")

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
       table = NA_character_)
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
resolve_panels <- function(scenario, panels = PANELS, tables = DASH_TABLES) {
  lapply(Filter(panel_enabled, panels), function(p) {
    if (is.na(p$table) || identical(p$table, "S_RUN_METADATA")) {
      p$available <- TRUE; return(p)
    }
    mod <- tables$MODULE[match(p$table, tables$TABLE)]
    ran <- !is.na(mod) && mod %in% scenario$modules
    p$available <- isTRUE(ran)
    p$why <- if (p$available) "" else if (is.na(mod))
      sprintf("%s is not a table this package writes.", p$table)
    else sprintf("The '%s' module did not run in this scenario, so %s is empty.",
                 mod, p$table)
    p
  })
}
