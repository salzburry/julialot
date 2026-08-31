# The kernel: what the engine does, tumor-free

The engine (`Jul 28/lot/engine/`) never reasons about a disease. It reasons about
**per-drug coverage intervals** and **typed dated events**, and assembles lines by
date arithmetic over them. This file is the condensed mechanism; the full
reference with worked diagrams is the "How LOT works" document, and the code
itself is laid out one rule per step file (see the file map at the end).

## Substrate

**Episodes (MAP — Medication Available Period).** Claims from four arms
(`medical.PROC_CD`/`BILL_PROC_CD` against HCPCS, `medical.NDC` and `rx.NDC`
against NDC-11) are deduplicated and given day supply: pharmacy fills carry their
own `DAYS_SUP` (missing/nonpositive imputed 28), medical administrations a fixed
28. Per `(patient, drug)`, a state machine merges claims into episodes: a fill
inside pharmacy coverage pushes the runout forward by its full supply; medical
coverage never pushes out; a claim past both runouts starts a new episode — any
positive gap splits. `MAP_END_DT` is the later runout. A gap of ≥ 90 days to the
next episode (or to end of observation) sets the per-drug discontinuation flag;
that is the engine's only 90-day rule.

**Event streams.** The SCT code list yields typed dated events. AUTO claims are
clustered (claims within 13 days of a cluster's first claim are one event, dated
by the last claim — the infusion, not the workup; clusters closer than 60 days
merge; a cluster straddling the 180-day tandem boundary is dated by the claim
closest to the boundary). ALLO and CAR-T dates are taken as-is, ordered. This
machinery is the prototype for any non-drug event stream (radiation, surgery).

**Observation.** Every scan is bounded per patient by
`[INDEX_DATE, OBS_END_DT]`. Primary: `OBS_END_DT = ENDDATE` = min(death, study
end) — disenrollment does not censor. Every line also carries a CE-sensitivity
end/reason pair re-capped at disenrollment, so the sensitivity reading needs no
second run.

## Line assembly

**LOT1** starts at the first non-supportive episode (always type `MED` — a
myeloma convention; see rule-shapes). A line's **regimen** is every
non-supportive drug whose episode *begins* in the line's window (60 days for
LOT1, 30 later, 45 when CAR-T-started); the **base set** adds each regimen drug's
declared equivalents (`permissible_subs.csv`). The **discontinuation date** is
the base set's last runout inside observation — base drugs may refill without
bound and the line stretches. The **first added drug** is the earliest
non-supportive episode outside the base set at or before discontinuation; ties on
a day resolve by seeded deterministic random.

**A line ends** the day before the event that starts the next one, through a
fixed priority ladder (myeloma's instance):

```
SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD
        > DEATH > DISCONTINUATION > STUDY_END
```

with two guards: CART_INIT (an added drug followed by CAR-T within 45 days is
bridging; the line ends the day before the CAR-T), and the post-runout guard
(death outranks an earlier runout only when no next-line trigger sits between
them — the guard mirrors the next line's own trigger logic exactly).

**LOT2–5 triggers**, all strictly after the previous line's end: the earliest
non-supportive episode of a drug that is not an equivalent of a drug in the
PREVIOUS line's regimen (neither a prior drug continuing NOR a fresh episode of
it after the line ended triggers - the line runs over the break instead; a drug
last given two or more lines back is outside that scope and triggers like any
other); any ALLO; any CAR-T; any *unplanned* AUTO (outside the prior
line's window and not tandem). Earliest wins; same-day ties resolve
ALLO > CART > AUTO > MED. ALLO lines span a single day with no regimen. The loop
stops at the first empty line, cap 5.

**Criteria layer.** Declared per-study criteria are computed as 0/1 columns on
`LOT_LONG_ALLFLAGS` whether enabled or not; enabled `truncate` criteria remove a
patient's first failing line and everything after, producing `LOT_LONG_FINAL`.

## Guarantees

Fail-loud before `complete`: unique `(PATID, LOT_NUM)`; no null/inverted dates;
lines run 1..n per patient; each starts strictly after the previous ended;
nothing ends past observation. Attrition rows are typed (input / reconciliation /
criterion / final / progression). Six face-validity bands are reported, not
fatal. Every run records code fingerprint, contract settings, code-list hashes,
criteria applied, and counts.

## File map

| File | Owns |
|---|---|
| `R/steps/01_codelists.R` | code-list loading and the consistency checks |
| `R/steps/02_patient_input.R` | `OBS_END_DT` and the disenrollment switch |
| `R/steps/03_mma_map.R` | extraction, NDC normalization, the MAP state machine |
| `R/steps/04_lot1_base.R` | LOT1 start, regimen, discontinuation, first add |
| `R/steps/05_sct.R`, `05b_lot1_sct.R` | event streams; LOT1's transplant summary |
| `R/steps/06_lot1_end.R` | CART_INIT, post-runout guard, LOT1's end ladder |
| `R/steps/10_lot2_5_base.R` | next-line triggers, LOT2–5 assembly, publish |
| `R/line_criteria.R` | the criteria layer |
| `R/melp_rule.R` | the melphalan short-course rule, applied by every study build |
| `R/build_lot.R` | run order, contract checks, attrition, face validity |
