# validate_canonical (adapter validation report)
res <- validate_canonical_dir("tests/fixtures/synthetic")
ok(isTRUE(attr(res, "ok")), "synthetic fixtures conform to the canonical contract")
ok(!is.null(res$pharmacy) && length(res$pharmacy$errors) == 0, "pharmacy entity valid")

# crafted negatives
sp <- CANONICAL_SPEC$pharmacy
miss <- data.frame(patient_id = "9000000001", stringsAsFactors = FALSE)
ok(any(grepl("missing required", validate_entity(miss, sp)$errors)), "missing required column caught")

# NDC contract: normalized_code must ITSELF be a valid 11-digit NDC. A non-11-digit
# normalized value is rejected (the adapter owns segment-aware 10->11 conversion).
bad_ndc <- data.frame(patient_id = "9000000001", service_date = "2020-01-01",
  raw_ndc = "00002-1433-80", normalized_code = "2143380", code_system = "NDC",
  days_supply = "28", source_table = "rx", source_record_id = "x", data_vintage = "SYNTH",
  stringsAsFactors = FALSE)
ok(any(grepl("canonical 11-digit NDC", validate_entity(bad_ndc, sp)$errors)),
   "non-11-digit normalized NDC caught")
# the STORED value must be EXACTLY 11 digits: a dashed 11-digit value is rejected
# (is_ndc11 does not strip separators the way the adapter's normalize_ndc does).
dash_ndc <- data.frame(patient_id = "9000000001", service_date = "2020-01-01",
  raw_ndc = "00002-1433-80", normalized_code = "0000-2143-380", code_system = "NDC",
  days_supply = "28", source_table = "rx", source_record_id = "x", data_vintage = "SYNTH",
  stringsAsFactors = FALSE)
ok(any(grepl("canonical 11-digit NDC", validate_entity(dash_ndc, sp)$errors)),
   "dashed stored NDC rejected (exact ^[0-9]{11}$, not stripped)")
# raw is preserved for lineage, NOT recomputed: an exact 11-digit normalized_code
# passes even when raw carries dashes / a different segmentation.
good_ndc <- data.frame(patient_id = "9000000001", service_date = "2020-01-01",
  raw_ndc = "00002-1433-80", normalized_code = "00002143380", code_system = "NDC",
  days_supply = "28", source_table = "rx", source_record_id = "x", data_vintage = "SYNTH",
  stringsAsFactors = FALSE)
ok(!any(grepl("11-digit NDC", validate_entity(good_ndc, sp)$errors)),
   "valid 11-digit normalized NDC accepted (raw not recomputed)")
# two duplicate grains: source-level (incl source_record_id) AND the post-dedup
# algorithm grain (excl it) are BOTH validated.
ddp <- read.csv("tests/fixtures/synthetic/pharmacy.csv", colClasses = "character")
ddp <- rbind(ddp, ddp[1, ]); ddp$source_record_id[nrow(ddp)] <- "DIFFERENT_REC"
ok(any(grepl("dedup grain", validate_entity(ddp, sp)$errors)),
   "post-dedup grain collision flagged (same patient+date+code, diff source_record_id)")

dup <- read.csv("tests/fixtures/synthetic/pharmacy.csv", colClasses = "character")
dup <- rbind(dup, dup[1, ])  # duplicate the full key
ok(any(grepl("not unique", validate_entity(dup, sp)$errors)), "duplicate key caught")

bad_date <- data.frame(patient_id = "9000000001", service_date = "01/02/2020",
  raw_ndc = "00002143380", normalized_code = "00002143380", code_system = "NDC",
  days_supply = "28", source_table = "rx", source_record_id = "x", data_vintage = "SYNTH",
  stringsAsFactors = FALSE)
ok(any(grepl("non-ISO date", validate_entity(bad_date, sp)$errors)), "non-ISO date caught")

ph <- function() read.csv("tests/fixtures/synthetic/pharmacy.csv", colClasses = "character")
bs <- ph(); bs$code_system[1] <- "HCPCS"
ok(any(grepl("code_system.*not in", validate_entity(bs, sp)$errors)), "wrong code_system domain caught")
bd <- ph(); bd$days_supply[1] <- "0"
ok(any(grepl("non-positive", validate_entity(bd, sp)$errors)), "non-positive day-supply caught")
bi <- ph(); bi$days_supply[1] <- "28.5"
ok(any(grepl("non-integer", validate_entity(bi, sp)$errors)), "decimal rejected by integer check")
mem <- read.csv("tests/fixtures/synthetic/members.csv", colClasses = "character"); mem$span_end[1] <- "2018-01-01"
ok(any(grepl("span_start > span_end", validate_entity(mem, CANONICAL_SPEC$members)$errors)), "bad enrollment span caught")
nl <- ph(); nl$source_record_id <- NULL
ok(any(grepl("source_record_id", validate_entity(nl, sp)$errors)), "missing lineage column caught")
 med_ok <- validate_canonical_dir("tests/fixtures/synthetic")$medical
ok(length(med_ok$errors) == 0, "one-row-per-code medical fixture valid")
# medical grain: the same code from two physical fields on ONE record must be
# collapsed to one row by the adapter; a residual collision (rows differing only
# by source_code_field) is a blocking key violation, not a silent merge.
spm <- CANONICAL_SPEC$medical
medc <- data.frame(patient_id = c("9000000001", "9000000001"), service_date = c("2020-01-01", "2020-01-01"),
  raw_code = c("J9999", "J9999"), normalized_code = c("J9999", "J9999"), code_system = c("HCPCS", "HCPCS"),
  source_code_field = c("proc_cd", "bill_proc_cd"), day_supply = c("1", "1"),
  source_table = c("med", "med"), source_record_id = c("r1", "r1"), data_vintage = c("SYNTH", "SYNTH"),
  stringsAsFactors = FALSE)
ok(any(grepl("not unique", validate_entity(medc, spm)$errors)),
   "same-record two-field code collision flagged (key enforces dedup-to-one)")

# required-entity enforcement (an incomplete adapter output must not pass)
tmp <- file.path(tempdir(), "incomplete_canon"); dir.create(tmp, showWarnings = FALSE)
file.copy("tests/fixtures/synthetic/pharmacy.csv", file.path(tmp, "pharmacy.csv"), overwrite = TRUE)
r2 <- validate_canonical_dir(tmp)   # require_present = TRUE (default)
ok(!isTRUE(attr(r2, "ok")) &&
   any(grepl("required canonical entity", unlist(lapply(r2, `[[`, "errors")))),
   "missing required entity blocks (require_present)")
ok(isTRUE(attr(validate_canonical_dir(tmp, require_present = FALSE), "ok")),
   "require_present=FALSE allows a partial fixture dir")
ok(length(REQUIRED_ENTITIES) == 6L, "all six canonical entities are in the spec")
