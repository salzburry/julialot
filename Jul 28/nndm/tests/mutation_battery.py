# Each entry breaks one thing the suite claims to hold, and the suite has to
# notice. A mutation that survives means the assertion for it reads the source
# rather than running it. Run from anywhere:
#
#   python3 "Jul 28/nndm/tests/mutation_battery.py"
#
# Attrition labels are deliberately not pinned: they are prose on the delivered
# table and are meant to be editable without a test change.
#
# Two mutations are deliberately absent: dropping method = "radix" from the
# sorts in code_fingerprint() and contract_settings(). Radix buys
# locale-independence, and telling it from the default needs a collation that
# differs from C. This container ships only C locales, so both mutations would
# survive here for want of a machine to fail on rather than for want of a test.
# test_runner.R runs the real comparison when a differing locale exists and
# says plainly when it did not.
import os, shutil, subprocess, sys, tempfile
# The package is the parent of tests/, wherever this file happens to live, and
# the scratch copy goes wherever the platform puts temporary directories. Both
# were absolute paths from the machine this was written on, which meant the
# battery could not run from any other checkout.
SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# test_same_as_source.R looks for apr_30_2026 two levels above the package, and
# skips with status 0 when it is not there. A scratch copy at a flat temp path
# therefore silently drops that whole suite - which is how a stale anchor read
# as a pass once before. So the copy keeps the repository shape and apr_30_2026
# is linked in beside it, and the run below refuses to proceed if the suite
# reports a skip anyway.
ROOT = os.path.dirname(os.path.dirname(SRC))
BASE = os.path.join(tempfile.gettempdir(), "nndm_mutation_battery")
WORK = os.path.join(BASE, os.path.basename(os.path.dirname(SRC)), os.path.basename(SRC))
M = [
 ("upstream check dropped","R/build_nndm.R","  check_upstream(con, cfg)\n","  "),
 ("upstream after the build","R/build_nndm.R","  check_upstream(con, cfg)\n  write_build_status(con, cfg, \"started\")","  write_build_status(con, cfg, \"started\")\n  check_upstream(con, cfg)"),
 ("monotonic after the write","R/build_nndm.R","  check_attrition_monotonic(counts)\n","  "),
 ("date format check","R/build_nndm.R",'    if (nzchar(x) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x))\n      bad <- c(bad, paste0(v, "=\'", x, "\' (want YYYY-MM-DD)"))','    if (FALSE)\n      bad <- c(bad, paste0(v, "=\'", x, "\' (want YYYY-MM-DD)"))'),
 ("integer text check","R/build_nndm.R",'    if (nzchar(x) && !grepl("^[0-9]+$", x))','    if (nzchar(x) && is.na(suppressWarnings(as.integer(x))))'),
 ("run id check","R/build_nndm.R",'  if (nzchar(r) && !grepl("^[A-Za-z0-9_.-]+$", r))','  if (FALSE)'),
 ("settings never raise","R/build_nndm.R","  if (length(bad))\n    stop(\"Settings that would build a different cohort","  if (FALSE)\n    stop(\"Settings that would build a different cohort"),
 ("prefix required","R/build_nndm.R",'  if (!nzchar(prefix))\n    stop("NDMM needs an output prefix','  if (FALSE)\n    stop("NDMM needs an output prefix'),
 ("prefix shape","R/build_nndm.R",'  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))','  if (FALSE)'),
 ("wrk drops the prefix","R/db_utils.R",'  full_name(cfg$work_schema, paste0(prefix, tbl))\n}','  full_name(cfg$work_schema, tbl)\n}'),
 ("contract never raises","R/build_nndm.R","  if (length(wrong))\n    stop(\"This cohort is defined as","  if (FALSE)\n    stop(\"This cohort is defined as"),
 ("contract first key only","R/build_nndm.R","lapply(names(CONTRACT), function(k) {","lapply(names(CONTRACT)[1], function(k) {"),
 ("contract fu_ce_days","R/build_nndm.R","  fu_ce_days           = 0L,","  fu_ce_days           = 90L,"),
 ("upstream raw tables","R/build_nndm.R","  c(cfg$tbl_medical, cfg$tbl_rx, cfg$tbl_med_diag, cfg$tbl_med_proc,\n    cfg$tbl_confinement, cfg$tbl_member_enroll, cfg$tbl_member_elig, cfg$tbl_dod)","  c(cfg$tbl_medical)"),
 ("upstream first miss only","R/build_nndm.R",'    stop("Cannot read:\\n  ", paste(missing, collapse = "\\n  "),','    stop("Cannot read:\\n  ", missing[1],'),
 ("attrition key typo","R/build_nndm.R",'list(key = "noother_nopreg",','list(key = "noother_nopreg2",'),
 ("ndc profile dropped","R/build_nndm.R","  check_ndc_shape(con, cfg)\n","  "),
 ("ndc profile after the scan","R/build_nndm.R","  check_ndc_shape(con, cfg)\n  build_ndmm_belantamab_codes(con)","  build_ndmm_belantamab_codes(con)\n  check_ndc_shape(con, cfg)"),
 ("ndc ten-digit ignored","R/build_nndm.R","  ten    <- prof$n_ndc > 0 & prof$n_10 > 0","  ten    <- rep(FALSE, nrow(prof))"),
 ("ndc bad shape ignored","R/build_nndm.R","  bad    <- prof$n_ndc > 0 & (prof$n_alpha > 0 | prof$n_other > 0 | prof$n_zero > 0)","  bad    <- rep(FALSE, nrow(prof))"),
 ("ndc all-zero ignored","R/build_nndm.R","prof$n_alpha > 0 | prof$n_other > 0 | prof$n_zero > 0)","prof$n_alpha > 0 | prof$n_other > 0)"),
 ("ndc never stops","R/build_nndm.R","    if (!(name %in% waivers())) stop(msg, call. = FALSE)","    if (FALSE) stop(msg, call. = FALSE)"),
 ("ndc one waiver waives all","R/build_nndm.R","    if (!(name %in% waivers())) stop(msg, call. = FALSE)","    if (!length(waivers())) stop(msg, call. = FALSE)"),
 ("ndc codelist side unprofiled","R/build_nndm.R","                db_q(con, codelist_sql))","                db_q(con, codelist_sql)[0, ])"),
 ("ndc window unscoped","R/build_nndm.R","            AND cast(t.{dt} AS date)\n                  BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})\n                      AND date_sub(l1.LOT1_START_DT, 1))))\")","            AND cast(t.{dt} AS date) >= date('1900-01-01'))))\")"),
 ("waiver allowlist off","R/build_nndm.R","waivers <- function() intersect(waivers_named(), WAIVABLE_CHECKS)","waivers <- function() waivers_named()"),
 ("unknown waiver accepted","R/build_nndm.R","  unknown <- setdiff(waivers_named(), WAIVABLE_CHECKS)","  unknown <- character(0)"),
 ("run metadata dropped","R/build_nndm.R","  write_run_metadata(con, cfg, here, counts$ndmm_final)\n","  "),
 ("run metadata no code md5","R/build_nndm.R","{sql_text(code_fingerprint(here))}, ","NULL, "),
 ("run metadata no settings","R/build_nndm.R","         \"{sql_text(contract_settings())}, \"","         \"NULL, \""),
 ("run metadata waivers merged","R/build_nndm.R","         \"{sql_text(paste(sort(waivers_named(), method = 'radix'), collapse = ','))}, \"","         \"NULL, \""),
 ("run metadata not replaced","R/build_nndm.R","    glue(\"DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'\"),\n    glue(\"INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (\",\n         \"{sql_text(run_id)}, {sql_text(cfg$object_prefix)}, \"","    glue(\"SELECT 1\"),\n    glue(\"INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (\",\n         \"{sql_text(run_id)}, {sql_text(cfg$object_prefix)}, \""),
 ("mm dx strict test","R/steps/00_mm_cohort.R","LIKE 'C900%'","LIKE 'C90%'"),
 ("mm dx inpatient POS list","R/steps/00_mm_cohort.R","POS IN ('21', '51', '61')","POS IN ('21', '51')"),
 ("mm dx confinement ignored","R/steps/00_mm_cohort.R","CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL\n           THEN 1 ELSE 0 END AS inpatient_flg","CASE WHEN h.line_inpatient = 1\n           THEN 1 ELSE 0 END AS inpatient_flg"),
 ("mm dx header join not null-safe","R/steps/00_mm_cohort.R","AND d.PAT_PLANID <=> h.PAT_PLANID","AND d.PAT_PLANID =   h.PAT_PLANID"),
 ("mm dx inpatient not strict","R/steps/00_mm_cohort.R","      WHERE inpatient_flg = 1\n        AND mm_dx_strict_flg = 1","      WHERE inpatient_flg = 1"),
 ("mm dx outpatient window","R/steps/00_mm_cohort.R","AND datediff(next_dt, svc_dt) <= {NDMM_OUTPATIENT_WINDOW}","AND datediff(next_dt, svc_dt) <= 365"),
 ("demo eligibility ranking","R/steps/00_mm_cohort.R","cast(ELIGEND as date) DESC) AS rn","cast(ELIGEND as date) ASC) AS rn"),
 ("death month resolution","R/steps/00_mm_cohort.R","ELSE make_date(b.death_yr, b.death_mo, 15)","ELSE make_date(b.death_yr, b.death_mo, 1)"),
 ("death year resolution","R/steps/00_mm_cohort.R","ELSE make_date(b.death_yr, 7, 15)","ELSE make_date(b.death_yr, 1, 1)"),
 ("death clamp","R/steps/00_mm_cohort.R","    SELECT PATID, MM_DX_DT,\n           CASE WHEN death_raw IS NOT NULL AND death_raw < MM_DX_DT THEN MM_DX_DT\n                ELSE death_raw END AS DEATH_DT","    SELECT PATID, MM_DX_DT, death_raw AS DEATH_DT"),
 ("age gate dropped","R/steps/00_mm_cohort.R","        AND (year(q.MM_DX_DT) - m.YRDOB) >= {NDMM_MIN_AGE}\n",""),
 ("latest qualifying date, not earliest","R/steps/00_mm_cohort.R","ORDER BY MM_DX_DT) AS rn","ORDER BY MM_DX_DT DESC) AS rn"),
 ("parent criterion leaks in","R/steps/00_mm_cohort.R","             m.GDR_CD, m.YRDOB,","             m.GDR_CD, m.YRDOB, 1 AS CE_b,"),
 ("belantamab abbr unchecked","R/steps/00b_lot1_index.R","  if (is.na(n) || n == 0)","  if (FALSE)"),
 ("belantamab sets the index","R/steps/00b_lot1_index.R","      WHERE bl.code IS NULL\n","      WHERE 1 = 1\n"),
 ("index before diagnosis","R/steps/00b_lot1_index.R","        AND cast(t.{dt} as date) >= b.MM_DX_DT\n",""),
 ("index before the cutoff","R/steps/00b_lot1_index.R","        AND cast(t.{dt} as date) >= date('{NDMM_LOT1_FROM}')\n",""),
 ("index not the first claim","R/steps/00b_lot1_index.R","    SELECT PATID, min(tx_dt) AS LOT1_START_DT","    SELECT PATID, max(tx_dt) AS LOT1_START_DT"),
 ("belantamab abbr constant","R/standalone_constants.R",'NDMM_BELANTAMAB_ABBR <- Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BEL%")','NDMM_BELANTAMAB_ABBR <- Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BELX%")'),
 ("outpatient window constant","R/standalone_constants.R",'NDMM_OUTPATIENT_WINDOW <- as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90"))','NDMM_OUTPATIENT_WINDOW <- as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "30"))'),
 ("min age constant","R/standalone_constants.R",'NDMM_MIN_AGE <- as.integer(Sys.getenv("MIN_AGE", unset = "18"))','NDMM_MIN_AGE <- as.integer(Sys.getenv("MIN_AGE", unset = "21"))'),
 ("mm_dx codelist undeclared","R/codelists.R",'CODELIST_FILES <- c("cl_mma_codelist.csv", "mm_dx.csv", "other_malig.csv",\n                    "pregnancy.csv")','CODELIST_FILES <- c("cl_mma_codelist.csv", "other_malig.csv",\n                    "pregnancy.csv")'),
 ("dod unpreflighted","R/build_nndm.R","    cfg$tbl_confinement, cfg$tbl_member_enroll, cfg$tbl_member_elig, cfg$tbl_dod)","    cfg$tbl_confinement, cfg$tbl_member_enroll, cfg$tbl_member_elig)"),
 ("cohort index from the diagnosis","R/build_nndm.R","      SELECT DISTINCT cast(p.PATID as string) AS PATID, l1.LOT1_START_DT AS INDEX_DATE","      SELECT DISTINCT cast(p.PATID as string) AS PATID, b0.MM_DX_DT AS INDEX_DATE"),
 ("cohort age inherited","R/build_nndm.R","           (year(i.INDEX_DATE) - d.YRDOB)                             AS AGE_INDEX_YR,","           d.AGE_INDEX_YR                                             AS AGE_INDEX_YR,"),
 ("cohort ce end unanchored","R/build_nndm.R","             AND s.cov_start <= i.INDEX_DATE\n             AND s.cov_end   >= i.INDEX_DATE\n","             AND s.cov_end >= date('1900-01-01')\n"),
 ("cohort fu from wrong day","R/build_nndm.R","                    date_add(i.INDEX_DATE, 1)) + 1                    AS FU_DAYS,","                    date_add(d.INDEX_DATE, 1)) + 1                    AS FU_DAYS,"),
 ("cohort column dropped","R/build_nndm.R","           d.GDR_CD,\n","           "),
 ("cohort check dropped","R/build_nndm.R","  check_ndmm_cohort(con, cfg, counts$ndmm_final)\n","  "),
 ("cohort columns unchecked","R/build_nndm.R","  miss <- setdiff(NDMM_COHORT_COLS, cols)","  miss <- character(0)"),
 ("cohort duplicates allowed","R/build_nndm.R","  if (q$n_rows != q$n_pat)","  if (FALSE)"),
 ("cohort null index allowed","R/build_nndm.R","  if (isTRUE(q$n_noidx > 0))","  if (FALSE)"),
 ("cohort count unreconciled","R/build_nndm.R","  if (!is.na(n_expected) && q$n_pat != n_expected)","  if (FALSE)"),
 ("cohort col list short","R/build_nndm.R",'NDMM_COHORT_COLS <- c("PATID", "INDEX_DATE", "ENDDATE", "ENDDATE_CE",\n                      "DEATH_DT", "GDR_CD", "YRDOB", "AGE_INDEX_YR",\n                      "FU_DAYS", "FU_DAYS_CE")','NDMM_COHORT_COLS <- c("PATID", "INDEX_DATE")'),
 ("output declared but unwritten","R/build_nndm.R",'OUTPUTS <- c("NDMM_FLAGS_ALL", "NDMM_COHORT", "NDMM_ATTRITION",','OUTPUTS <- c("NDMM_LOT_LONG_FILT", "NDMM_FLAGS_ALL", "NDMM_COHORT", "NDMM_ATTRITION",'),
 ("dashboard table built again","R/build_nndm.R","  # build_lot_long_filtered() is not called.","  build_lot_long_filtered(con, lot_long)\n  # build_lot_long_filtered() is not called."),
 ("codelist allowlist short","R/codelists.R",'"pregnancy.csv")','")'),
 ("codelist allowlist off","R/codelists.R","  if (!csv_name %in% CODELIST_FILES)","  if (FALSE)"),
 ("codelist hashes dropped","R/build_nndm.R","  write_codelist_metadata(con, cfg)\n","  "),
 ("codelist hash empty ok","R/build_nndm.R","  if (!length(seen))","  if (FALSE)"),
 ("member_enrollment unpreflighted","R/build_nndm.R","cfg$tbl_confinement, cfg$tbl_member_enroll, cfg$tbl_member_elig, cfg$tbl_dod)","cfg$tbl_confinement, cfg$tbl_member_elig, cfg$tbl_dod)"),
 ("constants unchecked","R/build_nndm.R","  check_constants(cfg)\n","  "),
 ("constants never raise","R/build_nndm.R",'    stop("The SQL would not use the settings this run checked','    warning("The SQL would not use the settings this run checked'),
 ("lot1_from constant unchecked","R/build_nndm.R",'  list(const = "NDMM_LOT1_FROM",     cfg = "lot1_from",\n       note = "set by NDMM_LOT1_FROM, not LOT1_FROM"),',''),
 ("study_start constant unchecked","R/build_nndm.R",'  list(const = "NDMM_STUDY_START",   cfg = "study_start",\n       note = "set by STUDY_START"),\n',''),
 ("mma blank code guard","R/steps/03_prior_therapy.R","      AND regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '') <> ''\n",""),
 ("mma ndc digit guard","R/steps/03_prior_therapy.R","      AND (upper(trim(CL_CODE_TYPE)) <> 'NDC'\n           OR regexp_replace(CL_CODE, '[^0-9]', '') <> '')\n",""),
 ("claim proc blank guard","R/steps/03_prior_therapy.R","       AND regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''\n",""),
 ("claim rx ndc blank guard","R/steps/03_prior_therapy.R","       AND regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') <> ''\n",""),
 ("op pair second claim unbounded","R/steps/04_other_malig.R","            AND op.next_dt  BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end\n",""),
 ("op pair second claim half-bounded","R/steps/04_other_malig.R","            AND op.next_dt  BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end","            AND op.next_dt  >= l1.pre_lot1_start"),
 ("op pair first claim unbounded","R/steps/04_other_malig.R","            AND op.first_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end\n",""),
 ("op pair 30-day window","R/steps/04_other_malig.R","            AND op.diff_days <= 30\n",""),
 ("ip claim unbounded","R/steps/04_other_malig.R","            AND ip.event_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end\n",""),
 ("baseline ends on the index date","R/steps/04_other_malig.R","             date_sub(LOT1_START_DT, 1)                  AS pre_lot1_end","             LOT1_START_DT                               AS pre_lot1_end"),
 ("other malig blank guard","R/steps/04_other_malig.R","      AND regexp_replace(trim(dx), '[^A-Za-z0-9]', '') <> ''\n",""),
 ("pregnancy blank guard","R/steps/05_pregnancy.R","      AND regexp_replace(trim(code), '[^A-Za-z0-9]', '') <> ''\n",""),
 ("override warns again","R/steps/04_other_malig.R","  if (is.na(n_matched) || n_matched < n_exp)\n    stop(","  if (FALSE)\n    stop("),
 ("attrition step dropped","R/build_nndm.R",'  list(key = "noother",        label = "+ no other cancer in 12-month baseline"),\n',''),
 ("monotonic never raises","R/build_nndm.R","  bad <- which(n[-1] > n[-length(n)])","  bad <- integer(0)"),
 ("monotonic empty cohort","R/build_nndm.R","  if (n[length(n)] == 0)","  if (FALSE)"),
 ("attrition scientific notation","R/db_utils.R","  format(x, scientific = FALSE, trim = TRUE)","  as.character(x)"),
 ("attrition percentages","R/build_nndm.R","           else sql_count(round(100 * n / start, 2))","           else \"NULL\""),
 ("db_replace atomicity","R/db_utils.R","  with_retry(function() for (s in sqls) db_exec_once(con, s))","  for (s in sqls) with_retry(function() db_exec_once(con, s))"),
 ("status size unquoted","R/build_nndm.R","{sql_count(n)}, ","{n}, "),
 ("failed status ordering","R/build_nndm.R","          add = TRUE, after = FALSE)","          add = TRUE)"),
 ("outputs list","R/build_nndm.R",'OUTPUTS <- c("NDMM_FLAGS_ALL", "NDMM_COHORT", "NDMM_ATTRITION",\n             "NDMM_CODELIST_METADATA", "NDMM_RUN_METADATA",\n             "NDMM_BUILD_STATUS")','OUTPUTS <- c("NDMM_FLAGS_ALL", "NDMM_COHORT", "NDMM_ATTRITION")'),
 ("ported fu ce constant","R/nndm_constants.R","NDMM_FU_CE_DAYS          <- 0L","NDMM_FU_CE_DAYS          <- 90L"),
 ("ported flags sql","R/steps/06_flags.R","      AND CE_lot1_fu              = 1","      AND 1 = 1"),
 ("cohort sql outside the rewrite","R/steps/07_cohort.R","            ON cast(l.PATID as string) = a.PATID","            ON cast(l.PATID as string) = a.PATIDX"),
 ("ported cohort sql","R/steps/07_cohort.R","     WHERE CE_pre_lot1_12mo = 1 AND CE_lot1_fu = 1\"))$n","     WHERE CE_pre_lot1_12mo = 1\"))$n"),
 ("attrition order","R/build_nndm.R",'  list(key = "ce12_fuce",      label = "+ CE during follow-up"),\n  list(key = "fuce_nopriortx", label = "+ no MM oncology therapy in 12-month baseline"),','  list(key = "fuce_nopriortx", label = "+ no MM oncology therapy in 12-month baseline"),\n  list(key = "ce12_fuce",      label = "+ CE during follow-up"),'),
 ("belantamab last","R/steps/07_cohort.R","       AND NO_PREGNANCY = 1\"))$n","       AND NO_BELANTAMAB = 1\"))$n"),
]
TESTS = ["tests/test_runner.R", "tests/test_same_as_source.R",
         "tests/test_same_as_overall.R"]
