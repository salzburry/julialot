# Patient-journey examples (Q1) — reproducible

These are the six worked patient journeys behind **Q1** in
`../julia_july5_answers.xlsx` (tabs *Q1 raw claims / Q1 MAP segments / Q1 LOT
assignment*). They trace patients from raw claims through to their final
assigned line of therapy (LOT), with dates.

## Important

The patients here are **illustrative synthetic examples** (reserved ID range
`9000000000+`), not real cohort members — this repository holds no real patient
data. They were run through the project's actual LOT engine
(`jun_21_2026/engine`), a documented, spec-faithful re-implementation of the
line-of-therapy algorithm, so the journeys are the algorithm's **real,
rule-faithful output**, not hand-drawn mock-ups. They exist to show Julia the
exact journey format and the algorithm's behaviour on each archetype. Real
patient journeys are produced by running the same MAP → LOT extraction against
the warehouse (SQL is on the *Q1 journeys — guide* tab of the workbook).

## The six archetypes

| Patient | Archetype |
|---|---|
| 9000000101 | POMA in first line (1L) |
| 9000000102 | Induction triplet + **single autologous SCT** + maintenance (still 1L) |
| 9000000103 | **Tandem autologous SCT** (two transplants ~100 days apart) |
| 9000000104 | **Allogeneic SCT** ends LOT1 → single-day LOT2 → LOT3 |
| 9000000105 | **CAR-T with consolidation therapy** (DARA within the 45-day window) |
| 9000000106 | **Deep progressor**, LOT1 → LOT5 |

## Reproduce

```
# from the repo root
python3 "Questions/July 5 2026/patient_journey_examples/generate_inputs.py"
cd jun_21_2026
Rscript engine/run_engine.R \
  "../Questions/July 5 2026/patient_journey_examples/inputs" \
  /tmp/journey_out
# /tmp/journey_out/LOT_LONG.csv and MAP_STACKED.csv match outputs/ here exactly
```

## Contents

- `generate_inputs.py` — writes the synthetic input fixtures into `inputs/`.
- `inputs/` — canonical engine inputs (members, pharmacy, medical, procedure,
  rollup, sct_codelist).
- `outputs/` — engine output: `MAP_STACKED.csv`, `LOT1_BASE.csv`,
  `LOT1_END.csv`, `LOT_LONG.csv`.
