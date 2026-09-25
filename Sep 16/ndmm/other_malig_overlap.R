#!/usr/bin/env Rscript
# What the other-cancer list actually says about myeloma. Reads the CSVs and
# nothing else - no warehouse, no build, no connection.
#
#   Rscript "ndmm/other_malig_overlap.R"
#   CODELIST_DIR=/some/other/dir Rscript "ndmm/other_malig_overlap.R"
#
# It answers the three questions DECISIONS.md #4 leaves open:
#
#   1. Does other_malig.csv carry codes that are also on mm_dx.csv? If it does,
#      the derived override in 04_other_malig.R is load-bearing and the
#      criterion would exclude cohort members without it. If it does not, that
#      join matches nothing and the label list is the whole mechanism.
#   2. Which plasma-cell labels are on the list, with their codes - including
#      what sits under MONOCLONAL GAMMOPATHY, which this package never names.
#   3. Which of the configured labels match, and which plasma-cell-looking
#      labels are left excluding.
#
# NDMM_MM_ADJACENT_STATES chooses the set, so it is honoured here too:
#
#   NDMM_MM_ADJACENT_STATES=none Rscript "ndmm/other_malig_overlap.R"

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
# The build's own constants, not a copy of them - a list written out again here
# would answer for a setting the build does not use. Neither file opens a
# connection.
for (f in c("ndmm_constants.R", "standalone_constants.R"))
  source(file.path(.script_dir, "R", f))

DIR <- Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist")
cat("codelist dir: ", DIR, "\n\n", sep = "")
for (f in c("other_malig.csv", "mm_dx.csv"))
  if (!file.exists(file.path(DIR, f)))
    stop(f, " is not in ", DIR, ". Set CODELIST_DIR.", call. = FALSE)

rd <- function(f) read.csv(file.path(DIR, f), stringsAsFactors = FALSE,
                           colClasses = "character",
                           na.strings = c("", "NA", "NaN"))
om <- rd("other_malig.csv")
mm <- rd("mm_dx.csv")

# The same normalisation 04_other_malig.R applies before it joins: strip
# punctuation and upper-case, or C90.10 and C9010 look like different codes.
norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", trimws(as.character(x))))
fam  <- function(x) ifelse(toupper(trimws(as.character(x))) %in%
                             c("9", "ICD9", "ICD-9", "ICD9DIAG"), "ICD9", "ICD10")
om$k <- paste(fam(om$icd_family), norm(om$dx))
mm$k <- paste(fam(mm$icd_family), norm(mm$dx))
om$g <- toupper(trimws(as.character(om$tumor_group)))

line <- function(...) cat(..., "\n", sep = "")
rule <- function() line(strrep("-", 72))

# ---- 1. the overlap -------------------------------------------------------
rule(); line("1. Codes on BOTH lists - what the derived override catches")
rule()
both <- om[om$k %in% mm$k, ]
line("other_malig.csv: ", nrow(om), " rows, ", length(unique(om$g)), " labels")
line("mm_dx.csv:       ", nrow(mm), " rows")
line("on both:         ", nrow(both), " codes")
if (nrow(both)) {
  line("")
  line("So the criterion WOULD exclude cohort members without the override.")
  line("These are kept by `m.dx IS NOT NULL` alone - no list, no sign-off:")
  b <- unique(both[order(both$g, both$k), c("g", "dx", "icd_family")])
  for (g in unique(b$g))
    line("  ", g, ": ", paste(b$dx[b$g == g], collapse = ", "))
} else {
  line("")
  line("NONE. The mm_dx join in 04_other_malig.R matches nothing, so the label")
  line("list is the WHOLE override and every part of it is judgement. The claim")
  line("in ndmm/README.md that the criterion would empty the cohort is wrong.")
}

# ---- 2. every plasma-cell label, with codes -------------------------------
line(""); rule()
line("2. Plasma-cell and myeloma labels on the other-cancer list")
rule()
# Plasma-cell wording only. REMISSION and RELAPSE are a disease state, not a
# disease - as standalone terms they pulled in every leukemia and lymphoma
# label carrying the word and reported it as MM-adjacent.
pat <- "MYELOMA|PLASMA CELL|PLASMACYTOMA|GAMMOPATHY"
pc  <- om[grepl(pat, om$g), ]
if (!nrow(pc)) line("  none - nothing on this list looks plasma-cell at all") else
  for (g in sort(unique(pc$g))) {
    d <- pc[pc$g == g, ]
    line("  ", g)
    line("      ", paste(unique(d$dx), collapse = ", "),
         "   [", paste(unique(fam(d$icd_family)), collapse = "/"), "]",
         if (any(d$k %in% mm$k)) "  <- also on mm_dx.csv" else "")
  }

# ---- 3. the configured labels --------------------------------------------
line(""); rule()
line("3. What NDMM_MM_ADJACENT_STATES='", NDMM_MM_ADJACENT_STATES,
     "' overrides - matched, or a silent no-op")
rule()
GROUPS <- ndmm_mm_adjacent_groups()
# The build stops on a missing one only where the setting asks for it, which is
# what 04_other_malig.R validates.
CORE   <- intersect(NDMM_MM_ADJACENT_OVERRIDE, GROUPS)
STATES <- setdiff(GROUPS, CORE)
if (!length(GROUPS))
  line("  Nothing. Every label on the other-cancer list excludes, and only ",
       "codes\n  that are also on mm_dx.csv survive it.")
for (nm in list(list("required (build stops if missing)", CORE),
                list("states (reported only)", STATES))) {
  if (!length(nm[[2]])) next
  line("  ", nm[[1]], ":")
  for (l in nm[[2]])
    line("    ", if (l %in% om$g) "on the list " else "NOT ON LIST",
         "  ", l,
         if (l %in% om$g) paste0("  (", sum(om$g == l), " codes)") else "")
}
# Anything plasma-cell-looking that no label covers AND the mm_dx join does not
# reach. Both halves matter: a label off the list is still overridden if its
# codes are on mm_dx.csv, and reporting those as excluding would send a
# reviewer after codes the build already keeps.
uncovered <- pc[!(pc$g %in% GROUPS) & !(pc$k %in% mm$k), ]
line("")
if (!nrow(uncovered)) {
  line("  Nothing plasma-cell-looking is left excluding.")
} else {
  line("  STILL EXCLUDING - no label covers these and mm_dx.csv does not",
       " reach them, so they remove patients:")
  for (g in sort(unique(uncovered$g)))
    line("    ", g, ": ", paste(unique(uncovered$dx[uncovered$g == g]),
                                collapse = ", "))
}
line("")
