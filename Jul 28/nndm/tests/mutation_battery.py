# Each entry breaks one thing the suite claims to hold, and the suite has to
# notice. A mutation that survives means the assertion for it reads the source
# rather than running it. Run from anywhere:
#
#   python3 ".../mutation_battery.py"                    changed files only
#   python3 ".../mutation_battery.py" --all              all of them
#   python3 ".../mutation_battery.py" --only "clear run" the ones named that
#
# Every anchor is verified before the first mutation runs, and a run says which
# files it skipped. A clean tree runs everything, which is the release check.
#
# --only takes a substring of a mutation's name, repeatable and comma-separated,
# and matched case-insensitively. It is for iterating on a mutation you are
# writing: editing tests/ re-judges every mutation, so the changed-files rule
# above cannot narrow anything while the suite itself is being edited, and the
# full sweep is four and a half minutes. It is NOT a check - it says so on
# every run - because the mutations it skips are exactly the ones a test edit
# might have stopped catching. Nothing ships on an --only run.
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
# Per-process, so two runs of this file cannot collide on the same staging
# directory - which they did, and shutil.copytree then failed rather than
# reporting a mutation.
BASE = os.path.join(tempfile.gettempdir(), "nndm_mutation_battery_%d" % os.getpid())
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
 ("ndc window unscoped","R/build_nndm.R","                                date_sub(b.MM_DX_DT, {NDMM_PRE_LOT1_DAYS}))","                                date('1900-01-01'))"),
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
 ("age gate dropped","R/steps/00_mm_cohort.R","      AND (year(f.MM_DX_DT) - m.YRDOB) >= {NDMM_MIN_AGE}\n",""),
 ("age moves the diagnosis date","R/steps/00_mm_cohort.R","    WITH ranked AS (\n      SELECT q.PATID, q.MM_DX_DT, q.index_source,\n             row_number() OVER (PARTITION BY q.PATID ORDER BY q.MM_DX_DT) AS rn\n      FROM {NDMM_MM_QUALIFYING} q\n      WHERE q.inpt_qual = 1 OR q.outpt_qual = 1\n    ),\n    first_dx AS (\n      SELECT PATID, MM_DX_DT, index_source FROM ranked WHERE rn = 1\n    )","    WITH ranked AS (\n      SELECT q.PATID, q.MM_DX_DT, q.index_source,\n             row_number() OVER (PARTITION BY q.PATID ORDER BY q.MM_DX_DT) AS rn\n      FROM {NDMM_MM_QUALIFYING} q\n      INNER JOIN {NDMM_MEMBER_DEMO} d ON d.PATID = q.PATID\n      WHERE (q.inpt_qual = 1 OR q.outpt_qual = 1)\n        AND (year(q.MM_DX_DT) - d.YRDOB) >= {NDMM_MIN_AGE}\n    ),\n    first_dx AS (\n      SELECT PATID, MM_DX_DT, index_source FROM ranked WHERE rn = 1\n    )"),
 ("latest qualifying date, not earliest","R/steps/00_mm_cohort.R","ORDER BY q.MM_DX_DT) AS rn","ORDER BY q.MM_DX_DT DESC) AS rn"),
 ("parent criterion leaks in","R/steps/00_mm_cohort.R","           m.GDR_CD, m.YRDOB,","           m.GDR_CD, m.YRDOB, 1 AS CE_b,"),
 ("belantamab abbr unchecked","R/steps/00b_lot1_index.R","  if (is.na(n) || n == 0)","  if (FALSE)"),
 ("belantamab droppable from the index bar","R/steps/00b_lot1_index.R","  for (a in c(NDMM_BELANTAMAB_ABBR, abbrs))","  for (a in abbrs)"),
 ("named agents not barred","R/steps/00b_lot1_index.R","  for (a in c(NDMM_BELANTAMAB_ABBR, abbrs))","  for (a in NDMM_BELANTAMAB_ABBR)"),
 ("index disease can be another cancer","R/steps/04_other_malig.R","    LEFT JOIN {NDMM_MM_DX_CODES} m\n           ON m.dx = om.dx AND m.icd_family = om.icd_family","    LEFT JOIN {NDMM_MM_DX_CODES} m\n           ON m.dx = om.dx AND m.icd_family = om.icd_family AND 1 = 0"),
 ("index disease match ignores family","R/steps/04_other_malig.R","ON m.dx = om.dx AND m.icd_family = om.icd_family","ON m.dx = om.dx"),
 ("mm dx codes not checkpointed","R/build_nndm.R",'CHECKPOINTS <- c("NDMM_FLAGS_ALL", "NDMM_MM_DX_CODES",','CHECKPOINTS <- c("NDMM_FLAGS_ALL",'),
 ("relapse states dropped","R/standalone_constants.R",'  "PLASMA CELL LEUKEMIA IN RELAPSE",\n',''),
 ("remission variants excluded again","R/steps/04_other_malig.R","gsub(\"'\", \"''\", ndmm_mm_adjacent_groups())","gsub(\"'\", \"''\", NDMM_MM_ADJACENT_OVERRIDE)"),
 ("remission override default off","R/config.R",'mm_adjacent_states = Sys.getenv("NDMM_MM_ADJACENT_STATES", unset = "override")','mm_adjacent_states = Sys.getenv("NDMM_MM_ADJACENT_STATES", unset = "exclude")'),
 ("state labels dropped","R/standalone_constants.R",'  "PLASMA CELL LEUKEMIA IN REMISSION",\n',''),
 ("remission setting unknown accepted","R/standalone_constants.R",'    stop("NDMM_MM_ADJACENT_STATES=\'", NDMM_MM_ADJACENT_STATES,','    NDMM_MM_ADJACENT_OVERRIDE) ; if (FALSE) stop("NDMM_MM_ADJACENT_STATES=\'", NDMM_MM_ADJACENT_STATES,'),
 ("remission setting unpinned","R/build_nndm.R",'  mm_adjacent_states   = c("override", "exclude"),\n',''),
 ("required five widened","R/steps/04_other_malig.R","      AND upper(trim(tumor_group)) IN ({req_in})\n",""),
 ("adjacent groups not written","R/build_nndm.R","  build_ndmm_mm_adjacent_groups(con, cfg)\n","  "),
 ("adjacent groups miss remission","R/steps/00b_lot1_index.R","       OR upper(tumor_group) LIKE '%REMISSION%'\n",""),
 ("override binds to the wrong relation","R/steps/04_other_malig.R","           ON m.dx = om.dx AND m.icd_family = om.icd_family","           ON m.dx = m.dx AND m.icd_family = m.icd_family"),
 ("override join dropped","R/steps/04_other_malig.R","    LEFT JOIN {NDMM_MM_DX_CODES} m\n           ON m.dx = om.dx AND m.icd_family = om.icd_family","    "),
 ("override flag ignores the join","R/steps/04_other_malig.R","           CASE {ovr_case}WHEN trim(om.tumor_group) IN ({ovr_in}) OR m.dx IS NOT NULL","           CASE {ovr_case}WHEN trim(om.tumor_group) IN ({ovr_in})"),
 ("belantamab proc matches any type","R/steps/00b_lot1_index.R",'    arm(medical_tbl, "FST_DT",  txt_match("PROC_CD", "\'HCPCS\',\'CPT\'")), "\\n      UNION\\n",','    arm(medical_tbl, "FST_DT",  txt_match("PROC_CD", "c.code_type")), "\\n      UNION\\n",'),
 ("belantamab code type unconstrained","R/steps/00b_lot1_index.R",'    "c.code_type IN (", types, ")",\n','    "1 = 1",\n'),
 ("belantamab ndc type unconstrained","R/steps/00b_lot1_index.R","    \"c.code_type = 'NDC'\",\n","    \"1 = 1\",\n"),
 ("ndc profile misses the study start","R/build_nndm.R","                  BETWEEN least(date('{NDMM_STUDY_START}'),\n                                date_sub(b.MM_DX_DT, {NDMM_PRE_LOT1_DAYS}))","                  BETWEEN date_sub(b.MM_DX_DT, {NDMM_PRE_LOT1_DAYS})"),
 ("choices unchecked","R/build_nndm.R","  check_choices(cfg)\n","  "),
 ("choices allow anything","R/build_nndm.R","    } else if (!(v %in% allowed)) {","    } else if (FALSE) {"),
 ("choice values widened","R/build_nndm.R",'  mm_adjacent_states   = c("override", "exclude"),','  mm_adjacent_states   = c("override", "exclude", "sometimes"),'),
 ("codelist metadata partial","R/build_nndm.R","  miss <- setdiff(CODELIST_FILES, names(seen))","  miss <- character(0)"),
 ("codelist hash unvalidated","R/build_nndm.R","  if (length(bad))\n    stop(\"Hash not usable for \"","  if (FALSE)\n    stop(\"Hash not usable for \""),
 ("belantamab unbounded below","R/steps/00b_lot1_index.R","    study_period = glue(\"b.bel_dt >= date('{NDMM_STUDY_START}')\"),","    study_period = \"1 = 1\","),
 ("belantamab scope from_index","R/steps/00b_lot1_index.R","    from_index   = \"b.bel_dt >= l1.LOT1_START_DT\",","    from_index   = \"1 = 1\","),
 ("belantamab unknown scope accepted","R/steps/00b_lot1_index.R","    stop(\"NDMM_BELANTAMAB_SCOPE='\", NDMM_BELANTAMAB_SCOPE, \"' is not a scope. \",","    \"1 = 1\") ; if (FALSE) stop(\"NDMM_BELANTAMAB_SCOPE='\", NDMM_BELANTAMAB_SCOPE, \"' is not a scope. \","),
 ("belantamab not cohort-scoped","R/steps/00b_lot1_index.R","    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = b.PATID\n    WHERE {scope}","    WHERE {scope}"),
 ("belantamab scope counts dropped","R/build_nndm.R","  build_ndmm_belantamab_scope_counts(con, cfg)\n","  "),
 ("belantamab scope count by claim","R/steps/00b_lot1_index.R","           count(DISTINCT scd.PATID)            AS N_PATIENTS,","           count(*)                             AS N_PATIENTS,"),
 ("belantamab scope unpinned","R/build_nndm.R",'  list(const = "NDMM_BELANTAMAB_SCOPE",       cfg = "belantamab_scope",   note = ""),\n',''),
 ("belantamab scope default","R/build_nndm.R",'  belantamab_scope     = c("study_period", "from_index"),','  belantamab_scope     = c("from_index"),'),
 ("excluded codes ignored","R/steps/00b_lot1_index.R","  codes <- split_setting(NDMM_INDEX_EXCLUDED_CODES)","  codes <- character(0)"),
 ("excluded code type ignored","R/steps/00b_lot1_index.R",'        sql  = sprintf("(code_type = \'%s\' AND code = \'%s\')",','        sql  = sprintf("(code = \'%s\' AND code = \'%s\')",'),
 ("excluded code not normalised","R/steps/00b_lot1_index.R",'  norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))','  norm <- function(x) x'),
 ("excluded codes unpinned","R/build_nndm.R",'  list(const = "NDMM_INDEX_EXCLUDED_CODES",   cfg = "index_excluded_codes", note = ""),\n',''),
 ("excluded codes shape unchecked","R/build_nndm.R",'      if (grepl("[^A-Za-z0-9_,:|%. -]", v))','      if (FALSE)'),
 ("unmatched exclusion accepted","R/steps/00b_lot1_index.R","    if (is.na(n) || n == 0)\n      stop(\"The 1L index exclusions name","    if (FALSE)\n      stop(\"The 1L index exclusions name"),
 ("belantamab not checked for exclusions","R/steps/00b_lot1_index.R","  for (t in terms[-1]) {","  for (t in terms[0]) {"),
 ("index agents not written","R/build_nndm.R","  build_ndmm_index_agents(con, cfg)\n","  "),
 ("index agents counted off-date","R/steps/00b_lot1_index.R","              ON l1.PATID = tx.PATID AND tx.tx_dt = l1.LOT1_START_DT","              ON l1.PATID = tx.PATID"),
 ("index agents counted by claim","R/steps/00b_lot1_index.R","                      count(DISTINCT PATID) AS N_PATIENTS","                      count(*) AS N_PATIENTS"),
 ("index exclusions unpinned","R/build_nndm.R",'  list(const = "NDMM_INDEX_EXCLUDED_ABBRS",   cfg = "index_excluded_abbrs", note = ""),\n',''),
 ("choices not recorded","R/build_nndm.R","{sql_text(NDMM_BELANTAMAB_SCOPE)}, \",","NULL, \","),
 ("belantamab sets the index","R/steps/00b_lot1_index.R","      WHERE bl.code IS NULL\n","      WHERE 1 = 1\n"),
 ("index before diagnosis","R/steps/00b_lot1_index.R","        AND cast(t.{dt} as date) >= b.MM_DX_DT\n",""),
 ("index before the cutoff","R/steps/00b_lot1_index.R","        AND cast(t.{dt} as date) >= date('{NDMM_LOT1_FROM}')\n",""),
 ("index not the first claim","R/steps/00b_lot1_index.R","    SELECT PATID, min(tx_dt) AS LOT1_START_DT","    SELECT PATID, max(tx_dt) AS LOT1_START_DT"),
 ("belantamab abbr constant","R/standalone_constants.R",'NDMM_BELANTAMAB_ABBR <- Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BEL%")','NDMM_BELANTAMAB_ABBR <- Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BELX%")'),
 ("outpatient window setting","config.csv","OUTPATIENT_WINDOW,90","OUTPATIENT_WINDOW,30"),
 ("min age setting","config.csv","MIN_AGE,18","MIN_AGE,21"),
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
 ("ndc profile reads a later view","R/build_nndm.R","          INNER JOIN {NDMM_BASE_COHORT} b ON cast(t.PATID as string) = b.PATID","          INNER JOIN {NDMM_LOT1_STARTS} b ON cast(t.PATID as string) = b.PATID"),
 ("study period start","R/build_nndm.R",'  study_start          = "2016-01-01",','  study_start          = "2015-07-01",'),
 ("study period end","R/build_nndm.R",'  study_end            = "2026-03-31",','  study_end            = "2025-06-30",'),
 ("study period in config","config.csv","STUDY_END,2026-03-31","STUDY_END,2025-06-30"),
 ("death not re-clamped at the index","R/build_nndm.R","             CASE WHEN b.DEATH_DT IS NOT NULL AND b.DEATH_DT < i.INDEX_DATE\n                  THEN i.INDEX_DATE ELSE b.DEATH_DT END AS DEATH_DT","             b.DEATH_DT AS DEATH_DT"),
 ("backwards follow-up allowed","R/build_nndm.R","  if (isTRUE(q$n_backwards > 0))","  if (FALSE)"),
 ("empty follow-up allowed","R/build_nndm.R","  if (isTRUE(q$n_nofu > 0))","  if (FALSE)"),
 ("flags materialization warns again","R/steps/06_flags.R",'  checkpoint(con, "NDMM_FLAGS_ALL")','  tryCatch(checkpoint(con, "NDMM_FLAGS_ALL"), error = function(e) log_msg("WARN: could not materialize"))'),
 ("flags not materialized at all","R/steps/06_flags.R",'  checkpoint(con, "NDMM_FLAGS_ALL")\n\n',''),
 ("flags checkpoint after patids","R/steps/06_flags.R",'  checkpoint(con, "NDMM_FLAGS_ALL")\n\n  db_exec(con, glue("\n    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS','  db_exec(con, glue("\n    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS'),
 ("flags dropped from checkpoints","R/build_nndm.R",'CHECKPOINTS <- c("NDMM_FLAGS_ALL", "NDMM_MM_DX_CODES",','CHECKPOINTS <- c("NDMM_MM_DX_CODES",'),
 ("hot view left as a query","R/build_nndm.R",'                 "NDMM_BELANTAMAB_CODES", "NDMM_LOT1_STARTS",','                 "NDMM_BELANTAMAB_CODES",'),
 ("checkpoint call dropped","R/build_nndm.R",'  checkpoint(con, "NDMM_LOT1_STARTS")\n',''),
 ("checkpoint before its view","R/build_nndm.R",'  build_ndmm_lot1_index(con, cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx))\n  checkpoint(con, "NDMM_INDEX_TX")','  checkpoint(con, "NDMM_INDEX_TX")\n  build_ndmm_lot1_index(con, cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx))'),
 ("checkpoint does not repoint","R/build_nndm.R",'  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW {view} AS SELECT * FROM {tbl}"))\n',''),
 ("checkpoint writes nothing","R/build_nndm.R",'  db_exec(con, glue("CREATE OR REPLACE TABLE {tbl} AS SELECT * FROM {view}"))\n',''),
 ("checkpoint degrades quietly","R/build_nndm.R",'  db_exec(con, glue("CREATE OR REPLACE TABLE {tbl} AS SELECT * FROM {view}"))','  try(db_exec(con, glue("CREATE OR REPLACE TABLE {tbl} AS SELECT * FROM {view}")), silent = TRUE)'),
 ("checkpoints undeclared","R/build_nndm.R","OUTPUTS <- c(DELIVERABLES, CHECKPOINTS)","OUTPUTS <- DELIVERABLES"),
 ("output declared but unwritten","R/build_nndm.R",'DELIVERABLES <- c("NDMM_COHORT",','DELIVERABLES <- c("NDMM_LOT_LONG_FILT", "NDMM_COHORT",'),
 ("dashboard table built again","R/build_nndm.R","  # build_lot_long_filtered() is not called.","  build_lot_long_filtered(con, lot_long)\n  # build_lot_long_filtered() is not called."),
 ("codelist allowlist short","R/codelists.R",'"pregnancy.csv")','")'),
 ("codelist allowlist off","R/codelists.R","  if (!csv_name %in% CODELIST_FILES)","  if (FALSE)"),
 ("codelist hashes dropped","R/build_nndm.R","  write_codelist_metadata(con, cfg)\n","  "),
 ("codelist hash empty ok","R/build_nndm.R","  if (length(miss))\n    stop(\"No hash recorded for \"","  if (FALSE)\n    stop(\"No hash recorded for \""),
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
 ("other malig blank guard","R/steps/04_other_malig.R","        AND regexp_replace(trim(dx), '[^A-Za-z0-9]', '') <> ''\n",""),
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
 ("outputs list","R/build_nndm.R",'DELIVERABLES <- c("NDMM_COHORT", "NDMM_ATTRITION", "NDMM_INDEX_AGENTS",','DELIVERABLES <- c("NDMM_COHORT",'),
 ("ported fu ce constant","R/nndm_constants.R","NDMM_FU_CE_DAYS          <- 0L","NDMM_FU_CE_DAYS          <- 90L"),
 ("ported flags sql","R/steps/06_flags.R","      AND CE_lot1_fu              = 1","      AND 1 = 1"),
 ("cohort sql outside the rewrite","R/steps/07_cohort.R","            ON cast(l.PATID as string) = a.PATID","            ON cast(l.PATID as string) = a.PATIDX"),
 ("ported cohort sql","R/steps/07_cohort.R","     WHERE CE_pre_lot1_12mo = 1 AND CE_lot1_fu = 1\"))$n","     WHERE CE_pre_lot1_12mo = 1\"))$n"),
 ("attrition order","R/build_nndm.R",'  list(key = "ce12_fuce",      label = "+ CE during follow-up"),\n  list(key = "fuce_nopriortx", label = "+ no MM oncology therapy in 12-month baseline"),','  list(key = "fuce_nopriortx", label = "+ no MM oncology therapy in 12-month baseline"),\n  list(key = "ce12_fuce",      label = "+ CE during follow-up"),'),
 ("belantamab last","R/steps/07_cohort.R","       AND NO_PREGNANCY = 1\"))$n","       AND NO_BELANTAMAB = 1\"))$n"),
 ("active run check dropped","R/build_nndm.R","  check_no_active_run(con, cfg)\n","  "),
 ("active run checked too late","R/build_nndm.R","  check_no_active_run(con, cfg)\n  check_upstream(con, cfg)","  check_upstream(con, cfg)\n  check_no_active_run(con, cfg)"),
 ("active run ignores prefix","R/build_nndm.R","    WHERE OBJECT_PREFIX = '{cfg$object_prefix}' AND STATE = 'started'","    WHERE STATE = 'started'"),
 ("active run counts itself","R/build_nndm.R","\n      AND RUN_ID <> '{run_id}'","\n      AND 1 = 1"),
 ("active run warns instead","R/build_nndm.R","  stop(\"Run(s) \", who, \" are already building prefix \"","  log_msg(\"Run(s) \", who, \" are already building prefix \""),
 ("active run override always on","R/build_nndm.R","  if (identical(toupper(Sys.getenv(\"NDMM_IGNORE_ACTIVE_RUN\", unset = \"\")), \"TRUE\")) {","  if (TRUE) {"),
 ("active run drops the timestamp","R/build_nndm.R","  who <- paste(paste0(d$RUN_ID, \" (started \", d$UPDATED_AT, \")\"), collapse = \", \")","  who <- paste(d$RUN_ID, collapse = \", \")"),
 ("readme port count stale","README.md","19 added lines","18 added lines"),
 ("readme port total stale","README.md","36 places","35 places"),
 ("port deviation unregistered","tests/test_same_as_source.R",'    "AND regexp_replace(trim(code), \'[^A-Za-z0-9]\', \'\') <> \'\'" = 1L)','    "AND regexp_replace(trim(code), \'[^A-Za-z0-9]\', \'\') <> \'\'" = 2L)'),
 ("readme criteria drop one","README.md","| 8 | **No pregnancy** |","| 8b | **No pregnancy** |"),
 ("readme criteria lose the file","README.md","anywhere in `[2016-01-01, 2026-03-31]` \u2014 the **study period**, not the baseline | `05_pregnancy.R` |","anywhere in `[2016-01-01, 2026-03-31]` \u2014 the **study period**, not the baseline | |"),
 ("readme funnel short a step","README.md","| 8 | + no pregnancy in study period | \u00a76.2.1.2, excl. 3 |\n","")
