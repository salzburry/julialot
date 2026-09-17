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

# The contract, as one value a run can record.
#
# A sibling reads a SHIPPED COPY of the contract, and a copy is a thing that
# can be stale: TFLS fills its shells from a snapshot on a machine where this
# package is often not installed, so nothing there can regenerate the contract
# and compare. Its suite catches a stale copy only where the two are side by
# side. This is the other half - the run records the contract it was actually
# driven by, so a table filled from the copy can be checked against the run
# that produced the numbers rather than against whatever the copy says today.
#
# Over the CSV's LINES rather than its bytes. The sibling reads a copy that
# has been through version control, and a checkout on another platform can
# rewrite the line endings without touching a character of the content; a
# byte hash would then refuse a contract that is the same contract. So the
# value is the md5 of the lines joined by "\n" with one at the end - the same
# function, contract_text_md5(), that TFLS computes over its shipped copy.
contract_text_md5 <- function(path) {
  txt <- paste0(paste(readLines(path, warn = FALSE), collapse = "\n"), "\n")
  tmp <- tempfile(); on.exit(unlink(tmp), add = TRUE)
  writeBin(charToRaw(txt), tmp)
  unname(tools::md5sum(tmp))
}
study_contract_md5 <- function() {
  tmp <- tempfile(); on.exit(unlink(tmp), add = TRUE)
  write_study_contract(tmp)
  contract_text_md5(tmp)
}

# ...and which CODE that contract came out of.
#
# The same question the LOT engine asks of itself, asked the same way: a hash
# of the sources rather than a revision, because the package is copied into
# Domino to run and the hash describes what actually executed either way.
#
# radix, not the default: character sort is collation-sensitive, and a hash
# meant to say "the same code" must not depend on the machine's locale.
study_code_md5 <- function(here = ".") {
  fs <- sort(c(list.files(file.path(here, "R"), "\\.R$", full.names = TRUE,
                          recursive = TRUE),
               file.path(here, "build.R")), method = "radix")
  fs <- fs[file.exists(fs)]
  if (!length(fs)) return(NA_character_)
  tmp <- tempfile(); on.exit(unlink(tmp), add = TRUE)
  writeLines(unlist(lapply(fs, readLines, warn = FALSE)), tmp)
  unname(tools::md5sum(tmp))
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
