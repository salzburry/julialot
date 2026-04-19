# Spec Cell Replacements — Apr 18 2026

For each cell below: open the file + tab, find the row by variable name, replace the named column with the text in the code block.

**Renumbering:** Rule 1 = substitutions, Rule 2 = discontinuation, Rule 3 = SCT / CAR-T events, Rule 4 = death (was 5), Rule 5 = disenrollment (was 6), Rule 6 = study end (was 7). Old maintenance Rules 4 and 8 are removed. Propagate this renumbering to the protocol, other spec tabs, and `lot_program.R` comments. Alternative: keep old numbering with gaps at 4 and 8 — pick one before applying.

---

## Replacement 1

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_END_REASON_TEMP` · **Column:** `Definition`

```
The LOT will continue until the earliest of any of the following:

(Rule 1) Permissible substitutions: Substitution of a biologic reference product with any of its biosimilars, or between biosimilars of the same reference product, does not advance the LOT (Rule 1 is an exception, not an ending event).

(Rule 2) Discontinuation of all agents in the regimen, with or without switch to a new agent. The LOT end date is the run-out date, defined as the last date that any MM medication in that LOT is considered to be available. If the current LOT is immediately interrupted by a new agent, the LOT end date is the day before the first administration / dispense date of the new agent.

(Rule 3) SCT / CAR-T events: if an autologous SCT occurs > 180 days following a previous autologous SCT, the LOT will end the day before the latter SCT. Any allogeneic SCTs are considered a new LOT and the current LOT will end the day before the allogeneic SCT. CAR-T cellular therapy infusions are classified as their own LOT; the preceding LOT transition for CAR-T is defined in the LOT1_TX_ENDDATE_REASON and LOT1_BASE_END_DT rows.

(Rule 4) Death.

(Rule 5) Health plan disenrollment.

(Rule 6) End of the study period.

Rules 2, 3, 4, 5, and 6 are the ending events. Maintenance is NOT treated as a separate LOT-ending construct in this study.
```

---

## Replacement 2

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_BASE_END_DT` · **Column:** `Definition`

```
LOT1_BASE_END_DT is the earliest applicable LOT-ending date derived from: discontinuation of all agents (Rule 2), new qualifying medication addition (Rule 2), qualifying SCT or CAR-T events (Rule 3), death (Rule 4), health plan disenrollment (Rule 5), or end of study period (Rule 6). Rule 1 defines permissible substitutions that do NOT end the LOT. Maintenance is NOT an independent LOT-ending event in this study.

If the current LOT is immediately interrupted by a new qualifying medication, the LOT end date is the day before the first administration or dispense date of that new medication.

For CAR-T transitions — including the CART_INIT case — LOT1_BASE_END_DT is the day before FIRST_CART_DT. The CAR-T LOT begins on FIRST_CART_DT.
```

---

## Replacement 3

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_BASE_END_REASON` · **Column:** `Values`

```
Allowed values: DISCONTINUATION, MED_ADD, SCT_AUTO, SCT_ALLO, SCT_CART, CART_INIT, DEATH, DISENROLLMENT, STUDY_END.

The study does NOT use MAINTENANCE_END or SCT_NO_MAINT as final values.
```

---

## Replacement 4

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_BASE_END_REASON` · **Column:** `Definition`

```
Final LOT1 base period end reason. Derived by selecting the earliest end date across the LOT-ending events listed in the LOT1_END_REASON_TEMP rules narrative (Rules 2, 3, 4, 5, 6).

Priority order below applies when more than one end-reason resolves on the same earliest end date:
SCT_ALLO  >  SCT_CART  >  SCT_AUTO  >  CART_INIT  >  MED_ADD  >  DISCONTINUATION  >  DEATH  >  DISENROLLMENT  >  STUDY_END

CART_INIT applies when a CAR-T infusion (FIRST_CART_DT) occurs within 45 days of the start date of the first added agent. The end reason is CART_INIT (not MED_ADD), and LOT1_BASE_END_DT is the day before FIRST_CART_DT.

Patients who would previously have ended LOT1 via end of maintenance regimen now map to DISCONTINUATION unless a higher-priority event applies first.

Patients who would previously have been bucketed as SCT_NO_MAINT must be classified under the final non-maintenance LOT-ending rules above; SCT_NO_MAINT is not a final value in this study.
```

---