,("readme funnel miscounted","README.md","the nine-step funnel","the ten-step funnel"),
 ("readme drops a setting","R/db_utils.R",'  envf <- Sys.getenv("PIPELINE_LOG_FILE", unset = "")','  envf <- Sys.getenv("PIPELINE_LOGFILE", unset = "")'),
 ("readme drops a csv setting","R/config.R",'  primary_groups_csv = Sys.getenv("NDMM_PRIMARY_GROUPS_CSV", unset = ""),','  primary_groups_csv = Sys.getenv("NDMM_PRIMARY_GROUP_CSV", unset = ""),'),
 ("readme drops a checkpoint","README.md","NDMM_ENROLL_SPANS_STRICT","NDMM_ENROLL_SPANS_LOOSE"),
 ("readme drops a view","README.md","NDMM_INDEX_INELIGIBLE","NDMM_INDEX_UNELIGIBLE"),
 ("scope counts not costed","R/steps/00b_lot1_index.R","                                AND f.NO_PREGNANCY             = 1\n                               THEN f.PATID END) AS N_COHORT,","                               THEN f.PATID END) AS N_COHORT,"),
 ("scope counts this run unmarked","R/steps/00b_lot1_index.R","           max(CASE WHEN sp.SCOPE = '{NDMM_BELANTAMAB_SCOPE}' THEN 1 ELSE 0 END)","           max(1)"),
 ("scope counts drop a reading","R/steps/00b_lot1_index.R","    sp AS (SELECT * FROM (VALUES ('ever'), ('study_period'), ('from_index')) AS t(SCOPE))","    sp AS (SELECT * FROM (VALUES ('study_period'), ('from_index')) AS t(SCOPE))"),
 ("scope counts before the flags","R/build_nndm.R","  checkpoint(con, \"NDMM_BELANTAMAB_PATIDS\")\n","  checkpoint(con, \"NDMM_BELANTAMAB_PATIDS\")\n  build_ndmm_belantamab_scope_counts(con, cfg)\n"),
 ("reconcile not written","R/build_nndm.R","  build_ndmm_belantamab_reconcile(con, cfg)\n","  "),
 ("reconcile beyond the cohort","R/steps/00b_lot1_index.R","    INNER JOIN {NDMM_BELANTAMAB_TX} b ON b.PATID = c.PATID","    LEFT JOIN {NDMM_BELANTAMAB_TX} b ON b.PATID = c.PATID"),
 ("reconcile drops the date","R/steps/00b_lot1_index.R","           datediff(b.bel_dt, c.INDEX_DATE)   AS DAYS_FROM_INDEX","           0                                  AS DAYS_FROM_INDEX"),
 ("primary group map never read","R/steps/04_other_malig.R","  pg_src   <- load_primary_groups_csv(nndm_config()$primary_groups_csv)","  pg_src   <- NULL"),
 ("primary group column ignored","R/steps/04_other_malig.R",'  pg_col   <- if (is.null(pg_src)) "om.tumor_group" else "coalesce(pg.pg_primary, om.tumor_group)"','  pg_col   <- "om.tumor_group"'),
 ("pairing back on the raw label","R/steps/04_other_malig.R","             lead(event_dt) OVER (PARTITION BY PATID, grp ORDER BY event_dt) AS next_dt","             lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt"),
 ("pairing dates on the raw label","R/steps/04_other_malig.R","      SELECT DISTINCT PATID, primary_group AS grp, event_dt\n      FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 0","      SELECT DISTINCT PATID, tumor_group AS grp, event_dt\n      FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 0"),
 ("primary group half row accepted","R/codelists.R","  bad <- which(is.na(from) | !nzchar(from) | is.na(to) | !nzchar(to))","  bad <- integer(0)"),
 ("primary group duplicate accepted","R/codelists.R","  dup <- unique(from[duplicated(from)])","  dup <- character(0)"),
 ("primary group alias collides","R/codelists.R",'         "\\n) AS t(pg_label, pg_primary)) pg")','         "\\n) AS t(tumor_group, primary_group)) pg")'),
 ("grain table not written","R/build_nndm.R","  build_ndmm_other_malig_grain(con, cfg)\n","  "),
 ("grain coarsest dropped","R/steps/00b_lot1_index.R",'    by("any label at all",     "")))','    by("as configured",        ", primary_group")))'),
 ("grain rescans the claims","R/steps/00b_lot1_index.R","               FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 1) ip","               FROM cdm.med_diagnosis WHERE inpatient_flg = 1) ip"),
 ("grain pair unbounded","R/steps/00b_lot1_index.R","          AND op.next_dt  BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})\n                              AND date_sub(l1.LOT1_START_DT, 1)\n    WHERE","    WHERE"),
 ("groups table not written","R/build_nndm.R","  build_ndmm_other_malig_groups(con, cfg)\n","  "),
 ("fu ce counts not written","R/build_nndm.R","  build_ndmm_fu_ce_counts(con, cfg)\n","  "),
 ("fu ce windows drop the protocol","R/steps/00b_lot1_index.R","ndmm_fu_ce_windows <- function() sort(unique(c(NDMM_FU_CE_DAYS, 0L, 30L, 60L, 90L)))","ndmm_fu_ce_windows <- function() sort(unique(c(NDMM_FU_CE_DAYS, 0L, 30L, 60L)))"),
 ("fu ce windows drop this run","R/steps/00b_lot1_index.R","ndmm_fu_ce_windows <- function() sort(unique(c(NDMM_FU_CE_DAYS, 0L, 30L, 60L, 90L)))","ndmm_fu_ce_windows <- function() c(0L, 30L, 60L, 90L)"),
 ("fu ce exact months dropped","R/steps/00b_lot1_index.R","            \"(9999, '3 months (exact)', 3)\")","            character(0))"),
 ("fu ce ignores death","R/steps/00b_lot1_index.R","                   coalesce(idx.DEATH_DT, date('{cfg$study_end}'))) AS want_end,","                   date('{cfg$study_end}')) AS want_end,"),
 ("fu ce on gapped spans","R/steps/00b_lot1_index.R","      LEFT JOIN {NDMM_ENROLL_SPANS_STRICT} s ON s.PATID = want.PATID","      LEFT JOIN {NDMM_ENROLL_SPANS} s ON s.PATID = want.PATID"),
 ("fu ce criterion count only","R/steps/00b_lot1_index.R","                                AND f.NO_BELANTAMAB            = 1\n","                                AND 1 = 1\n"),
 ("fu ce this run unmarked","R/steps/00b_lot1_index.R","           max(CASE WHEN cov.sort_key = {NDMM_FU_CE_DAYS} THEN 1 ELSE 0 END)","           max(1)"),
 ("eligible list never read","R/steps/00b_lot1_index.R","  el    <- load_eligible_agents_csv(nndm_config()$eligible_1l_csv)","  el    <- NULL"),
 ("eligible deny rows ignored","R/steps/00b_lot1_index.R","  abbrs <- c(split_setting(NDMM_INDEX_EXCLUDED_ABBRS), el$deny)","  abbrs <- split_setting(NDMM_INDEX_EXCLUDED_ABBRS)"),
 ("allowlist not applied","R/steps/00b_lot1_index.R","  if (length(el$allow)) {\n    allow_in","  if (FALSE) {\n    allow_in"),
 ("allowlist inverted","R/steps/00b_lot1_index.R",'      sql  = sprintf("upper(trim(med_abbr)) NOT IN (%s)", allow_in))','      sql  = sprintf("upper(trim(med_abbr)) IN (%s)", allow_in))'),
 ("allowlist agent unchecked","R/steps/00b_lot1_index.R","  for (a in el$allow) {","  for (a in character(0)) {"),
 ("eligible csv path not pinned","R/build_nndm.R",'  cfg$eligible_1l_csv <- fill(cfg$eligible_1l_csv, "eligible_1l_agents.csv")\n',"  "),
 ("eligible bad value accepted","R/codelists.R",'  bad <- which(!(el %in% c("0", "1")))',"  bad <- integer(0)"),
 ("eligible blank abbr accepted","R/codelists.R","  bad <- which(is.na(ab) | !nzchar(ab))","  bad <- integer(0)"),
 ("eligible duplicate accepted","R/codelists.R","  dup <- unique(ab[duplicated(ab)])","  dup <- character(0)"),
 ("index agents winners only","R/steps/00b_lot1_index.R","    FROM universe u\n    LEFT JOIN barred b ON b.med_abbr = u.med_abbr","    FROM (SELECT DISTINCT upper(trim(med_abbr)) AS med_abbr FROM on_index) u\n    LEFT JOIN barred b ON b.med_abbr = u.med_abbr"),
 ("index agents eligibility hidden","R/steps/00b_lot1_index.R","           CASE WHEN b.med_abbr IS NULL THEN 1 ELSE 0 END AS ELIGIBLE,","           1 AS ELIGIBLE,"),
 ("override csv never read","R/steps/04_other_malig.R","  ovr_src  <- load_override_csv(nndm_config()$mm_adjacent_csv)","  ovr_src  <- NULL"),
 ("override csv ignored by the case","R/steps/04_other_malig.R",'  ovr_case <- if (is.null(ovr_src)) "" else "WHEN ovr.override IS NOT NULL THEN ovr.override "','  ovr_case <- ""'),
 ("override csv path not pinned","R/build_nndm.R","  cfg <- pin_override_csv(cfg, here)\n","  "),
 ("override csv bad value accepted","R/codelists.R",'  bad <- which(!(ov %in% c("0", "1")))','  bad <- integer(0)'),
 ("override csv bad family accepted","R/codelists.R",'  bad <- which(!(fam %in% c("ICD9", "ICD10")))','  bad <- integer(0)'),
 ("override csv blank code accepted","R/codelists.R","  bad <- which(is.na(dx) | !nzchar(dx))","  bad <- integer(0)"),
 ("override csv duplicate accepted","R/codelists.R","  dup <- unique(key[duplicated(key)])","  dup <- character(0)"),
 ("optional csv columns unchecked","R/codelists.R","  miss <- setdiff(cols, names(df))","  miss <- character(0)"),
 ("override csv not hashed","R/codelists.R","  seen[[basename(path)]] <- list(md5 = md5, n_rows = nrow(df))\n","  "),
 ("adjacent codes not written","R/build_nndm.R","  build_ndmm_mm_adjacent_codes(con, cfg)\n","  "),
 ("adjacent codes lists everything","R/steps/00b_lot1_index.R","    FROM {NDMM_OTHER_MALIG_CODES}\n    WHERE is_mm_adjacent_override = 1\n    ORDER BY TUMOR_GROUP, ICD_FAMILY, DX","    FROM {NDMM_OTHER_MALIG_CODES}\n    ORDER BY TUMOR_GROUP, ICD_FAMILY, DX"),
 ("clear run rows dropped","R/build_nndm.R","  clear_run_rows(con, cfg)\n","  "),
 ("clear run rows before the status","R/build_nndm.R","  write_build_status(con, cfg, \"started\")\n  # After the status row, so a run is marked started whatever this does, and\n  # before the first step, so no writer can be reached with the previous\n  # attempt's rows still under this run's id.\n  clear_run_rows(con, cfg)","  clear_run_rows(con, cfg)\n  write_build_status(con, cfg, \"started\")"),
 ("clear run rows misses metadata","R/build_nndm.R","RUN_SCOPED_TABLES <- c(\"NDMM_ATTRITION\", \"NDMM_RUN_METADATA\",\n                       \"NDMM_CODELIST_METADATA\")","RUN_SCOPED_TABLES <- c(\"NDMM_ATTRITION\")"),
 ("clear run rows wipes the started row","R/build_nndm.R","RUN_SCOPED_TABLES <- c(\"NDMM_ATTRITION\", \"NDMM_RUN_METADATA\",","RUN_SCOPED_TABLES <- c(\"NDMM_BUILD_STATUS\", \"NDMM_ATTRITION\", \"NDMM_RUN_METADATA\","),
 ("clear run rows unscoped","R/build_nndm.R","      db_exec(con, glue(\"DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'\")); NULL","      db_exec(con, glue(\"DELETE FROM {tbl}\")); NULL"),
 ("clear run rows swallows everything","R/build_nndm.R","    if (!is.null(err) &&\n        !grepl(\"TABLE_OR_VIEW_NOT_FOUND|Table or view not found\", err,\n               ignore.case = TRUE))","    if (FALSE)"),
 ("clear run rows warns on a first run","R/build_nndm.R","    if (!is.null(err) &&\n        !grepl(\"TABLE_OR_VIEW_NOT_FOUND|Table or view not found\", err,\n               ignore.case = TRUE))","    if (!is.null(err))"),
 ("clear run rows stops the build","R/build_nndm.R","      log_msg(\"WARNING: could not clear \", tbl, \" of run \", run_id, \": \", err,","      stop(\"WARNING: could not clear \", tbl, \" of run \", run_id, \": \", err,"),
 ("active run blocks a first run","R/build_nndm.R","      AND RUN_ID <> '{run_id}'\")), error = function(e) NULL)","      AND RUN_ID <> '{run_id}'\")), error = function(e) data.frame(RUN_ID = \"?\", UPDATED_AT = \"?\"))"),
]
TESTS = ["tests/test_runner.R", "tests/test_same_as_source.R",
         "tests/test_same_as_overall.R"]
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

