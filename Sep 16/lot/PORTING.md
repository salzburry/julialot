# Moving the LOT engine to another database

**The line-assembly half moves as it stands; the extraction half does not.**
They are separated by five tables, and that seam is the whole of the porting
question.

Two axes, and they are independent. Moving to another **data source** — MDV,
JMDC, Flatiron, a national registry — is the subject of this file. Moving to
another **tumour** is a different change: the rules in `LOT_RULES.md` are
myeloma's, and changing them is a contract decision, not a data one. A source
port keeps the rules and rebuilds the inputs. A tumour port keeps the inputs
and rebuilds the rules. Doing both at once is two projects.

## The seam

**Two step files read the source, and they are not the first two.**

| Step | Reads | Produces |
|---|---|---|
| `03_mma_map.R` | `medical`, `rx` | `MAP_STACKED` |
| `05_sct.R` | `medical`, `med_procedure`, `med_diagnosis` | `TX_AUTO_DATES`, `TX_ALLO_CART_DATES` |

Outside the steps, `check_claim_ndc()` in `R/build_lot.R` profiles the NDC
column of `medical` and `rx` before extraction; it is Optum's NDC handling and
goes with the extraction half. `02_patient_input.R` reads the cohort table the
caller hands it, and `01_codelists.R` reads code-list CSVs from disk. Everything
else — including `05b_lot1_sct.R`, which sits between the two source-readers and
reads neither — touches no source table at all.

So the seam runs **through** `05_sct.R` rather than before it: that file both
reads Optum and holds the AUTO clustering rules, which are the tumour's. A port
rewrites its extraction half and keeps its clustering half — a file to split,
not a file to move.

Produce the five tables below and the **line-assembly statements** run
unchanged. `lot/qc/extract_patients.R` writes exactly these out for named
patients, so their real rows can be put back through the same statements with
no warehouse at all.

**That set is what line assembly reads, not everything a run needs.** A
production run starts earlier and checks more, and two things it needs go
beyond it:

- `LOT_PATIENT_INPUT` carries `FU_DAYS` and `FU_DAYS_CE` on the ordinary
  cohort-entry path (`02_patient_input.R`).
- `MAP_STACKED` carries both run-out columns below. No rule reads them, but the
  build's LOT1 invariants do, and a run without them stops.

Port the full set.

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
| `MAP_CNT` | int | the episode's **ordinal** within `(PATID, MAP_MED_TYPE)`, and it is read: it is the sort key the next-episode lookup orders by |
| `MAP_START_DT` | date | first day of cover |
| `MAP_RX_RUNOUT_DT` | date | how far the pharmacy fills reach. Null where there are none |
| `MAP_MED_RUNOUT_DT` | date | the same for medical administrations |
| `MAP_END_DT` | date | last day of cover, and it must equal the later of the two run-outs — the build's invariants check exactly that |
| `MAP_DISCON_FLG` | int | 1 where the drug stopped: either the gap to its next episode is at least `MAP_DISCON_GAP_DAYS`, **or** there is no next episode and observation runs at least that long past this one's end |

### 3. `TX_AUTO_DATES` — autologous transplants

`PATID`, `TX_SEQ` (int, ordered within patient), `TX_DT` (date). One row per
**event**, already clustered.

### 4. `TX_ALLO_CART_DATES` — allogeneic transplants and CAR-T

`PATID`, `SCT_TYPE` (`'ALLO'` or `'CART'`), `TX_SEQ`, `TX_DT`.

### 5. `PERMISSIBLE_SUBS` — equivalence

`original_med`, `substitute_med`. One row per pair, in one direction; the engine
reads each row both ways. This is §4.4's whole input: a biosimilar and its
reference product are one agent.

### ...and one thing that is not a table

**The drug universe.** The emitted SQL is *parameterised* by the set of
`(MAP_MED_TYPE, MAP_MED_CLASS)` pairs the code list carries: the build writes
one `LOT1_MED_<x>` and `LOT1_CLASS_<x>` column per member, so the statements
themselves change shape with the list. A drug missing from it is a drug the
emitted build cannot flag. `extract_patients.R` writes it beside the five as
`MED_UNIVERSE` for that reason. Port the universe with the tables, not after
them.

## What is Optum's and has to be rebuilt

Everything that makes those five tables:

