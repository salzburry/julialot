# Moving the LOT engine to another database

The short answer: **the line-assembly half moves as it stands; the extraction
half does not.** They are separated by five tables, and that seam is the whole
of the porting question.

Two axes, and they are independent. Moving to another **data source** — MDV,
JMDC, Flatiron, a national registry — is the subject of this file. Moving to
another **tumour** is a different change: the rules in `LOT_RULES.md` are
myeloma's, and changing them is a contract decision, not a data one. A source
port keeps the rules and rebuilds the inputs. A tumour port keeps the inputs
and rebuilds the rules. Doing both at once is two projects.

## The seam

`R/steps/01_codelists.R` through `03_mma_map.R` read Optum and produce five
tables. Everything from `04_lot1_base.R` on reads only those five and never
touches a source table again. Produce them for another database and the rest of
the engine runs unchanged — that is not a claim about the design, it is what
`lot/qc/extract_patients.R` does
today: it writes exactly these five out for named patients, so their real rows
can be put back through the same statements with no warehouse at all.

### 1. `LOT_PATIENT_INPUT` — one row per patient

| Column | Type | What it must mean |
|---|---|---|
| `PATID` | string | the patient key, stable across the other four |
| `INDEX_DATE` | date | the cohort's index. Nothing before it is read |
| `ENDDATE` | date | end of observation: min(death, study end) |
| `ENDDATE_CE` | date | the same, re-capped at loss of coverage |
| `OBS_END_DT` | date | whichever of the two the run uses |
| `DEATH_DT` | date | null where not observed |
| `GDR_CD`, `YRDOB`, `AGE_INDEX_YR` | string, int, int | carried through; no rule reads them |

### 2. `MAP_STACKED` — one row per drug episode

This is the substrate. An **episode** is a stretch of continuous coverage of one
drug for one patient.

| Column | Type | What it must mean |
|---|---|---|
| `PATID` | string | |
| `MAP_MED_TYPE` | string | the drug's abbreviation — the engine's identity for it |
| `MAP_MED_CLASS` | string | its class. Only `STEROID` is read, as "supportive, not line-defining" |
| `MAP_CNT` | int | claims merged into the episode; reported, not read |
| `MAP_START_DT` | date | first day of cover |
| `MAP_END_DT` | date | last day of cover |
| `MAP_DISCON_FLG` | int | 1 where the gap to the next episode of this drug is at least `MAP_DISCON_GAP_DAYS` |

### 3. `TX_AUTO_DATES` — autologous transplants

`PATID`, `TX_SEQ` (int, ordered within patient), `TX_DT` (date). One row per
**event**, already clustered — the engine does not cluster claims here.

### 4. `TX_ALLO_CART_DATES` — allogeneic transplants and CAR-T

`PATID`, `SCT_TYPE` (`'ALLO'` or `'CART'`), `TX_SEQ`, `TX_DT`.

### 5. `PERMISSIBLE_SUBS` — equivalence

`original_med`, `substitute_med`. One row per pair, in one direction; the engine
expands it both ways. This is §4.4's whole input: a biosimilar and its reference
product are one agent.

## What is Optum's and has to be rebuilt

Everything that makes those five tables:

- **Drug identification.** Four claim arms against HCPCS and NDC-11, with NDC
  normalisation and the leading-zero rules. Another database has another drug
  vocabulary, and `cl_mma_codelist.csv` is written in Optum's.
- **Day supply.** A pharmacy fill carries `DAYS_SUP`; a medical administration
  is given a fixed `MEDICAL_DAY_SUPPLY` of 28 days. This is the single most
  source-specific assumption in the build — it is what turns a claim into a
  span, and every line boundary downstream is a consequence of it.
- **The episode state machine** (`03_mma_map.R`): a fill inside pharmacy cover
  pushes the runout forward, medical cover never does, a claim past both starts
  a new episode.
- **Observation and coverage.** `ENDDATE_CE` and the disenrolment switch assume
  an insurance enrolment span.
- **Transplant and CAR-T identification**, including the AUTO clustering
  windows (`SCT_AUTO_WINDOW_DAYS`, `SCT_AUTO_GAP_DAYS`) — written against
  Optum's procedure coding.
- **The quarterly-table convention** (`USE_QUARTERLY_TABLES`, the vintage
  suffix) is Optum-on-Databricks plumbing and has no meaning elsewhere.

## What is not Optum's and moves unchanged

`04_lot1_base.R`, `05_sct.R`, `05b_lot1_sct.R`, `06_lot1_end.R`,
`10_lot2_5_base.R`, `line_criteria.R`, `melp_rule.R`, `foldin_rule.R`,
`cart_rule.R`, `prior_regimen.R` — the induction windows, the run-out chain, the
end ladder, the next-line triggers, §4.3 through §4.8, the criteria layer. These
read the five tables and the settings, and nothing else.

