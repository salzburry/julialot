# What this package writes, as data a sibling delivery can read.
#
# TFLS fills the requested shells from a finished run, and it does that where
# this package is often NOT installed - from a snapshot on a machine that has
# the CSVs and nothing else. So it has to know which module writes which table,
# which of them the release module publishes a suppressed copy of, and which
# are written only when a switch asks for them. It used to know by restating
# all three lists by hand, and a hand-written restatement drifts: a table added
# to SUPPRESSION_SPEC and not added there would be filled from with the
# recoverability gate not knowing to refuse it.
#
# This is the one place those three facts are written down - MODULES,
# SUPPRESSION_SPEC and OPTIONAL_FEATURES, which the run itself is driven by -
# and study_contract() is them in a shape a CSV can hold. TFLS ships a
# generated copy and reads it; its suite regenerates from here whenever this
# package is beside it and fails on any difference. So the lists are authored
# once and the copy cannot quietly diverge from the run that produced it.

# One row per table this package can write.
#
#   MODULE    the module that writes it
#   TABLE     the table's base name, without the run's prefix
#   RELEASED  1 where the release module publishes a suppressed copy
#   SWITCH    the setting that has to be recorded TRUE for it to be written,
#             blank where the module always writes it
study_contract <- function() {
  # The optional outputs, flattened: output name -> the switch that asks for it.
  opt <- unlist(lapply(OPTIONAL_FEATURES, function(m)
    stats::setNames(vapply(m, function(f) f$output, character(1)), names(m))),
    use.names = TRUE)
  by_output <- stats::setNames(sub("^[^.]*[.]", "", names(opt)), unname(opt))

  rows <- lapply(names(MODULES), function(k) {
    out <- MODULES[[k]]$outputs
    if (!length(out)) return(NULL)
    data.frame(MODULE = k, TABLE = out,
               RELEASED = as.integer(out %in% names(SUPPRESSION_SPEC)),
               SWITCH = unname(ifelse(out %in% names(by_output),
                                      by_output[out], "")),
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, Filter(Negate(is.null), rows))
  out[order(out$MODULE, out$TABLE), , drop = FALSE]
}

# The contract as a file, for a sibling that ships a copy.
#
# Written with the same writer settings every time so two emissions of an
# unchanged registry are byte-identical - a comparison that fails on a
# formatting difference would be a comparison nobody keeps.
write_study_contract <- function(path) {
  d <- study_contract()
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(d, path, row.names = FALSE, quote = FALSE, na = "")
  invisible(path)
}
