# Code lists

The shapes every module reads, shipped so this folder is complete on its own.
**The codes are blank.** They come from the protocol's Annex 2 and Annex 3,
which were not delivered — `../../CODELISTS.md` says which annex owes each file.

A blank code column is not a gap the run papers over. `load_codelist()` refuses
a file with an unfilled row and names the concepts, because a rate of zero for
want of a code list is indistinguishable downstream from a rate of zero for want
of events. So these files are a to-do list the code checks rather than a set of
defaults anything could quietly run on.

The preflight **loads** each file the selected modules need rather than checking
that its path exists, so a run pointed at this directory stops in its first
second naming what is unfilled — not after the expensive steps, and not at the
module. A path check passes on every one of these templates.

`CODELIST_DIR` defaults to this directory. On production, point it at the real
one instead:

```
CODELIST_DIR=/mnt/code/codelist Rscript build.R
```

## What is already filled in, and what is not

| file | concepts | codes | where the codes come from |
|---|---|---|---|
| `safety_events.csv` | **all 23 Table 3 rows**, with the protocol's own acute/chronic typing | — | Annex 3 |
| `secondary_malig.csv` | **Table 2's ten categories** and its example subtypes | — | Annex 3 |
| `soc_regimen_categories.csv` | **§7.2.2's categories**, both line scopes | — | Annex 2 |
| `charlson_quan2011.csv` | **Quan's seventeen conditions, weights and hierarchy** | — | Quan et al. 2011 — no annex supplies it |
| `hcru.csv` | the three ED constructions the CDM allows | — | undecided — `../../OPEN_QUESTIONS.md` Q11 |
| `comorbid_subgroups.csv` | neuropathy, lung parenchymal disease | — | Annex 3 |
| `frailty_kim2018.csv` | — | — | Annex 7, if frailty is kept at all |
| `mm_dx.csv`, `cl_mma_codelist.csv`, `cl_mma_rollup.csv`, `cl_sct_codelist.csv` | — | — | **already on production** — these are headers so a run pointed here fails loudly rather than reading an empty definition of myeloma |

`charlson_quan2011.csv` is the one file whose non-code content is complete: the
weights are Quan's published ones — including **0 for myocardial infarction**,
which is the 2011 revision's weight and not the original Charlson 1 — and the
`supersedes` column carries his hierarchy, so severe liver disease overrides
mild and metastatic solid tumour overrides any malignancy. Without that column a
patient with both scores 6 where Quan gives 4.

Note that Quan carries myeloma under `any_malignancy` and has no myeloma row of
its own, which is why the comorbidity module makes Table 4's MM adjustment on
the **codes** (`mm_dx.csv`) rather than on a condition name — see
`../MODULES.md`.

## Not these: `../tests/fixtures/codelists/`

The test harness ships its own filled miniatures of all eleven files, so it can
run the modules that need one. Those are dummy codes chosen to exercise the
loader and the SQL. They are not codes to run a study on, and nothing outside
`tests/` reads them.

## Two rows that will stop the run before the codes do

`safety_events.csv` carries `toxic_liver_disease` and `hepatic_failure` typed
**"Acute or chronic"** and **"Acute/Chronic"** — the protocol's own wording.
Those name two different counting rules at once, and §7.8.1's chronic list does
not resolve either, so `canonical_acute_chronic()` stops and asks.

That is deliberate. Counted as acute, every recurrence is an event and no patient
ever leaves the denominator; counted as chronic, only the first occurrence
counts and a prior history removes the patient from both. The two give
materially different rates for two of the twenty-three conditions, and the
protocol does not choose. Type them explicitly before the safety module can run.
