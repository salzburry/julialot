#!/usr/bin/env Rscript
# The NDMM cohort is a port of the cohort half of
# apr_30_2026/06_ndmm_dashboard.R, not a rewrite. That file is 1,479 lines of
# which roughly 840 build the cohort and the rest render a dashboard; this
# package takes the first half only. Every ported file is compared line for
# line against the range it came from.
#
# Skipped when apr_30_2026 is not beside this folder, so a copied-out package
# still runs its other suites.
#
#   Rscript validation/port/ndmm.R

COMMON <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (!length(a)) getwd()
       else dirname(normalizePath(gsub("~+~", " ",
                                       sub("^--file=", "", a[1]), fixed = TRUE)))
  file.path(dirname(d), "_common.R")
})
source(COMMON)
ROOT <- pkg_dir("ndmm")
need_dirs(ROOT)
source(file.path(ROOT, "tests", "testutil.R"))

SRC <- file.path(BASELINE, "06_ndmm_dashboard.R")
if (!file.exists(SRC)) {
  cat("apr_30_2026 not beside this folder -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}
src <- readLines(SRC, warn = FALSE)

# Where each file came from. The ranges are contiguous and non-overlapping, and
# together they are the cohort half of the source - asserted below, so a range
# that is quietly narrowed cannot drop code without saying so.
PARTS <- list(
  list(file = "R/ndmm_constants.R",      from = 62,  to = 147),
  list(file = "R/steps/01_enrollment.R",  from = 148, to = 198),
  list(file = "R/steps/02_lot1_starts.R", from = 199, to = 216),
  list(file = "R/steps/03_prior_therapy.R", from = 217, to = 317),
  list(file = "R/steps/04_other_malig.R", from = 318, to = 533),
  list(file = "R/steps/05_pregnancy.R",   from = 534, to = 621),
  list(file = "R/steps/06_flags.R",       from = 622, to = 755),
  list(file = "R/steps/07_cohort.R",      from = 756, to = 839)
)

# The port is allowed to differ from the source in exactly the ways named here,
# and in no others. Each deviation is undone before the comparison, so an
# unapproved change survives and breaks equality; and a deviation that gets
# deleted leaves its entry with nothing to undo, which is reported rather than
# reading as a perfect match.
#
# All of these are the one clinical change the study team confirmed: the 1L
# follow-up CE is one day of enrollment on the index date, not three months.
# The protocol text (Rev Round 2, S6.2.1.1) says three months, so this is a
# deliberate override of the written spec and is spelled out rather than
# absorbed - the numbers it produces are not the numbers apr_30_2026 produces.
SUBST <- list(
  # The study-period default. S6.1 gives 01 Jan 2016; the source defaulted to
  # 2015-07-01, which is the overall build's window, not this one's. config.csv
  # supplies STUDY_START in a real run so the effective date was already the
  # protocol's - but cfg$study_start defaults the same variable to 2016-01-01,
  # so without config.csv the two disagreed and check_constants() stopped the
  # build. Both defaults are the protocol's date now, and a config.csv that
  # goes missing no longer widens the pregnancy and MM-diagnosis scans.
  "R/ndmm_constants.R" = list(
    # The dated events view the pregnancy scan now writes. A new name, not a
    # changed rule.
    list(from = "NDMM_STUDY_START         <- Sys.getenv(\"STUDY_START\", unset = \"2016-01-01\")",
         to   = "NDMM_STUDY_START         <- Sys.getenv(\"STUDY_START\", unset = \"2015-07-01\")", n = 1L)),
  # The sixth clinical change, and it is a fail-open rather than a rule: the
  # source read any ICD_FLAG that was not an ICD-9 spelling as ICD-10, so a
  # blank or unexpected flag on a genuine ICD-9 claim was mis-classed and then
  # matched no code. Both families are named now and anything else is NULL,
  # which matches neither. It can only remove matches the source should not
  # have made, and the same change is in the overall build so the two still
  # agree - tests/test_same_as_overall.R holds that.
  # The scan gained a fifth source, so the builder gained the table to read it
  # from. See the ADDED entry for the mproc CTE below.
  "R/steps/03_prior_therapy.R" = list(
    # The claim side of the NDC join yields a key only from a value that could
    # be an NDC. The source left-padded anything to eleven, so NONE and UNK -
    # how Optum spells "no NDC", 1.2bn rows - became 00000000000 and could
    # collide with a real code. It can only remove matches the source should
    # not have made, and it retires the shape check that policed them.
    list(from = "AND {ndc_key('m.NDC')}",
         to   = "AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')",
         n = 1L),
    list(from = "AND {ndc_key('r.NDC')}",
         to   = "AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')",
         n = 1L),
    list(from = "build_ndmm_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl, med_proc_tbl) {",
         to   = "build_ndmm_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl) {", n = 1L)),
  "R/steps/05_pregnancy.R" = list(
    # The medical arm now projects the claim date as well, because the events
    # view is dated - NDMM_PREG_WINDOW_COUNTS prices the study-period window
    # against the program spec's baseline+follow-up reading, and cannot without
    # dates. The EXCLUSION is unchanged: still every patient with a matched
    # claim anywhere in the study period. See DECISIONS.md #9.
    list(from = "SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT as date) AS event_dt,",
         to   = "SELECT cast(m.PATID as string) AS PATID, m.PROC_CD, m.RVNU_CD", n = 1L),
    list(from = "SELECT s.PATID, s.event_dt, t.code_type, t.code",
         to   = "SELECT s.PATID, t.code_type, t.code", n = 1L),
    list(from = "SELECT DISTINCT e.PATID, e.event_dt", to = "SELECT DISTINCT e.PATID", n = 1L),
    list(from = "SELECT m.PATID, m.event_dt", to = "SELECT DISTINCT m.PATID", n = 1L),
    list(from = "CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_EVENTS} AS",
         to   = "CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_PATIDS} AS", n = 1L),
    list(from = "LATERAL VIEW stack(3,", to = "LATERAL VIEW stack(2,", n = 1L),
    list(from = "{icd_family_sql('d.ICD_FLAG', 'ICD9DIAG', 'ICD10DIAG')} AS code_type,",
         to   = "CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,", n = 1L),
    list(from = "{icd_family_sql('p.ICD_FLAG', 'ICD9PROC', 'ICD10PROC')} AS code_type,",
         to   = "CASE WHEN upper(p.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,", n = 1L)),
  # The override now covers the remission variants of the plasma-cell groups as
  # well - the criterion is another cancer distinct from the index MM, and
  # remission cannot make a plasma-cell disorder more like a different one. The
  # list moves behind ndmm_mm_adjacent_groups() so the setting that decides it
  # lives in one place.
  "R/steps/04_other_malig.R" = list(
    # The comma the line-level inpatient flag needed after the column it now
    # follows. The flag itself is in the ADDED entry below.
    list(from = "max(TOS_CD)  AS TOS_CD,", to = "max(TOS_CD)  AS TOS_CD", n = 1L),
    list(from = "ovr_in <- paste(sprintf(\"'%s'\", gsub(\"'\", \"''\", ndmm_mm_adjacent_groups())),",
         to   = "ovr_in <- paste(sprintf(\"'%s'\", gsub(\"'\", \"''\", NDMM_MM_ADJACENT_OVERRIDE)),",
         n = 1L),
    # Path B pairs on the mapped primary group instead of the raw label. Both
    # DISTINCT lines were identical in the source; the outpatient one is
    # renamed so this can name it without touching the inpatient one.
    list(from = "SELECT DISTINCT PATID, primary_group AS grp, event_dt",
         to   = "SELECT DISTINCT PATID, tumor_group, event_dt", n = 2L),
    list(from = "SELECT PATID, grp, event_dt,",
         to   = "SELECT PATID, tumor_group, event_dt,", n = 1L),
    list(from = "lead(event_dt) OVER (PARTITION BY PATID, grp ORDER BY event_dt) AS next_dt",
         to   = "lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt",
         n = 1L),
    list(from = "SELECT PATID, grp, event_dt AS first_dt, next_dt,",
         to   = "SELECT PATID, tumor_group, event_dt AS first_dt, next_dt,", n = 1L),
    list(from = "FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 1",
         to   = "FROM dx_with_setting WHERE inpatient_flg = 1", n = 1L),
    list(from = "FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 0",
         to   = "FROM dx_with_setting WHERE inpatient_flg = 0", n = 1L)),
  "R/steps/06_flags.R" = list(
    list(from = "AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, {NDMM_FU_CE_DAYS}),",
         to   = "AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, 90),", n = 1L),
    list(from = "THEN 1 ELSE 0 END) AS CE_fu",
         to   = "THEN 1 ELSE 0 END) AS CE_lot1_3mo", n = 1L),
    list(from = "coalesce(fuce.CE_fu, 0)                              AS CE_lot1_fu,",
         to   = "coalesce(fuce.CE_lot1_3mo, 0)                        AS CE_lot1_3mo_fu,", n = 1L))
  # 06_flags.R's fourth CE_lot1_fu reference was the one in NDMM_PATIDS's WHERE.
  # That clause is now generated, so the line it renamed no longer exists and
  # the whole clause is undone by SPLICE below instead. 07_cohort.R's reference
  # is inside its own rewritten block, and is undone the same way.
)

# Lines the port adds that the source has no counterpart for, and how many.
#
# The <> '' guards are the second clinical change. Every codelist and claim
# value is normalised by stripping punctuation, and the source only checked the
# raw value for blankness: a CL_CODE of '---' survives that check, normalises
# to '', and then equals the normalised form of any claim whose code is
# missing. In the NDC branches both sides pad to 00000000000. The result is a
# patient excluded as previously treated, or as having another cancer, on the
# strength of a claim with no code in it. These add the check on the normalised
# value; they can only ever remove matches the source should not have made.
ADDED <- list(
  "R/ndmm_constants.R" = c("NDMM_FU_CE_DAYS          <- 0L" = 1L,
    # The dated events view the pregnancy scan writes. A new name, not a new
    # rule - see DECISIONS.md #9 and the pregnancy entry below.
    "NDMM_PREGNANCY_EVENTS    <- \"_ndmm_pregnancy_events\"" = 1L),
  "R/steps/03_prior_therapy.R" = c(
    "AND regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '') <> ''" = 1L,
    "AND (upper(trim(CL_CODE_TYPE)) <> 'NDC'" = 1L,
    "OR regexp_replace(CL_CODE, '[^0-9]', '') <> '')" = 1L,
    "AND regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''" = 1L,
    "AND regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''" = 1L,
    # The fifth clinical change. The program spec names T_MED_PROCEDURE (PROC)
    # among the CDM tables joined to CL_MMA_CODELIST, and Optum business rule 5
    # says PROC finds a drug given as a procedure under a HCPCS or CPT code. The
    # source reads four sources and not that one, so a therapy administered and
    # coded that way is invisible to it - which would let a patient pass the
    # no-prior-therapy criterion on missing data. This adds the arm. It can only
    # add exclusions, so the cohort is smaller than apr_30_2026's.
    "mproc AS (" = 1L,
    "SELECT /*+ BROADCAST(c) */ cast(mp.PATID as string) AS PATID" = 1L,
    "FROM {med_proc_tbl} mp" = 1L,
    "INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(mp.PATID as string) = l1.PATID" = 1L,
    "INNER JOIN {NDMM_MMA_CODELIST} c ON c.code_type IN ('HCPCS','CPT')" = 1L,
    "AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = c.code" = 1L,
    "AND regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '') <> ''" = 1L,
    "WHERE cast(mp.FST_DT as date) >= date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})" = 1L,
    "AND cast(mp.FST_DT as date) <= date_sub(l1.LOT1_START_DT, 1)" = 1L,
    "),  -- end mproc" = 1L,
    "UNION SELECT DISTINCT PATID FROM mproc" = 1L),
  "R/steps/04_other_malig.R" = c(
    # Metastatic codes group together instead of pairing by ICD category: two
    # outpatient claims for metastases at different sites are still metastatic
    # cancer, which the rule excludes on in its own right. The CASE that does
    # it is inside the spliced view; these two lines sit outside it.
    "met_pred <- ndmm_metastatic_sql(\"om.dx\")" = 1L,
    "met_own  <- ndmm_metastatic_own_group_sql(\"om.dx\")" = 1L,
    # An empty override list is reachable now - NDMM_MM_ADJACENT_STATES=none,
    # or mgus_only where the label is absent - and IN () is a syntax error.
    "if (!nzchar(ovr_in)) ovr_in <- \"NULL\"" = 1L,
    "if (!nzchar(req_in)) req_in <- \"NULL\"" = 1L,
    "report_metastatic_group(con)" = 1L,
    # The required-match count is now against the five labels the code list
    # must carry, not against every group the override reaches - the remission
    # variants are a proposal and their absence is reported, not fatal.
    "req    <- gsub(\"'\", \"''\", NDMM_MM_ADJACENT_OVERRIDE)" = 1L,
    "req_in <- paste(sprintf(\"'%s'\", req), collapse = \", \")" = 1L,
    "AND upper(trim(tumor_group)) IN ({req_in})" = 1L,
    # The third clinical change. The other-cancer rule is >=1 inpatient claim
    # or >=2 outpatient claims within 30 days of each other, in the 12-month
    # 1L baseline. The source bounded only the first of the outpatient pair, so
    # a claim on the day before the index and its confirmation a month after it
    # excluded the patient on a single baseline claim. This bounds the second
    # claim too, so both fall in the baseline the criterion names. It can only
    # remove exclusions, so the cohort it builds is larger than apr_30_2026's.
    "AND op.next_dt  BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end" = 1L,
    # The line-level inpatient flag, and the classification reading it. The
    # source classified from max(POS)/max(TOS_CD), so a claim with an inpatient
    # line and a lexically larger non-inpatient one read as outpatient - and one
    # inpatient other-cancer claim excludes on its own while an outpatient one
    # needs a second. 00_mm_cohort.R already flagged per line, with a comment
    # saying why; this view did not. It can only add exclusions.
    "max(CASE WHEN POS IN ('21', '51', '61')" = 1L,
    "OR TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')" = 1L,
    "THEN 1 ELSE 0 END) AS line_inpatient" = 1L),
  # The rest of the pre-index belantamab criterion: the CTE, the flag and the
  # join. Each line is unique, so these are counted rather than spliced; the
  # expression that builds them is undone by the SPLICE above. See the comment
  # there for why the criterion exists.
  "R/steps/06_flags.R" = c(
    "bela_pre AS ({bela_pre_expr})," = 1L,
    "CASE WHEN bela_pre.PATID     IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB_PRE_LOT1," = 1L,
    "LEFT JOIN bela_pre     ON ec_l1.PATID = bela_pre.PATID" = 1L),
  # The blank-after-normalising guard now sits inside the spliced builder, so
  # it is undone there rather than counted here.
  "R/steps/05_pregnancy.R" = c(
    # BILL_PROC_CD, the facility-claim procedure code. S6.2.1.2 asks for a
    # diagnosis, procedure or revenue code, and the therapy and SCT scans
    # already read this column - pregnancy did not, so a code populated only
    # there kept the patient. It can only add exclusions.
    "'HCPCS', CASE WHEN s.BILL_PROC_CD IS NOT NULL" = 1L,
    "THEN upper(regexp_replace(s.BILL_PROC_CD, '[^A-Za-z0-9]', '')) END," = 1L,
    # The scan carries the claim date now, so NDMM_PREG_WINDOW_COUNTS can price
    # the study-period window against the program spec's baseline+follow-up
    # reading. The EXCLUSION is unchanged - still every patient with a matched
    # claim anywhere in the study period. See DECISIONS.md #9.
    "cast(d.FST_DT as date) AS event_dt," = 1L,
    "m.PROC_CD, m.BILL_PROC_CD, m.RVNU_CD" = 1L,
    "cast(p.FST_DT as date) AS event_dt," = 1L,
    "checkpoint(con, \"NDMM_PREGNANCY_EVENTS\")" = 1L,
    "db_exec(con, glue(\"CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_PATIDS} AS SELECT DISTINCT PATID FROM {NDMM_PREGNANCY_EVENTS}\"))" = 1L),
  # The funnel's last row, read by key rather than named literally in the
  # runner. Added because the last criterion is no longer ndmm_final:
  # S6.2.1.2's belantamab exclusion moved to the lot package, so this package's
  # funnel ends at pregnancy and the runner cannot hard-code the key.
  "R/steps/07_cohort.R" = c(
    "ndmm_final_count <- function(counts)" = 1L,
    "counts[[NDMM_CRITERIA[[length(NDMM_CRITERIA)]]$key]]" = 1L)
)

# Blocks the port rewrote rather than edited. Patching these back line by line
# would take twenty SUBST entries and would not be readable by anyone checking
# what changed; instead the block is named by its first and last line and
# swapped for the source's own lines before the comparison. Everything outside
# it is still held to the source exactly, and markers that stop matching are
# reported - so deleting the rewrite does not read as a perfect match.
#
# ndmm_counts(): the attrition follows protocol Rev Round 2 S6.2.1.1 then
# S6.2.1.2 in the order those sections list the criteria. The source applies
# belantamab first and follow-up CE second-to-last. Same final cohort - it is
# one conjunction either way - but different per-step counts, and the attrition
# is the deliverable.
SPLICE <- list(
  # The sixth clinical change, and the one the protocol dictates rather than
  # permits. S6.2.1.2 excludes on "the same primary tumor type and/or
  # metastatic cancer". SECONDARY MALIGNANT NEOPLASM OF BONE is C79.51, a
  # metastatic cancer, so the protocol says it excludes; the source overrode it
  # because myeloma bone disease is often miscoded that way. Dropped from the
  # override list, so it excludes as written. The cohort is smaller than
  # apr_30_2026's. See ndmm/DECISIONS.md #4.
  "R/ndmm_constants.R" = list(
    list(from = "NDMM_MM_ADJACENT_OVERRIDE <- c(",
         to   = "\"EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION\"",
         src_from = 109L, src_to = 114L)),
  # The pregnancy code list gained a guard: a code_type no claim source emits
  # matches nothing, so the exclusion keeps those patients silently. Every other
  # named thing in this package already stops when it matches nothing; this list
  # was the exemption. Whole builder spliced - the guard is most of it.
  "R/steps/05_pregnancy.R" = list(
    list(from = "NDMM_PREG_CODE_TYPES <- c(\"ICD9DIAG\", \"ICD10DIAG\", \"ICD9PROC\", \"ICD10PROC\",",
         to   = "invisible(TRUE)",
         # Through the statement, not the closing brace: the port block ends at
         # invisible(TRUE) and its own } closes the restored function.
         src_from = 534L, src_to = 543L)),
  "R/steps/07_cohort.R" = list(
    # Widened: whole/elig/elig_lot1 are rewritten too. This package no longer
    # reads LOT_LONG or a parent cohort table, so the first three rows of the
    # funnel are a qualifying MM diagnosis, then age, then an eligible 1L
    # treatment - derived here rather than inherited.
    list(from = "ndmm_counts <- function(con, mm_qualifying, base_cohort) {",
         to   = "setNames(list(ndmm_final), NDMM_CRITERIA[[length(NDMM_CRITERIA)]]$key))",
         src_from = 795L, src_to = 837L)
  ),
  # The materialization of NDMM_FLAGS_ALL. The source wrapped it in tryCatch and
  # warned on failure, keeping the in-place view: correct arithmetic, but this
  # package declares that table an output, so the run would report complete with
  # it missing - and every later read would re-run the whole scan DAG. It is one
  # call to checkpoint() now, which is what every other materialization in this
  # package uses and which stops if the write fails. It stays inside this
  # function because NDMM_PATIDS is defined over the view a few lines below and
  # Spark inlines a temp view's plan.
  # The cohort's own conjunction. The source wrote the six flags out in
  # NDMM_PATIDS's WHERE, and ndmm_counts() wrote fifteen more predicates over
  # the same flags for the funnel - two hand-maintained copies of the rule that
  # says who is in the cohort. Both now render NDMM_CRITERIA, so the view and
  # the attrition are the same six criteria by construction. The clause the
  # source wrote is swapped back in here; the flags and their order are held by
  # test_runner.R, which reads the generated clause rather than the file.
  # The seventh clinical change, and the second the protocol dictates rather
  # than permits. S6.2.1.2 excludes belantamab "in any LOT" and, unlike the
  # three exclusions beside it - "during the 12-month 1L baseline period", "in
  # the 1L baseline period", "during the study period" - gives that one no
  # period at all. So a belantamab line earlier in the patient's history
  # disqualifies them too. The lot package cannot see that: map_stacked is built
  # from claims on or after the cohort's INDEX_DATE. So the pre-index half is
  # decided here and lot keeps the half from the index onward.
  #
  # Spliced rather than counted: bela_pre_expr is bela_expr with one predicate
  # added, so two of its lines are the same text as two of bela_expr's and
  # removing "the first occurrence" would take the wrong one out.
  "R/steps/06_flags.R" = list(
    # Ends on the added predicate, which is the only unique line in the block:
    # the `") else "SELECT ... WHERE 1 = 0"` that closes it closes all five of
    # these CTEs. The port's own copy of that line then lines up with the
    # source's, so the splice restores bela_expr's first four lines only.
    list(from = "bela_expr <- if (q2_ok_belantamab) glue(\"",
         to   = "WHERE upper(MAP_MED_TYPE) LIKE 'BEL%' AND PRE_LOT1 = 1",
         src_from = 627L, src_to = 630L),
    list(from = 'checkpoint(con, "NDMM_FLAGS_ALL")',
         to   = 'checkpoint(con, "NDMM_FLAGS_ALL")',
         src_from = 727L, src_to = 741L),
    list(from = "CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS",
         to   = "WHERE {ndmm_criteria_where()}",
         src_from = 744L, src_to = 751L)
  ),
  # The MM-adjacent override. The source logged how many of the expected
  # tumour-group labels matched the production codelist and carried on; an
  # unmatched label means the override silently does nothing for that group,
  # so a patient whose only other cancer is MM-adjacent is excluded as having
  # another cancer. The source's own comment calls that a run-review blocker.
  # This stops instead.
  # The codelist statement. Two changes: the blank-after-normalising guard, and
  # the join that marks a code as the index disease when it is on mm_dx.csv.
  # It is a rewrite rather than added lines because the whole statement moved
  # to a CTE - the first version put that test in a correlated EXISTS whose
  # inner relation has columns called dx and icd_family too, so the unqualified
  # names bound to the inner ones and every other-cancer code came back
  # overridden. Normalise, then join, and qualify everything.
  "R/steps/04_other_malig.R" = list(
    # Ends at the mm_dx join, which is the last line of the statement.
    # The fourth clinical change is inside it. S6.2.1.2 pairs two outpatient
    # claims on the same primary tumor type and/or metastatic cancer. The source
    # pairs on the code-list label, and a label is one ICD code's description -
    # 1,618 over 1,643 codes - so pairing on it means pairing on the identical
    # code, and a cancer at two subsites never confirms itself. This pairs on
    # the ICD category, which is the protocol's unit. It can only add
    # exclusions, so the cohort is smaller than apr_30_2026's.
    list(from = "CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_CODES} AS",
         to   = "ON m.dx = om.dx AND m.icd_family = om.icd_family",
         src_from = 325L, src_to = 332L),
    list(from = "if (is.na(n_matched) || n_matched < n_exp)",
         to   = "\" expected MM-adjacent tumor_group labels\")",
         src_from = 340L, src_to = 348L),
    # The claim scan split from the rule it feeds. One statement became two so
    # NDMM_OTHER_MALIG_GRAIN can ask what the pairing grain costs without
    # scanning med_diagnosis a second time. Same scan, same rule; the seam is
    # new, and a seam is not something SUBST can express.
    list(from = "CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_EVENTS} AS",
         to   = "WITH inpatient_flag AS (",
         src_from = 400L, src_to = 438L)
  )
)

undo_report <- new.env()

undeviate <- function(lines, file) {
  short <- character(0)
  for (sp in SPLICE[[file]]) {
    i <- which(lines == sp$from); j <- which(lines == sp$to)
    if (length(i) != 1L || length(j) != 1L || j[1] < i[1]) {
      short <- c(short, paste0("rewritten block ", sp$from, " ... ", sp$to,
                               " (found ", length(i), " start, ", length(j), " end)"))
      next
    }
    lines <- append(lines[-(i[1]:j[1])], code_only(src[sp$src_from:sp$src_to]),
                    after = i[1] - 1L)
  }
  for (sb in SUBST[[file]]) {
    hit <- which(lines == sb$from)
    if (length(hit) != sb$n)
      short <- c(short, paste0(sb$from, " (expected ", sb$n, ", found ", length(hit), ")"))
    if (length(hit)) lines[hit[seq_len(min(sb$n, length(hit)))]] <- sb$to
  }
  for (nm in names(ADDED[[file]])) {
    want <- ADDED[[file]][[nm]]
    hit  <- which(lines == nm)
    if (length(hit) < want)
      short <- c(short, paste0(nm, " (expected ", want, ", found ", length(hit), ")"))
    if (length(hit)) lines <- lines[-hit[seq_len(min(want, length(hit)))]]
  }
  assign(file, short, envir = undo_report)
  lines
}

# Definitions the port leaves behind: named here and dropped from the SOURCE
# side before the comparison, which is the mirror of ADDED. Each is unreachable
# in this build - nothing calls the two functions, and the three constants are
# read only by them or by nobody - so dropping them changes no behaviour. A name
# that is not found in the source is reported, so an entry cannot quietly rot.
DROPPED <- list(
  # checkpoint() names the table after the view variable, so the *_TBL twins the
  # source needed have no reader here.
  "R/ndmm_constants.R"       = c("NDMM_LOT_LONG_FILT", "NDMM_LOT_LONG_FILT_TBL",
                                 "NDMM_FLAGS_ALL_TBL"),
  # NDMM_LOT1_STARTS is built by 00b_lot1_index.R from claims, not from LOT_LONG.
  "R/steps/02_lot1_starts.R" = "build_lot1_starts_ndmm",
  # Nothing reads NDMM_LOT_LONG_FILT: the LOT-detail views it fed are the
  # dashboard package's, and that reads LOT_LONG_FINAL directly.
  "R/steps/07_cohort.R"      = "build_lot_long_filtered"
)

# Remove each named definition from the source lines. A function runs to its
# closing brace in column 0; a constant is the one line.
undrop <- function(want, file) {
  short <- character(0)
  for (nm in DROPPED[[file]]) {
    i <- grep(paste0("^", nm, "\\s*<-"), want)
    if (!length(i)) { short <- c(short, paste0(nm, " (not in the source)")); next }
    i <- i[1]
    j <- i
    if (grepl("function", want[i], fixed = TRUE)) {
      k <- which(want[(i + 1L):length(want)] == "}")
      if (!length(k)) { short <- c(short, paste0(nm, " (no closing brace)")); next }
      j <- i + k[1]
    }
    want <- want[-(i:j)]
  }
  list(want = want, short = short)
}

CHANGED <- c("R/ndmm_constants.R", "R/steps/03_prior_therapy.R",
             "R/steps/04_other_malig.R", "R/steps/05_pregnancy.R",
             "R/steps/06_flags.R", "R/steps/07_cohort.R")

# Comments are compared out, so the copied comments can be tidied without
# weakening the check. Change a code line and it fails; change a comment and it
# does not. Whole-line comments only - stripping trailing ones would mangle a
# "#" inside a SQL string.
code_only <- function(lines) {
  keep <- !grepl("^\\s*(#|--)", lines) & nzchar(trimws(lines))
  trimws(lines[keep])
}

# The header each ported file adds above the copied body.
body_of <- function(lines) {
  i <- which(!grepl("^\\s*#", lines) & nzchar(trimws(lines)))
  if (!length(i)) return(character(0))
  lines[seq(min(i), length(lines))]
}

# One entry per file in each list. R returns the FIRST match for a duplicated
# name, so a second entry for a file silently disables the first - which is how
# an approved deviation stops being applied while the list still appears to name
# it. Caught here rather than by the comparison failing somewhere unrelated.
for (nm in c("SPLICE", "ADDED", "DROPPED")) {
  k <- names(get(nm))
  d <- unique(k[duplicated(k)])
  ok(!length(d),
     if (length(d)) paste0(nm, " names a file twice, so the first entry is dead: ",
                           paste(d, collapse = ", "))
     else paste0(nm, " names each file once, so no entry shadows another"))
}

cat("\n-- every ported file is the source, line for line --\n")
for (p in PARTS) {
  f <- file.path(ROOT, p$file)
  if (!file.exists(f)) { ok(FALSE, paste0(p$file, ": missing")); next }
  raw  <- code_only(body_of(readLines(f, warn = FALSE)))
  got  <- if (p$file %in% CHANGED) undeviate(raw, p$file) else raw
  want <- code_only(src[p$from:p$to])
  dropped <- character(0)
  if (!is.null(DROPPED[[p$file]])) {
    u <- undrop(want, p$file); want <- u$want; dropped <- u$short
  }
  if (p$file %in% CHANGED) {
    sh <- c(get(p$file, envir = undo_report), dropped)
    if (length(sh)) { ok(FALSE, paste0(p$file, ": an approved deviation is missing -- ", sh[1])); next }
  } else if (length(dropped)) {
    ok(FALSE, paste0(p$file, ": an approved deviation is missing -- ", dropped[1])); next
  }
  if (identical(got, want)) {
    ok(TRUE, paste0(p$file, ": ",
                    if (p$file %in% CHANGED) "identical once the approved deviations are undone"
                    else paste0("same code as lines ", p$from, "-", p$to),
                    " (", length(want), " lines)"))
  } else {
    n <- max(length(got), length(want))
    g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
    d <- which(is.na(g) | is.na(w) | g != w)[1]
    ok(FALSE, paste0(p$file, ": differs at source line ", p$from + d - 1,
                     "\n           source: ", if (is.na(w[d])) "<nothing>" else w[d],
                     "\n           ported: ", if (is.na(g[d])) "<nothing>" else g[d]))
  }
}

cat("\n-- and every ported file parses --\n")
# Line-for-line equality does not imply this: a range that ends mid-statement
# compares clean and then fails to source. It did, between the constants and
# the enrollment step.
for (p in PARTS) {
  f <- file.path(ROOT, p$file)
  e <- tryCatch({ parse(f); NULL }, error = function(e) e)
  ok(is.null(e), paste0(p$file, ": parses",
                        if (!is.null(e)) paste0(" -- ", conditionMessage(e)) else ""))
}

cat("\n-- and the ranges account for the whole cohort half --\n")
# Contiguous and in order, so no source line between the first and the last
# falls outside a ported file. A narrowed range would leave a gap here rather
# than silently dropping the code inside it.
gaps <- character(0)
for (i in seq_along(PARTS)[-1]) {
  if (PARTS[[i]]$from != PARTS[[i - 1]]$to + 1L)
    gaps <- c(gaps, paste0(PARTS[[i - 1]]$to, " -> ", PARTS[[i]]$from))
}
ok(length(gaps) == 0,
   if (length(gaps)) paste0("the ranges skip source lines: ", paste(gaps, collapse = ", "))
   else paste0("the ", length(PARTS), " ranges are contiguous, ",
               PARTS[[1]]$from, "-", PARTS[[length(PARTS)]]$to))

report()
