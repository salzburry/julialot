# lib/ — the plumbing, so `Jul 28` ships on its own

`Jul 28` is the folder that goes to production. Nothing in it may read
`apr_30_2026` at run time, so the shared helpers live here.

Every file in this folder is a **verbatim copy** of its `apr_30_2026/R/`
original. Not a rewrite, not a subset — byte-identical, and
`../tests/test_equivalence.R` asserts that on every run **while
`apr_30_2026` is still present**. In production it is absent, the check
skips, and these copies are simply the code.

| file | what it supplies |
|---|---|
| `load_inputs.R` | `load_pipeline_inputs()` — the `pipeline_inputs.csv` reader |
| `config_prompts.R` | `cfg_defaults` — study window, baseline, the nine `APPLY_*` toggles |
| `codelists.R` | quarterly table resolution (`t_<table>_YYYYqQ`) |
| `db_utils.R` | connect, retry, logging, `run_step`, the CSV code-list loader |
| `config_lot.R` | the LOT stack's `cfg` |
| `db_utils_lot.R` | `db_exec`, `db_q`, `wrk`, `cdm_src` for the LOT stack |
| `codelists_lot.R` | `load_codelist_csv` |

## Why verbatim, and what that costs

Copying is a second definition, and a second definition can drift. The
alternative — reading `apr_30_2026` at run time — was worse: it would mean the
production folder is not the deployable unit, and a prod run would depend on a
directory nobody intends to ship.

So the copy is kept honest two ways:

- **byte-identity is asserted**, per file, whenever `apr_30_2026` is visible. A
  one-character edit on either side is a red suite.
- **nothing here is edited**. Behaviour that this folder needs to differ on is
  layered *on top* in the caller, never patched in. `cohort_overall/ie_config.R`
  is the worked example: `config_prompts.R` hardcodes the study dates, so the
  override lives in `ie_config.R` under `IE_STUDY_*` names, and this copy stays
  identical.

If you do need to change one of these files, change it in `apr_30_2026/R/` and
re-copy, so the two never disagree silently.

## `../pipeline_inputs.csv`

Also a verbatim copy, and also drift-checked. It is the configuration the
`Jul 28` entry points read.
