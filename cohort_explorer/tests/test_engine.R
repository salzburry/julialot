#!/usr/bin/env Rscript
# Unit tests for the reusable cohort-explorer engine (base R + optional
# survival). Run:  Rscript cohort_explorer/tests/test_engine.R
# Exits non-zero if any assertion fails.

.here <- tryCatch(dirname(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1])),
          error = function(e) ".")
rdir <- normalizePath(file.path(.here, "..", "R"))
for (f in c("criteria_registry.R", "build_flagged_cohort.R", "cohort_select.R",
            "summaries.R", "checks.R", "km.R", "lot_views.R"))
  source(file.path(rdir, f))

# tiny harness
.n_pass <- 0L; .n_fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { .n_pass <<- .n_pass + 1L; cat("PASS:", msg, "\n") }
  else { .n_fail <<- .n_fail + 1L; cat("FAIL:", msg, "\n") }
}

REG <- criteria_registry(); COH <- cohort_definitions()
VARDICT <- variable_dictionary()
df  <- load_flagged_cohort("synthetic", n = 2000L, seed = 7L)

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
ok(all(c("Female", "Male") %in% sc$Category[sc$Variable == "Sex"]),
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

# ---- new characteristics + suppression ----
ok(all(c("age_band","age_ge70","cci_band","ti_te_age","ti_te_age_cci",
         "ip_hosp_band") %in% names(df)), "derived subgroup columns are present")
sc_bin <- summarize_categorical(df, c("bl_cv"), strata = NULL, VARDICT)
ok(all(c("Yes","No") %in% sc_bin$Category), "binary comorbidity renders Yes/No")
# force a tiny stratum to confirm <25 suppression drops it
tiny <- df; tiny$region[1:15] <- "TINYREG"; tiny <- tiny[c(1:15, 100:nrow(tiny)), ]
sc_sup <- summarize_categorical(tiny, c("gender"), strata = "region", VARDICT)
ok("TINYREG" %in% attr(sc_sup, "suppressed"), "<25-patient stratum is suppressed")
ok(!any(grepl("TINYREG", names(sc_sup))), "suppressed stratum has no column")

# ---- LOT-long + regimen/transitions ----
ll <- synth_lot_long(df)
ok(nrow(ll) == sum(df$n_lines), "LOT-long has one row per patient-line")
ok(all(c("lot_soc","next_soc","ttd_time") %in% names(ll)), "LOT-long has SOC + TTE cols")
rf <- regimen_frequency(ll, df$patient_id, 2L)
ok(!is.null(rf) && sum(rf$N) == sum(df$n_lines >= 2L), "2L regimen freq totals reaching-2L patients")
tr <- lot_transition_table(ll, df$patient_id, 1L)
ok(!is.null(tr) && all(c("From","To","Freq") %in% names(tr)), "1L->2L transition table built")

# ---- review fix #1: default filters are neutral ----
neutral_pv <- list()
for (id in registry_param_ids(REG)) {
  crit <- REG[[id]]
  neutral_pv[[id]] <- if (identical(crit$filter, "range"))
    range(df[[crit$variable]], na.rm = TRUE)
  else sort(unique(as.character(df[[crit$variable]])))
}
ov_np <- select_cohort(df, COH$overall$active_flags, neutral_pv,
                       registry_param_ids(REG), REG)
ok(ov_np$n_out == ov$n_out,
   "neutral param filters do not shrink the cohort (Overall == flag-only)")
ok(is.null(REG$flt_payer$default) && is.null(REG$flt_age$default),
   "payer/age defaults are NULL (no silent Medicare / age>90 drop)")

# ---- review fix #9: potential follow-up is death-independent ----
early_death_kept <- sum(df$os_time < 3 & df$os_event == 1L & df$fu_potential_months >= 3)
ok(early_death_kept > 0, "early deaths (<3mo) are retained by the >=3-mo cut")

# ---- review fix: validate_lot_long ----
ok(tryCatch({ validate_lot_long(ll); TRUE }, error = function(e) FALSE),
   "synthetic LOT-long passes validation")
bad_ll <- ll; bad_ll$os_event[1] <- 5L
ok(tryCatch({ validate_lot_long(bad_ll); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects a non-0/1 event")

# ---- review fix #4: baseline strata carried onto LOT-long ----
llx <- augment_lot_long(ll, df)
ok(all(c("ti_te_age", "cci_band", "bl_cv") %in% names(llx)),
   "augment_lot_long carries baseline strata forward for later-line KM")

# ---- review round 2: LOT-long contract completeness + pathway ----
ok(all(c("next_soc", "payer_type") %in% LOT_LONG_REQUIRED_COLS),
   "LOT-long contract requires next_soc + payer_type (downstream deps)")
ll_no_next <- ll; ll_no_next$next_soc <- NULL
ok(tryCatch({ validate_lot_long(ll_no_next); FALSE }, error = function(e) TRUE),
   "validate_lot_long now rejects a table missing next_soc")
.tmp <- tempfile(fileext = ".csv"); .w <- ll; .w$next_soc <- NULL
write.csv(.w, .tmp, row.names = FALSE)
ok(tryCatch({ load_lot_long(.tmp); TRUE }, error = function(e) FALSE),
   "load_lot_long derives next_soc for a CSV lacking it, then validates")
ok("lot_soc" %in% names(variable_dictionary()) && "lot_soc" %in% names(df),
   "current-line SOC (lot_soc) is available as a stratum at patient + line level")
ok(any(ll$os_time < ll$fu_potential_months),
   "synthetic LOT-long follow-up is death-independent (os_time can be < fu_potential)")
pd <- lot_pathway_data(augment_lot_long(ll, df), df$patient_id, max_line = 4L)
ok(!is.null(pd) && all(sort(unique(pd$trans$stage)) == 1:3),
   "lot_pathway_data yields the full 1L->2L->3L->4L journey")
if (requireNamespace("survival", quietly = TRUE)) {
  LM <- c(6, 9, 12, 18, 24)                     # all five protocol landmarks
  dd <- data.frame(t = ov$data$os_time, e = ov$data$os_event)
  dd <- dd[ov$data$fu_potential_months >= 3, ]
  fit <- survival::survfit(survival::Surv(t, e) ~ 1, data = dd)
  ss <- summary(fit, times = LM, extend = TRUE)
  km_ev  <- cumsum(ss$n.event);  km_ce <- cumsum(ss$n.censor)
  true_ev <- sapply(LM, function(tt) sum(dd$t <= tt & dd$e == 1))
  true_ce <- sapply(LM, function(tt) sum(dd$t <= tt & dd$e == 0))
  ok(all(km_ev == true_ev), "landmark cumulative EVENTS == ground truth (all 5)")
  ok(all(km_ce == true_ce), "landmark cumulative CENSORED == ground truth (all 5)")
  # stratified: per-group cumulative events match ground truth too
  os_strat <- km_fit(ov$data, "OS", strata = "ti_te_age", min_fu = 3)
  lmk <- km_landmark(os_strat)
  ok(all(LM %in% lmk$Month) && all(c("AtRisk","Events","Censored") %in% names(lmk)) &&
       length(unique(lmk$Group)) == 2,
     "km_landmark: stratified, all 5 landmarks, with at-risk/events/censored")
}

# ---- review round 3: consistency + type-safety + coverage + count validation ----
bad_next <- ll; bad_next$next_soc <- "WRONG"
ok(tryCatch({ validate_lot_long(bad_next); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects next_soc inconsistent with the SOC sequence")
dbl_ln <- ll; dbl_ln$lot_num <- as.numeric(dbl_ln$lot_num)
ok(tryCatch({ validate_lot_long(dbl_ln); TRUE }, error = function(e) FALSE),
   "validate_lot_long accepts integer-VALUED numeric lot_num (DBI/CSV type-safe)")
frac_ln <- ll; frac_ln$lot_num[1] <- 1.5
ok(tryCatch({ validate_lot_long(frac_ln); FALSE }, error = function(e) TRUE),
   "validate_lot_long still rejects a non-integer lot_num")
bad_cnt <- df; bad_cnt$n_cv[1] <- -1L
ok(tryCatch({ validate_flagged_cohort(bad_cnt); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects a negative safety count")
bad_py <- df; bad_py$baseline_py[1] <- 0
ok(tryCatch({ validate_flagged_cohort(bad_py); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects non-positive baseline_py")
ll_gap <- ll[!(ll$patient_id %in% df$patient_id[1:5]), ]
ok(tryCatch({ load_lot_long(function() ll_gap, cohort = df); FALSE },
            error = function(e) TRUE),
   "load_lot_long rejects LOT-long missing flagged patients (no silent undercount)")
llx2 <- augment_lot_long(ll, df)
ok(all(c("age_ge70","ip_hosp_band","bl_hepatic","soc_category") %in% names(llx2)),
   "augment carries ALL advertised strata onto LOT-long (no silent 2L/3L gaps)")

# ---- review fix #7: safety-event rates per PY ----
sb <- safety_baseline_table(df)
ok(!is.null(sb) && "Rate per 100 PY" %in% names(sb) && nrow(sb) == 6,
   "safety_baseline_table reports 6 events with rate per 100 PY")

# ---- review fix #2: warehouse source fails closed ----
ok(tryCatch({ source_flagged_cohort_warehouse(); FALSE }, error = function(e) TRUE),
   "source_flagged_cohort_warehouse() fails closed (not implemented)")

# ---- protocol DQ checks ----
dq <- protocol_dq_checks(ov$data)
ok(any(grepl("TTE denominator", dq$Check)), "DQ reports the >=3-mo TTE denominator")

# ---- KM (optional) ----
if (requireNamespace("survival", quietly = TRUE)) {
  for (ep in c("OS","TTD","TTNT","Attrition","PFS_exploratory")) {
    k <- km_fit(ov$data, ep, min_fu = if (ep == "Attrition") NULL else 3)
    ok(!is.null(k) && k$n > 0, paste0("km_fit returns a fit for ", ep))
  }
  k <- km_fit(ov$data, "OS", strata = "ti_te_age", min_fu = 3)
  lm <- km_landmark(k)
  ok(!is.null(lm) && all(c("Group","Month","AtRisk","Events","Censored") %in% names(lm)) &&
       all(c(6,9,12,18,24) %in% lm$Month),
     "km_landmark reports at-risk/events/censored at 6/9/12/18/24 months")
  ok(nrow(km_medians(k)) == 2, "stratified median table has one row per stratum")
  # per-LOT KM off the LOT-long slice
  k2 <- km_fit(lot_slice(ll, ov$data$patient_id, 2L), "TTD", min_fu = 3)
  ok(!is.null(k2) && k2$n > 0, "per-LOT (2L) KM fits off the LOT-long slice")
} else cat("SKIP: survival not installed — KM tests skipped\n")

cat(sprintf("\n%d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0) quit(status = 1L)
