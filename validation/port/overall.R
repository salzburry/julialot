#!/usr/bin/env Rscript
# Every step this package builds is apr_30_2026's step, line for line, once the
# deviations registered below are undone.
#
#   Rscript validation/port/overall.R
#
# This suite used to assert that a changed step "differs from source", which is
# satisfied by any difference at all - so once a step was listed as changed,
# every later edit to it was invisible here. It now works the way port/ndmm.R
# does: each deviation is written out, both sides of it, and undone before the
# comparison. What is left must match the source exactly. A deviation that stops
# matching is reported rather than skipped, so deleting one from the shipping
# code does not read as a pass either.

COMMON <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (!length(a)) getwd()
       else dirname(normalizePath(gsub("~+~", " ",
                                       sub("^--file=", "", a[1]), fixed = TRUE)))
  file.path(dirname(d), "_common.R")
})
source(COMMON)
ROOT <- pkg_dir("overall")
# apr_30_2026 sits at the repo root; walk up until we find it.
APR <- BASELINE
need_dirs(ROOT, APR)

pass <- 0L; fail <- 0L
ok <- function(cond, what, detail = NULL) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok   ", what, "\n") }
  else {
    fail <<- fail + 1L; cat("  FAIL ", what, "\n")
    for (d in detail) cat("         ", d, "\n")
  }
}

if (!file.exists(file.path(APR, "R", "pipeline_steps.R"))) {
  cat("apr_30_2026 not present -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}

# glue is not installed everywhere; the templates only use {expr}, so a small
# stand-in keeps this runnable offline. Where the real package is present it has
# to be attached rather than merely loadable: env_of() sys.source()s each file
# into an environment whose parent is globalenv, so glue() is found on the
# search path or not at all.
if (requireNamespace("glue", quietly = TRUE)) {
  library(glue)
} else {
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)),
                 collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }
  assign("glue", glue, envir = globalenv())
}

# Build the config once and use it for both sides.
env_of <- function(dir, files, extra = NULL) {
  e <- new.env(parent = globalenv())
  for (f in files) sys.source(file.path(dir, f), envir = e)
  if (!is.null(extra)) for (f in extra) sys.source(f, envir = e)
  e
}

apr <- env_of(file.path(APR, "R"),
              c("load_inputs.R", "config_prompts.R", "codelists.R",
                "db_utils.R", "criteria_attrition.R", "pipeline_steps.R"))
apr$load_pipeline_inputs(c(APR, dirname(APR)))
cfg <- apr$cfg_defaults
cfg$outpatient_window <- apr$validate_outpatient_window(cfg$outpatient_window)

# This folder. Same helper files, but our split pipeline_steps.R + steps/.
new <- env_of(file.path(ROOT, "R"),
              c("load_inputs.R", "config_prompts.R",
                "db_utils.R", "criteria_attrition.R", "pipeline_steps.R"))
new$load_phase_steps(file.path(ROOT, "R", "steps"))

a <- Filter(Negate(is.null), apr$build_steps(cfg, new.env()))
b <- Filter(Negate(is.null), new$build_steps(cfg, new.env()))

# Registry lines carrying {table} or {date} are rendered against the same config
# and the same naming helpers the steps use, so this file names no catalog,
# schema, table vintage or study date of its own.
REG <- local({
  e <- list2env(c(new$make_naming_helpers(cfg), list(cfg = cfg)),
                parent = globalenv())
  e
})
r <- function(x) {
  if (!length(x)) return(character(0))
  vapply(x, function(s) as.character(glue(s, .envir = REG)), character(1),
         USE.NAMES = FALSE)
}

# ---------------------------------------------------------------------------
# The deviations.
#
# Each entry is one edit: `port` is the contiguous run of lines this package
# emits, `src` the run apr_30_2026 emits in its place (character(0) when the
# port only adds). Runs are matched as sequences rather than as single lines,
# so a block that opens with something as common as UNION ALL is still located
# unambiguously. `n` says how many times the run occurs; a different count is a
# failure, which is what makes an unregistered edit - or a registered one that
# has since been deleted - visible.
#
# The ICD_FLAG family test appears in five steps. Both sides are written out
# here rather than obtained by calling icd_family_sql(): if that helper started
# emitting something else, calling it would make this test agree with the change
# instead of catching it.
port_icd <- function(col, nine, ten)
  paste0("CASE WHEN upper(trim(", col, ")) IN ('9', 'ICD9', 'ICD-9') THEN '",
         nine, "' WHEN upper(trim(", col, ")) IN ('10', 'ICD10', 'ICD-10') THEN '",
         ten, "' ELSE NULL END")
