# validate_study + base+delta + gate DAG
reg <- load_registry("cohort/gates/registry.yml")
studies <- load_all_studies("studies")

ov <- validate_study("studies/overall.yml", "cohort/gates/registry.yml", "studies")
ok(length(ov$errors) == 0, "overall (base study) valid")
eq(length(ov$resolved), 6L, "overall resolves to 6 gates")

nd <- validate_study("studies/ndmm.yml", "cohort/gates/registry.yml", "studies")
ok(length(nd$errors) == 0, "ndmm (base+delta) valid")
eq(length(nd$resolved), 10L, "ndmm resolves to 10 gates (6 inherited + 4 added)")
ok(nd$resolved$baseline_ce$months == 12, "ndmm override: baseline_ce months 6->12")
ok(isTRUE(nd$resolved$followup_ce$strict), "ndmm override: followup_ce strict")
ok("no_pregnancy" %in% names(nd$resolved), "ndmm added no_pregnancy")
ok(any(grepl("unpinned", nd$warnings)), "unpinned base hash warned")

# cross-rule violations (resolve_study directly)
bad_ovr <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "TBD"),
                gates = list(override = list(no_pregnancy = TRUE)))  # not inherited
ok(any(grepl("override references non-inherited", resolve_study(bad_ovr, studies, reg)$errors)),
   "override of non-inherited gate caught")

bad_dup <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "TBD"),
                gates = list(add = list(baseline_ce = TRUE)))  # already inherited
ok(any(grepl("duplicates inherited", resolve_study(bad_dup, studies, reg)$errors)),
   "add of inherited gate caught")

both <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "TBD"),
             gates = list(override = list(baseline_ce = list(months = 9)),
                          disable = list("baseline_ce")))
ok(any(grepl("both disabled and overridden", resolve_study(both, studies, reg)$errors)),
   "gate both disabled and overridden caught")

# DAG: a gate depending on an unknown node is rejected
reg2 <- reg; reg2$gates$followup_ce$depends_on <- list("nonexistent_stage")
ok(any(grepl("unknown node", validate_dag(nd$resolved, reg2))), "unknown dependency caught")

# base-hash pinning: TBD warns (non-strict) but BLOCKS (strict)
nds <- validate_study("studies/ndmm.yml", "cohort/gates/registry.yml", "studies", strict = TRUE)
ok(any(grepl("hash unpinned", nds$errors)), "strict: unpinned (TBD) base hash blocks")
# a correctly pinned hash passes; a wrong one is rejected (verified, not accepted)
exp <- content_hash(paste(deparse(studies[["overall_2025"]]), collapse = ""))
pin_ok <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = exp),
               gates = list(add = list(no_pregnancy = TRUE)))
ok(length(resolve_study(pin_ok, studies, reg, strict = TRUE)$errors) == 0, "correct base hash pin passes (strict)")
pin_bad <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "deadbeef"),
                gates = list(add = list(no_pregnancy = TRUE)))
ok(any(grepl("hash mismatch", resolve_study(pin_bad, studies, reg)$errors)), "wrong base hash rejected")