miss = []
def stage():
    if os.path.exists(BASE): shutil.rmtree(BASE)
    os.makedirs(os.path.dirname(WORK))
    shutil.copytree(SRC, WORK)
    for rel in ("apr_30_2026", os.path.join("Jul 28", "overall")):
        real = os.path.join(ROOT, rel)
        link = os.path.join(BASE, rel)
        if not os.path.isdir(real): continue
        os.makedirs(os.path.dirname(link), exist_ok=True)
        try: os.symlink(real, link)
        except (OSError, NotImplementedError): shutil.copytree(real, link)

stage()
for t in ("tests/test_same_as_source.R", "tests/test_same_as_overall.R"):
    probe = subprocess.run(["Rscript", t], cwd=WORK, capture_output=True, text=True)
    if "Skipping" in probe.stdout or probe.returncode != 0:
        sys.exit("%s does not run against the staged copy:\n%s%s"
                 % (t, probe.stdout, probe.stderr))

for name, f, a, b in M:
    stage()
    p = os.path.join(WORK, f); s = open(p).read()
    if a not in s:
        miss.append((name, "ANCHOR GONE")); continue
    open(p, 'w').write(s.replace(a, b, 1))
    caught = any(subprocess.run(["Rscript", t], cwd=WORK, capture_output=True).returncode != 0 for t in TESTS)
    if not caught: miss.append((name, "NOT CAUGHT"))
print("battery size:", len(M))
print("problems:", len(miss))
for n, w in miss: print("   ", n, "->", w)
