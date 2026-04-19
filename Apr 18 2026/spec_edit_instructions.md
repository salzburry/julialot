# Spec Cell Replacements — Apr 18 2026

**Format:** For each cell, the file, tab, variable (= row), column, and the **complete final text** to replace the cell with. No commentary inside the replacement text — paste it verbatim.

**Note on cell references:** The Apr 18 spec workbook is set up as a tabbed Excel-style document with columns like Variable, Label, Values, Definition, Code Lists Group, Additional Notes, Date Modified, QC Reviewed. The replacements below identify each cell by tab + variable name + column header. (Excel column letters depend on the workbook layout — locate by header.)

---

## Replacement 1

**File:** `lot1baseendapr18.pdf` (Excel: `lot1baseendapr18.xlsx`)
**Tab:** `10. LOT1_BASE_END`
**Cell:** Page 1, top narrative cell (the long free-form cell that lists Rules 1–8 — there is only one such cell on page 1 above the variable table)

**Replace the entire cell contents with:**

```
The LOT will continue until the earliest of any of the following:

(Rule 1) Permissible substitutions: Substitution of a biologic reference product with any of its biosimilars, or between biosimilars of the same reference product, does not advance the LOT (Rule 1 is an exception, not an ending event).

(Rule 2) Discontinuation of all agents in the regimen, with or without switch to a new agent. The LOT end date is the run-out date, defined as the last date that any MM medication in that LOT is considered to be available. If the current LOT is immediately interrupted by a new agent, the LOT end date is the day before the first administration / dispense date of the new agent.

(Rule 3) Unplanned SCTs: if an autologous SCT occurs > 180 days following a previous autologous SCT, the LOT will end the day before the latter SCT. Any allogeneic SCTs are considered a new LOT and the current LOT will end the day before the allogeneic SCT.

(Rule 5) Death.

(Rule 6) Health plan disenrollment.

(Rule 7) End of the study period.

Rules 2, 3, 5, 6, and 7 are the ending events. Maintenance is NOT treated as a separate LOT-ending construct in this study (former Rules 4 and 8 removed per Apr 15 2026 meeting decision).
```

---

## Replacement 2

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `LOT1_BASE_END_DT`
**Column:** `Definition`

**Replace the entire cell contents with:**

```
LOT1_BASE_END_DT is the earliest applicable LOT-ending date derived from: discontinuation of all agents (Rule 2), new qualifying medication addition (Rule 2), qualifying SCT or CAR-T events (Rule 3), death (Rule 5), health plan disenrollment (Rule 6), or end of study period (Rule 7). Rule 1 defines permissible substitutions that do NOT end the LOT. Maintenance is NOT an independent LOT-ending event in this study.

If the current LOT is immediately interrupted by a new qualifying medication, the LOT end date is the day before the first administration or dispense date of that new medication.
```

---

## Replacement 3

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `LOT1_BASE_END_REASON`
**Column:** `Values`

**Replace the entire cell contents with:**

```
Allowed values: DISCONTINUATION, MED_ADD, SCT_AUTO, SCT_ALLO, SCT_CART, CART_INIT, DEATH, DISENROLLMENT, STUDY_END.

The study does NOT use MAINTENANCE_END or SCT_NO_MAINT as final values.
```

---

## Replacement 4

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `LOT1_BASE_END_REASON`
**Column:** `Definition`

**Replace the entire cell contents with:**

```
Final LOT1 base period end reason. Derived from priority evaluation of the LOT-ending events listed in the Rules narrative on page 1.

Priority order (earliest-matching rule wins):
SCT_ALLO  >  SCT_CART  >  SCT_AUTO  >  CART_INIT  >  MED_ADD  >  DISCONTINUATION  >  DEATH  >  DISENROLLMENT  >  STUDY_END

CART_INIT applies when LOT1_BASE_1ST_ADD_MED_DT is not missing AND a CAR-T infusion (FIRST_CART_DT) occurs within 45 days of that added agent. In that case the end reason is CART_INIT (not MED_ADD). The LOT1_BASE_END_DT convention for CART_INIT is set in the LOT1_BASE_END_DT row and must be applied consistently with lot_program.R.

Patients who would previously have ended LOT1 via end of maintenance regimen now map to DISCONTINUATION unless a higher-priority event applies first.

Patients who would previously have been bucketed as SCT_NO_MAINT (planned single or tandem AUTO without a maintenance period) must be classified under the final non-maintenance LOT-ending rules above; SCT_NO_MAINT is not a final value in this study.
```

---

## Replacement 5

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `LOT1_BASE_LENGTH`
**Column:** `Definition`

**Replace the entire cell contents with:**

```
LOT1 base period duration in days. Computed as LOT1_BASE_END_DT - LOT1_START_DT + 1. The LOT start date is defined per Section 5.1.1 of the protocol ("LOT1 begins on the date of the first fill for an MM therapy following a patient's index date"). The LOT end date is the priority-based end date defined in the LOT1_BASE_END_DT row (earliest of Rules 2, 3, 5, 6, 7 — Rule 1 is permissible substitutions and does not end the LOT; former Rules 4 and 8 maintenance-based endings are removed per Apr 15 2026 meeting decision).
```

---

## Replacement 6

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `contains_mtx_reg`
**Column:** `Definition`

**Replace the entire cell contents with:**

