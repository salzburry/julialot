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
