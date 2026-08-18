# Analysis

What is derived from a finished LOT run: the protocol's treatment-patterns and
outcomes table, and the study team's individual asks.

Neither package builds a line. `outcomes/` writes its own `OUT_*` tables under
the study's prefix, derived from a finished run rather than a second account of
it; `questions/` writes nothing to the warehouse at all. Both resolve which run
owns the tables before reading a number off them, and refuse a run that did not
finish or that carries contract deviations.

`lot/LOT_RULES.md` is the algorithm these numbers rest on.

---

## `analysis/outcomes/` — protocol Table 4

`build.R <COHORT_TABLE> <lot_prefix_>`. Reads only; writes five `OUT_*` tables.

| path | what it does |
|---|---|
| `build.R` | Entry point for treatment patterns and treatment-related outcomes. |
| `R/build_outcomes.R` | Computes those outcomes off one finished run. Builds no line and no cohort of its own. |
| `R/run_outcomes.R` | Resolves which run owns the tables, refuses anything it cannot vouch for, then writes the five output tables. |
| `R/config_out.R` | Settings, all about which run to read. Nothing here defines a clinical rule. |
| `R/db_utils_out.R`, `R/load_inputs.R` | Connection, logging and settings helpers for that package. |
| `config.csv` | Three settings: the run to read, the cohort prefix, and `STUDY_END`, which is checked against the LOT run rather than trusted. |
| `followup_outcomes.sql` | Paste-and-run: reads observed follow-up, event counts and the attrition split back off a finished run, and checks the five categories sum to `N_ON_LINE`. |
| `tests/test_runner.R` | The SQL as a string, and the censoring arithmetic evaluated in R over hand-made cases. |

| table | one row per |
|---|---|
| `<prefix>OUT_TTE` | patient per line — TTNT, TTD and OS as a date and a 0/1 each |
| `<prefix>OUT_ATTRITION` | denominator and line — the attrition categories, which partition it |
| `<prefix>OUT_LINE_GAP` | denominator and line pair — months from one line's start to the next |
| `<prefix>OUT_REGIMEN` | denominator, line and regimen — N and % receiving each |
| `<prefix>OUT_DX_TO_LOT1` | one row — months from MM diagnosis to the 1L index. The only optional output. |

It refuses a run it cannot identify and a lineage it cannot prove — the newest
`LOT_BUILD_STATUS` row has to be `complete`, built from the cohort named on the
command line, carry no `CONTRACT_DEVIATIONS`, and name the same `STUDY_END` this
package is set to. `OUT_ALLOW_UNPROVEN_LINEAGE=TRUE` accepts what could not be
checked; a lineage shown to be wrong still stops.

Both readings of "of the patients who reached 2L" are reported side by side —
`ALL_LINES` and `LINE_ELIGIBLE` — because nothing in the protocol picks one.
Regimens are raw, not the Annex 2 SOC categories.

## `analysis/questions/` — the study team's asks

One script per ask, each writing its own CSVs or workbook. All read a finished
run and write nothing to the warehouse. `OBJECT_PREFIX` and `INPUT_COHORT_TABLE`
are required, and each script checks the cohort it was given against what the LOT
build recorded.

| path | what it does |
|---|---|
| `_setup.R` | Shared setup, using the engine's own modules rather than a second copy so the two cannot drift. Loads `config.csv` first, then pins a config the way the build does. |
| `lot1_studyteam_qs.R` | The standalone LOT1 asks. |
| `poma_studyteam_qs.R` | The POMA-in-1L asks — one workbook, one tab per question. |
| `jul20_studyteam_qs.R` | The July-20 set, including `q3_cart_screen()`, which counts the patients the CAR-T induction rule touches. Its **Q3a melphalan screen is superseded** and off unless `JUL20_Q3A_MELP=TRUE`: it screened an earlier one-sentence rule off persisted tables, and the restated five-branch ask is built as three complete runs in `exploration/melphalan/`. |
| `lot_followup_qs.R` | The follow-ups on steroids, regimen mix and CAR-T. |
| `broad_studyteam_qs.R` | The two asks NDMM cannot answer, over the broad cohort — the other-cancer association, and the diagnosis-anchored trial flags. |
| `validation_qs.R` | The "MM LOT validation next steps" asks. |
| `validation_helpers.R` | The analysis behind those questions, shared with the dashboard's exploratory tables. |
| `tests/test_setup.R` | Executes the setup and holds the population, the table names and the bone-metastasis list to what the build does. |

`LOT_POPULATION=PRECRITERIA` is the one axis: the same run before the line
criteria, worth asking for when the question is what a criterion cost. It is not
a cohort, and a denominator taken from it counts patients the study removed.
