import os, re, shutil, subprocess, sys, tempfile
_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(os.environ.get("PKG_BASE", os.path.join(_REPO, "Jul 28")), "lot")
WORK = os.path.join(tempfile.gettempdir(), "lot_mutation_battery_%d" % os.getpid())
M = [
 ("failed-status ordering","R/build_lot.R","          add = TRUE, after = FALSE)","          add = TRUE)"),
 ("complete guard","R/build_lot.R",'on.exit(if (!isTRUE(getOption("lot_complete", FALSE)))\n            try(write_build_status(con, cfg, "failed"), silent = TRUE),','on.exit(try(write_build_status(con, cfg, "failed"), silent = TRUE),'),
 ("invariants no-op","R/build_lot.R",'    if (is.na(n) || n > 0) bad <- c(bad, paste0(iv$name, ": ", n))','    if (FALSE) bad <- c(bad, paste0(iv$name, ": ", n))'),
 ("invariants first only","R/build_lot.R","  for (iv in LOT1_INVARIANTS) {","  for (iv in LOT1_INVARIANTS[1]) {"),
 ("cohort re-validation","R/build_lot.R","  after <- check_cohort_input(con, tbl)","  after <- list(n_rows = before$n_rows, n_patients = before$n_patients)"),
 ("criteria final source","R/build_lot.R",'line_criteria_final_sql(cfg, "lot_long_allflags", "lot_long_final")','line_criteria_final_sql(cfg, "lot_long", "lot_long_final")'),
 ("sct crossed pair","R/build_lot.R",'list(view = "tx_auto_dates",      name = "TX_AUTO_DATES")','list(view = "tx_auto_dates",      name = "SCT_CLAIMS_RAW")'),
 ("sct order","R/build_lot.R",'  list(view = "sct_claims_raw",     name = "SCT_CLAIMS_RAW"),\n  list(view = "tx_auto_dates",      name = "TX_AUTO_DATES"),','  list(view = "tx_auto_dates",      name = "TX_AUTO_DATES"),\n  list(view = "sct_claims_raw",     name = "SCT_CLAIMS_RAW"),'),
 ("sql_count","R/db_utils_lot.R","  format(x, scientific = FALSE, trim = TRUE)","  as.character(x)"),
 ("sql_text NA","R/db_utils_lot.R",'  if (length(x) != 1L || is.na(x)) return("NULL")\n  paste0("\'", gsub("\'", "\'\'", as.character(x), fixed = TRUE), "\'")','  paste0("\'", as.character(x), "\'")'),
 ("CODE_MD5 quoting","R/build_lot.R","           CODE_MD5 = {sql_text(cfg$code_md5)},","           CODE_MD5 = '{cfg$code_md5}',"),
 ("run_id check","R/build_lot.R",'  if (nzchar(r) && !grepl("^[A-Za-z0-9_.-]+$", r))','  if (FALSE)'),
 ("integer text check","R/build_lot.R",'if (nzchar(x) && !grepl("^[0-9]+$", x))','if (nzchar(x) && is.na(suppressWarnings(as.integer(x))))'),
 ("db_replace atomicity","R/db_utils_lot.R","  with_retry(function() for (s in sqls) db_exec_once(con, s))","  for (s in sqls) with_retry(function() db_exec_once(con, s))"),
 ("clear_run_rows call","R/build_lot.R","  clear_run_rows(con, cfg)\n",""),
 ("clear_run_rows scope","R/build_lot.R",'RUN_SCOPED_TABLES <- c("LOT_RUN_METADATA", "LOT_QC_SUMMARY",\n                       "LOT_CODELIST_METADATA")','RUN_SCOPED_TABLES <- c("LOT_RUN_METADATA")'),
 ("concurrency check","R/build_lot.R","  check_no_active_run(con, cfg)\n",""),
 ("concurrency self-filter","R/build_lot.R","AND STATE = 'started'\n      AND RUN_ID <> '{run_id}'","AND STATE = 'started'"),
 ("codelist metadata migration","R/build_lot.R",'  if (length(add)) {\n    db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS (",\n                      paste(add, CODELIST_METADATA_COLS[add], collapse = ", "), ")"))\n    log_msg("  Codelist metadata schema evolution: added ", paste(add, collapse = ", "))\n  }\n',''),
 ("four-file gate","R/build_lot.R","  if (is.na(c4$k) || c4$k != length(CODELIST_FILES))","  if (FALSE)"),
 ("duplicate metadata gate","R/build_lot.R","  if (n > 1)","  if (FALSE)"),
 ("REQUIRED_COHORT_COLS","R/build_lot.R",'"DEATH_DT", "GDR_CD", "YRDOB", "AGE_INDEX_YR",','"DEATH_DT", "GDR_CD", "YRDOB",'),
 ("LOT2_5_INPUT_VIEWS","R/build_lot.R",'"sct_codelist", "sct_claims_raw", "tx_auto_dates",','"sct_codelist", "sct_claims_raw",'),
 ("WAIVABLE_CHECKS","R/build_lot.R",'"subs_substitute", "subs_original", "ndc_short",','"subs_substitute", "subs_original",'),
 ("CODELIST_FILES","R/codelists_lot.R",'"permissible_subs.csv", "cl_sct_codelist.csv"','"cl_sct_codelist.csv"'),
 ("CONTRACT drift","R/build_lot.R","  max_lot                     = 5L,","  max_lot                     = 6L,"),
 ("unpinned config setting","config.csv","MAX_LOT,5,","OUTPUT_DIR,/mnt/artifacts/results,x\nMAX_LOT,5,"),
 ("quarter arithmetic","R/db_utils_lot.R",'qtr <- ceiling(as.integer(format(dt, "%m")) / 3)','qtr <- ceiling(as.integer(format(dt, "%m")) / 3) + 1L'),
 ("date ambiguity (quarter)","R/db_utils_lot.R","    if (length(unique(vapply(cand, format, character(1)))) > 1L)","    if (FALSE)"),
 ("date ambiguity (config)","R/load_inputs.R","  if (length(iso) > 1L)","  if (FALSE)"),
 ("codelist md5 guard","R/codelists_lot.R",'  if (!grepl("^[0-9a-f]{32}$", md5))','  if (FALSE)'),
 ("criteria flag collision","R/build_lot.R","    if (length(clash))\n      stop(","    if (FALSE)\n      stop("),
 ("criteria max_lot","R/line_criteria.R","      if (isTRUE(okl) && !is.null(max_lot) && any(ln > max_lot))","      if (FALSE)"),
 ("undefined call","R/build_lot.R",'tbl <- lot_out("LOT_PATIENT_INPUT")','tbl <- lot_ouy("LOT_PATIENT_INPUT")'),
 ("dangling view","R/steps/06_lot1_end.R","FROM lot1_base_end","FROM lot1_base_endd"),
 ("check_lot_final empty","R/build_lot.R","  if (q$n_rows == 0)\n    stop(tbl, \" is empty","  if (FALSE)\n    stop(tbl, \" is empty"),
 ("ported sql_count","R/steps/08_persist.R","{sql_count(cohort_n)},","{cohort_n},"),
]
TESTS = ["tests/test_line_criteria.R","tests/test_runner.R","../../validation/port/lot.R","../../validation/hygiene/lot_selfcontained.R"]
miss = []
for name, f, a, b in M:
    if os.path.exists(WORK): shutil.rmtree(WORK)
    shutil.copytree(SRC, WORK)
    p = os.path.join(WORK, f); s = open(p).read()
    if a not in s:
        miss.append((name, "ANCHOR GONE")); continue
    open(p,'w').write(s.replace(a,b,1))
    caught = any(subprocess.run(["Rscript",t], cwd=WORK, capture_output=True).returncode != 0 for t in TESTS)
    if not caught: miss.append((name, "NOT CAUGHT"))
print("battery size:", len(M))
print("problems:", len(miss))
for n,w in miss: print("   ", n, "->", w)
