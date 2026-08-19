# Where to look

There is more than one delivery in this repository and their names do not put
them in order. This file says which is which, so a reader does not have to
infer it from the folder dates.

| folder | what it is |
|---|---|
| **`Jul 28/`** | **The current delivery.** The lines-of-therapy engine, the cohort builds, the readers, the melphalan exploration and the study documentation. Everything below assumes this one unless it says otherwise. |
| `Aug 14/` | A **fork** of `Jul 28/`, not its successor, despite the name. It carries a descriptive `LOT_CONTINUING_MEDS` column that `Jul 28/` does not, and it still holds packages `Jul 28/` has since moved. Its melphalan document predates the restated ask and carries a banner saying so. |
| `apr_30_2026/` | The baseline the port suites compare `Jul 28/` against. Not a delivery to run. |
| `jun_21_2026/`, `cohort_explorer/`, `Apr 18 2026/` | Earlier work, each with its own suites. |
| `validation/` | The merge gate, the hygiene suites, the port comparisons and the synthetic harness. Not part of any delivery. |

## Running the checks

```
Rscript validation/run_gate.R                 # every suite in Jul 28 + validation
STUDY_FOLDER="Aug 14" Rscript validation/run_gate.R
```

It exits non-zero if any suite is missing, skipped, or not as expected. The port
suite's known failures are pinned by identity, so one fixed and one introduced
still fails the gate.

The synthetic harness is separate and needs `duckdb` and `sqlglot`:

```
python3 validation/synthetic/run_synthetic.py
MELP_RULE=as_asked python3 validation/synthetic/run_synthetic.py
python3 validation/synthetic/run_lot_scenarios.py   # the workbook's worked lines
python3 validation/synthetic/run_aug15_screen.py    # the MAP-splitting screen vs the engine
python3 validation/synthetic/run_melp_simple.py     # the simplified melphalan rule's planted cases
python3 validation/synthetic/run_map_foldin.py      # the MAP fold-in rule's planted cases
```

## GitHub Actions

`.github/workflows/jul28-tests.yml` exists to make the gate's result something a
machine records against a commit rather than something an author reports.

**It has never produced that record.** Every run since the workflow was added
has ended in 2 to 4 seconds with no runner assigned and no logs to download, and
`cohort_explorer-tests.yml` — which passed on 11 August — began failing the same
way on 13 August. That pattern is the job never starting, not a suite failing:
an Actions billing or spending limit, or hosted runners turned off for the
account. It needs someone with repository settings access, and until it is
fixed the only evidence the gate is green is running it locally.

## What to read first

| question | file |
|---|---|
| What rules does the LOT engine apply? | `Jul 28/lot/LOT_RULES.md` |
| What is still open for the study team? | the Open questions sheet of `Jul 28/exploration/lot/run_lot_scenarios.R`'s workbook |
| How do I run this on production? | `Jul 28/RUN_ON_PROD.md` |
| What is in each folder? | each folder's own `FILES.md` |
| The melphalan proposal and its branch table | `Jul 28/exploration/FILES.md` |