src_icd <- function(col, nine, ten)
  paste0("CASE WHEN upper(", col, ") IN ('9','ICD9','ICD-9') THEN '", nine,
         "' ELSE '", ten, "' END")
icd <- function(col, nine, ten, prefix = "", suffix = "", n = 1L)
  list(port = paste0(prefix, port_icd(col, nine, ten), suffix),
       src  = paste0(prefix, src_icd(col, nine, ten), suffix), n = n)

# The line-level inpatient test, before and after. The source classified a claim
# from max(POS) and max(TOS_CD), so a claim carrying an inpatient line (POS 21)
# and a lexically larger outpatient one (POS 81) has max(POS) = 81 and reads as
# outpatient. The header flags each line first now, and the classification reads
# the aggregated flag.
SRC_IP  <- c("CASE WHEN h.POS IN ('21', '51', '61')",
             "OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')",
             "OR cf.CONF_ID IS NOT NULL")
SRC_OP  <- c("CASE WHEN NOT (h.POS IN ('21', '51', '61')",
             "OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')",
             "OR cf.CONF_ID IS NOT NULL)")
PORT_IP <- "CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL"
PORT_OP <- "CASE WHEN NOT (h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL)"

# The facility procedure code, read by the pregnancy and clinical-trial scans.
# Both exclusions ask for a diagnosis, procedure or revenue code, and every
# other scan in the package already reads this column; these two did not, so a
# code populated only there kept the patient. It can only add exclusions.
BILL_PROC <- c(
  "bill_proc AS (",
  "SELECT PATID, cast(FST_DT as date) AS event_dt, 'HCPCS' AS code_type,",
  "upper(regexp_replace(BILL_PROC_CD, '[^A-Za-z0-9]', '')) AS code",
  "FROM {cdm_src(cfg$tbl_medical)}",
  "WHERE BILL_PROC_CD IS NOT NULL",
  "AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')",
  "),")
EVENTS_SRC  <- paste0("events AS (SELECT * FROM dx UNION ALL SELECT * FROM ",
                      "hcpcs_proc UNION ALL SELECT * FROM icd_proc UNION ALL ",
                      "SELECT * FROM rev),")
EVENTS_PORT <- paste0("events AS (SELECT * FROM dx UNION ALL SELECT * FROM ",
                      "hcpcs_proc UNION ALL SELECT * FROM bill_proc UNION ALL ",
                      "SELECT * FROM icd_proc UNION ALL SELECT * FROM rev),")

