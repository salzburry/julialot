# Apr 19 Spec — Remaining Changes

**Target file:** `Apr 18 2026/Program Spec and Scenarios/lot1baseendupdatedapr19.xlsx` (the source behind `lot1baseendupdatedapr19.pdf`)
**Tab:** `10. LOT1_BASE_END`

Three changes remain before the old `lot1baseendapr18.pdf` can be deleted.

---

## Change 1 — `LOT1_BASE_1ST_ADD_MED_DT` row, Definition column

**Row:** `LOT1_BASE_1ST_ADD_MED_DT` / `LOT1_BASE_1ST_ADD_MED`
**Column:** `Definition`
**Issue:** References "Per Rule 1" for permissible substitutions, but substitutions are no longer numbered — they're a Note in the new scheme.

**Find:**
```
Per Rule 1: permissible substitutions (biologic reference product with biosimilars) 'do not advance the LOT.'
```

**Replace with:**
```
Per the permissible-substitutions Note in the LOT1_END_REASON_TEMP rules: 'Substitution of a biologic reference product with any of its biosimilars … does not advance the LOT.'
```

---

## Change 2 — `FIRST_ALLO_DT` row, Definition column

**Row:** `FIRST_ALLO_DT`
**Column:** `Definition`
**Issue:** Still quotes "Rule 3" for ALLO, but ALLO now lives under Rule 2 (SCT / CAR-T events).

**Find:**
```
'Allogeneic SCT: Presence of an allogeneic SCT immediately ends a LOT and starts a new LOT.' Rule 3: 'Any allogeneic SCTs are considered a new LOT and the current LOT will end the day before an allogeneic SCT occurs.'
```

**Replace with:**
```
'Allogeneic SCT: Presence of an allogeneic SCT immediately ends a LOT and starts a new LOT.' Rule 2 (SCT / CAR-T events): 'Any allogeneic SCTs are considered a new LOT and the current LOT will end the day before an allogeneic SCT occurs.'
```

---

## Change 3 — `ALLO_ALWAYS_ENDS_LOT` row, Definition column

**Row:** `ALLO_ALWAYS_ENDS_LOT`
**Column:** `Definition`
**Issue:** Same "Rule 3" reference as Change 2, different row.

**Find:**
```
'An autologous SCT followed by an allogeneic SCT will not be considered planned because an allogeneic SCT typically follows failed autologous SCTs.' Rule 3: 'Any allogeneic SCTs are considered a new LOT and the current LOT will end the day before an allogeneic SCT occurs.'
```

**Replace with:**
```
'An autologous SCT followed by an allogeneic SCT will not be considered planned because an allogeneic SCT typically follows failed autologous SCTs.' Rule 2 (SCT / CAR-T events): 'Any allogeneic SCTs are considered a new LOT and the current LOT will end the day before an allogeneic SCT occurs.'
```

---

## Change 4 — `LOT1_BASE_END_REASON` row, Values column

**Row:** `LOT1_BASE_END_REASON`
**Column:** `Values` (this cell is currently empty)
**Issue:** No enumerated list of allowed string values.

**Paste this into the cell:**
```
Allowed values: DISCONTINUATION, MED_ADD, SCT_AUTO, SCT_ALLO, SCT_CART, CART_INIT, DEATH, DISENROLLMENT, STUDY_END.

The study does NOT use MAINTENANCE_END or SCT_NO_MAINT as final values.
```

---

## Change 5 — `contains_mtx_reg` row, Definition column

**Row:** `contains_mtx_reg`
**Column:** `Definition`
**Issue:** The cell has the new flag-only framing at the top, then jumps into the old operational paragraph (`"Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued leaving only maintenance medications for xx days. It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen to anchor the start of that mtx regimen."`) without any label saying the old paragraph is background, not algorithm.

**Find** (immediately before the "Definition of a maintenance period:" paragraph):
```
Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued leaving only maintenance medications for xx days.
```

**Replace with:**
```
Background clarification (for interpreting the flag only — not an operational derivation):

Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued leaving only maintenance medications for xx days.
```

(Only the single-line label is added — the existing paragraph stays verbatim after it.)

---

## Summary

| # | Row | Column | Action |
|---|---|---|---|
| 1 | `LOT1_BASE_1ST_ADD_MED_DT` | Definition | Replace "Per Rule 1" → "Per the permissible-substitutions Note in the LOT1_END_REASON_TEMP rules" |
| 2 | `FIRST_ALLO_DT` | Definition | Replace "Rule 3" → "Rule 2 (SCT / CAR-T events)" |
| 3 | `ALLO_ALWAYS_ENDS_LOT` | Definition | Replace "Rule 3" → "Rule 2 (SCT / CAR-T events)" |
| 4 | `LOT1_BASE_END_REASON` | Values | Paste the allowed-values enumeration (currently empty) |
| 5 | `contains_mtx_reg` | Definition | Prepend "Background clarification (for interpreting the flag only — not an operational derivation):" before the existing "Definition of a maintenance period…" paragraph |

After these 5 changes, the old `lot1baseendapr18.pdf` is safe to delete.

---

## Out of scope for this file (but don't forget)

- **Protocol Section 5.1.1** — if it uses rule numbers, align to 1 = Discontinuation, 2 = SCT / CAR-T, 3 = Death, 4 = Disenrollment, 5 = Study end.
- **`lot_program.R`** — existing `# Rule 3`, `# Rule 4` comments are stale. Most are deleted when `SCT_NO_MAINT` logic is removed per the code review; any surviving references should use the new numbers.
- **`lot1baseapr18.xlsx`** — Cell 7 from the spec instructions: remove "or maintenance begins" from the LOT1 Base period narrative.
- **`Mtx_scenarios.xlsx`** — Cell 8: add REFERENCE ONLY banner on page 1.
