# `tools/` — load the CDM sources into your own schema

```sh
Rscript "Jul 28/tools/load_tables.R" --dry-run     # see the SQL first
Rscript "Jul 28/tools/load_tables.R"               # study window, needed columns
Rscript "Jul 28/tools/load_tables.R" --years=2018:2022
Rscript "Jul 28/tools/load_tables.R" --patients=5000
```

## What it does

Copies the 8 CDM tables the pipeline reads into your work schema, keeping **only
the columns that are actually read** and **only the years you ask for** — instead
of the cumulative, all-columns, all-history quarterly tables on a read-only
schema.

`medical` goes from ~40 columns of full history to **12 columns over the study
window**.

## Naming

The CDM base names are kept, with the `t_`/quarter decoration dropped:

```
clnprw_optum.t_medical_2025q2   ->   <your schema>.medical
clnprw_optum.t_rx_2025q2        ->   <your schema>.rx
```

That is deliberate — it means the **whole pipeline** reads your copies with two
env vars and no code change, because `cdm_src()` resolves to
`<your schema>.medical`:

```sh
export OPTUM_CDM_SCHEMA=<your schema>
export USE_QUARTERLY_TABLES=FALSE
```

Set `SRC_PREFIX=src_` if you'd rather tag them (`src_medical`) for browsing —
but then nothing can be redirected at them.

## What gets kept

| Table | Cols | Date rule |
|---|---:|---|
| `medical` | 12 | `FST_DT` in window |
| `med_diagnosis` | 7 | `FST_DT` in window |
| `med_procedure` | 4 | `FST_DT` in window |
| `rx` | 4 | `FILL_DT` in window |
| `confinement` | 4 | `ADMIT_DATE` in window |
| `member_enrollment` | 3 | **overlap**, not start date |
| `member_cont_enrollment` | 4 | **none** |
| `dod` | 2 | **none** |

The date rule is **not** one blanket filter, and the exceptions matter:

- **`member_enrollment` uses overlap.** A span running 2010–2020 covers a 2016
  baseline. `ELIGEFF >= study_start` would throw it away and silently break
  every CE criterion.
- **`member_cont_enrollment` and `dod` are not filtered.** Demographics are
  picked by latest `ELIGEND`, and death can fall after `study_end`; filtering
  either would change which row wins.

The column list is derived from every `cdm_src()` call in the repo and is
**verified against the live schema before any copy runs** — a missing column
stops the load rather than producing a table that fails three stages later.

## Is a copy exact?

**A default run is an exact slice, not a sample.** The study window is what the
pipeline scans anyway and the dropped columns are never read, so counts should
match production. The script says so at the end of the run.

`--years` or `--patients` make it a sample; the script says that too, and the
manifest records which.

## Manifest

Every run writes `<your schema>.src_manifest`: source table, target, row count,
columns kept, date window, patient filter, timestamp. Without it a schema full
of copies is unattributable a week later, and "are these two tables from the
same load?" has no answer.

```sql
SELECT * FROM <your schema>.src_manifest ORDER BY table_name;
```

## Options

| | |
|---|---|
| `--years=2018:2022` | narrow to whole calendar years |
| `--patients=N` | reproducible N-patient sample (same ids every run), applied to **every** table so the copy stays referentially consistent |
| `--patients=from:<table>` | use the PATIDs already in a table |
| `--only=medical,rx` | just those tables |
| `--refresh` | rebuild tables that already exist (default: skip) |
| `--all-columns` / `--all-years` | escape hatches |
| `--dry-run` | print the SQL, touch nothing |

## Safety

- Refuses to run if the work schema is the CDM schema.
- Verifies projected columns exist before copying anything.
- Skips tables that already exist unless `--refresh`, so a re-run is cheap.
- Never writes outside the work schema.

## Files

| | |
|---|---|
| `load_tables_spec.R` | The registry and the SQL builders — pure, no DB, no packages |
| `load_tables.R` | The runner: config, connection, execution, manifest |
| `tests/test_load_tables.R` | 40 offline assertions against the generated SQL |
