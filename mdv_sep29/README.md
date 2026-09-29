# mdv_sep29: the NDMM cohort and lines of therapy on MDV

The Sep 16 study code for the NDMM cohort (`../Sep 16/ndmm/`) and the lines-of-therapy
engine (`../Sep 16/lot/engine/`), ported from Optum Clinformatics to **MDV** (Medical
Data Vision): `clnprw_mdv_all_use`, the 2026q2 extract, on the same Databricks
warehouse.

**Sep 16 is the only source.** The NDMM cohort definition is Sep 16's
(`../Sep 16/ndmm/`) and the LOT rules are Sep 16's (`../Sep 16/lot/`). Nothing
is taken from the earlier deliveries (Jul 28, Aug 14, Sep 10 and before). This
folder sits beside Sep 16, not inside it, and Sep 16 is not changed.

**`MDV_RULES.md` is the document to read.** It sets each Optum rule beside its
MDV form, gives where each MDV choice came from, and lists what is still open.

## What is here

| folder / file | what it is |
|---|---|
| `MDV_RULES.md` | the rules, Optum and MDV side by side; open decisions; what was tested |
| `ndmm/` | the 1L NDMM cohort on MDV. Writes `<prefix>NDMM_COHORT`, the table the LOT engine reads. `ndmm/README.md` |
| `lot/engine/` | the LOT engine on MDV: the Sep 16 line rules, with the MDV extraction. `lot/README.md` |
| `codelists/` | the MDV code lists' shapes (headers only) and how to author them. The lists themselves live on production, like the Optum ones |
| `reference/` | the colleague's MDV ovarian cancer business rules, transcribed; the search of this account's other repositories for MDV documentation |
| `tests/` | the DuckDB stand-in warehouse (`duck_bridge.py`), the synthetic MDV patients (`fixture_mdv.R`) the suites run against, and `run_all.R`, which runs every suite |

Rules, not code, are the port's substance. The machinery around them is the
Sep 16 build's and is kept as it was: the contract, the checks made before
anything is written, the attrition, the status and metadata tables, the run
log. Someone who knows the Optum build can read this one.

## Before the first run

1. **Confirm five column names** against the MDV data dictionary. The OC rules
   do not name them, and no other repository this account can reach does:
   the birth year (`MDV_COL_BIRTH`), the FF1 discharge outcome
   (`MDV_COL_FF1_OUTCOME`), an ICD-10 column on `diseasedata`
   (`MDV_COL_ICD10`), and the care setting and days supplied on `actdata`
   (`MDV_COL_ACT_NYUGAIKBN`, `MDV_COL_ACT_DAYS`). Set them in both
   `ndmm/config.csv` and `lot/engine/config.csv`. A wrong name stops the run at
   its first check, naming the table and the column.
2. **Author the MDV code lists** (`codelists/README.md`) and put them in a
   folder of their own on production. The default is `/mnt/code/codelist_mdv`.
   The Optum lists will not load: every HCPCS, NDC and ICD-9 row is refused
   by type.
3. **Read the open decisions** (`MDV_RULES.md`, section 5). Each has a default,
   and the first run writes the tables that price them.

## Running it

The same two stages as Sep 16, with one difference: the cohort and the lines
now run over MDV.

```bash
SCHEMA=$DOMINO_USER_NAME
CL=/mnt/code/codelist_mdv

# 1. the cohort. Writes mdv_NDMM_COHORT and mdv_NDMM_ATTRITION.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript ndmm/build.R mdv_

# 2. lines of therapy over it.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript lot/engine/build.R mdv_NDMM_COHORT mdv_
```

Give MDV runs a prefix of their own (`mdv_`) so they never sit on an Optum
prefix. The settings, the run log, the "one run per prefix" rule and the
override switches all work as in Sep 16 (`../Sep 16/README.md`).

**Sensitivity builds.** PORTING.md asks for two or three day-supply values
before one is chosen. Run each under its own prefix, recorded as a deviation:

```bash
MEDICAL_DAY_SUPPLY=21 LOT_CONTRACT_OVERRIDE=TRUE ... Rscript lot/engine/build.R mdv_NDMM_COHORT mdvds21_
```

## Checking it without a warehouse

```bash
Rscript tests/run_all.R                               # all five, one exit status
```

or one at a time:

```bash
(cd ndmm       && Rscript tests/test_runner.R)       # the runner, the checks, the SQL shapes
(cd ndmm       && Rscript tests/test_mdv_build.R)    # the whole cohort build on synthetic MDV
(cd lot/engine && Rscript tests/test_runner.R)
(cd lot/engine && Rscript tests/test_line_criteria.R)
(cd lot/engine && Rscript tests/test_mdv_extract.R)  # cohort, then LOT's MDV extraction
```

They need base R with `glue`. The two MDV suites also need `python3` with
`duckdb` and `sqlglot`, and each stops with a counted skip if those are
missing. All five pass: 407, 57, 532, 59, 23. `MDV_RULES.md`, "What was
tested", says what they cover and what they do not.

The repository's merge gate (`../validation/run_gate.R`) gates Sep 16. This
folder is not part of that delivery, so `tests/run_all.R` is what checks it.

## Not ported

- **The 2L and 3L cohorts** (`../Sep 16/ndmm/build_subsequent_cohorts.R`).
- **The study package, table shells and dashboard** (`../Sep 16/variables/`,
  `../Sep 16/TFLS/`, `../Sep 16/dashboard/`). They read `S_*` tables built from the cohort
  and the lines, and are written against Optum's variables: HCRU, comorbidity
  and secondary malignancy by Optum codes.
- **The LOT QC, melphalan and vignette packages** beside `../Sep 16/lot/engine/`.
  They read LOT outputs and would run over this engine's tables. They are left
  in Sep 16 until the MDV lines exist.
