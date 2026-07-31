# Each entry breaks one thing the suite claims to hold, and the suite has to
# notice. A mutation that survives means the assertion for it reads the source
# rather than running it. Run from anywhere:
#
#   python3 "Jul 28/nndm/tests/mutation_battery.py"
#
# Attrition labels are deliberately not pinned: they are prose on the delivered
# table and are meant to be editable without a test change.
import os, shutil, subprocess
SRC = "/home/user/julialot/Jul 28/nndm"
WORK = "/tmp/claude-0/-home-user-julialot/548affc2-dd45-5731-a3cd-a13a48e1a7b2/scratchpad/nbat"
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
 ("upstream raw tables","R/build_nndm.R","  raw <- c(cfg$tbl_medical, cfg$tbl_rx, cfg$tbl_med_diag, cfg$tbl_med_proc,\n           cfg$tbl_confinement)","  raw <- c(cfg$tbl_medical)"),
 ("upstream first miss only","R/build_nndm.R",'    stop("Cannot read:\\n  ", paste(missing, collapse = "\\n  "),','    stop("Cannot read:\\n  ", missing[1],'),
 ("upstream built tables","R/build_nndm.R","  for (t in names(UPSTREAM)) {","  for (t in names(UPSTREAM)[0]) {"),
 ("upstream owner","R/build_nndm.R",'  ELIG_COH_FINAL = "Jul 28/overall"','  ELIG_COH_FINAL = "Jul 28/lot"'),
 ("attrition key typo","R/build_nndm.R",'list(key = "noother_fuce",','list(key = "noother_fu",'),
 ("attrition step dropped","R/build_nndm.R",'  list(key = "noother",               label = "+ no other cancer in 12-month baseline"),\n',''),
 ("monotonic never raises","R/build_nndm.R","  bad <- which(n[-1] > n[-length(n)])","  bad <- integer(0)"),
 ("monotonic empty cohort","R/build_nndm.R","  if (n[length(n)] == 0)","  if (FALSE)"),
 ("attrition scientific notation","R/db_utils.R","  format(x, scientific = FALSE, trim = TRUE)","  as.character(x)"),
 ("attrition percentages","R/build_nndm.R","           else sql_count(round(100 * n / start, 2))","           else \"NULL\""),
 ("db_replace atomicity","R/db_utils.R","  with_retry(function() for (s in sqls) db_exec_once(con, s))","  for (s in sqls) with_retry(function() db_exec_once(con, s))"),
 ("status size unquoted","R/build_nndm.R","{sql_count(n)}, ","{n}, "),
 ("failed status ordering","R/build_nndm.R","          add = TRUE, after = FALSE)","          add = TRUE)"),
 ("outputs list","R/build_nndm.R",'OUTPUTS <- c("NDMM_FLAGS_ALL", "NDMM_LOT_LONG_FILT", "NDMM_COHORT",\n             "NDMM_ATTRITION", "NDMM_BUILD_STATUS")','OUTPUTS <- c("NDMM_FLAGS_ALL", "NDMM_LOT_LONG_FILT", "NDMM_COHORT")'),
 ("ported fu ce constant","R/nndm_constants.R","NDMM_FU_CE_DAYS          <- 0L","NDMM_FU_CE_DAYS          <- 90L"),
 ("ported flags sql","R/steps/06_flags.R","      AND CE_lot1_fu              = 1","      AND 1 = 1"),
 ("ported cohort sql","R/steps/07_cohort.R","       AND CE_lot1_fu = 1","       AND 1 = 1"),
]
TESTS = ["tests/test_runner.R", "tests/test_same_as_source.R"]
miss = []
for name, f, a, b in M:
    if os.path.exists(WORK): shutil.rmtree(WORK)
    shutil.copytree(SRC, WORK)
    p = os.path.join(WORK, f); s = open(p).read()
    if a not in s:
        miss.append((name, "ANCHOR GONE")); continue
    open(p, 'w').write(s.replace(a, b, 1))
    caught = any(subprocess.run(["Rscript", t], cwd=WORK, capture_output=True).returncode != 0 for t in TESTS)
    if not caught: miss.append((name, "NOT CAUGHT"))
print("battery size:", len(M))
print("problems:", len(miss))
for n, w in miss: print("   ", n, "->", w)