The SQL is Spark SQL, and the repository's synthetic harnesses already
transpile it to DuckDB through SQLGlot to run the whole chain offline - so the
dialect is not the obstacle it looks like; a warehouse
with window functions, `datediff`, `date_add`/`date_sub`, `least`/`greatest`,
`array_contains`/`split` and lateral explode will take it with little change.

## Settings, and which of them are a decision rather than a copy

`config.csv` carries them all. Three groups:

**Copy as they are** — these are the myeloma rules and travel with the tumour,
not the source: `INDUCTION_WINDOW_DAYS` 60, `LOT_N_INDUCTION_WINDOW_DAYS` 30,
`CART_CONSOLIDATION_DAYS` 45, `SCT_TANDEM_DAYS` 180, `ALLO_LOT_SPAN`
`single_day`, `APPLY_MELP_RULE`, `APPLY_MAP_FOLDIN`, `APPLY_OWN_RETURN_FOLD`,
`APPLY_CART_INDUCTION_RULE`, `MAX_LOT`.

**Decide for the new source** — each of these is an assumption about how the
data represents treatment, and a different database can make a different one
true:

| Setting | The decision behind it |
|---|---|
| `MEDICAL_DAY_SUPPLY` (28) | how long one administration covers, where the claim does not say |
| `MAP_DISCON_GAP_DAYS` (90) | the gap that makes two episodes two courses rather than one |
| `LOT_DISCON_CONFIRM_DAYS` (90) | how much observation after a run-out before it is a discontinuation |
| `SCT_AUTO_WINDOW_DAYS` (13), `SCT_AUTO_GAP_DAYS` (60) | how transplant claims cluster into one event |
| `CENSOR_AT_DISENROLLMENT` | meaningless without an enrolment concept |

**Rewrite** — `CATALOG`, `CDM_SCHEMA`, `DSN`, `TBL_MEDICAL`, `TBL_MED_PROC`,
`TBL_MED_DIAG`, `TBL_RX`, `USE_QUARTERLY_TABLES`, `CODELIST_DIR`.

## MDV specifically

MDV is hospital-based Japanese administrative data, and three of its properties
meet the engine at the seam above. None is a blocker; each is a decision to take
before any number is believed, and each should be confirmed against MDV's own
data dictionary rather than taken from here.

1. **No NDC, no HCPCS.** Drugs are identified by Japanese receipt/YJ codes.
   `cl_mma_codelist.csv` must be re-authored in that vocabulary, and the four
   Optum claim arms in `03_mma_map.R` collapse to whatever MDV's drug-order
   table offers. The code list's `code_type` column is the extension point —
   the engine already carries several types and matches each source against the
   ones it can hold.

2. **Observation is attendance at a contributing hospital, not enrolment.**
   There is no insurance span, so "continuously enrolled" and
   `CENSOR_AT_DISENROLLMENT` have no direct analogue, and a patient who stops
   attending is indistinguishable from one who stopped treatment. That is the
   most consequential difference for a LOT algorithm: `DISCONTINUATION` is
   defined by absence of claims, and in MDV absence has a second cause. Decide
   explicitly what `ENDDATE` means — last visit, last visit plus a grace
   window, or a fixed study end — and state it wherever the numbers are read.

3. **Inpatient administration, and day supply.** A DPC inpatient record carries
   an administration date rather than a dispensed supply, so
   `MEDICAL_DAY_SUPPLY` becomes the dominant assumption rather than a fallback.
   Every line boundary is downstream of it. It is worth running the whole build
   at two or three values before choosing, and the sensitivity machinery is
   already there for that.

Beyond those: myeloma treatment practice in Japan differs, so the regimen
vocabulary, the transplant rate and the relevance of the melphalan rule (§4.7)
should all be re-examined with a clinician before the rules are assumed to
carry over.

## What porting does not carry with it

The validation. The synthetic harnesses plant Optum-shaped patients and assert
Optum-shaped answers, the code lists are hashed and pinned, and a line-for-line
comparison holds this build against the Optum-era code it was derived from. All
of that machinery lives beside this folder rather than in it, and all of it is
evidence about THIS database. A port needs its own planted cases, its own
face-validity bands, and its own reconciliation against published Japanese
line-of-therapy distributions before any output is used.

The engine's contract machinery travels though, and should be used: a build that
is not the contract build records its deviations and no downstream reader
accepts it as the study's. A port is a deviation until someone signs it off.
