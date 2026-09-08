# The small-cell rule.
#
# s7.2.3: "Stratifications with <25 patients will not be performed
# or may be regrouped due to low volumes."
# s7.8: "If there are less than 25 patients in a particular
# stratifications or cohort, analyses will not be conducted (unless specific to
# SOC)."
#
# Two sentences, and they differ. The second carries an exemption for SOC-
# specific analyses and the first does not. Both are applied here: a stratum is
# suppressed below the threshold unless it is a SOC stratum, and every
# suppressed row is REPLACED rather than dropped, so a reader can tell a
# suppressed stratum from one that did not occur.

# Marks rather than deletes. A deleted row and an absent stratum look the same
# in a table, and only one of them means "we could not say".
apply_suppression <- function(df, n_col = "N_PATIENTS", cfg,
                              exempt = logical(nrow(df)),
                              value_cols = NULL) {
  if (!nrow(df)) return(df)
  if (!n_col %in% names(df))
    stop("SUPPRESSION ERROR: no column '", n_col, "' to suppress on. ",
         "Columns: ", paste(names(df), collapse = ", "), ".", call. = FALSE)
  if (length(exempt) == 1L) exempt <- rep(exempt, nrow(df))
  if (length(exempt) != nrow(df))
    stop("SUPPRESSION ERROR: `exempt` is length ", length(exempt),
         " for ", nrow(df), " rows.", call. = FALSE)

  n <- suppressWarnings(as.numeric(df[[n_col]]))
  hit <- !is.na(n) & n < cfg$suppress_min_n & !exempt
  if (is.null(value_cols))
    value_cols <- setdiff(names(df)[vapply(df, is.numeric, logical(1))], n_col)

  df$SUPPRESSED <- as.integer(hit)
  df$SUPPRESSION_REASON <- ifelse(
    hit, sprintf("n < %d", cfg$suppress_min_n),
    ifelse(!is.na(n) & n < cfg$suppress_min_n & exempt,
           "below threshold, SOC-exempt", NA_character_))
  for (cl in value_cols) df[[cl]][hit] <- NA
  df[[n_col]][hit] <- NA

  if (any(hit))
    log_msg("  suppressed ", sum(hit), " of ", nrow(df), " row(s) at n < ",
            cfg$suppress_min_n,
            if (any(!is.na(df$SUPPRESSION_REASON) &
                    df$SUPPRESSION_REASON == "below threshold, SOC-exempt"))
              paste0("; ", sum(df$SUPPRESSION_REASON ==
                     "below threshold, SOC-exempt", na.rm = TRUE),
                     " kept under the SOC exemption") else "")
  df
}

# A count that is itself below the threshold can be recovered by subtraction
# from a total that is not. Checks a set of parts against their whole and says
# so; it does not fix it, because the fix is a regrouping decision.
check_complementary_disclosure <- function(df, group_cols, n_col = "N_PATIENTS",
                                           total_col = "N_TOTAL", cfg) {
  if (!nrow(df) || !all(c(n_col, total_col) %in% names(df))) return(invisible(NULL))
  key <- interaction(df[group_cols], drop = TRUE)
  risky <- vapply(split(seq_len(nrow(df)), key), function(ix) {
    s <- df[ix, , drop = FALSE]
    sum(s$SUPPRESSED %in% 1L) == 1L
  }, logical(1))
  if (any(risky))
    log_msg("  WARNING: ", sum(risky), " group(s) have exactly one suppressed ",
            "row, so that row is recoverable by subtraction. Regroup before ",
            "the table leaves the warehouse.")
  invisible(names(risky)[risky])
}
