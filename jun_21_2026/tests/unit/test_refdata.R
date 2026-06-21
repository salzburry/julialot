# validate_reference_data + NDC normalization (require validated 11-digit)
ok(is.na(normalize_ndc("1234567890")), "10-digit NDC rejected as ambiguous (require 11)")
eq(normalize_ndc("00002-1433-80"), "00002143380", "dashed 11-digit NDC normalized")
ok(is.na(normalize_ndc("BADNDC")), "non-numeric NDC rejected (NA)")

good <- data.frame(code = c("J8540", "00002-1433-80"),
                   code_type = c("HCPCS", "NDC"),
                   mapped_to = c("DEXA", "DEXA"), stringsAsFactors = FALSE)
r <- validate_reference_data(good, list(id = "s", row_count_min = 1,
                                        expected_systems = c("HCPCS", "NDC")))
ok(length(r$errors) == 0, "valid HCPCS+NDC codelist passes")

bad <- data.frame(code = c("J8540", "XYZ"), code_type = c("HCPCS", "NDC"),
                  mapped_to = c("DEXA", "DEXA"), stringsAsFactors = FALSE)
ok(length(validate_reference_data(bad, list(id = "s", row_count_min = 1))$errors) > 0,
   "bad NDC blocks")

noco <- data.frame(code = "J8540", mapped_to = "DEXA", stringsAsFactors = FALSE) # missing code_type
ok(any(grepl("missing required column", validate_reference_data(noco, list(id = "s"))$errors)),
   "missing column blocks")

# one normalized NDC mapping to TWO different concepts -> BLOCKING error
conflict <- data.frame(code = c("00002-1433-80", "00002143380"),
                       code_type = c("NDC", "NDC"), mapped_to = c("DEXA", "PRED"),
                       stringsAsFactors = FALSE)
ok(any(grepl("map to >1 concept", validate_reference_data(conflict, list(id = "s", row_count_min = 1))$errors)),
   "same normalized NDC -> two concepts blocks")
# two raw forms -> same code, SAME concept -> warning only
samec <- data.frame(code = c("00002-1433-80", "00002143380"),
                    code_type = c("NDC", "NDC"), mapped_to = c("DEXA", "DEXA"),
                    stringsAsFactors = FALSE)
rs <- validate_reference_data(samec, list(id = "s", row_count_min = 1))
ok(length(rs$errors) == 0 && any(grepl("normalize to the same code", rs$warnings)),
   "raw-form collision (same concept) is warning, not blocking")
# collision check is GENERAL: an HCPCS code mapping to two concepts also blocks
hconf <- data.frame(code = c("J8540", "J8540"), code_type = c("HCPCS", "HCPCS"),
                    mapped_to = c("DEXA", "PRED"), stringsAsFactors = FALSE)
ok(any(grepl("map to >1 concept", validate_reference_data(hconf, list(id = "s", row_count_min = 1))$errors)),
   "HCPCS code -> two concepts blocks")

# promote: blocks bad codelist / missing approval; dry-run is promotable but NOT written
bad_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(code = "XYZ", code_type = "NDC", mapped_to = "DEXA"), bad_csv, row.names = FALSE)
ok(!isTRUE(promote(bad_csv, "s", "1.0.0", clinical = "c", engineering = "e")$promotable),
   "promote blocks an invalid codelist")
good_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(code = "J8540", code_type = "HCPCS", mapped_to = "DEXA"), good_csv, row.names = FALSE)
ok(!isTRUE(promote(good_csv, "s", "1.0.0")$promotable), "promote blocks missing approval")
ok(!isTRUE(promote(good_csv, "s", "1.0.0", clinical = "c", engineering = "")$promotable),
   "promote blocks a blank approval")
pr <- promote(good_csv, "s", "1.0.0", clinical = "c", engineering = "e")
ok(isTRUE(pr$promotable) && !isTRUE(pr$written),
   "promote dry-run is promotable but NOT written (distinct flags)")
