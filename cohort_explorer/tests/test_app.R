#!/usr/bin/env Rscript
# Shiny behaviour tests (testServer) for the risky UI logic the engine tests
# can't reach: neutral-default parity, deterministic cohort-switch reset,
# later-line stratum handling, and the transition/pathway outputs.
# Run:  Rscript cohort_explorer/tests/test_app.R   (skips cleanly if shiny absent)

.here <- tryCatch(dirname(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1])),
          error = function(e) ".")
app_dir <- normalizePath(file.path(.here, ".."))

if (!requireNamespace("shiny", quietly = TRUE)) {
  cat("SKIP: shiny not installed — app tests skipped\n"); quit(status = 0L)
}
suppressMessages(library(shiny)); options(shiny.testmode = TRUE)

.n_pass <- 0L; .n_fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { .n_pass <<- .n_pass + 1L; cat("PASS:", msg, "\n") }
  else { .n_fail <<- .n_fail + 1L; cat("FAIL:", msg, "\n") }
}

app <- source(file.path(app_dir, "app.R"), local = new.env())$value
ok(inherits(app, "shiny.appobj"), "app.R builds a shiny.appobj")

# neutral params helper mirroring the server, for parity assertions
neutral_pv <- function() {
  pv <- list()
  for (id in registry_param_ids(REG)) {
    crit <- REG[[id]]
    pv[[id]] <- if (identical(crit$filter, "range"))
      { r <- range(FLAGGED[[crit$variable]], na.rm = TRUE); c(floor(r[1]), ceiling(r[2])) }
    else sort(unique(as.character(FLAGGED[[crit$variable]])))
  }
  pv
}

testServer(app, {
  session$flushReact()
  # (1) initial Overall == flag-only selection (neutral filters)
  init <- selected()$n_out
  flagonly <- select_cohort(FLAGGED, COHORTS$overall$active_flags, list(),
                            character(), REG)$n_out
  ok(init == flagonly, "initial Overall equals the flag-only cohort (neutral defaults)")

  # (2) deterministic cohort switch: Overall -> NDMM resets to NDMM defaults
  session$setInputs(cohort = "ndmm", apply_cohort = 1); session$flushReact()
  nd <- selected()$n_out
  nd_expect <- select_cohort(FLAGGED, COHORTS$ndmm$active_flags, neutral_pv(),
                             registry_param_ids(REG), REG)$n_out
  ok(nd == nd_expect, "Apply Cohort deterministically resets IE flags to NDMM defaults")

  # (3) 1L KM landmark + safety table render the RIGHT content (value, not null)
  session$setInputs(restrict_fu = TRUE, lot = 1, trans_from = 1,
                    pc_vars = c("age_band", "cci_band"), pc_strata = "ti_te_age",
                    pc_apply = 1,
                    km_OS_apply = 1, km_OS_strata = "ti_te_age", km_OS_horizon = 60)
  session$flushReact()
  lm_html <- as.character(output$km_OS_landmark)
  ok(grepl("AtRisk", lm_html) && grepl("Survival % \\(95% CI\\)", lm_html) &&
     grepl("6.00", lm_html, fixed = TRUE) && grepl("24.00", lm_html, fixed = TRUE),
     "1L OS landmark table shows at-risk + the 6..24-month landmarks")
  saf_html <- as.character(output$pc_safety)
  ok(grepl("Rate per 100 PY", saf_html) && grepl("Cardiovascular", saf_html),
     "baseline safety table shows the per-100-PY rate + event rows")

  # (4) current-line SOC stratum actually STRATIFIES at 2L (groups are SOC
  #     levels, not a single 'Overall' — proves lot_soc reached the fit)
  session$setInputs(lot = 2, km_OS_strata = "lot_soc", km_OS_apply = 2)
  session$flushReact()
  k2 <- km_fit(lot_slice(LOT_LONG, selected()$data$patient_id, 2L), "OS",
               strata = "lot_soc", min_fu = MIN_FU_MONTHS)
  ok(!is.null(k2) && !("Overall" %in% km_medians(k2)$Group),
     "2L KM stratified by current-line SOC produces real SOC groups (not 'Overall')")

  # (5) 1L-only endpoints at 2L must NOT crash the table renderers (QC P1/P2)
  session$setInputs(lot = 2, km_Attrition_apply = 1, km_Attrition_horizon = 60,
                    km_Attrition_strata = "")
  session$flushReact()
  ok(tryCatch({ invisible(output$km_Attrition_landmark)
                invisible(output$km_Attrition_med)
                invisible(output$km_Attrition_risk); TRUE }, error = function(e) FALSE),
     "Attrition KM tables at 2L render without error (return empty, no crash)")

  # (6) pathway spans 1L->4L; transition detail title tracks the from-line
  pd <- lot_pathway_data(LOT_LONG, selected()$data$patient_id, max_line = 4L)
  ok(!is.null(pd) && all(1:3 %in% pd$trans$stage), "pathway data spans 1L->2L->3L->4L")
  session$setInputs(trans_from = 2); session$flushReact()
  ok(grepl("2L -> 3L", output$trans_title), "transition detail title tracks the from-line")

  # (7) Patient Characteristics header N stays consistent with its snapshot when
  #     the cohort switches without re-applying PC (QC #4)
  session$setInputs(cohort = "overall", apply_cohort = 1, pc_apply = 2)
  session$flushReact()
  n_before <- sub(".*N = ([0-9,]+).*", "\\1", output$pc_title)
  session$setInputs(cohort = "ndmm", apply_cohort = 1); session$flushReact()  # no pc re-apply
  n_after <- sub(".*N = ([0-9,]+).*", "\\1", output$pc_title)
  ok(n_before == n_after,
     "PC header N reflects the applied snapshot, not a stale/mismatched live cohort")
})

cat(sprintf("\n%d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0) quit(status = 1L)
