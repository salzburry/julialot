# validate_canonical (adapter validation report)
res <- validate_canonical_dir("tests/fixtures/synthetic")
ok(isTRUE(attr(res, "ok")), "synthetic fixtures conform to the canonical contract")
ok(!is.null(res$pharmacy) && length(res$pharmacy$errors) == 0, "pharmacy entity valid")

# crafted negatives
sp <- CANONICAL_SPEC$pharmacy
miss <- data.frame(patient_id = "9000000001", stringsAsFactors = FALSE)
ok(any(grepl("missing required", validate_entity(miss, sp)$errors)), "missing required column caught")

bad_ndc <- data.frame(patient_id = "9000000001", service_date = "2020-01-01",
  raw_ndc = "00002-1433-80", normalized_code = "2143380", code_system = "NDC",
  days_supply = "28", source_record_id = "x", data_vintage = "SYNTH",
  stringsAsFactors = FALSE)
ok(any(grepl("NDC normalization mismatch", validate_entity(bad_ndc, sp)$errors)),
   "wrong normalized NDC caught")

dup <- read.csv("tests/fixtures/synthetic/pharmacy.csv", colClasses = "character")
dup <- rbind(dup, dup[1, ])  # duplicate the full key
ok(any(grepl("not unique", validate_entity(dup, sp)$errors)), "duplicate key caught")

bad_date <- data.frame(patient_id = "9000000001", service_date = "01/02/2020",
  raw_ndc = "00002143380", normalized_code = "00002143380", code_system = "NDC",
  days_supply = "28", source_record_id = "x", data_vintage = "SYNTH",
  stringsAsFactors = FALSE)
ok(any(grepl("non-ISO date", validate_entity(bad_date, sp)$errors)), "non-ISO date caught")