DEVIATIONS <- list(
  # Demographic selection was nondeterministic: one row per patient was picked
  # by known-sex then newest ELIGEND, and nothing broke a tie beyond that. Two
  # rows sharing an ELIGEND with YRDOB 1980 and 2010 could make the same
  # patient 40 and eligible on one run and 10 and excluded on the next, and a
  # newer row carrying a null YRDOB won and took the age with it. The added
  # keys prefer a usable birth year and then order by the values themselves,
  # so the same input always yields the same patient.
  # The two sort keys also swapped: a usable birth year now outranks a known
  # sex. Ranking sex first lost patients - an 'M' row with no YRDOB beat a 'U'
  # row carrying 1980, and the age filter then dropped someone eligible. So the
  # whole ORDER BY is registered rather than the added lines alone.
  "15_member_demo" = list(
    list(port = c("ORDER BY CASE WHEN cast(YRDOB as int) IS NOT NULL THEN 0 ELSE 1 END,",
                  "CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,",
                  "cast(ELIGEND as date) DESC,",
                  "cast(YRDOB as int), GDR_CD) AS rn"),
         src  = c("ORDER BY CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,",
                  "cast(ELIGEND as date) DESC) AS rn"))),
  # Every code list is read DISTINCT, and every one drops codes that normalize
  # to blank. A code that is only punctuation normalizes to the empty string and
  # then equals the normalized form of any claim whose code is missing - the
  # patient is flagged on a claim with no code in it. In the NDC joins both
  # sides lpad to 00000000000, which is the same failure. A repeated code in a
  # CSV duplicates every claim row it matches, which changes counts rather than
  # membership, but the counts are a deliverable too. Both can only remove
  # matches the source should not have made.
  "01_mm_dx_codes" = list(
    list(port = "SELECT DISTINCT", src = "SELECT"),
    list(port = "WHERE dx IS NOT NULL AND regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''",
         src  = "WHERE dx IS NOT NULL")),
  "03_mm_therapy_codes" = list(
    list(port = "SELECT DISTINCT upper(trim(CL_CODE_TYPE)) AS code_type,",
         src  = "SELECT upper(trim(CL_CODE_TYPE)) AS code_type,"),
    list(port = "AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''",
         src  = character(0))),
  "04_preg_codes" = list(
    list(port = "SELECT DISTINCT upper(trim(code_type)) AS code_type,",
         src  = "SELECT upper(trim(code_type)) AS code_type,"),
    list(port = "WHERE code IS NOT NULL AND regexp_replace(code, '[^A-Za-z0-9]', '') <> ''",
         src  = "WHERE code IS NOT NULL")),
  "05_clintrial_codes" = list(
    list(port = "SELECT DISTINCT upper(trim(code_type)) AS code_type,",
         src  = "SELECT upper(trim(code_type)) AS code_type,"),
    list(port = "WHERE code IS NOT NULL AND regexp_replace(code, '[^A-Za-z0-9]', '') <> ''",
         src  = "WHERE code IS NOT NULL")),
  "06_other_malig_codes" = list(
    list(port = "SELECT DISTINCT", src = "SELECT"),
    list(port = "AND regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''",
         src  = character(0))),

  # The claim header gained the line-level flag the classification steps read.
  "07a_med_claim_header" = list(
    list(port = "max(TOS_CD)  AS TOS_CD,", src = "max(TOS_CD)  AS TOS_CD"),
    list(port = c("max(CASE WHEN POS IN ('21', '51', '61')",
                  "OR TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')",
                  "THEN 1 ELSE 0 END) AS line_inpatient"),
         src  = character(0))),

  # The source read any ICD_FLAG that was not an ICD-9 spelling as ICD-10, so a
  # blank or unexpected flag on a genuine ICD-9 claim was mis-classed and then
  # matched no code. Both families are named now and anything else is NULL,
  # which matches neither. It can only remove matches the source should not have
  # made, and ndmm carries the same change - tests/test_same_as_overall.R holds
  # the two together.
  "08a_mm_dx_events_all" = list(
    icd("d.ICD_FLAG", "ICD9", "ICD10", suffix = " AS icd_family,"),
    list(port = PORT_IP, src = SRC_IP),
    list(port = PORT_OP, src = SRC_OP),
    icd("d.ICD_FLAG", "ICD9", "ICD10", prefix = "CASE WHEN (", suffix = ") = 'ICD9'"),
    icd("d.ICD_FLAG", "ICD9", "ICD10", prefix = "OR (", suffix = ") = 'ICD10'"),
    list(port = "h.line_inpatient AS pos_tos_inpatient",
         src  = paste0("CASE WHEN h.POS IN ('21', '51', '61') OR h.TOS_CD IN ",
                       "('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', ",
                       "'FAC_IP.SNF') THEN 1 ELSE 0 END AS pos_tos_inpatient")),
    icd("d.ICD_FLAG", "ICD9", "ICD10", prefix = "AND (", suffix = ") = c.icd_family")),
  "22_other_malig_flag" = list(
    icd("d.ICD_FLAG", "ICD9", "ICD10", suffix = " AS icd_family"),
    list(port = PORT_IP, src = SRC_IP)),

  "20_pregnancy_flag" = list(
    icd("ICD_FLAG", "ICD9DIAG", "ICD10DIAG", suffix = " AS code_type,"),
    icd("ICD_FLAG", "ICD9PROC", "ICD10PROC", suffix = " AS code_type,"),
    list(port = BILL_PROC, src = character(0)),
    list(port = EVENTS_PORT, src = EVENTS_SRC)),
  "21_clintrial_flag" = list(
    icd("ICD_FLAG", "ICD9DIAG", "ICD10DIAG", suffix = " AS code_type,"),
    icd("ICD_FLAG", "ICD9PROC", "ICD10PROC", suffix = " AS code_type,"),
    list(port = BILL_PROC, src = character(0)),
    list(port = EVENTS_PORT, src = EVENTS_SRC)),

  # The fifth therapy source. The program spec names T_MED_PROCEDURE (PROC)
  # among the CDM tables joined to CL_MMA_CODELIST, and Optum business rule 5
  # says PROC carries a drug given as a procedure under a HCPCS or CPT code. The
  # source read four sources and not that one, so a therapy administered and
  # coded that way was invisible to it.
  "18_therapy_events" = list(
    list(port = "AND regexp_replace(c.code, '[^0-9]', '') <> ''",
         src  = character(0), n = 2L),
    # The claim side of the NDC join yields a key only from a value that could
    # be an NDC. The source left-padded anything to eleven, so NONE and UNK -
    # which is how Optum spells "no NDC", 1.2bn rows of them - became
    # 00000000000 and could collide. It can only remove matches the source
    # should not have made, and it retires the shape check that policed them.
    list(port = "AND CASE WHEN regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') RLIKE '^0+$' THEN NULL WHEN length(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '')) = 11 THEN regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') WHEN length(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '')) = 10 THEN concat('0', regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '')) END",
         src  = "AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')",
         n = 1L),
    list(port = "AND CASE WHEN regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') RLIKE '^0+$' THEN NULL WHEN length(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '')) = 11 THEN regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') WHEN length(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '')) = 10 THEN concat('0', regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '')) END",
         src  = "AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')",
         n = 1L),
    list(port = c(
           "UNION ALL",
           "SELECT /*+ BROADCAST(c) */",
           "p.PATID, cast(p.FST_DT as date) AS event_dt, 'MED_PROCEDURE_PROC' AS source",
           "FROM {cdm_src(cfg$tbl_med_proc)} p",
           "INNER JOIN {work('mm_therapy_codes')} c",
           "ON c.code_type IN ('HCPCS','CPT')",
           "AND upper(regexp_replace(coalesce(cast(p.PROC as string),''), '[^A-Za-z0-9]', '')) = c.code",
           "AND regexp_replace(coalesce(cast(p.PROC as string),''), '[^A-Za-z0-9]', '') <> ''",
           "WHERE p.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')"),
         src  = character(0)))
)

