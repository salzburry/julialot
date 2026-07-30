# lib/ — the shared plumbing

`Jul 28` is the folder that goes to production, so nothing in it reads
`apr_30_2026` at run time. The shared helpers live here instead.

Each file is a **verbatim copy** of its `apr_30_2026/R/` original — byte-identical,
asserted by `../tests/test_equivalence.R` §6 while that folder is still present.
In production it is absent, the check skips, and these copies are just the code.

| file | supplies |
|---|---|
| `load_inputs.R` | `load_pipeline_inputs()`, the `pipeline_inputs.csv` reader |
| `config_prompts.R` | `cfg_defaults` — study window, baseline, the nine `APPLY_*` |
| `codelists.R` | quarterly table names (`t_<table>_YYYYqQ`) |
| `db_utils.R` | connect, retry, logging, `run_step`, the CSV code-list loader |
| `config_lot.R` | the LOT stack's `cfg` |
| `db_utils_lot.R` | `db_exec`, `db_q`, `wrk`, `cdm_src` |
| `codelists_lot.R` | `load_codelist_csv` |

## The rule

**Do not edit these files.** If behaviour has to differ, layer it on top in the
caller. `cohort_overall/ie_config.R` is the example: `config_prompts.R` hardcodes
the study dates, so the override lives there under `IE_STUDY_*` names and this copy
stays identical.

If one of these genuinely needs changing, change it in `apr_30_2026/R/` and
re-copy, so the two never disagree quietly.

`../pipeline_inputs.csv` is also a verbatim copy, also drift-checked. It is the
config the `Jul 28` entry points read.
