# Distribution benchmarks: what this algorithm produces, beside what has been
# published.
#
# LOT counts per patient, regimen frequencies per line, durations and time to
# next treatment, each against a published figure.
#
# The published numbers are not here and were not written from memory. They
# live in benchmarks.csv, which ships with a row per metric and the value
# blank, so an unfilled row reports itself instead of quietly comparing
# nothing.
#
# Each row carries its own definition, because "median 2 lines" from a paper is
# not comparable on its own. It depends on who was counted, how long they were
# followed, and whose line algorithm was used - a source counting maintenance
# as a line reports a larger median than this algorithm can produce, and the
# gap is the two definitions rather than a defect in either.
#
# So `comparable` is the operator's judgement, recorded in the file:
#
#   yes       close enough to compare
#   caveat    usable, with the difference named in `notes`
#   no        recorded for context, scored as nothing
#
# An unmarked row is treated as `no`. The other way round would let a
# convenient number become evidence.
BENCHMARK_COLS <- c(
  "metric",            # one of BENCHMARK_METRICS
  "line",              # LOT number where the metric is per line, else blank
  "regimen",           # regimen string for regimen-frequency rows, else blank
  "published_value",   # the figure, in the unit below. BLANK = not supplied
  "unit",              # count | pct | days
  "source",            # citation - author, year, journal
  "source_population", # who the source counted
  "source_followup",   # median or minimum follow-up in the source
  "source_algorithm",  # the line algorithm the source used
  "comparable",        # yes | caveat | no
  "notes")

# What the harness measures. Each one names its own definition, because that is
# the thing a published figure has to match.
BENCHMARK_METRICS <- list(
  median_lines_per_patient = list(
    unit = "count",
    what = "median lines per patient in LOT_LONG_FINAL",
    defn = paste0("Denominator is patients with at least one built line, not ",
                  "everyone diagnosed. Capped at MAX_LOT, so a source without a ",
                  "cap reports a larger tail.")),
  pct_reaching_line = list(
    unit = "pct", per_line = TRUE,
    what = "% of LOT1 patients who reach line n",
    defn = paste0("Denominator is LOT1 patients. NOT adjusted for follow-up: a ",
                  "patient with six months of observation had less chance to ",
                  "reach LOT2 than one with five years, and this is a crude ",
                  "proportion. A source reporting a Kaplan-Meier estimate is ",
                  "measuring something else.")),
  median_line_duration_days = list(
    unit = "days", per_line = TRUE,
    what = "median LOT_BASE_LENGTH for line n, completed lines only",
    defn = paste0("LOT_BASE_LENGTH is inclusive - datediff + 1. Lines still open ",
                  "at study end (LOT_BASE_END_REASON = 'STUDY_END') are EXCLUDED ",
                  "and counted separately: including them drags the median down ",
                  "by treating a censored line as a short one.")),
  km_median_ttnt_days = list(
    unit = "days", per_line = TRUE,
    what = "Kaplan-Meier median time from line n start to line n+1 start",
    defn = paste0("A real KM median, not the median among those who progressed. ",
                  "Patients who never start the next line are CENSORED at their ",
                  "observation end, not dropped - dropping them is the standard ",
                  "way to report a time-to-next-treatment that is far too short, ",
                  "and it is what makes the naive figure incomparable to every ",
                  "published one.")),
  pct_regimen_at_line = list(
    unit = "pct", per_line = TRUE, per_regimen = TRUE,
    what = "% of line-n patients on a named regimen",
    defn = paste0("LOT_BASE_MEDS as a whole string, so a four-drug regimen is not ",
                  "the same row as the three-drug one inside it. Order is ",
                  "normalised by the build. A registry reporting 'VRd' as a class ",
                  "will not line up with a string comparison without mapping. ",
                  "The DENOMINATOR is every patient with a line at n, including ",
                  "allogeneic lines, which carry no regimen string by ",
                  "construction - so the top-N percentages do not sum to 100 and ",
                  "the remainder is the tail beyond N plus those.")))