# The QC query for the step that gained a source gained the count for it. Every
# other step's QC has to be the source's, untouched.
QC_DEVIATIONS <- list(
  "18_therapy_events" = list(
    list(port = "sum(CASE WHEN source = 'RX'                   THEN 1 ELSE 0 END) AS n_rx_ndc,",
         src  = "sum(CASE WHEN source = 'RX'                   THEN 1 ELSE 0 END) AS n_rx_ndc"),
    list(port = "sum(CASE WHEN source = 'MED_PROCEDURE_PROC'   THEN 1 ELSE 0 END) AS n_med_procedure",
         src  = character(0)))
)

# ---------------------------------------------------------------------------
# Compare what runs, not the comments around it. A tidied -- comment inside a
# SQL string is not a change to the study logic.
strip <- function(x) {
  l <- strsplit(as.character(x), "\n")[[1]]
  l <- trimws(l[!grepl("^\\s*--", l)])
  l[nzchar(l)]
}

# Where does this run of lines start? Sequence match, so shared opening lines
# such as UNION ALL do not send the edit to the wrong block.
run_starts <- function(lines, run) {
  k <- length(run)
  if (!k || length(lines) < k) return(integer(0))
  Filter(function(i) identical(lines[i:(i + k - 1L)], run),
         seq_len(length(lines) - k + 1L))
}

# A multi-line run that no longer matches is named by its first line, which for
# a block opening with UNION ALL says nothing about where it went wrong. Report
# how far the closest occurrence got, so the reader sees the line that changed
# rather than the line the block starts with.
near_miss <- function(lines, run) {
  if (length(run) < 2L) return(character(0))
  best <- 0L; at <- 0L
  for (i in seq_along(lines)) {
    k <- 0L
    while (k < length(run) && i + k <= length(lines) && lines[i + k] == run[k + 1L])
      k <- k + 1L
    if (k > best) { best <- k; at <- i }
  }
  if (!best) return("no part of the run appears at all")
  c(paste0("closest run matched ", best, " of ", length(run),
           " lines, from line ", at),
    paste0("expected next: ", run[best + 1L]),
    paste0("found:         ",
           if (at + best <= length(lines)) lines[at + best] else "<end>"))
}

undeviate <- function(lines, devs) {
  unmatched <- character(0)
  for (d in devs) {
    port <- r(d$port); src <- r(d$src); n <- if (is.null(d$n)) 1L else d$n
    hits <- run_starts(lines, port)
    if (length(hits) != n) {
      unmatched <- c(unmatched,
                     paste0(port[1], " (expected ", n, ", found ", length(hits), ")"),
                     paste0("  ", near_miss(lines, port)))
      next
    }
    for (h in rev(hits))
      lines <- append(lines[-(h:(h + length(port) - 1L))], src, after = h - 1L)
  }
  list(lines = lines, unmatched = unmatched)
}

# First place two line vectors part company, phrased the way port/ndmm.R does.
first_diff <- function(src, port) {
  n <- min(length(src), length(port))
  d <- which(src[seq_len(n)] != port[seq_len(n)])
  i <- if (length(d)) d[1] else n + 1L
  c(paste0("differs at line ", i),
    paste0("source: ", if (i <= length(src))  src[i]  else "<end>"),
    paste0("ported: ", if (i <= length(port)) port[i] else "<end>"))
}