# --- anchors first ---------------------------------------------------------
# Every anchor is checked against the pristine copy before a single mutation
# runs. A stale one used to surface eight minutes in, after the run it belonged
# to had already been paid for; six runs in a row went that way. This costs one
# file read each and reports them all at once.
stale = [(name, f) for name, f, a, _ in M if a not in open(os.path.join(WORK, f)).read()]
if stale:
    print("stale anchors:", len(stale))
    for n, f in stale: print("   ", n, "->", f)
    sys.exit(1)

for t in ("tests/test_same_as_source.R", "tests/test_same_as_overall.R"):
    probe = subprocess.run(["Rscript", t], cwd=WORK, capture_output=True, text=True)
    if "Skipping" in probe.stdout or probe.returncode != 0:
        sys.exit("%s does not run against the staged copy:\n%s%s"
                 % (t, probe.stdout, probe.stderr))

# --- what to run -----------------------------------------------------------
# Only the mutations whose file this working tree has changed. The suites do
# not vary by mutation, so a file nobody touched cannot have started surviving.
# Anything under tests/ changes what every mutation is judged against, so a
# change there runs the lot - as does --all, and as does a clean tree, which is
# what a release check looks like.
def changed_files():
    out = []
    for cmd in (["git", "diff", "--name-only", "HEAD", "--", SRC],
                ["git", "ls-files", "--others", "--exclude-standard", "--", SRC]):
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if r.returncode: return None            # not a git tree; run everything
        out += [l for l in r.stdout.splitlines() if l.strip()]
    rel = os.path.relpath(SRC, ROOT).replace(os.sep, "/") + "/"
    return sorted({p[len(rel):] for p in out if p.startswith(rel)})