## Replacement 5

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_BASE_LENGTH` · **Column:** `Definition`

```
LOT1 base period duration in days. Computed as LOT1_BASE_END_DT - LOT1_START_DT + 1. LOT start date is defined per Section 5.1.1 of the protocol. LOT end date is the priority-based end date defined in the LOT1_BASE_END_DT row.
```

---

## Replacement 6

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `contains_mtx_reg` · **Column:** `Definition`

```
contains_mtx_reg is a descriptive flag. The study does NOT derive a separate standalone maintenance period or maintenance regimen. This flag records whether LOT1 contains a valid maintenance-approved subset; it does NOT create a maintenance start date, maintenance end date, or LOT-ending event.

Set contains_mtx_reg = 1 when BOTH of the following are true for the LOT1 induction regimen:
  (a) The induction regimen contains at least one valid mono-maintenance agent OR a valid dual-maintenance combination (see lists below); AND
  (b) At least one additional agent — of any class in CL_MMA_ROLLUP, including corticosteroids (e.g., dexamethasone, prednisone) — is present outside that qualifying maintenance subset, acting as an anchor.

Otherwise contains_mtx_reg = 0.

Valid mono-maintenance agents: lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide.
Valid dual-maintenance combinations: bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide.

The anchor concept exists only to support this descriptive flag. It is NOT used to derive a separate maintenance period or a maintenance-based LOT end. Any additional drug in the induction regimen — oncology or supportive (including steroids) — satisfies the anchor requirement, so the flag identifies the full set of LOT1 patients whose induction contains a maintenance-approved subset alongside any further therapy.
```

---

## Replacement 7

**File:** `lot1baseapr18.xlsx` · **Tab:** `6. LOT1_BASE` · **Row:** `LOT1_MED_[MED]` · **Column:** `Additional Notes`

Find this passage:

```
Once the induction regimen medications are identified, the induction regimen period is defined as the time period beginning with the earliest MMA medication claim and continuing until a valid medication add is introduced (see list of permissible substitutions in LOT1_BASE_MEDS), all induction regimen medications discontinue, censoring, HSCT, or maintenance begins.
```

Replace with:

```
Once the induction regimen medications are identified, the induction regimen period is defined as the time period beginning with the earliest MMA medication claim and continuing until a valid medication add is introduced (see list of permissible substitutions in LOT1_BASE_MEDS), all induction regimen medications discontinue, censoring occurs, or HSCT occurs.
```

(Difference: removed "or maintenance begins".)

---

## Replacement 8

**File:** `Mtx_scenarios.xlsx` · **Tab:** (single tab) · **Cell:** page 1, cell A1 (top banner above existing content)

```
REFERENCE ONLY — updated per Apr 15 2026 meeting.

These maintenance scenarios are retained as background examples and do NOT define an operational maintenance period for this study. The current study uses contains_mtx_reg as a descriptive flag only and does not use maintenance to create a LOT-ending event. For the active definition, see the contains_mtx_reg row in lot1baseendapr18.xlsx, tab 10. LOT1_BASE_END.
```

---

## Replacement A

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_BASE_END_REASON` · **Column:** `Additional Notes`

```
SCT_NO_MAINT is not a final end-reason value in this study. Cases previously classified as SCT_NO_MAINT must be recategorized under the final non-maintenance LOT-ending rules based on the earliest applicable event.
```

---

## Replacement B — RESOLVED: `FIRST_CART_DT − 1` (spec wins)

**File:** `lot1baseendapr18.xlsx` · **Tab:** `10. LOT1_BASE_END` · **Row:** `LOT1_BASE_END_DT` · **Column:** `Additional Notes`

```
CART_INIT end date: When LOT1_BASE_END_REASON = CART_INIT, LOT1_BASE_END_DT is the day before FIRST_CART_DT. The CAR-T LOT begins on FIRST_CART_DT.
```

**Code alignment required:** update all CART_INIT end-date derivations and dependent `LOT1_BASE_LENGTH` logic in `lot_program.R` — not only the 1940-1942 branch (there is a parallel branch in the `LOT1_BASE_LENGTH` CASE around 1972-1974 and potentially other `CART_INIT` date comparisons that need review).

---

## Summary

| # | File | Tab | Row | Column |
|---|---|---|---|---|
| 1 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_END_REASON_TEMP` | Definition |
| 2 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_DT` | Definition |
| 3 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_REASON` | Values |
| 4 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_REASON` | Definition |
| 5 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_LENGTH` | Definition |
| 6 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `contains_mtx_reg` | Definition |
| 7 | `lot1baseapr18.xlsx` | `6. LOT1_BASE` | `LOT1_MED_[MED]` | Additional Notes |
| 8 | `Mtx_scenarios.xlsx` | (single tab) | page 1, A1 | top banner |
| A | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_REASON` | Additional Notes |
| B | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_DT` | Additional Notes |

Apply all 10. Only open item: the code alignment flagged under Replacement B (to be handled later, not in this pass).
