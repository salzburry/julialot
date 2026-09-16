# Counts at each filter step for the attrition card. Steps after
# ELIG_COH_FINAL + LOT1 are CUMULATIVE - each row applies all previous
# NDMM filters plus the new one, so the table reads top-to-bottom as
# the funnel a clinical reviewer would expect.
ndmm_counts <- function(con, mm_qualifying, base_cohort) {
  n_of <- function(sql) db_q(con, sql)$n
  # The population is everyone with a qualifying MM diagnosis, then those old
  # enough, then those with an eligible 1L treatment. These three count off
  # their own tables rather than off a flag.
  whole <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {mm_qualifying}"))
  elig <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {base_cohort}"))
  elig_lot1 <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_LOT1_STARTS}"))

  # From here the funnel runs in the study's own order: the remaining inclusion
  # (CE during follow-up), then the four exclusions as they are listed - prior
  # MM therapy, other cancer, pregnancy, belantamab last. The final cohort is
  # the same whichever order is used, but the per-step numbers are not, and the
  # attrition is what people read.
  #
  # Each row is NDMM_CRITERIA's first i criteria, so a row is the row above it
  # plus exactly one - that shape is the list's, not something restated here.
  cum <- list()
  for (i in seq_len(length(NDMM_CRITERIA) - 1L))
    cum[[NDMM_CRITERIA[[i]]$key]] <- n_of(glue(
      "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
       WHERE {ndmm_criteria_where(i)}"))

  # The last criterion completes the conjunction NDMM_PATIDS is defined on, so
  # this row reads that view rather than repeating it - the published number is
  # then the cohort's own, not a recount that has to agree with it.
  ndmm_final <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_PATIDS}"))
  # Keyed off the last criterion rather than repeating its name. The three at
  # the front are this function's own - they count off their own tables - but
  # the final row is the last entry of NDMM_CRITERIA. Writing its key here as
  # well would make two lists agree by hand.
  c(list(whole = whole, elig = elig, elig_lot1 = elig_lot1), cum,
    setNames(list(ndmm_final), NDMM_CRITERIA[[length(NDMM_CRITERIA)]]$key))
}

# The final row of the funnel, whatever the last criterion happens to be called.
# Naming that key literally is the same two-lists-agree problem ndmm_counts()
# removes one line above.
ndmm_final_count <- function(counts)
  counts[[NDMM_CRITERIA[[length(NDMM_CRITERIA)]]$key]]
