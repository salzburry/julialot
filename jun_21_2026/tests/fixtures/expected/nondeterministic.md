# Nondeterministic fields (excluded from the strict comparison)

Only **display-only** nondeterminism is excluded. Every field that influences
downstream MAP/LOT state must be deterministic.

| table | field | reason | plan |
|---|---|---|---|
| LOT1_BASE | lot1_base_1st_add_med | seeded random tie-break picks WHICH med among same-date first-add candidates (02_lot1.R:806, `ORDER BY MAP_START_DT, rand(42)`) | record seed + Databricks runtime versions; later, separately validated deterministic tie-break fix |
| LOT_LONG | lot_base_1st_add_med | inherits the LOT1 tie-break for LOT1 | same |

The excluded field is the **med identity**, not the date. The date is
`date_sub(MAP_START_DT, 1)`, which is identical across a same-date tie, so
`*_1st_add_med_dt` is **deterministic and strictly compared**; only the med the
seed happens to pick (`*_1st_add_med`) is excluded.

**This exclusion is PROVISIONAL — pending algorithmic sign-off.** It is only
justified if the seeded med pick is confirmed NOT to influence any downstream LOT
end/trigger/flag field (or the tie-break is replaced by a deterministic fix). That
confirmation is partly mechanical: every downstream field is NON-excluded, so the
strict comparison there is exactly what would catch a propagation (fail-closed).
The comparator also **surfaces** any difference in the excluded field
(`compare_run_outputs.R` reports `excluded_diffs`, printed as
`excluded_diffs=N (informational)`); a difference is never silently dropped, only
held back from the blocking verdict. If the field is later found to affect
downstream state, it moves back into the strict set.

Reporting-only token displays (`min_by`/`max_by` over date alone on a same-date
tie) are display-only and, where shown, compared as an unordered set — they are
not in the three output tables above.

**Everything else is compared strictly** (after canonical normalization, §14 of
the roadmap). If a refactor changes any non-excluded field, it is a regression.