# --only NAME, --only=NAME, and comma-separated within either. Parsed rather
# than grepped out of sys.argv so that a value which happens to start with a
# dash - or a --only with nothing after it - is a usage error rather than a
# pattern that silently matches nothing.
def only_patterns(argv):
    pats, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--only="):
            v = a[len("--only="):]; i += 1
        elif a == "--only":
            if i + 1 >= len(argv): sys.exit("--only needs a mutation name")
            v = argv[i + 1]; i += 2
        else:
            i += 1; continue
        pats += [p.strip().lower() for p in v.split(",") if p.strip()]
    if any(a == "--only" or a.startswith("--only=") for a in argv) and not pats:
        sys.exit("--only was given nothing to match")
    return pats

only = only_patterns(sys.argv[1:])
run_all = "--all" in sys.argv
touched = None if (only or run_all) else changed_files()
if only:
    selected = [m for m in M if any(p in m[0].lower() for p in only)]
    why = "--only " + ", ".join(repr(p) for p in only)
    # A typo would otherwise run nothing and report no problems, which is the
    # one answer this must never give for free.
    if not selected:
        sys.exit("no mutation name contains %s - nothing ran"
                 % " or ".join(repr(p) for p in only))
elif touched is None:
    selected, why = M, "--all" if run_all else "not a git checkout"
