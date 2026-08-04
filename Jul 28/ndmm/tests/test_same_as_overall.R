#!/usr/bin/env Rscript
# R/steps/00_mm_cohort.R and the overall package must agree on who counts as
# MM-diagnosed. This holds the two together.
#
# Not line for line - the two are shaped differently. overall splits its
# inpatient, outpatient and qualifying work across three views where this build
# needs one, and it carries columns only its own attrition reads.
#
# Instead this takes the clinically decisive expressions out of overall's own
# files, renames its views to ours, and requires each to appear here word for
# word. Those are the parts where a difference changes who is in the cohort:
# what counts as inpatient, which codes qualify an inpatient claim, how the
# diagnosis claim is joined to its header, the outpatient window, how a partial
# death date is resolved, and which eligibility row wins. Change one on either
# side and this fails, which is the drift worth catching.
#
#   Rscript "ndmm/tests/test_same_as_overall.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

SRC_DIR <- file.path(dirname(ROOT), "overall", "R", "steps")
if (!dir.exists(SRC_DIR)) {
  cat("the overall build not beside this folder -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}
ours <- paste(readLines(file.path(ROOT, "R", "steps", "00_mm_cohort.R"), warn = FALSE),
              collapse = "\n")

read_src <- function(f) paste(readLines(file.path(SRC_DIR, f), warn = FALSE), collapse = "\n")

# overall's names for the views, and ours. Applied to overall's text
# before comparing, so a renamed view is not mistaken for a changed rule.
RENAME <- c(
  "{work('mm_dx_codes')}"       = "{NDMM_MM_DX_CODES}",
  "{work('med_claim_header')}"  = "{NDMM_MM_CLAIM_HEADER}",
  "{work('confinement')}"       = "{NDMM_MM_CONFINEMENT}",
  "{work('mm_dx_events_all')}"  = "{NDMM_MM_DX_EVENTS}",
  "{work('mm_dx_events_id')}"   = "{NDMM_MM_DX_EVENTS}",
  "{work('mm_qualifying')}"     = "{NDMM_MM_QUALIFYING}",
  "{work('member_demo')}"       = "{NDMM_MEMBER_DEMO}",
  "{work('death_dt')}"          = "{NDMM_DEATH_DT}",
  "{cdm_src(cfg$tbl_medical)}"  = "{medical_tbl}",
  "{cdm_src(cfg$tbl_confinement)}" = "{confinement_tbl}",
  "{cdm_src(cfg$tbl_med_diag)}" = "{med_diag_tbl}",
  "{cdm_src(cfg$tbl_member_elig)}" = "{member_elig_tbl}",
  "{cdm_src(cfg$tbl_dod)}"      = "{dod_tbl}",
  "{cfg$study_start}"           = "{NDMM_STUDY_START}",
  "{cfg$dx_window_90}"          = "{NDMM_OUTPATIENT_WINDOW}",
  # overall keeps every candidate index date and calls it index_date; here
  # the same column is the MM diagnosis date, because the NDMM index is the 1L
  # start and the two must not be confused.
  "q.index_date"                = "q.MM_DX_DT",
  "index_date"                  = "MM_DX_DT"
)
rename <- function(x) {
  for (k in names(RENAME)) x <- gsub(k, RENAME[[k]], x, fixed = TRUE)
  x
}
# Indentation is layout, not rule: overall's SQL sits inside a phase list and
# this one inside a function, so it is reindented. Comparing token sequences
# rather than lines keeps the check on what the SQL says.
squash <- function(x) trimws(gsub("[[:space:]]+", " ", x))

# Pull the text between two anchors out of overall, inclusive.
between <- function(txt, from, to) {
  i <- regexpr(from, txt, fixed = TRUE)
  if (i == -1) return(NA_character_)
  rest <- substring(txt, i)
  j <- regexpr(to, rest, fixed = TRUE)
  if (j == -1) return(NA_character_)
  substring(rest, 1, j + nchar(to) - 1)
}

RULES <- list(
  list(name = "what counts as an inpatient claim line",
       file = "02_dx_events.R",
       from = "max(CASE WHEN POS IN",
       to   = "AS line_inpatient"),
  list(name = "the claim grain headers are grouped to",
       file = "02_dx_events.R",
       from = "GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD",
       to   = "GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD"),
  list(name = "which confinements are usable",
       file = "02_dx_events.R",
       from = "WHERE CONF_ID IS NOT NULL",
       to   = "AND DISCH_DATE IS NOT NULL"),
  list(name = "inpatient means a line flag or a confinement",
       file = "02_dx_events.R",
       from = "CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL",
       to   = "THEN 1 ELSE 0 END AS inpatient_flg"),
  list(name = "the strict 203.0x / C90.0x test",
       file = "02_dx_events.R",
       from = "CASE WHEN ({icd_family_sql('d.ICD_FLAG')}) = 'ICD9'",
       to   = "THEN 1 ELSE 0 END AS mm_dx_strict_flg"),
  list(name = "how a diagnosis is joined to its claim header",
       file = "02_dx_events.R",
       from = "ON d.PATID      =   h.PATID",
       to   = "AND d.LOC_CD     <=> h.LOC_CD"),
  list(name = "how a diagnosis is matched to the code list",
       file = "02_dx_events.R",
       from = "ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = c.dx",
       to   = "AND ({icd_family_sql('d.ICD_FLAG')}) = c.icd_family"),
  list(name = "which claim qualifies an inpatient index date",
       file = "03_index_date.R",
       from = "WHERE inpatient_flg = 1",
       to   = "AND mm_dx_strict_flg = 1"),
  list(name = "how outpatient dates are paired",
       file = "03_index_date.R",
       from = "lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt",
       to   = "lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt"),
  list(name = "which eligibility row gives sex and birth year",
       file = "05_demographics.R",
       from = "row_number() OVER (PARTITION BY PATID",
       to   = "cast(ELIGEND as date) DESC) AS rn"),
  list(name = "how a partial death date is read",
       file = "05_demographics.R",
       from = "cast(SUBSTR(YMDOD, 1, 4) as int) AS death_yr",
       to   = "ELSE NULL"),
  list(name = "how a month-only death date is resolved",
       file = "05_demographics.R",
       from = "WHEN year(q.MM_DX_DT) = b.death_yr",
       to   = "ELSE make_date(b.death_yr, b.death_mo, 15)"),
  list(name = "how a year-only death date is resolved",
       file = "05_demographics.R",
       from = "THEN make_date(b.death_yr, 12, 31)",
       to   = "ELSE make_date(b.death_yr, 7, 15)"),
  list(name = "the clamp that keeps death on or after the anchor",
       file = "05_demographics.R",
       from = "WHEN death_raw IS NOT NULL AND death_raw < MM_DX_DT THEN MM_DX_DT",
       to   = "WHEN death_raw IS NOT NULL AND death_raw < MM_DX_DT THEN MM_DX_DT")
)

cat("\n-- both packages use the same rule for who is in the population --\n")
for (r in RULES) {
  txt <- rename(read_src(r$file))
  want <- between(txt, r$from, r$to)
  if (is.na(want)) {
    ok(FALSE, paste0(r$name, ": not found in overall/R/steps/", r$file,
                     " -- overall changed, so the two are unverified"))
    next
  }
  ok(grepl(squash(want), squash(ours), fixed = TRUE),
     paste0(r$name, " (", length(strsplit(want, "\n")[[1]]), " lines from ",
            r$file, ")"))
}

cat("\n-- and the criteria overall applies that this build must not --\n")
# overall has switches for six criteria; only two belong here. If this build
# had brought the others across, a patient would be dropped before the NDMM
# funnel ever counted them, and the attrition would not say so.
NOT_HERE <- c("CE_b", "CE_f", "CE_3mosf", "MM_bl_agents", "MM_FU_agents",
              "MM_baseline_diag", "CLINTRIAL", "PREGNANT_FLAG",
              "OTHER_MALIGN_FLAG")
brought <- Filter(function(k) grepl(paste0("\\b", k, "\\b"), ours, perl = TRUE), NOT_HERE)
ok(length(brought) == 0,
   if (length(brought)) paste0("overall's own criteria leaked in here: ",
                               paste(brought, collapse = ", "))
   else paste0("none of overall's ", length(NOT_HERE),
               " other criteria columns appear here"))
# The two that are applied, and nothing else standing between the population
# and the 1L index.
ok(grepl("NDMM_MIN_AGE", ours, fixed = TRUE),
   "age is applied here, at the diagnosis year")
ok(grepl("inpt_qual = 1 OR q.outpt_qual = 1", squash(ours), fixed = TRUE),
   "and the diagnosis has to qualify, by one inpatient claim or two outpatient")

cat("\n-- and age drops a patient, the way overall does, not their date --\n")
# overall applies age as a filter on an index date it has already chosen,
# so it can only remove a patient. This build once filtered the qualifying
# dates by age and then took the earliest survivor, which kept a patient who
# qualified at 17 and again at 18 and moved their MM_DX_DT to the later date -
# and MM_DX_DT gates the 1L index, so a later therapy claim became "first
# line". Read from overall, not asserted about it, so this fails if overall
# ever stops doing it this way.
PAR_AGE <- local({
  f <- file.path(dirname(ROOT), "overall", "R", "criteria_attrition.R")
  if (!file.exists(f)) NA_character_
  else paste(readLines(f, warn = FALSE), collapse = "\n")
})
ok(!is.na(PAR_AGE) &&
     grepl("AND AGE_INDEX_YR >= {cfg$min_age}", PAR_AGE, fixed = TRUE),
   "overall's age rule is a filter on an already-chosen index date")

# The function only: the comment above it argues for this, and an assertion
# that a comment can satisfy is not an assertion.
BC <- local({
  ln <- readLines(file.path(ROOT, "R", "steps", "00_mm_cohort.R"), warn = FALSE)
  i <- grep("^build_ndmm_base_cohort <- function", ln)
  j <- grep("^}", ln); j <- j[j > i[1]][1]
  if (!length(i) || is.na(j)) NA_character_ else paste(ln[i[1]:j], collapse = "\n")
})
i_fd <- if (is.na(BC)) -1L else regexpr("first_dx AS (", BC, fixed = TRUE)
PRE  <- if (i_fd > 0) substring(BC, 1, i_fd - 1) else ""
# The property, not its wording: whatever the ranking reads, age is not in it.
ok(i_fd > 0 && grepl("row_number() OVER", PRE, fixed = TRUE) &&
     grepl("NDMM_MM_QUALIFYING", PRE, fixed = TRUE) &&
     !grepl("NDMM_MIN_AGE", PRE, fixed = TRUE) &&
     !grepl("NDMM_MEMBER_DEMO", PRE, fixed = TRUE) &&
     !grepl("YRDOB", PRE, fixed = TRUE),
   "the earliest qualifying diagnosis is chosen without age or demographics in reach")
i_rn <- if (is.na(BC)) -1L else regexpr("WHERE rn = 1", BC, fixed = TRUE)
i_ag <- if (is.na(BC)) -1L else regexpr("NDMM_MIN_AGE", BC, fixed = TRUE)
ok(i_rn > 0 && i_ag > 0 && i_rn < i_ag,
   "...and age is tested on that one date, so 17-then-18 is dropped, not moved")

report()
