# Reporting

What a finished study run is rendered into. Nothing here builds a line or a
cohort; everything reads a run that `lot/engine/` has already finished and
`lot/qc/` has already signed off.

Reading only, so it can be re-run against a finished study as often as anyone
wants. `lot/LOT_RULES.md` is the algorithm behind the numbers on the page.

---

## `reporting/dashboard/` — one HTML off a finished run

`build.R <COHORT_TABLE> <lot_prefix_> [<cohort_prefix_>]`. Reading only: it
creates, replaces and drops nothing, so it can be re-run against a finished study
as often as anyone wants.

| path | what it does |
|---|---|
| `build.R` | Entry point. Renders one cohort's dashboard after the cohort and line builds. |
| `config.csv` | Settings: which tables to read, the attrition table's name and window, and one `SHOW_*` switch per panel. A switch that is neither `TRUE` nor `FALSE` stops the build. |
| `R/build_dashboard.R` | The runner. Resolves which LOT run owns the tables from `LOT_BUILD_STATUS`, refuses one that did not finish or that carries contract deviations, then draws. |
| `R/sections.R` | What the dashboard shows. Every panel is one entry — a name, a tab, its query, what it needs and how to draw the answer. Also the attrition layouts, the transition Sankeys and the patient-journey scenarios. |
| `R/render.R` | Writes one self-contained HTML file using base R only, so a missing plotting package cannot silently produce nothing. Holds `PALETTE`, the whole colour scheme. |
| `R/db_utils_dash.R` | Reading only. This package creates, replaces and drops nothing, which is what makes it safe to re-run against a finished study. |
| `R/config_dash.R`, `R/load_inputs.R` | Settings, and the `config.csv` reader. |
| `tests/test_runner.R` | The registry, the guards, the placeholder filling, that the package cannot write, and that the HTML escapes values and needs no network. |

Two things worth knowing before reading a number off it. Every clinical panel
is drawn on `LOT_LONG_FINAL`; only the Validation tab reads `LOT_LONG`, where
the before/after comparison is the point. And `followup_end_reason` is one row
per **patient** over the whole study population, while `outcomes`'
`N_LOST_TO_FU` and `N_ONGOING` are one row per patient-**line** and only over
what is left after the next line, death and discontinuation have been taken
out. The two do not reconcile, and `outcomes_followup` is the panel to read
beside `OUT_ATTRITION`.