```
contains_mtx_reg is a flag-only variable. The study does NOT derive a separate standalone maintenance period or maintenance regimen. This flag records whether LOT1 contains a valid maintenance-approved subset; it does NOT create a maintenance start date, maintenance end date, or LOT-ending event.

Set contains_mtx_reg = 1 when BOTH of the following are true for the LOT1 induction regimen:
  (a) The induction regimen contains at least one valid mono-maintenance agent OR a valid dual-maintenance combination (see lists below); AND
  (b) At least one additional non-steroid MM oncology agent outside that qualifying maintenance subset is present, acting as an anchor.

Otherwise contains_mtx_reg = 0.

Valid mono-maintenance agents: lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide.
Valid dual-maintenance combinations: bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide.

The anchor concept exists only to support this flag. It is NOT used to derive a separate maintenance period or a maintenance-based LOT end.

Background clarification (for interpreting the flag only — not an operational derivation): A maintenance regimen would conceptually be a period during which the LOT's initial regimen transitions into a state where only valid maintenance medications remain after the non-maintenance medications drop off. This study does not compute that transition.
```

---

## Replacement 7

**File:** `lot1baseapr18.pdf` (Excel: `lot1baseapr18.xlsx`)
**Tab:** `6. LOT1_BASE`
**Variable / row:** `LOT1_MED_[MED]` (the row whose Additional Notes / Definition narrative contains the LOT1 Base period definition with the phrase "maintenance begins")
**Column:** `Additional Notes` (or whichever column currently holds the phrase "all induction regimen medications discontinue, censoring, HSCT, or maintenance begins")

**Find this passage in the cell:**

```
Once the induction regimen medications are identified, the induction regimen period is defined as the time period beginning with the earliest MMA medication claim and continuing until a valid medication add is introduced (see list of permissible substitutions in LOT1_BASE_MEDS), all induction regimen medications discontinue, censoring, HSCT, or maintenance begins.
```

**Replace it with:**

```
Once the induction regimen medications are identified, the induction regimen period is defined as the time period beginning with the earliest MMA medication claim and continuing until a valid medication add is introduced (see list of permissible substitutions in LOT1_BASE_MEDS), all induction regimen medications discontinue, censoring occurs, or HSCT occurs.
```

(Difference: removed "or maintenance begins". Maintenance is no longer an LOT1-Base-ending condition in this study.)

---

## Replacement 8

**File:** `mtx scenarios.pdf` (Excel: `Mtx_scenarios.xlsx`)
**Tab:** Tab 1 (the only tab; the one that opens with "Definition of a maintenance period…")
**Cell:** Page 1, very top, cell A1 (or whichever is the topmost free cell above the existing "Definition of a maintenance period" line)

**Insert this banner above the existing content:**

```
REFERENCE ONLY — updated per Apr 15 2026 meeting.

These maintenance scenarios are retained as background examples and do NOT define an operational maintenance period for this study. The current study uses contains_mtx_reg as a descriptive flag only and does not use maintenance to create a LOT-ending event. For the active definition, see the contains_mtx_reg row in lot1baseendapr18.xlsx, tab 10. LOT1_BASE_END.
```

(Leave the rest of the existing content in the file intact — the banner just clarifies framing.)

---

# Two cells you should NOT finalise yet — wait for Julia

These two replacement texts depend on decisions Julia has not made yet. Apply the placeholder text below for now; replace once she answers.

## Pending Replacement A — Former `SCT_NO_MAINT` mapping

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `LOT1_BASE_END_REASON`
**Column:** `Additional Notes`

**Placeholder text to use until Julia answers:**

```
SCT_NO_MAINT remap: Planned single or tandem autologous SCT without maintenance does not create a separate end-reason category in this study. These cases must be classified under the final non-maintenance LOT-ending rules listed in the Definition column. Specific sub-case mapping pending Julia's confirmation.
```

**Question to send Julia:**

> "For the former SCT_NO_MAINT cohort, do you want to (a) relabel all of them as SCT_AUTO, or (b) route them by the actual earliest downstream event (DISCONTINUATION / MED_ADD / CART_INIT / SCT_AUTO / SCT_ALLO)?"

---

## Pending Replacement B — `CART_INIT` end date

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Variable / row:** `LOT1_BASE_END_DT`
**Column:** `Additional Notes`

**Placeholder text to use until Julia answers:**

```
CART_INIT end date: When LOT1_BASE_END_REASON = CART_INIT, LOT1_BASE_END_DT follows the study's chosen CAR-T transition convention and must be applied consistently across lot1baseendapr18, the protocol, and lot_program.R. Convention pending Julia's confirmation.
```

**Question to send Julia:**

> "For CART_INIT, should LOT1_BASE_END_DT = FIRST_CART_DT (matches current code at lot_program.R:1940-1942) or FIRST_CART_DT - 1 (matches the general CAR-T-as-new-LOT convention stated in the LOT1_TX_ENDDATE_REASON row)?"

---

# Summary table

| # | File | Tab | Variable / row | Column |
|---|---|---|---|---|
| 1 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | (page 1 narrative cell, no variable) | full cell |
| 2 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_DT` | Definition |
| 3 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_REASON` | Values |
| 4 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_REASON` | Definition |
| 5 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_LENGTH` | Definition |
| 6 | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `contains_mtx_reg` | Definition |
| 7 | `lot1baseapr18.xlsx` | `6. LOT1_BASE` | `LOT1_MED_[MED]` | Additional Notes |
| 8 | `Mtx_scenarios.xlsx` | (single tab) | (page 1 cell A1) | full cell — banner |
| A | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_REASON` | Additional Notes — placeholder until Julia decides |
| B | `lot1baseendapr18.xlsx` | `10. LOT1_BASE_END` | `LOT1_BASE_END_DT` | Additional Notes — placeholder until Julia decides |

Apply Replacements 1–8 now. Use placeholders A and B until Julia answers the two questions.
