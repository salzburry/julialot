# validate_study + base+delta + gate DAG
reg <- load_registry("cohort/gates/registry.yml")
studies <- load_all_studies("studies")

ov <- validate_study("studies/overall.yml", "cohort/gates/registry.yml", "studies", strict = TRUE)
ok(length(ov$errors) == 0, "overall (base study) valid (strict)")
eq(length(ov$resolved), 6L, "overall resolves to 6 gates")

# ndmm.yml is now PINNED -> valid under strict (the CLI default behaviour)
nd <- validate_study("studies/ndmm.yml", "cohort/gates/registry.yml", "studies", strict = TRUE)
ok(length(nd$errors) == 0, "ndmm (base+delta) valid (strict, pinned base)")
eq(length(nd$resolved), 10L, "ndmm resolves to 10 gates (6 inherited + 4 added)")
ok(nd$resolved$baseline_ce$months == 12, "ndmm override: baseline_ce months 6->12")
ok(isTRUE(nd$resolved$followup_ce$strict), "ndmm override: followup_ce strict")
ok("no_pregnancy" %in% names(nd$resolved), "ndmm added no_pregnancy")

mk <- function(gates) list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "TBD"),
                           gates = gates)

# cross-rule violations
ok(any(grepl("override references non-inherited", resolve_study(mk(list(override = list(no_pregnancy = TRUE))), studies, reg)$errors)),
   "override of non-inherited gate caught")
ok(any(grepl("duplicates inherited", resolve_study(mk(list(add = list(baseline_ce = TRUE))), studies, reg)$errors)),
   "add of inherited gate caught")
ok(any(grepl("both disabled and overridden",
   resolve_study(mk(list(override = list(baseline_ce = list(months = 9)), disable = list("baseline_ce"))), studies, reg)$errors)),
   "gate both disabled and overridden caught")

# FALSE in add/override is invalid (use disable)
ok(any(grepl("'false' invalid", resolve_study(mk(list(add = list(no_pregnancy = FALSE))), studies, reg)$errors)),
   "false in gates.add rejected")
# param TYPE validation
ok(any(grepl("param 'months' expected integer",
   resolve_study(mk(list(override = list(baseline_ce = list(months = "lots")))), studies, reg)$errors)),
   "bad param type caught")
# unknown param
ok(any(grepl("unknown param", resolve_study(mk(list(add = list(no_pregnancy = list(bogus = 1)))), studies, reg)$errors)),
   "unknown param caught")
# base VERSION mismatch
badv <- list(id = "x", base = list(id = "overall_2025", version = "9.9.9", hash = "TBD"),
             gates = list(add = list(no_pregnancy = TRUE)))
ok(any(grepl("version pinned", resolve_study(badv, studies, reg)$errors)), "base version mismatch caught")

# DAG: unknown node + phase feasibility
reg2 <- reg; reg2$gates$followup_ce$depends_on <- list("nonexistent_stage")
ok(any(grepl("unknown node", validate_dag(nd$resolved, reg2))), "unknown dependency caught")
reg3 <- reg; reg3$gates$adult_at_index$depends_on <- list("lot1_start")  # a pre_lot gate
ok(any(grepl("not produced until a later phase", validate_dag(nd$resolved, reg3))),
   "phase-infeasible dependency caught")

# base-hash pinning: an unpinned (TBD) base warns (non-strict) but BLOCKS (strict)
unp <- list(id = "u", base = list(id = "overall_2025", version = "1.0.0", hash = "TBD"),
            gates = list(add = list(no_pregnancy = TRUE)))
ok(any(grepl("hash unpinned", resolve_study(unp, studies, reg, strict = TRUE)$errors)), "strict: TBD base hash blocks")
ok(any(grepl("hash unpinned", resolve_study(unp, studies, reg, strict = FALSE)$warnings)), "non-strict: TBD base hash warns")
exp <- content_hash(paste(deparse(studies[["overall_2025"]]), collapse = ""))
pin_ok <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = exp),
               gates = list(add = list(no_pregnancy = TRUE)))
ok(length(resolve_study(pin_ok, studies, reg, strict = TRUE)$errors) == 0, "correct base hash pin passes (strict)")
pin_bad <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "deadbeef"),
                gates = list(add = list(no_pregnancy = TRUE)))
ok(any(grepl("hash mismatch", resolve_study(pin_bad, studies, reg)$errors)), "wrong base hash rejected")

# --- registry defaults / required params / numeric ranges --------------------
# defaults are filled into the resolved artifact (baseline_ce gets max_gap_days=30)
ok(isTRUE(nd$resolved$baseline_ce$max_gap_days == 30), "registry default filled into resolved gate")
# numeric range bounds (min/max) enforced
ok(any(grepl("above max", resolve_study(mk(list(override = list(baseline_ce = list(months = 999)))), studies, reg)$errors)),
   "out-of-range param (above max) caught")
ok(any(grepl("below min", resolve_study(mk(list(override = list(adult_at_index = list(minimum_age = -5)))), studies, reg)$errors)),
   "out-of-range param (below min) caught")
# a required param with NO default that is not supplied -> blocking
reg_req <- reg; reg_req$gates$no_pregnancy$params <- list(window_days = list(type = "integer", required = TRUE))
ok(any(grepl("missing required param", resolve_study(mk(list(add = list(no_pregnancy = TRUE))), studies, reg_req)$errors)),
   "missing required param (no default) caught")
# a param WITH a default is filled rather than required
reg_def <- reg; reg_def$gates$no_pregnancy$params <- list(window_days = list(type = "integer", default = 30))
ok(isTRUE(resolve_study(mk(list(add = list(no_pregnancy = TRUE))), studies, reg_def)$resolved$no_pregnancy$window_days == 30),
   "param default fills when unset (no required error)")
# an unknown registry phase name is not silently allowed
reg5 <- reg; reg5$gates$qualifying_mm$phase <- "bogus_phase"
ok(any(grepl("unknown phase", validate_dag(nd$resolved, reg5))), "invalid phase name caught")

# --- clinical approval axis (machine-enforced, separate from structural) ------
# a DRAFT study is structurally valid (errors==0) but warns; a release gate blocks
ok(any(grepl("NOT cleared for production", ov$warnings)), "draft study warns by default")
ov_ra <- validate_study("studies/overall.yml", "cohort/gates/registry.yml", "studies",
                        strict = TRUE, require_approved = TRUE)
ok(any(grepl("NOT cleared for production", ov_ra$errors)), "require_approved: draft study blocks (fail closed)")
# an 'approved' claim must carry an auditable signer + date, else rejected
ok(any(grepl("requires signed_off_by", validate_approval(list(approval = list(status = "approved")), "study x")$errors)),
   "approved without signer rejected")
ok(length(validate_approval(list(approval = list(status = "approved", signed_off_by = "Dr X",
   signed_off_date = "2026-01-01")), "study x")$errors) == 0, "approved with signer+date passes")
ok(any(grepl("not in", validate_approval(list(approval = list(status = "bogus")), "study x")$errors)),
   "unknown approval status caught")