elif not touched:
    selected, why = M, "no local changes"
elif any(t.startswith("tests/") for t in touched):
    selected, why = M, "tests/ changed, so every mutation is judged differently"
else:
    selected = [m for m in M if m[1] in touched]
    why = "changed: " + ", ".join(touched)

skipped = len(M) - len(selected)
print("battery size: %d (running %d, skipping %d)" % (len(M), len(selected), skipped))
print("selection:", why)
if only:
    # Named one by one: with --only the whole point is that you chose these, so
    # the run has to show you what it understood you to mean.
    for name, f, _, _ in selected: print("    running:", name, "->", f)
    print("    NOT A CHECK: %d mutations were not run. Re-run with --all before"
          " committing." % skipped)
elif skipped:
    # Named, not silently dropped: a run that says "0 problems" has to say what
    # it did not look at.
    for f in sorted({m[1] for m in M if m not in selected}):
        print("    skipped, unchanged:", f,
              "(%d)" % len([m for m in M if m[1] == f]))

miss = []
for name, f, a, b in selected:
    stage()
    p = os.path.join(WORK, f); s = open(p).read()
    open(p, 'w').write(s.replace(a, b, 1))
    caught = any(subprocess.run(["Rscript", t], cwd=WORK, capture_output=True).returncode != 0
                 for t in TESTS)
    if not caught: miss.append((name, "NOT CAUGHT"))
shutil.rmtree(BASE, ignore_errors=True)
print("problems:", len(miss))
for n, w in miss: print("   ", n, "->", w)
sys.exit(1 if miss else 0)
