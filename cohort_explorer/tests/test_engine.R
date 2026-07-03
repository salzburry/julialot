#!/usr/bin/env Rscript
# Unit tests for the reusable cohort-explorer engine (base R + optional
# survival). Run:  Rscript cohort_explorer/tests/test_engine.R
# Exits non-zero if any assertion fails.

.here <- tryCatch(dirname(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1])),
          error = function(e) ".")
rdir <- normalizePath(file.path(.here, "..", "R"))
for (f in c("indication.R", "criteria_registry.R", "build_flagged_cohort.R",
            "cohort_select.R", "summaries.R", "checks.R", "km.R", "lot_views.R"))
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
ok(all(grepl("^9", df$patient_id)), "synthetic patient ids use the reserved 9b range")

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
  # stratified: per-group cumulative events + censored match ground truth
  os_strat <- km_fit(ov$data, "OS", strata = "ti_te_age", min_fu = 3)
  lmk <- km_landmark(os_strat)
  sub <- ov$data[ov$data$fu_potential_months >= 3, ]
  strat_ok <- length(unique(lmk$Group)) == 2 && all(LM %in% lmk$Month)
  for (g in unique(lmk$Group)) {
    gg <- sub[sub$ti_te_age == g, ]
    lg <- lmk[lmk$Group == g, ]; lg <- lg[order(lg$Month), ]
    te <- sapply(LM, function(tt) sum(gg$os_time <= tt & gg$os_event == 1))
    tc <- sapply(LM, function(tt) sum(gg$os_time <= tt & gg$os_event == 0))
    strat_ok <- strat_ok && all(lg$Events == te) && all(lg$Censored == tc)
  }
  ok(strat_ok,
     "km_landmark: per-group events + censored == ground truth at all 5 landmarks")
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

# ---- review round 4: deeper LOT-long + flag/count consistency ----
tr1 <- derive_next_soc(ll[ll$lot_num == 1L, ])   # only-1L rows, valid internally
ok(tryCatch({ load_lot_long(function() tr1, cohort = df); FALSE },
            error = function(e) TRUE),
   "load_lot_long rejects LOT-long whose line count != n_lines (later-line undercount)")