- **Drug identification.** Four claim arms against HCPCS and NDC-11, with NDC
  normalisation and the leading-zero rules (`FILES.md`, "The code-list
  checks"). Another database has another drug vocabulary, and
  `cl_mma_codelist.csv` is written in Optum's.
- **Day supply.** A pharmacy fill carries `DAYS_SUP`; a medical administration
  is given a fixed `MEDICAL_DAY_SUPPLY` of 28 days. This is the single most
  source-specific assumption in the build — it is what turns a claim into a
  span, and every line boundary downstream is a consequence of it.
- **The episode state machine** (`03_mma_map.R`): a fill inside pharmacy cover
  pushes the run-out forward, medical cover never does, a claim past both starts
  a new episode.
- **Observation and coverage.** `ENDDATE_CE` and the disenrolment switch assume
  an insurance enrolment span.
- **Transplant and CAR-T identification**, including the AUTO clustering
  windows (`SCT_AUTO_WINDOW_DAYS`, `SCT_AUTO_GAP_DAYS`) — written against
  Optum's procedure coding.
- **The quarterly-table convention** (`USE_QUARTERLY_TABLES`, the vintage
  suffix `STUDY_END` picks) is Optum-on-Databricks plumbing and has no meaning
  elsewhere.

## What is not Optum's and moves unchanged

`04_lot1_base.R`, `05b_lot1_sct.R`, `06_lot1_end.R`, `10_lot2_5_base.R`,
`line_criteria.R`, `melp_rule.R`, `foldin_rule.R`, `cart_rule.R`,
`prior_regimen.R` — the induction windows, the run-out chain, the end cascade,
the next-line triggers, §4.3 through §4.8, the criteria layer. These read the
five tables, the drug universe and the settings, and nothing else.

`05_sct.R` is the exception and is not in that list: its clustering rules move;
its extraction does not.

The SQL is Spark SQL, and the offline suites already transpile it to DuckDB
through sqlglot and run it (`qc/tests/run_duckdb.py`,
`melphalan/tests/run_duckdb.py`), so the dialect is not the obstacle it looks
like: a warehouse with window functions, `datediff`, `date_add`/`date_sub`,
`least`/`greatest`, `array_contains`/`split` and lateral explode will take it
with little change.

## Settings, and which of them are a decision rather than a copy

`config.csv` carries them all. Three groups:

**Copy as they are** — these are the myeloma rules and travel with the tumour,
not the source: `INDUCTION_WINDOW_DAYS` 60, `INDUCTION_WINDOW_DAYS_LOT_N` 30,
`CART_CONSOLIDATION_DAYS` 45, `SCT_TANDEM_DAYS` 180, `ALLO_LOT_SPAN`
`single_day`, `APPLY_MELP_RULE`, `MELP_EXPOSURE_DAYS`, `MELP_SIMPLE_COURSE_DAYS`,
`APPLY_MAP_FOLDIN`, `APPLY_OWN_RETURN_FOLD`, `APPLY_CART_INDUCTION_RULE`,
`APPLY_NO_BELANTAMAB`, `MAX_LOT`. `MELP_MED_ABBR` and `BELANTAMAB_MED_ABBR` keep
their meaning but must match the abbreviations the rewritten code list uses.

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

**Rewrite** — the connection and source: `DATABRICKS_DSN`,
`DATABRICKS_CATALOG`, `OPTUM_CDM_SCHEMA`, `USE_QUARTERLY_TABLES`, `CODELIST_DIR`,
and the four source table names, which are fixed in `R/config_lot.R`
(`tbl_medical`, `tbl_med_proc`, `tbl_med_diag`, `tbl_rx`).

Every setting named in this section is pinned in
`CONTRACT` in `R/build_lot.R` (`LOT_RULES.md` §1). A port therefore either edits
`CONTRACT` to the values it has decided, or runs with `LOT_CONTRACT_OVERRIDE=TRUE`
and is recorded as a deviation.

## MDV specifically

MDV is hospital-based Japanese administrative data, and three of its properties
meet the engine at the seam above. None is a blocker; each is a decision to take
before any number is believed, and each should be confirmed against MDV's own
data dictionary.

1. **No NDC, no HCPCS.** Drugs are identified by Japanese receipt/YJ codes.
   `cl_mma_codelist.csv` must be re-authored in that vocabulary, and the four
   Optum claim arms in `03_mma_map.R` collapse to whatever MDV's drug-order
   table offers. The code list's `CL_CODE_TYPE` column is the extension point,
   but drug extraction reads only `NDC` and `HCPCS`, and any other type
   stops the build under `code_types` until an arm that reads it is added.

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
   Every line boundary is downstream of it. Run the whole build at two or three
   values before choosing, as sensitivity builds.

Beyond those: myeloma treatment practice in Japan differs, so the regimen
vocabulary, the transplant rate and the relevance of the melphalan rule (§4.7)
should all be re-examined with a clinician before the rules are assumed to
carry over.

## What porting does not carry with it

The validation. The test suites plant Optum-shaped patients and assert
Optum-shaped answers, and the code lists are hashed per run. All of it is
evidence about this database. A port needs its own planted cases, its own
face-validity bands, and its own reconciliation against published line-of-therapy
distributions for the new source before any output is used.

The engine's contract machinery travels, and should be used: a build that is
not the contract build records its deviations and no downstream reader accepts
it as the study's. A port is a deviation until someone signs it off.
