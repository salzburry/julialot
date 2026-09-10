# What this folder cites, and what it needs

`ndmm_study_updated/` is self-contained. Everything in it can be read, and the
package in `study223926/` can be run, without any file outside this directory.

The documents do cite files elsewhere in the repository. That is the evidence
trail, not a dependency. This file separates the two.

## Needed to run

| what | where |
|---|---|
| the R package | `study223926/` |
| its settings | `study223926/config.csv` |
| its code lists | `study223926/codelists/` — the shapes ship with it; the codes do not exist yet anywhere |
| its tests | `study223926/tests/run_tests.R` — 361 checks, no warehouse. The last section runs every module against recorders using `study223926/tests/fixtures/codelists/` |

Two optional external tools, both Python packages rather than files in this
folder: **sqlglot**, which `tests/parse_sql.py` uses to parse the captured
statements and `tests/run_duckdb.py` uses to transpile them, and **duckdb**,
which executes them against the fixtures. Without them those checks report
`SKIP` — not a pass — and the rest run unchanged.

Two things live outside the folder and always will, because they are not files:

- **the warehouse** — `INPUT_COHORT_TABLE` and the LOT tables, read through
  sparklyr from `hive_metastore.<schema>`;
- **the production code lists**, if you point `CODELIST_DIR` at
  `/mnt/code/codelist` instead of the folder's own.

Copy this folder anywhere and the package still resolves, still runs its tests,
and still refuses the same things.

## Cited as evidence, not needed

Nothing in this folder reads any of the sources below, and every quotation they
support is reproduced inline where it is used.

### The protocol

GSK 223926, `Belantamab_Optum LoT_Unmet_Need_Aug 26 2026 (final).docx`, effective
26 Aug 2026. The June 2026 version is cited in `VERSION_DIFF.md`; an older one is
marked superseded and not used.

### The warehouse runs

Three runs against the CDM: 03 Sep 2026 (`RUN_ONCE.sql`, 14 result sets),
07 Sep 2026 (`RUN_ONCE_2.sql`, 23) and 08 Sep 2026 (`RUN_ONCE_3.sql`, 14).
`OPEN_QUESTIONS.md` records what each one closed or priced.

### Optum documentation — `DATA_MAPPING.md`

| source | what it gave |
|---|---|
| the Optum CDM V9.0 data dictionary | `2025_05_CDM Data Dictionary V9 SES.xls`, 24 pages, SES view |
| the Optum business rules document | `Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx` — the join diagram, table inventory and 14 rules |
| the Optum enrolment documentation | `describe table t_member_enrollment_2025q4`, and the observed `BUS`/`PRODUCT`/`CDHP` distributions |
| `docs/Part 3/Program Spec/*_validated.csv` | the Jan-2026 spec's "Optum CDM Implementation" column |

### The existing builds — `BUILD_DELTA.md`, `CODELISTS.md`, `OPEN_QUESTIONS.md`

| file | what it gave |
|---|---|
| `Jul 28/ndmm/DECISIONS.md` | the build's own record — it settles Q4 and Q17, and leaves Q21-Q24 open |
| `Jul 28/ndmm/README.md`, `RULES.md`, `config.csv`, `R/**` | what the 1L, 2L and 3L cohorts do today |
| `Sep 10/lot/LOT_RULES.md`, `lot/engine/R/**` | the line rules these numbers rest on |
| `Jul 28/STUDY_TEAM_ASKS.md` | what was asked and what was settled |
| `Jul 28/RUN_ON_PROD.md` | that the code lists are not in version control |
| `Jul 28/overall/R/build_cohort.R` | that the broad build reads the same five lists |
| `Aug 14/lot/safety/codelists/*` | the only safety and HCRU scaffolding in the repo |
| `apr_30_2026/regimen_categories.csv` | the nearest existing SOC categorisation, keyed on a regimen string |

### Code lists — `CODELISTS.md`

| source | what it gave |
|---|---|
| the Apr 2026 code list record | the deployed CSVs of the Domino project `219870_mm_optumlot` — `mm_dx.csv` in full |
| the Part 1 code list workbook | the MM diagnosis sheet and the `40.CL MMA ROLLUP` tab |
| `docs/Part 3/Program Spec/Program_Spec_Workbook.xlsx` | four sheets headed "STATUS: TO BE BUILT" |

## The one thing that would break if the folder moved

Nothing in the code. The citations above are repo-relative, so moving this folder
out of `julialot/` keeps every quotation and loses the ability to open the source
it came from. The quotations are inline for that reason.