bc1 <- df; bc1$bl_cv[1] <- 1L; bc1$n_cv[1] <- 0L
bc2 <- df; bc2$bl_renal[1] <- 0L; bc2$n_renal[1] <- 3L
ok(tryCatch({ validate_flagged_cohort(bc1); FALSE }, error = function(e) TRUE) &&
   tryCatch({ validate_flagged_cohort(bc2); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects a safety flag that disagrees with its count")
na_soc <- ll; na_soc$lot_soc[1] <- NA; na_soc <- derive_next_soc(na_soc)
na_pay <- ll; na_pay$payer_type[1] <- NA
ok(tryCatch({ validate_lot_long(na_soc); FALSE }, error = function(e) TRUE) &&
   tryCatch({ validate_lot_long(na_pay); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects missing lot_soc / payer_type")
bt <- ll; bt$ttd_time <- bt$fu_potential_months + 50
ok(tryCatch({ validate_lot_long(bt); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects a TTE beyond potential follow-up")
be <- ll; be$ttnt_event <- 1L
ok(tryCatch({ validate_lot_long(be); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects a TTNT event with no subsequent line")

# ---- review round 5: patient-level TTE + numeric contract + TTNT biconditional ----
pe1 <- df; pe1$os_event[1] <- 5L
pe2 <- df; pe2$ttd_event[1] <- 4L
pe3 <- df; pe3$os_time[1] <- pe3$fu_potential_months[1] + 99
ok(tryCatch({ validate_flagged_cohort(pe1); FALSE }, error = function(e) TRUE) &&
   tryCatch({ validate_flagged_cohort(pe2); FALSE }, error = function(e) TRUE) &&
   tryCatch({ validate_flagged_cohort(pe3); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort validates patient-level TTE (0/1 events, TTE<=follow-up)")
pd1 <- df; pd1$os_event[1] <- 1L; pd1$death_dt[1] <- NA
ok(tryCatch({ validate_flagged_cohort(pd1); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort requires a death_dt when os_event=1")
nl <- df; nl$n_lines[1] <- 1.5
ok(tryCatch({ validate_flagged_cohort(nl); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects a fractional n_lines")
hc <- df; hc$ip_hosp_count[1] <- -2L
ll1 <- df; ll1$lot1_length[1] <- 0
ok(tryCatch({ validate_flagged_cohort(hc); FALSE }, error = function(e) TRUE) &&
   tryCatch({ validate_flagged_cohort(ll1); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects negative HCRU counts and non-positive lot1_length")
dt1 <- df; dt1$index_date[1] <- dt1$lot1_start_dt[1] + 5
ok(tryCatch({ validate_flagged_cohort(dt1); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects index_date after lot1_start_dt")
# TTNT biconditional: event=0 on a non-terminal line must also fail
multi <- names(which(table(ll$patient_id) >= 2))[1]
tb <- ll; tb$ttnt_event[tb$patient_id == multi & tb$lot_num == 1L] <- 0L
ok(tryCatch({ validate_lot_long(tb); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects ttnt_event=0 on a non-terminal line (biconditional)")

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

# ---- review round 6 (QC workflow): correctness + labels + runtime guards ----
# F1 patient-level TTNT biconditional
a1 <- df; a1$ttnt_event[which(a1$n_lines > 1L)[1]] <- 0L
ok(tryCatch({ validate_flagged_cohort(a1); FALSE }, error = function(e) TRUE),
   "validate_flagged_cohort rejects patient-level ttnt_event != (n_lines>1)")
# F2 neutral categorical filter keeps NA rows
b1 <- df; b1$region[1:5] <- NA
fo <- select_cohort(b1, COH$overall$active_flags, list(), character(), REG)$n_out
ne <- select_cohort(b1, COH$overall$active_flags, list(flt_region = cat_levels(b1$region)),
                    "flt_region", REG)$n_out
ok(fo == ne, "a neutral categorical filter does not drop NA-valued rows")
# F4 lot_checks death-date rule matches the validator (death_dt with os_event=0 OK)
e1 <- df; j <- which(e1$os_event == 0)[1]; e1$death_dt[j] <- e1$lot1_start_dt[j] + 100
lc1 <- lot_checks(e1, 5L)
ok(tryCatch({ validate_flagged_cohort(e1); TRUE }, error = function(e) FALSE) &&
   lc1$Status[grepl("Death", lc1$Check)] == "PASS",
   "lot_checks does not FAIL a death_dt+os_event=0 state the validator allows")
# F5 ttnt_time reconciled with next-line gap
g1 <- ll; m1 <- names(which(table(ll$patient_id) >= 2))[1]
g1$ttnt_time[g1$patient_id == m1 & g1$lot_num == 1L] <- 0.3
ok(tryCatch({ validate_lot_long(g1); FALSE }, error = function(e) TRUE),
   "validate_lot_long rejects ttnt_time inconsistent (>2mo) with the next-line gap")

if (requireNamespace("survival", quietly = TRUE)) {
  # QC1 single-surviving stratum keeps the real group label, never 'Overall'
  d2 <- df[1:400, ]; d2$grp2 <- "BIG"; d2$grp2[1:10] <- "TINY"
  km2 <- km_fit(d2, "OS", strata = "grp2")
  ok(km_medians(km2)$Group[1] == "BIG" && km_landmark(km2)$Group[1] == "BIG",
     "single-surviving stratum is labelled by its real name, not 'Overall'")
  # F3 NA stratum becomes an explicit (Missing) group, not dropped
  d3 <- df; d3$gender[1:80] <- NA; k3 <- km_fit(d3, "OS", strata = "gender", min_fu = 3)
  ok("(Missing)" %in% k3$groups, "km_fit keeps NA stratum as an explicit (Missing) group")
  # QC2 table renderers do not crash on the app's 1L-only sentinel (empty list)
  sent <- structure(list(), msg = "1L only")
  ok(is.null(km_medians(sent)) && is.null(km_landmark(sent)) && is.null(km_risk_table(sent)),
     "km_medians/landmark/risk return NULL on the 1L-only sentinel (no 2L/3L crash)")
  # QC8 binary strata render Yes/No consistently
  kbin <- km_fit(df, "OS", strata = "bl_cv")
  scb  <- summarize_categorical(df, "gender", strata = "bl_cv")
  ok(all(c("Yes", "No") %in% kbin$groups) && any(grepl("Yes", names(scb))),
     "binary strata are labelled Yes/No in km and summaries (not 0/1)")
  # QC11 Attrition landmark never prints a malformed 'NA-NA' CI
  lmk_at <- km_landmark(km_fit(df, "Attrition"))
  ok(!any(grepl("NA-NA", lmk_at[["Survival % (95% CI)"]])),
     "Attrition landmark CI is blanked (no 'NA-NA') beyond the last event time")
}

# QC5 'Follow-up from diagnosis' is OBSERVED (dx->1L + observed OS), not potential
ok(isTRUE(all.equal(df$fu_from_dx_months, round(df$dx_to_1l_months + df$os_time, 1))),
   "fu_from_dx_months is observed follow-up, not administrative potential")
# QC9 HCRU counts are summarizable as continuous
sc9 <- summarize_continuous(df, c("ip_hosp_count", "er_visit_count"), NULL, VARDICT)
ok(!is.null(sc9) && nrow(sc9) == 2 && "Median" %in% names(sc9),
   "HCRU counts (hosp/ER) are available as continuous Table-1 stats")
# QC12 commercial-only transitions are strictly fewer than all-payer
tr_c <- lot_transition_table(ll, df$patient_id, 1L, commercial_only = TRUE)
tr_a <- lot_transition_table(ll, df$patient_id, 1L, commercial_only = FALSE)
ok(sum(tr_c$Freq) < sum(tr_a$Freq) &&
   sum(tr_c$Freq) == sum(df$payer_type == "Commercial"),
   "commercial-only transition total < all-payer and equals the commercial-patient count")
# QC13 continuous <25 suppression + suppressed_strata are exercised
tinyc <- df; tinyc$region[1:12] <- "TINYREG"; tinyc <- tinyc[c(1:12, 200:nrow(tinyc)), ]
sk13 <- summarize_continuous(tinyc, "age_index", strata = "region", VARDICT)
ok(!("TINYREG" %in% sk13$Group) && "TINYREG" %in% attr(sk13, "suppressed") &&
   "TINYREG" %in% suppressed_strata(tinyc, "region"),
   "continuous <25 stratum is suppressed and reported by suppressed_strata()")

# ---- round 7: movable thresholds, Cox covariates, A/B compare, Sankey config ----
ok(all(c("baseline_ce_months", "followup_ce_months") %in% names(df)),
   "raw CE-month measures are carried on the analytic cohort")
ok(all(df$incl_baseline_ce_6m == as.integer(df$baseline_ce_months >= 6L)) &&
   all(df$incl_baseline_ce_12m == as.integer(df$baseline_ce_months >= 12L)) &&
   all(df$incl_baseline_ce_12m <= df$incl_baseline_ce_6m),
   "CE flags are derived from the raw measure (12mo subset of 6mo by construction)")
ok(all(c("flt_baseline_ce","flt_followup_ce","flt_dx_year","flt_lot_init_year") %in%
       registry_param_ids(REG)),
   "movable CE / year range filters are registered")
base_n <- select_cohort(df, COH$overall$active_flags, list(), character(), REG)$n_out
ce9_n  <- select_cohort(df, COH$overall$active_flags, list(flt_baseline_ce = c(9, 999)),
                        "flt_baseline_ce", REG)$n_out
ok(ce9_n > 0 && ce9_n <= base_n, "movable baseline-CE slider restricts in memory")
yr_n <- select_cohort(df, COH$overall$active_flags, list(flt_lot_init_year = c(2020, 2025)),
                      "flt_lot_init_year", REG)$n_out
ok(yr_n > 0 && yr_n <= base_n, "movable 1L-initiation-year window restricts in memory")

if (requireNamespace("survival", quietly = TRUE)) {
  cx <- km_cox(df, "OS", c("age_ge70", "cci_band", "soc_category"), min_fu = 3)
  ok("HR" %in% names(cx) && all(c("LCL","UCL","p") %in% names(cx)) && nrow(cx) >= 3,
     "km_cox returns an adjusted HR table for selected covariates")
  ok("Note" %in% names(km_cox(df, "Attrition", "age_ge70")),
     "km_cox declines the all-events Attrition endpoint with a Note")
  ok("Note" %in% names(km_cox(df, "OS", character(0))),
     "km_cox requires >=1 covariate")
  aids <- df$patient_id[df$age_index >= 70]; bids <- df$patient_id[df$age_index < 70]
  kc <- km_compare(df, "OS", aids, bids, min_fu = 3)
  ok(!is.null(kc) && all(c("Group A","Group B") %in% km_medians(kc)$Group),
     "km_compare overlays two id-sets as Group A / Group B")
}

# Sankey/pathway configurability
pd4 <- lot_pathway_data(ll, df$patient_id, max_line = 4L)
pd2 <- lot_pathway_data(ll, df$patient_id, max_line = 2L)
ok(max(pd4$trans$stage) == 3 && max(pd2$trans$stage) == 1,
   "pathway depth (max_line) is configurable")
tc <- lot_transition_table(ll, df$patient_id, 1L, commercial_only = TRUE)
ta <- lot_transition_table(ll, df$patient_id, 1L, commercial_only = FALSE)
ok(sum(tc$Freq) < sum(ta$Freq), "commercial-only toggle changes the transition denominator")

# ---- round 8: movable landmarks/follow-up parser + study_config env mapping ----
ok(identical(parse_landmark_months("6, 9, 12"), c(6, 9, 12)),
   "parse_landmark_months parses a comma list")
ok(identical(parse_landmark_months(""), LANDMARK_MONTHS) &&
   identical(parse_landmark_months("junk"), LANDMARK_MONTHS),
   "parse_landmark_months falls back to the protocol default on empty/garbage")
ok(identical(parse_landmark_months("12, 3, 3, -1"), c(3, 12)),
   "parse_landmark_months sorts, dedups, drops non-positive")

source(file.path(rdir, "..", "config", "study_config.R"))
env <- study_config_to_env()
ok(all(c("STUDY_START","STUDY_END","NDMM_LOT1_FROM","NDMM_PRE_LOT1_DAYS",
         "MAP_DISCON_GAP_DAYS","MAX_LOT") %in% names(env)),
   "study_config_to_env emits the pipeline env keys")
ok(env[["NDMM_LOT1_FROM"]] == study_config()$lot1_from &&
   env[["NDMM_PRE_LOT1_DAYS"]] == as.character(study_config()$pre_lot1_days),
   "study_config values map to the correct env vars")
Sys.setenv(NDMM_LOT1_FROM = "2018-06-01")
ok(resolved_study_config()$lot1_from == "2018-06-01" &&
   study_config_to_env()[["NDMM_LOT1_FROM"]] == "2018-06-01",
   "an env override flows through resolved_study_config into the mapping")
Sys.unsetenv("NDMM_LOT1_FROM")

# ---- indication-pack portability: every registered tumour type must build a
#      valid synthetic cohort + LOT-long through the SAME engine ----------------
.mm_flags <- registry_flag_ids(criteria_registry())      # capture before switching
for (ind in names(INDICATION_PACKS())) {
  options(cohort_explorer.indication = ind)
  p <- active_pack(ind)
  reg <- criteria_registry(); coh <- cohort_definitions()
  d2 <- load_flagged_cohort("synthetic", n = 300L)
  has1 <- unique(synth_lot_long(d2)$patient_id)           # ensure generator runs
  ll2 <- synth_lot_long(d2)
  d2 <- d2[d2$patient_id %in% ll2$patient_id[ll2$lot_num == 1L], ]
  ll2 <- ll2[ll2$patient_id %in% d2$patient_id, ]
  okp <- tryCatch({ validate_flagged_cohort(d2); validate_lot_long(ll2)
                    length(soc_levels_1l()) >= 2 && length(endpoint_dictionary()) >= 1 &&
                    all(registry_flag_ids(reg) %in% names(d2)) }, error = function(e) FALSE)
  ok(isTRUE(okp), sprintf("indication pack '%s' (%s) builds + validates end-to-end",
                          ind, p$disease))
}
options(cohort_explorer.indication = "mm")               # restore default
ok(identical(registry_flag_ids(criteria_registry()), .mm_flags),
   "indication resets to mm after switching packs")

# ---- patient explorer (swimlane) engine -------------------------------------
source(file.path(rdir, "patient_explorer.R"))
.pe_ll  <- synth_lot_long(df)
.pe_coh <- df[df$patient_id %in% .pe_ll$patient_id[.pe_ll$lot_num == 1L], ]
.pe_ll  <- .pe_ll[.pe_ll$patient_id %in% .pe_coh$patient_id, ]
.td <- patient_timeline_data(.pe_ll, .pe_coh, n = 12L, sort_by = "lines")
ok(!is.null(.td) && .td$n <= 12L && nrow(.td$segs) >= .td$n,
   "patient_timeline_data returns <= n lanes and >=1 segment each")
ok(all(.td$segs$x1 >= .td$segs$x0) && all(.td$marks$type %in% c("death", "censor")),
   "swimlane segments are non-negative width; markers are death/censor")
.socs <- sort(unique(.pe_coh$soc_category))
.tf <- patient_timeline_data(.pe_ll, .pe_coh, n = 50L, soc_filter = .socs[1])
ok(is.null(.tf) || all(.pe_coh$soc_category[match(.tf$ids, .pe_coh$patient_id)] == .socs[1]),
   "1L-regimen filter restricts the swimlane sample to that regimen")
ok(is.null(patient_timeline_data(.pe_ll, .pe_coh, soc_filter = "__none__")),
   "swimlane returns NULL when no patient matches the filter")

cat(sprintf("\n%d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0) quit(status = 1L)
