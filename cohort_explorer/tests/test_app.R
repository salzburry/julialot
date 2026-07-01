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

  # (3) 1L KM + landmark render; PC + safety render
  session$setInputs(restrict_fu = TRUE, lot = 1, trans_from = 1,
                    pc_vars = c("age_band", "cci_band"), pc_strata = "ti_te_age",
                    pc_apply = 1,
                    km_OS_apply = 1, km_OS_strata = "ti_te_age", km_OS_horizon = 60)
  session$flushReact()
  ok(!is.null(output$km_OS_landmark), "1L OS landmark table renders")
  ok(!is.null(output$pc_safety), "baseline safety table renders")

  # (4) current-line SOC stratum works at 2L (lot_soc carried onto LOT-long)
  session$setInputs(lot = 2, km_OS_strata = "lot_soc", km_OS_apply = 2)
  session$flushReact()
  ok(!is.null(output$km_OS_plot), "2L KM stratified by current-line SOC renders")

  # (5) pathway Sankey + per-stage transition table render
  session$setInputs(trans_from = 2)
  session$flushReact()
  ok(!is.null(output$sankey), "1L->4L pathway Sankey renders")
  ok(grepl("2L -> 3L", output$trans_title), "transition detail title tracks the from-line")
})

cat(sprintf("\n%d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0) quit(status = 1L)
