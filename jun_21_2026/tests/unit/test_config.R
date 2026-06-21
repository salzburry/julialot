# validate_config
good <- list(study_start = "2015-07-01", study_end = "2025-06-30",
             id_start = "2016-01-01", id_end = "2025-06-30")
ok(length(validate_config(apply_defaults(good))) == 0, "defaults+dates valid")
e <- validate_config(apply_defaults(c(good, list(max_lot = 99L))))
ok(any(grepl("max_lot", e)), "max_lot out of range caught")
e <- validate_config(apply_defaults(c(good, list(allo_lot_span = "bogus"))))
ok(any(grepl("allo_lot_span", e)), "bad enum caught")
e <- validate_config(apply_defaults(list()))  # missing required dates
ok(any(grepl("study_start", e)), "missing required field caught")
e <- validate_config(apply_defaults(modifyList(good, list(study_start = "2030-01-01"))))
ok(any(grepl("study_start must be", e)), "cross-field date order caught")
# ID window: ordering + containment inside the study period
e <- validate_config(apply_defaults(modifyList(good, list(id_start = "2026-01-01"))))
ok(any(grepl("id_start must be <= id_end", e)), "id window order caught")
e <- validate_config(apply_defaults(modifyList(good, list(id_start = "2014-01-01"))))
ok(any(grepl("id_start must be >= study_start", e)), "id_start before study period caught")
e <- validate_config(apply_defaults(modifyList(good, list(id_end = "2030-01-01"))))
ok(any(grepl("id_end must be <= study_end", e)), "id_end after study period caught")
