# Nondeterministic fields (excluded from the strict comparison)

Only **display-only** nondeterminism is excluded. Every field that influences
downstream MAP/LOT state must be deterministic.

| table | field | reason | plan |
|---|---|---|---|
| LOT1_BASE | lot1_base_1st_add_med_dt | seeded random tie-break on same-day first-add-med (seed=42 today) | record seed + Spark/runtime versions; later, separately validated deterministic tie-break fix |
| LOT_LONG | lot_base_1st_add_med_dt | inherits the LOT1 tie-break for LOT1 | same |

**This exclusion is PROVISIONAL — pending algorithmic sign-off.** Excluding
`*_1st_add_med_dt` from the strict verdict is only justified if the seeded
tie-break is confirmed NOT to influence any downstream LOT end/trigger/flag field
(or the tie-break is replaced by a deterministic fix). Until that sign-off, the
comparator still **surfaces** any difference in these fields
(`compare_run_outputs.R` reports `excluded_diffs`, printed as
`excluded_diffs=N (informational)`); a difference is never silently dropped, only
held back from the blocking verdict. If the field is later found to affect
downstream state, it moves back into the strict set.

Reporting-only token displays (`min_by`/`max_by` over date alone on a same-date
tie) are display-only and, where shown, compared as an unordered set — they are
not in the three output tables above.

**Everything else is compared strictly** (after canonical normalization, §14 of
the roadmap). If a refactor changes any non-excluded field, it is a regression.
