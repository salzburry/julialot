#!/usr/bin/env Rscript
# diagnose_data.R -- report HOW MANY rows fail each contract check, so we can
# see which LOT data definitions are clean vs problematic (instead of bypassing
# blind). Reports counts only; changes nothing.
#
#   COHORT_EXPLORER_DATA=/tmp/cohort_data/analytic_cohort.csv \
#   COHORT_EXPLORER_LOTLONG=/tmp/cohort_data/analytic_lot_long.csv \
#   Rscript diagnose_data.R

ap <- Sys.getenv("COHORT_EXPLORER_DATA",    "/tmp/cohort_data/analytic_cohort.csv")
lp <- Sys.getenv("COHORT_EXPLORER_LOTLONG", "/tmp/cohort_data/analytic_lot_long.csv")
ac <- read.csv(ap, stringsAsFactors = FALSE)
ll <- read.csv(lp, stringsAsFactors = FALSE)
for (d in c("index_date","lot1_start_dt","death_dt"))
  if (d %in% names(ac)) ac[[d]] <- as.Date(ac[[d]])

N  <- nrow(ac); NL <- nrow(ll)
row <- function(label, count, denom = N) {
  pct <- if (denom > 0) sprintf("%5.1f%%", 100*count/denom) else "   -  "
  cat(sprintf("  %-48s %8s  %s\n", label, format(count, big.mark=","), pct))
}
cat(sprintf("\n=== PATIENT-LEVEL  (%s patients) ===\n", format(N, big.mark=",")))
row("lot1_length <= 0 or NA",        sum(ac$lot1_length <= 0 | is.na(ac$lot1_length)))
row("n_lines < 1",                    sum(ac$n_lines < 1, na.rm = TRUE))
row("index_date > lot1_start_dt",     sum(ac$index_date > ac$lot1_start_dt, na.rm = TRUE))
row("missing index_date/lot1_start",  sum(is.na(ac$index_date) | is.na(ac$lot1_start_dt)))
row("os_time > fu_potential",         sum(ac$os_time  > ac$fu_potential_months, na.rm = TRUE))
row("ttd_time > fu_potential",        sum(ac$ttd_time > ac$fu_potential_months, na.rm = TRUE))
row("ttnt_time > fu_potential",       sum(ac$ttnt_time> ac$fu_potential_months, na.rm = TRUE))
row("any TTE negative",               sum(ac$os_time<0 | ac$ttd_time<0 | ac$ttnt_time<0 | ac$pfs_time<0, na.rm = TRUE))
row("os_event=1 but death_dt missing",sum(ac$os_event==1 & is.na(ac$death_dt)))
row("ttnt_event != (n_lines>1)",      sum(ac$ttnt_event != as.integer(ac$n_lines>1), na.rm = TRUE))
row("age_index NA or < 0",            sum(is.na(ac$age_index) | ac$age_index < 0))
flags <- grep("^(incl_|excl_)", names(ac), value = TRUE)
row("flag cells not strictly 0/1",    sum(vapply(flags, function(f) sum(!ac[[f]] %in% c(0,1)), integer(1))))
row("duplicate patient_id",           sum(duplicated(ac$patient_id)))

cat(sprintf("\n=== LOT-LONG  (%s rows) ===\n", format(NL, big.mark=",")))
key <- paste(ll$patient_id, ll$lot_num)
row("duplicate (patient_id, lot_num)", sum(duplicated(key)), NL)
sp <- split(ll$lot_num, ll$patient_id)
noncontig <- sum(vapply(sp, function(v){ v <- sort(unique(v)); !(v[1]==1 && all(diff(v)==1)) }, logical(1)))
row("patients w/ non-contiguous lines", noncontig, length(sp))
row("lot_soc blank/NA",                sum(is.na(ll$lot_soc)  | ll$lot_soc  == ""), NL)
row("payer_type blank/NA",             sum(is.na(ll$payer_type)| ll$payer_type== ""), NL)
row("lot_start_dt missing",            sum(is.na(as.Date(ll$lot_start_dt))), NL)
row("os_time  > fu_potential",         sum(ll$os_time  > ll$fu_potential_months, na.rm = TRUE), NL)
row("ttd_time > fu_potential",         sum(ll$ttd_time > ll$fu_potential_months, na.rm = TRUE), NL)
row("ttnt_time > fu_potential",        sum(ll$ttnt_time > ll$fu_potential_months, na.rm = TRUE), NL)
row("any TTE negative",                sum(ll$os_time<0 | ll$ttd_time<0 | ll$ttnt_time<0, na.rm = TRUE), NL)
# line-count vs n_lines
rc  <- tapply(ll$lot_num, ll$patient_id, length)
exp <- setNames(ac$n_lines, ac$patient_id)
common <- intersect(names(rc), names(exp))
row("patients: lot-long count != n_lines", sum(rc[common] != exp[common]), length(common))
row("flagged patients missing in lot-long", sum(!ac$patient_id %in% ll$patient_id))
# per-patient ordered checks via row-shift (ord sorted by patient, lot_num):
# a row "has a next line" iff the following row is the SAME patient.
ord <- ll[order(ll$patient_id, ll$lot_num), ]
ord$lot_start_dt <- as.Date(ord$lot_start_dt)
n <- nrow(ord)
has_next  <- c(ord$patient_id[-1] == ord$patient_id[-n], FALSE)     # row i's next row same patient?
nxt_soc   <- c(ord$lot_soc[-1],    NA); nxt_soc[!has_next]   <- NA   # next line's lot_soc
nxt_start <- c(as.numeric(ord$lot_start_dt)[-1], NA); nxt_start[!has_next] <- NA
row("ttnt_event != (subsequent line exists)", sum(ord$ttnt_event != as.integer(has_next)), NL)
mismatch_soc <- (is.na(ord$next_soc) != is.na(nxt_soc)) |
                (!is.na(ord$next_soc) & !is.na(nxt_soc) & ord$next_soc != nxt_soc)
row("next_soc != next line's lot_soc",  sum(mismatch_soc), NL)
gap_mo <- (nxt_start - as.numeric(ord$lot_start_dt))/30.44
recon_bad <- sum(ord$ttnt_event==1 & !is.na(gap_mo) & abs(gap_mo - ord$ttnt_time) > 2, na.rm = TRUE)
row("ttnt_time vs next-line gap off >2mo", recon_bad, NL)

cat("\n(For each: count of offending rows, and % of the denominator.)\n")
cat("NOTE: make_analytic_csv.R also self-validates with the REAL dashboard\n")
cat("validators when COHORT_EXPLORER_DIR is set - this is a quick pre-check.\n")
