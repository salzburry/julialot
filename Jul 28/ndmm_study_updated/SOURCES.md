# What this folder cites, and what it needs

`ndmm_study_updated/` is self-contained. Everything in it can be read, and the
package in `study223926/` can be run, without any file outside this directory.

That is not the same as saying nothing outside it exists. The documents cite
about ninety files elsewhere in the repository — that is the evidence trail, and
it is what lets a reader check a claim rather than take it. This file separates
the two, so nobody has to guess which is which.

## Needed to run

| what | where |
|---|---|
| the R package | `study223926/` |
| its settings | `study223926/config.csv` |
| its code lists | `study223926/codelists/` — the shapes ship with it; the codes do not exist yet anywhere |
| its tests | `study223926/tests/run_tests.R` — 173 checks, no warehouse. The last section runs every module against recorders using `study223926/tests/fixtures/codelists/`, which ship with it |

One optional external tool: `tests/parse_sql.py` parses the captured statements
with **sqlglot**, which is a Python package rather than a file in this folder.
Without it that one check reports `SKIP` — not a pass — and the other 172 run
unchanged.

Two things live outside the folder and always will, because they are not files:

- **the warehouse** — `INPUT_COHORT_TABLE` and the LOT tables, read through
  sparklyr from `hive_metastore.<schema>`;
- **the production code lists**, if you point `CODELIST_DIR` at
  `/mnt/code/codelist` instead of the folder's own.

Neither is a dependency on a sibling directory. Copy this folder anywhere and
the package still resolves, still runs its tests, and still refuses the same
things.

## Cited as evidence, not needed

Every reference below is a **citation**. Nothing in this folder reads any of
them, and every quotation they support is reproduced inline where it is used.

### The one warehouse run

| file | what it gave |
|---|---|
| `SQL Result.pdf` *(in this folder)* | 14 result sets, 03 Sep 2026. The DOD key match, the RACE/ETHNICITY value lists, the ICD_FLAG distribution, the YRDOB cap, and `DESCRIBE` on seven tables |

### The protocol itself

| file | what it gave |
|---|---|
| `ashley study.pdf` *(in this folder)* | the source — GSK 223926, effective 26 Aug 2026 |

### Optum documentation — `DATA_MAPPING.md`

| file | what it gave |
|---|---|
| `docs/Part 3/Optum/optum data dict.pdf` | CDM V9.0 data dictionary, all 24 pages |
| `docs/Part 3/Optum/optum business rules.pdf` | the join diagram, table inventory and 14 rules |
| `docs/optum enrolment.pdf` | `describe table t_member_enrollment_2025q4`, and the observed `BUS`/`PRODUCT`/`CDHP` distributions |
| `docs/Part 3/Program Spec/*_validated.csv` | the Jan-2026 spec's "Optum CDM Implementation" column |

Byte-identical copies also sit at `docs/optum *.pdf` and
`Apr 18 2026/Optum - Business Rules/`.

### The existing builds — `BUILD_DELTA.md`, `CODELISTS.md`, `OPEN_QUESTIONS.md`

| file | what it gave |
|---|---|
| `Jul 28/ndmm/DECISIONS.md` | the build's own record — it settles Q4 and Q17, and leaves Q21-Q24 open |
| `Jul 28/ndmm/README.md`, `RULES.md`, `config.csv`, `R/**` | what the 1L, 2L and 3L cohorts do today |
| `Jul 28/lot/LOT_RULES.md`, `lot/engine/R/**` | the line rules these numbers rest on |
| `Jul 28/STUDY_TEAM_ASKS.md` | what was asked and what was settled |
| `Jul 28/RUN_ON_PROD.md` | that the code lists are not in version control |
| `Jul 28/overall/R/build_cohort.R` | that the broad build reads the same five lists |
| `Aug 14/lot/safety/codelists/*` | the only safety and HCRU scaffolding in the repo |
| `apr_30_2026/regimen_categories.csv` | the nearest existing SOC categorisation, keyed on a regimen string |

### Earlier protocol versions — `VERSION_DIFF.md`

| file | what it gave |
|---|---|
| `Questions/July 30 2026/Updated NNDM cohort.pdf` | the June 16 2026 version, with a text layer — the diff, and the reconstruction of the corrupt page |
| `docs/june_22_2026/NNDM/SUPERSEDED_nmdmprotocol_do_not_use.pdf` | an older version, marked superseded and not used |

### Code lists — `CODELISTS.md`

| file | what it gave |
|---|---|
| `Apr 18 2026/codelist.pdf` | photographs of the deployed CSVs — `mm_dx.csv` legible in full |
| `docs/Part 1/codist.pdf` | the MM diagnosis sheet and the `40.CL MMA ROLLUP` tab |
| `docs/Part 3/Program Spec/Program_Spec_Workbook.xlsx` | four sheets headed "STATUS: TO BE BUILT" |

## The one thing that would break if the folder moved

Nothing in the code. But the citations above are repo-relative, so a reader who
moves this folder out of `julialot/` keeps every quotation and loses the ability
to open the source it came from. The quotations are inline for exactly that
reason: the argument survives the move even when the footnote does not.
