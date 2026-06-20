# validate_reference_data + NDC normalization
eq(normalize_ndc("1234567890"), "01234567890", "10-digit NDC zero-padded to 11")
eq(normalize_ndc("00002-1433-80"), "00002143380", "dashed NDC normalized")
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
ok(length(rs$errors) == 0 && any(grepl("same 11-digit code", rs$warnings)),
   "raw-form collision (same concept) is warning, not blocking")

# promote: blocks bad codelist / missing approval; dry-run succeeds with both approvals
bad_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(code = "XYZ", code_type = "NDC", mapped_to = "DEXA"), bad_csv, row.names = FALSE)
ok(!isTRUE(promote(bad_csv, "s", "1.0.0", clinical = "c", engineering = "e")$promoted),
   "promote blocks an invalid codelist")
good_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(code = "J8540", code_type = "HCPCS", mapped_to = "DEXA"), good_csv, row.names = FALSE)
ok(!isTRUE(promote(good_csv, "s", "1.0.0")$promoted), "promote blocks missing approval")
ok(isTRUE(promote(good_csv, "s", "1.0.0", clinical = "c", engineering = "e")$promoted),
   "promote dry-run succeeds with both approvals")
