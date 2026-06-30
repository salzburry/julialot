#!/usr/bin/env Rscript
# Unit tests for the reusable cohort-explorer engine (base R + optional
# survival). Run:  Rscript cohort_explorer/tests/test_engine.R
# Exits non-zero if any assertion fails.

.here <- tryCatch(dirname(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1])),
          error = function(e) ".")
rdir <- normalizePath(file.path(.here, "..", "R"))
for (f in c("criteria_registry.R", "build_flagged_cohort.R", "cohort_select.R",
            "summaries.R", "checks.R", "km.R"))
  source(file.path(rdir, f))

# tiny harness
.n_pass <- 0L; .n_fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { .n_pass <<- .n_pass + 1L; cat("PASS:", msg, "\n") }
  else { .n_fail <<- .n_fail + 1L; cat("FAIL:", msg, "\n") }
}

REG <- criteria_registry(); COH <- cohort_definitions()
VARDICT <- variable_dictionary()
df  <- synth_flagged_cohort(n = 2000L, seed = 7L)

# ---- flagged cohort contract ----
ok(tryCatch({ validate_flagged_cohort(df); TRUE }, error = function(e) FALSE),
   "synthetic flagged cohort passes the schema/flag validation")
ok(!anyDuplicated(df$patient_id), "patient_id is unique")
ok(all(unlist(df[registry_flag_ids(REG)]) %in% c(0L, 1L)),
   "all flag columns are strictly 0/1")
ok(all(grepl("^9", df$patient_id)), "synthetic PATIDs use the reserved 9b range")

# ---- selection: Overall ----
ov <- select_cohort(df, COH$overall$active_flags, reg = REG)
ok(ov$n_out > 0 && ov$n_out <= ov$n_in, "Overall selection is a non-empty subset")
ok(all(diff(ov$attrition$n_remaining) <= 0),
   "attrition is monotone non-increasing")
ok(ov$attrition$n_remaining[1] == nrow(df), "attrition starts at the superset N")
ok(tail(ov$attrition$n_remaining, 1) == ov$n_out,
   "attrition ends at the selected N")

# ---- selection: NDMM is a subset of (or equal to) Overall-ish, and tighter ----
nd <- select_cohort(df, COH$ndmm$active_flags, reg = REG)
ok(nd$n_out <= ov$n_out, "NDMM (more criteria) selects <= Overall")

# ---- toggling a criterion off never shrinks the cohort ----
ov_minus <- select_cohort(df, setdiff(COH$overall$active_flags, "incl_new_user"),
                          reg = REG)
ok(ov_minus$n_out >= ov$n_out, "dropping a criterion does not shrink the cohort")

# ---- param filters ----
age <- select_cohort(df, character(), list(flt_age = c(70, 80)),
                     active_params = "flt_age", reg = REG)
ok(all(age$data$age_index >= 70 & age$data$age_index <= 80),
   "age range filter restricts age_index correctly")
gen <- select_cohort(df, character(), list(flt_gender = "Female"),
                     active_params = "flt_gender", reg = REG)
ok(all(gen$data$gender == "Female"), "categorical gender filter works")
empty_cat <- select_cohort(df, character(), list(flt_gender = character(0)),
                           active_params = "flt_gender", reg = REG)
ok(empty_cat$n_out == nrow(df), "empty categorical selection = no restriction")

# ---- summaries ----
sc <- summarize_categorical(df, c("gender", "region"), strata = "payer_type", VARDICT)
ok(!is.null(sc) && "Overall N" %in% names(sc), "categorical summary has Overall N")
ok(all(c("Female", "Male") %in% sc$Category[sc$Variable == "Gender"]),
   "categorical summary enumerates gender levels")
sk <- summarize_continuous(df, c("age_index"), strata = NULL, VARDICT)
ok(!is.null(sk) && "Median" %in% names(sk), "continuous summary has Median")

# ---- checks: synthetic cohort is internally consistent ----
lc <- lot_checks(ov$data, max_lot = 5L)
ok(all(lc$Status != "FAIL"), "LOT structural checks have no FAIL on synthetic")
nc <- ndmm_protocol_checks(nd$data, COH$ndmm$active_flags, REG)
active_rows <- nc$Check %in% vapply(COH$ndmm$active_flags,
                                    function(i) REG[[i]]$label, character(1))
ok(all(nc$Status[active_rows] == "PASS"),
   "every ACTIVE NDMM criterion is 100% satisfied in the selected cohort")
ok(nc$Status[nc$Check == "12m baseline CE subset of 6m CE"] == "PASS",
   "12m-CE-subset-of-6m-CE invariant holds")

# ---- KM (optional) ----
if (requireNamespace("survival", quietly = TRUE)) {
  k <- km_fit(ov$data, "rwOS")
  ok(!is.null(k) && k$n > 0, "km_fit returns a fit for rwOS")
  ok(!is.null(km_medians(k)) && "Median" %in% names(km_medians(k)),
     "km_medians returns a median table")
  ks <- km_fit(ov$data, "rwPFS", strata = "gender")
  ok(!is.null(km_risk_table(ks)), "km_risk_table works with strata")
} else cat("SKIP: survival not installed — KM tests skipped\n")

cat(sprintf("\n%d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0) quit(status = 1L)