compare <- function(what, src, port, devs) {
  s <- strip(src); p <- strip(port)
  u <- undeviate(p, devs)
  if (length(u$unmatched)) {
    ok(FALSE, paste0(what, ": a registered deviation no longer matches"),
       u$unmatched)
    return(invisible(FALSE))
  }
  same <- identical(s, u$lines)
  ok(same,
     if (length(devs)) paste0(what, ": identical once the ", length(devs),
                              " registered deviation(s) are undone")
     else paste0(what, ": identical"),
     if (!same) first_diff(s, u$lines))
  invisible(same)
}

cat("\ncomparing ", length(a), " steps, config: window ", cfg$outpatient_window,
    "d, study ", cfg$study_start, " .. ", cfg$study_end, "\n\n", sep = "")

ok(length(a) == length(b),
   paste0("same number of steps (", length(a), " vs ", length(b), ")"))

if (length(a) == length(b)) {
  names_a <- vapply(a, `[[`, character(1), "name")
  names_b <- vapply(b, `[[`, character(1), "name")
  ok(identical(names_a, names_b), "same step names, in the same order")

  # A registry entry naming a step that no longer exists is a deviation nobody
  # is checking. Catch the rename here rather than as a silent gap.
  stale <- setdiff(c(names(DEVIATIONS), names(QC_DEVIATIONS)), names_b)
  ok(!length(stale), "every registered deviation names a step that exists",
     stale)

  cat("\n-- every step's SQL is the source's, line for line --\n")
  for (i in seq_along(a))
    compare(a[[i]]$name, a[[i]]$sql, b[[i]]$sql, DEVIATIONS[[a[[i]]$name]])

  cat("\n-- and so is every step's QC --\n")
  for (i in seq_along(a))
    compare(paste0(a[[i]]$name, " QC"), a[[i]]$qc, b[[i]]$qc,
            QC_DEVIATIONS[[a[[i]]$name]])

  cat("\n-- and the one criterion with no catalog entry is written once --\n")
  # Step 1 is the only criterion the catalog does not carry, so it is the one
  # that can be written twice - once in the Step 24 filter and once in the
  # attrition. It was. Both render qualifying_sql() now, and the literal appears
  # only inside that function: a second copy would let the cohort table and the
  # funnel's Step 1 row describe different patients, and nothing else would say
  # so. Neither check is covered by the SQL comparison above - the first is
  # about which expression produced a line that matches either way, the second
  # about a file this suite does not otherwise read.
  sql_of <- function(nm) as.character(b[[match(nm, names_b)]]$sql)
  ok(grepl(new$qualifying_sql(cfg$outpatient_window),
           sql_of("24_ELIG_COH_FINAL"), fixed = TRUE),
     "24_ELIG_COH_FINAL gates on qualifying_sql(configured window)")
  srcs <- c(list.files(file.path(ROOT, "R"), "[.]R$", full.names = TRUE),
            list.files(file.path(ROOT, "R", "steps"), "[.]R$", full.names = TRUE))
  n_lit <- sum(vapply(srcs, function(f)
    sum(grepl("(inpt_qual = 1 OR outpt2_", readLines(f, warn = FALSE),
              fixed = TRUE)), integer(1)))
  ok(n_lit == 1L,
     paste0("the Step 1 predicate is written once, in qualifying_sql() (found ",
            n_lit, ")"))
}

cat("\n-- and the files copied wholesale really are copies --\n")
# Local comments may differ.
code_lines <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines[!grepl("^[[:space:]]*#", lines)]
}
ok(identical(code_lines(file.path(ROOT, "R", "load_inputs.R")),
             code_lines(file.path(APR, "R", "load_inputs.R"))),
   "R/load_inputs.R has identical executable lines")

# config_prompts.R is deliberately smaller - the interactive prompts and the
# finalize_cfg round trip did nothing under Rscript. What still has to match is
# the study window, which CONTRACT does not cover.
apr_cfg <- apr$cfg_defaults
for (k in c("study_start", "study_end", "id_start", "id_end",
            "baseline_days", "gap_days", "dx_window_30", "dx_window_60",
            "dx_window_90"))
  ok(identical(new$cfg_defaults[[k]], apr_cfg[[k]]),
     paste0("cfg_defaults$", k, " = ", format(apr_cfg[[k]]), ", same as apr_30_2026"))
cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
