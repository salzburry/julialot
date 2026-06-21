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
# any non-TRUE/non-object scalar must block, not silently enable the gate
ok(any(grepl("invalid value", resolve_study(mk(list(add = list(no_pregnancy = "yes"))), studies, reg)$errors)),
   "string gate value rejected")
ok(any(grepl("invalid value", resolve_study(mk(list(add = list(no_pregnancy = 123))), studies, reg)$errors)),
   "numeric gate value rejected")
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
exp <- content_hash(studies[["overall_2025"]])
pin_ok <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = exp),
               gates = list(add = list(no_pregnancy = TRUE)))
ok(length(resolve_study(pin_ok, studies, reg, strict = TRUE)$errors) == 0, "correct base hash pin passes (strict)")
pin_bad <- list(id = "x", base = list(id = "overall_2025", version = "1.0.0", hash = "deadbeef"),
                gates = list(add = list(no_pregnancy = TRUE)))
ok(any(grepl("hash mismatch", resolve_study(pin_bad, studies, reg)$errors)), "wrong base hash rejected")
# base hash is order-stable: reordering YAML keys must NOT churn the pinned hash
ov_s <- studies[["overall_2025"]]
ok(content_hash(ov_s) == content_hash(ov_s[rev(names(ov_s))]), "base hash stable under key reordering")
ok(content_hash(list(a = 1, b = list(x = 1, y = 2))) == content_hash(list(b = list(y = 2, x = 1), a = 1)),
   "content_hash canonicalizes nested list key order")

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
# signed_off_date must be a real ISO date, not merely non-blank
ok(any(grepl("not an ISO", validate_approval(list(approval = list(status = "approved",
   signed_off_by = "Dr X", signed_off_date = "last tuesday")), "study x")$errors)),
   "non-ISO signed_off_date rejected")
# approval is validated across the WHOLE inherited chain: a draft BASE blocks a
# release even if the derived study were approved.
nd_ra <- validate_study("studies/ndmm.yml", "cohort/gates/registry.yml", "studies",
                        strict = TRUE, require_approved = TRUE)
ok(any(grepl("overall_2025.*NOT cleared", nd_ra$errors)), "draft BASE study blocks release (chain checked)")
ok(!is.null(nd_ra$chain_approvals[["overall_2025"]]), "every chain approval recorded in the artifact")

# study.schema.json and the runtime validator are one contract: the example
# studies conform; an undeclared top-level key is rejected (closed schema).
SCH <- "contracts/study.schema.json"
ov_obj <- read_yaml_file("studies/overall.yml")
nd_obj <- read_yaml_file("studies/ndmm.yml")
ok(length(validate_study_schema(ov_obj, SCH)) == 0, "overall conforms to closed schema")
ok(length(validate_study_schema(nd_obj, SCH)) == 0, "ndmm conforms to nested closed schema")
ok(any(grepl("undeclared key", validate_study_schema(modifyList(ov_obj, list(surprise_key = 1)), SCH))),
   "undeclared top-level key rejected")
# RECURSIVE: nested required + nested closedness + oneOf branch are all enforced
sp_bad <- ov_obj; sp_bad$study_period$id_end <- NULL
ok(any(grepl("study_period: missing required", validate_study_schema(sp_bad, SCH))),
   "nested missing required (study_period.id_end) caught")
ap_bad <- ov_obj; ap_bad$approval$bogus <- 1
ok(any(grepl("approval: undeclared", validate_study_schema(ap_bad, SCH))),
   "nested undeclared key (approval.bogus) caught")
base_bad <- nd_obj; base_bad$base$hash <- NULL
ok(any(grepl("base: missing required", validate_study_schema(base_bad, SCH))),
   "oneOf object branch: base missing hash caught")
ok(length(validate_study_schema(ov_obj, SCH)) == 0, "base: null still passes the oneOf null branch")

# gate -> gate phase feasibility (not just gate -> stage): a pre_lot gate may not
# depend on a post_lot1 gate.
reg6 <- reg; reg6$gates$qualifying_mm$depends_on <- list("no_prior_mm_tx")
ok(any(grepl("depends on gate .* in a later phase", validate_dag(nd$resolved, reg6))),
   "gate->gate phase feasibility caught")
# study -> validate_config wiring: a bad study_period date in the YAML is caught
tmpsd <- file.path(tempdir(), "studies_badcfg"); dir.create(tmpsd, showWarnings = FALSE)
file.copy("studies/overall.yml", file.path(tmpsd, "overall.yml"), overwrite = TRUE)
ndl <- readLines("studies/ndmm.yml")
ndl <- sub("study_start: \"2015-07-01\"", "study_start: \"2030-01-01\"", ndl, fixed = TRUE)
writeLines(ndl, file.path(tmpsd, "ndmm.yml"))
ndw <- validate_study(file.path(tmpsd, "ndmm.yml"), "cohort/gates/registry.yml", tmpsd, strict = FALSE)
ok(any(grepl("config:.*study_start must be", ndw$errors)), "bad study_period date caught via config wiring")
# the full resolved-study artifact carries definition + approval chain, not just gates
art <- resolved_study_artifact(nd)
ok(!is.null(art$study_period) && !is.null(art$parameters) && !is.null(art$chain_approvals) &&
   !is.null(art$resolved_gates), "resolved-study artifact is complete (period+params+approvals+gates)")
