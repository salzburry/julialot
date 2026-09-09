# ndmm_study_updated - the files

The updated NDMM protocol, read; what it asks for, mapped to Optum; and the
package that builds it from a finished LOT run. Self-contained — `SOURCES.md`
says what is cited and what is needed.

| path | what it is |
|---|---|
| `README.md` | Start here. What the protocol is, how it was read, what is missing from it. |
| `IE_CRITERIA.md` | Every inclusion and exclusion criterion, per cohort, quoted and operationalised, with the order they apply and the attrition funnel. |
| `VARIABLES.md` | Every variable the protocol asks to be derived, by objective, with definition, functional form and collection timing. |
| `DATA_MAPPING.md` | The Optum CDM reference — tables, columns, joins, and the caveats that change what a number means — and the criterion- and variable-level mapping. |
| `CODELISTS.md` | Which code lists the existing builds read, in what shape, and every list the protocol needs that does not exist yet. |
| `BUILD_DELTA.md` | The difference between what `Jul 28/ndmm` and `Sep 10/lot` do today and what the protocol asks for. |
| `VERSION_DIFF.md` | What changed since the June 2026 protocol, why three of the build's settings are a version behind rather than wrong, and a reconstruction of the rows the source does not carry. |
| `OPEN_QUESTIONS.md` | Twenty-seven things genuinely undecided, each with both readings and what turns on the answer. Two are answered, one partly. |
| `SOURCES.md` | What this folder cites and what it needs. The standalone boundary. |
| `RUN_ONCE_2.sql` | **Round two** — no placeholders, runs as-is. Targets the twelve questions a query can still reach. |
| `RUN_ONCE.sql` | **Everything worth asking the warehouse, in one sitting** — ordered so a late failure costs least. Two find-and-replaces, then run. |
| `PROFILE_QUERIES.sql` | The same material as separate blocks, for when there is no one-run constraint. |
| `ie_criteria.csv` | The criteria as a table, for the study team. |
| `variables.csv` | The variables as a table — 58 rows. |
| `optum_cdm_fields.csv` | The CDM field inventory as a table — 64 rows. |
| **`study223926/`** | The R package. `study223926/MODULES.md` is its own page. |
| **`dashboard/`** | The Shiny scenario explorer over what a run wrote. `dashboard/README.md` is its own page. |
| `study223926/codelists/` | The eleven code-list shapes, shipped blank. `study223926/codelists/README.md` says which annex owes each. |
| `study223926/tests/` | `run_tests.R`, the `emit_sql.R` harness that runs every module without a warehouse, `parse_sql.py`, and filled fixtures for the harness. |

## The package, in one paragraph

`study223926/` runs **after** the LOT engine: it reads `LOT_LONG_FINAL` and the
NDMM cohort table through sparklyr and writes its own `S_*` tables, so it builds
no line and no MM cohort of its own and can be re-run against a finished LOT run
as often as needed. Twelve modules and four cohorts, all selectable; every
reading `OPEN_QUESTIONS.md` records as open is a setting, defaulting to the
protocol's answer, and every run records which reading it used. Six of the twelve
modules run today — the rest are blocked on Annexes 2 and 3, and the preflight
loads every code list the selection needs before it opens a connection, so an
unfilled one stops the run in its first second naming the annex that owes it.

```
DRY_RUN=TRUE Rscript study223926/build.R      # print the plan, touch nothing
Rscript study223926/tests/run_tests.R         # 173 checks, no warehouse
```
