#!/usr/bin/env Rscript
# QC + route-scrub for steroid_codes.csv (MM LOT steroid codelist).
#
# WHY: the steroid loader (05_regimen_dashboard.R) matches ANY NDC/HCPCS in
# this file with no route filter. A broad NDC pull sweeps in dexamethasone
# eye/ear drops, topicals, and antibiotic-steroid combos (TobraDex,
# Ciprodex, neomycin-polymyxin-dex, etc.) that are NOT MM-regimen steroids.
# Counting those tags patients with a steroid they never took for MM:
# inflates steroid prevalence (Julia Q3) AND hides the missing-steroid
# cases (Julia Q4). This keeps oral + injectable (systemic) only.
#
# RUN in RStudio on Domino. Set `f` to your steroid_codes.csv, then:
#   source("qc_steroid_codes.R")
# Review steroid_codes_REMOVED_review.csv, then use steroid_codes_clean.csv.

f <- "steroid_codes.csv"   # <-- set to your path if not in the working dir

df <- read.csv(f, stringsAsFactors = FALSE, check.names = FALSE,
               comment.char = "#")
names(df) <- tolower(trimws(names(df)))
if (!"note" %in% names(df)) df$note <- ""
stopifnot(all(c("code", "code_type", "mapped_to") %in% names(df)))

code_n <- toupper(gsub("[^A-Za-z0-9]", "", df$code))
type_n <- toupper(trimws(df$code_type))
map_n  <- toupper(trimws(df$mapped_to))

# --- format problems (silent failures in the loader) ---
bad_type  <- !type_n %in% c("NDC", "HCPCS")          # won't match any claim field
blank_map <- !nzchar(map_n)                          # row is dropped at load
bad_ndc   <- type_n == "NDC" & !grepl("^[0-9]{10,11}$", code_n)

# --- route / formulation scrub (the important one) ---
# Flags non-systemic dexamethasone and antibiotic-steroid combos by their
# description. Heuristic on the note text -> ALWAYS eyeball the REMOVED file.
nonsys <- grepl(paste(c(
  "ophth", "eye", "otic", "\\bear\\b", "nasal", "intranasal", "inhal",
  "aerosol", "topical", "cream", "ointment", "lotion", "\\bgel\\b",
  "\\bdrops?\\b", "intravitreal", "implant",
  "tobramycin", "tobradex", "ciprofloxacin", "ciprodex", "neomycin",
  "polymyxin", "maxitrol", "gentamicin", "moxiflox"
), collapse = "|"), df$note, ignore.case = TRUE)

drop <- bad_type | blank_map | bad_ndc | nonsys

cat("== steroid_codes QC ==\n")
cat(sprintf("rows: %d | NDC: %d | HCPCS: %d\n",
            nrow(df), sum(type_n == "NDC"), sum(type_n == "HCPCS")))
cat("mapped_to tokens:\n"); print(table(map_n))
cat(sprintf("bad code_type: %d | blank mapped_to: %d | malformed NDC: %d | non-systemic/combo: %d\n",
            sum(bad_type), sum(blank_map), sum(bad_ndc), sum(nonsys)))
cat(sprintf("=> would REMOVE %d, KEEP %d\n\n", sum(drop), sum(!drop)))

out <- c("code", "code_type", "mapped_to", "note")
write.csv(df[drop,  out], "steroid_codes_REMOVED_review.csv", row.names = FALSE)
write.csv(df[!drop, out], "steroid_codes_clean.csv",          row.names = FALSE)
cat("wrote steroid_codes_REMOVED_review.csv  <- EYEBALL THIS first\n")
cat("wrote steroid_codes_clean.csv           <- swap in after review, then re-run\n")