# One row per line, and the counts a distribution needs.
bench_distribution_sql <- function(final_tbl) paste0("
  WITH per_pat AS (
    SELECT PATID, max(LOT_NUM) AS max_lot FROM ", final_tbl, " GROUP BY PATID
  )
  SELECT 'median_lines_per_patient' AS metric, cast(NULL as int) AS line,
         percentile_approx(max_lot, 0.5) AS observed, count(*) AS denom
  FROM per_pat")

bench_reaching_sql <- function(final_tbl, max_lot) paste0("
  WITH per_pat AS (
    SELECT PATID, max(LOT_NUM) AS max_lot FROM ", final_tbl, " GROUP BY PATID
  ), base AS (SELECT count(*) AS n FROM per_pat)
  SELECT 'pct_reaching_line' AS metric, l.line,
         round(100.0 * count(p.PATID) / nullif((SELECT n FROM base), 0), 2) AS observed,
         (SELECT n FROM base) AS denom
  FROM (SELECT explode(sequence(2, ", as.integer(max_lot), ")) AS line) l
  LEFT JOIN per_pat p ON p.max_lot >= l.line
  GROUP BY l.line ORDER BY l.line")

# Completed lines only. Censored ones are counted, not folded in.
bench_duration_sql <- function(final_tbl) paste0("
  SELECT 'median_line_duration_days' AS metric, LOT_NUM AS line,
         percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON,'') <> 'STUDY_END'
                                THEN LOT_BASE_LENGTH END, 0.5)            AS observed,
         sum(CASE WHEN coalesce(LOT_BASE_END_REASON,'') <> 'STUDY_END'
                  THEN 1 ELSE 0 END)                                      AS denom,
         sum(CASE WHEN LOT_BASE_END_REASON = 'STUDY_END' THEN 1 ELSE 0 END) AS censored
  FROM ", final_tbl, "
  WHERE LOT_BASE_LENGTH IS NOT NULL
  GROUP BY LOT_NUM ORDER BY LOT_NUM")

# Kaplan-Meier median time from line n to line n+1.
#
# The naive version - the median gap among patients who reached the next line -
# must not be done here: it conditions on the event, so it answers "among those
# who progressed, how fast" and comes out far shorter than any published KM
# median. Patients without the next line are censored at their observation end.
#
# S(t) as exp(sum(log(1 - d/n))) rather than a running product, because Spark
# has no product window. d = n would be log(0), so the CASE floors it and the
# curve reaches zero instead of going NULL.
bench_ttnt_sql <- function(final_tbl, patients_tbl, line) paste0("
  WITH cur AS (
    SELECT cast(PATID as string) AS PATID, min(cast(LOT_START_DT as date)) AS t0
    FROM ", final_tbl, " WHERE LOT_NUM = ", as.integer(line), " GROUP BY PATID
  ),
  nxt AS (
    SELECT cast(PATID as string) AS PATID, min(cast(LOT_START_DT as date)) AS t1
    FROM ", final_tbl, " WHERE LOT_NUM = ", as.integer(line) + 1L, " GROUP BY PATID
  ),
  obs AS (
    SELECT cast(PATID as string) AS PATID, cast(OBS_END_DT as date) AS obs_end
    FROM ", patients_tbl, "
  ),
  s AS (
    SELECT c.PATID,
           CASE WHEN n.t1 IS NOT NULL THEN datediff(n.t1, c.t0)
                ELSE datediff(o.obs_end, c.t0) END AS t,
           CASE WHEN n.t1 IS NOT NULL THEN 1 ELSE 0 END AS ev
    FROM cur c LEFT JOIN nxt n USING (PATID) LEFT JOIN obs o USING (PATID)
    WHERE CASE WHEN n.t1 IS NOT NULL THEN datediff(n.t1, c.t0)
               ELSE datediff(o.obs_end, c.t0) END >= 0
  ),
  n_all AS (SELECT count(*) AS n FROM s),
  tt AS (SELECT t, sum(ev) AS d, count(*) AS leaving FROM s GROUP BY t),
  cum AS (
    SELECT t, d,
           coalesce(sum(leaving) OVER (ORDER BY t
             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS gone
    FROM tt
  ),
  km AS (
    SELECT t, d, (SELECT n FROM n_all) - gone AS n_risk FROM cum
  ),
  surv AS (
    SELECT t, d, n_risk,
           exp(sum(CASE WHEN n_risk > 0 AND d < n_risk THEN log(1.0 - d / n_risk)
                        WHEN n_risk > 0 AND d = n_risk THEN -1e9
                        ELSE 0 END)
               OVER (ORDER BY t ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS s_t
    FROM km
  )
  SELECT 'km_median_ttnt_days' AS metric, ", as.integer(line), " AS line,
         (SELECT min(t) FROM surv WHERE s_t <= 0.5)            AS observed,
         (SELECT n FROM n_all)                                 AS denom,
         (SELECT sum(d) FROM km)                               AS events")

# The denominator is everyone with a line at n, INCLUDING lines with no regimen
# string. An allogeneic line has a blank LOT_BASE_MEDS by construction
# (10_lot2_5_base.R:348), so summing the named regimens instead would report
# "% of patients with a NAMED regimen" under a heading that says otherwise, and
# every percentage would come out high.
#
# The top-N percentages therefore do not sum to 100: the remainder is the tail
# beyond N plus those blank-regimen lines.
bench_regimen_sql <- function(final_tbl, top_n) paste0("
  WITH pat AS (
    SELECT DISTINCT LOT_NUM, cast(PATID as string) AS PATID FROM ", final_tbl, "
  ),
  tot AS (SELECT LOT_NUM, count(*) AS n_line FROM pat GROUP BY LOT_NUM),
  l AS (
    SELECT LOT_NUM, LOT_BASE_MEDS AS regimen, count(DISTINCT PATID) AS n
    FROM ", final_tbl, "
    WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    GROUP BY LOT_NUM, LOT_BASE_MEDS
  ),
  r AS (
    SELECT l.LOT_NUM, l.regimen, l.n, t.n_line,
           row_number() OVER (PARTITION BY l.LOT_NUM ORDER BY l.n DESC) AS rk
    FROM l JOIN tot t USING (LOT_NUM)
  )
  SELECT 'pct_regimen_at_line' AS metric, LOT_NUM AS line, regimen,
         round(100.0 * n / nullif(n_line, 0), 2) AS observed, n_line AS denom, rk
  FROM r WHERE rk <= ", as.integer(top_n), " ORDER BY LOT_NUM, rk")

# Read strictly. A malformed row is not skipped - a table missing the row
# somebody thought they supplied is worse than one that will not load.
read_benchmarks <- function(path) {
  if (!file.exists(path))
    stop("No benchmark file at ", path, ". Ship benchmarks.csv beside this ",
         "script, with published_value blank where nobody has supplied one.",
         call. = FALSE)
  df <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
                 na.strings = c("", "NA"))
  miss <- setdiff(BENCHMARK_COLS, names(df))
  if (length(miss))
    stop("benchmarks.csv is missing: ", paste(miss, collapse = ", "), call. = FALSE)
  bad <- character(0)
  unknown <- setdiff(unique(df$metric), names(BENCHMARK_METRICS))
  if (length(unknown))
    bad <- c(bad, paste0("names metrics the harness does not measure: ",
                         paste(unknown, collapse = ", ")))
  supplied <- !is.na(df$published_value) & nzchar(trimws(df$published_value))
  nonnum <- supplied & is.na(suppressWarnings(as.numeric(df$published_value)))
  if (any(nonnum))
    bad <- c(bad, paste0("published_value is not a number on row(s): ",
                         paste(which(nonnum), collapse = ", ")))
  # A number with no source becomes a citation nobody can chase.
  nosrc <- supplied & (is.na(df$source) | !nzchar(trimws(df$source)))
  if (any(nosrc))
    bad <- c(bad, paste0("a published_value with no source on row(s): ",
                         paste(which(nosrc), collapse = ", ")))
  badcmp <- !is.na(df$comparable) &
    !tolower(trimws(df$comparable)) %in% c("yes", "caveat", "no", "")
  if (any(badcmp))
    bad <- c(bad, paste0("comparable must be yes/caveat/no on row(s): ",
                         paste(which(badcmp), collapse = ", ")))
  # Claiming comparability is a claim about three things, and blank is not one
  # of them. A published median means nothing against ours without the
  # population it was measured on, how long they were followed, and which LOT
  # algorithm produced it - two studies can differ entirely because one counted
  # maintenance as a line. A blank `comparable` already falls back to "no", so
  # nothing is lost by staying silent; what is refused is saying yes or caveat
  # without saying on what basis.
  claims <- supplied & tolower(trimws(ifelse(is.na(df$comparable), "", df$comparable))) %in%
    c("yes", "caveat")
  ctx <- c(source_population = "the population it was measured on",
           source_followup   = "how long they were followed",
           source_algorithm  = "which LOT algorithm produced it")
  for (nm in names(ctx)) {
    blank <- claims & (is.na(df[[nm]]) | !nzchar(trimws(df[[nm]])))
    if (any(blank))
      bad <- c(bad, paste0("comparable is yes/caveat but ", nm, " is blank - ",
                           ctx[[nm]], " is what makes it comparable. Row(s): ",
                           paste(which(blank), collapse = ", ")))
  }
  if (length(bad))
    stop("benchmarks.csv does not load:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  df$published_value <- suppressWarnings(as.numeric(df$published_value))
  df
}

# Observed against published. Never a pass or a fail: a gap is two studies
# differing until `comparable` says otherwise.
compare_benchmarks <- function(observed, refs) {
  key <- function(d) paste(d$metric,
                           ifelse(is.na(d$line), "", d$line),
                           ifelse(is.null(d$regimen) | is.na(d$regimen), "", d$regimen),
                           sep = "|")
  refs$.k <- key(refs); observed$.k <- key(observed)
  # The three context columns travel with the verdict. Requiring them on the
  # way in and dropping them on the way out puts the basis for a comparison in
  # a file nobody reads and the verdict in the one they do - which is the
  # traceability the guard was added to get, lost at the last step.
  out <- merge(observed, refs[, c(".k", "published_value", "unit", "source",
                                  "source_population", "source_followup",
                                  "source_algorithm", "comparable", "notes")],
               by = ".k", all.x = TRUE)
  cmp <- tolower(trimws(ifelse(is.na(out$comparable), "no", out$comparable)))
  out$verdict <- ifelse(
    is.na(out$published_value), "no reference supplied",
    ifelse(cmp == "no", "recorded, not comparable",
      ifelse(is.na(out$observed), "no observation",
        ifelse(cmp == "caveat", "compared with caveat", "compared"))))
  out$difference <- ifelse(is.na(out$published_value) | is.na(out$observed),
                           NA_real_, out$observed - out$published_value)
  out$.k <- NULL
  out[order(out$metric, out$line), ]
}
