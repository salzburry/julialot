#!/usr/bin/env Rscript
# NDMM and LOT read one code list. They must not read it differently.
#
#   Rscript validation/hygiene/codelist_code_types.R
#
# cl_mma_codelist.csv carries a CL_CODE_TYPE per row, and both builds join on
# equality against a set of types each names for itself:
#
#   lot/engine/R/steps/01_codelists.R   EXTRACTED_CODE_TYPES
#   ndmm/R/steps/03_prior_therapy.R     NDMM_MMA_CODE_TYPES
#
# A type one reads and the other does not is not a style difference. NDMM's 1L
# index scan matches on HCPCS and CPT (00b_lot1_index.R), so a CPT-coded therapy
# can set the cohort's index date - and LOT extracts NDC and HCPCS only, so the
# same claim is invisible to it and no line starts there. The cohort would carry
# an index the lines cannot reproduce.
#
# LOT does notice a type it cannot extract, but that finding is waivable through
# CODELIST_WAIVERS, and NDMM's guard passes CPT by design. So both builds can be
# green at once while disagreeing about the same file. Nothing else compares
# them, which is why this is here rather than in either package: a check inside
# one would have to read the other, and study_folder_standalone.R forbids that.
#
# A divergence is not automatically wrong - it is a study decision about whether
# CPT-coded therapy counts. What it must not be is silent, so each one is
# registered below with its reason and this fails on any that is not.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO   <- dirname(dirname(HERE))
FOLDER <- Sys.getenv("STUDY_FOLDER", unset = "Jul 28")
ROOT   <- file.path(REPO, FOLDER)
if (!dir.exists(ROOT)) {
  cat("SKIP: no ", FOLDER, " folder beside this one.\n", sep = "")
  quit(status = 3L)
}

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

# Read each set out of the file that declares it, rather than restating them
# here - a third copy could agree with neither.
types_in <- function(path, name) {
  txt <- paste(readLines(file.path(ROOT, path), warn = FALSE), collapse = "\n")
  m <- regmatches(txt, regexpr(paste0(name, "\\s*<-\\s*c\\((?s).*?\\)"), txt, perl = TRUE))
  if (!length(m)) return(character(0))
  unique(unlist(regmatches(m, gregexpr('(?<=")[A-Z0-9]+(?=")', m, perl = TRUE))))
}

LOT  <- types_in("lot/engine/R/steps/01_codelists.R", "EXTRACTED_CODE_TYPES")
NDMM <- types_in("ndmm/R/steps/03_prior_therapy.R",   "NDMM_MMA_CODE_TYPES")

cat("\n-- both builds declare which code types they read --\n")
ok(length(LOT) > 0,  paste0("LOT extracts ", paste(LOT, collapse = ", ")))
ok(length(NDMM) > 0, paste0("NDMM joins on ", paste(NDMM, collapse = ", ")))

# Each divergence, and why it is allowed to stand. Delete the reason and this
# fails; add a type to one build and it fails until someone writes one.
KNOWN <- list(
  CPT = paste0(
    "NDMM reads CPT and LOT does not. NDMM's 1L index scan matches HCPCS and ",
    "CPT, so a CPT-coded therapy can set the cohort index while LOT sees no ",
    "claim and starts no line there. Whether CPT-coded therapy should count is ",
    "the study team's call; until they take it, cl_mma_codelist.csv carrying ",
    "CPT rows means the two stages disagree about those patients."))

cat("\n-- and every difference between them is registered --\n")
only_ndmm <- setdiff(NDMM, LOT)
only_lot  <- setdiff(LOT, NDMM)
unregistered <- setdiff(c(only_ndmm, only_lot), names(KNOWN))
ok(length(unregistered) == 0,
   if (length(unregistered))
     paste0("code type(s) one build reads and the other does not, with no ",
            "reason recorded: ", paste(unregistered, collapse = ", "))
   else if (length(c(only_ndmm, only_lot)))
     paste0("the ", length(c(only_ndmm, only_lot)), " divergence(s) are named ",
            "with a reason: ", paste(c(only_ndmm, only_lot), collapse = ", "))
   else "the two builds read exactly the same code types")

# The mirror: a registered reason for a divergence that no longer exists is a
# note nobody will delete, and it reads as a live caveat.
stale <- setdiff(names(KNOWN), c(only_ndmm, only_lot))
ok(length(stale) == 0,
   if (length(stale)) paste0("a divergence is registered that no longer exists: ",
                             paste(stale, collapse = ", "))
   else "...and no reason is recorded for a divergence that is gone")

# The claim the registered reason rests on. If the index scan stops matching
# CPT, the reason above is wrong and should be rewritten rather than kept.
idx <- paste(readLines(file.path(ROOT, "ndmm/R/steps/00b_lot1_index.R"),
                       warn = FALSE), collapse = "\n")
ok(!("CPT" %in% names(KNOWN)) || grepl("code_type IN ('HCPCS','CPT')", idx, fixed = TRUE),
   "the CPT reason still matches what the 1L index scan does")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
