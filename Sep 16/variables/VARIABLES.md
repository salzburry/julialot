# Variables

Everything the protocol asks to be derived (§7.2.2, §7.2.3, §7.2.4, §7.3,
Tables 1-6), with its timing and where it is written; the counting rules, the
time-to-event conventions and the strata. Where each comes from in Optum is
`DATA_MAPPING.md` "9. Variable → source, analysis variables"; which module
writes which table is `MODULES.md` "Modules".

## 1. Cohort and exposure variables

> "The exposure of interest is defined as the LOT-based cohort of eligible patients
> ... Time-to-event treatment outcomes and safety rates during each LOT will be
> assessed according to SOC regimens and select patient subgroups." — §7.3.1

| variable | definition | written as |
|---|---|---|
| patient | Optum patient identifier | `PATID` on every table |
| cohort | 1L / 2L / 3L / secondary 2L | `COHORT` - `1L`, `2L`, `3L`, `SEC2L` |
| MM diagnosis date | first medical claim for MM meeting I1 | `S_PERIODS.MM_DX_DT`; `DX_DT` is the date the diagnosis-anchored rows use (below, Q30) |
| index date | start date of that cohort's line | `S_PERIODS.INDEX_DATE`, `INDEX_YEAR` |
| baseline | index − 365 … index − 1 | `S_PERIODS.BASELINE_START` / `BASELINE_END`; the comorbidity window, which includes the index, is `COMORB_BASELINE_START` / `COMORB_BASELINE_END` (Q14) |
| follow-up | index … the earliest of end of CE, study end, death | `S_PERIODS.FU_END`, `FU_DAYS`, `FU_MONTHS` (`IE_CRITERIA.md` "Follow-up: three different things") |
| LOT start (1-4) | start of each line | `S_SPINE.LOT_START_DT`, with `NEXT_LOT_START_DT` beside it |
| LOT discontinuation | "all MM agents in the LOT are stopped or a new agent/qualifying SCT event is introduced" | `S_SPINE.IS_PROTOCOL_DISCON`, `PROTOCOL_DISCON_DT` (below, "Time-to-event conventions") |
| LOT treatment period | counting rule 7 below | `S_LOT_PERIODS.PERIOD_START` / `PERIOD_END` / `PERIOD_PY` |
| LOT regimen (1-4) | agents whose episode starts within the induction window (60 d for 1L, 30 d for 2L+, 45 d on a CAR-T-started line) | the engine's `LOT_BASE_MEDS`, on `S_SPINE` and as `S_SOC.REGIMEN` |
| SOC category (1-4) | §7.2.2 categories, below | `S_SOC.SOC_CATEGORY` |
| SCT and CAR-T | autologous / allogeneic transplant; CAR-T | `S_SOC.AUTO_SCT`, `ALLO_SCT`, `CART`, `AUTO_SCT_DT`, `AUTO_SCT_YEAR` |

**The diagnosis date** (`DX_DATE_SOURCE`, Q30). `cohort_mm_dx`, the default, is
the cohort build's qualifying I1 diagnosis, the date age and the 1L index are
already measured against. `baseline_first_claim` is Table 4's own definition -
the first MM claim (on `mm_dx.csv`) within the 1L baseline, index day included,
anchored on the patient's 1L index for every cohort - falling back to the
cohort's date where there is none. `S_PERIODS.DX_DT_SOURCE` says which
(`cohort_mm_dx` or `baseline_claim`). `DX_YEAR`, `DX_TO_INDEX_DAYS/MONTHS` and
`FU_FROM_DX_DAYS/MONTHS` hang on it.

## 2. SOC categorisation (§7.2.2)

> "... regimens will potentially be grouped according to commonly utilized
> quadruplets, triplets, doublets, anti-CD38 backbone, and class, allowing for
> potential off-label use." ... "**Annex 2** contains an exemplary list of potential
> treatment combinations that may be included in each group... Alternative groupings
> may consider broader categorizations such as 'quadruplets, triplets, BMCA vs
> non-BCMA' or other categories."

| line | tentative categories |
|---|---|
| **1L (NDMM)** | Quadruplets with anti-CD38 backbone · Triplets with anti-CD38 backbone · Other triplets (non-anti-CD38) · Doublets/monotherapies · Other (if applicable) |
| **Later lines (2L, 3L, 4L)** | Quadruplets with anti-CD38 backbone (off-label; some use expected) · Triplets with anti-CD38 backbone · Other triplets (non-anti-CD38) · Other novel agents (e.g. Selinexor) · CAR-T (inclusive of all targets) · BCMA bispecific · Non-BCMA bispecifics · Doublets/monotherapies (expected to be rare in 2L+) · Other (if applicable) |

The `soc` module categorises each line by the **set** of agents in
`LOT_BASE_MEDS` against `soc_regimen_categories.csv` (Annex 2), keyed on
`CL_MED_ABBR`. A size category is decided by the regimen's own agent count and
whether it has an anti-CD38 backbone agent (`role = backbone`), so it holds for
an agent on no list row (`MATCHED = 0`); a four-agent regimen with no backbone
is `Other`. A modality category (CAR-T, a bispecific, other novel agent) is
decided by the agent. Where a regimen's agents map to more than one category,
`SOC_PRECEDENCE` (`R/modules/05_soc.R`) decides: modality before size, `Other`
last - this package's own precedence, since §7.2.2 gives none. A transplant
line with no regimen keeps its row.

## 3. Subgroup stratifications (§7.2.3, Table 1)

> "results from the primary and secondary objectives will be stratified by patient
> subgroups of interest **among the 1L and 2L primary nested patient cohorts only**...
> **Stratifications with < 25 patients will not be performed** or may be regrouped due
> to low volumes."

| # | stratification | outcomes and cohorts |
|---|---|---|
| 1 | SOC category | All primary and secondary (SOCs within each LOT) |
| 2 | Age ≥ 75 vs < 75 years | All primary and secondary by LOT only, 1L and 2L safety and healthcare utilization events at baseline and follow-up only. Age ≥ 75 is a proxy for transplant-ineligible status, < 75 for transplant-eligible |
| 3 | Neuropathy | Secondary objective by LOT only, 1L and 2L outcomes |
| 4 | Frailty status (dependent on data use and mapping availability) | Secondary objective by LOT only, 1L and 2L outcomes |

The body text also names, as derived baseline flags: history of
**neuropathy**, of **lung parenchymal disease** (COPD, asthma, bronchiectasis,
emphysema), of **any event of interest**, **frailty** (Kim 2018 CFI, Annex 7),
and "potentially other conditions of interest, as determined by review of
data". `COMORBID_SUBGROUPS=TRUE` writes the neuropathy and lung flags to
`S_COMORB_SUBGROUP` (one row per patient per concept on `comorbid_subgroups.csv`,
`HAS_HISTORY` and `FIRST_DT`, over the comorbidity baseline); `FRAILTY=TRUE`
writes `S_FRAILTY`. Both are off by default because their code lists carry no
codes.

**How the strata are built.** `S_SAFETY_RATES`, `S_HCRU_RATES`,
`S_MALIGNANCY_RATES` and `S_TX_ATTRITION` carry `SOC_CATEGORY` and `AGE_GROUP`.
Each is written once for the line as a whole - `(all categories)` and
`(all ages)` - then once per regimen category where `soc` ran, and once per age
group where `demographics` ran. Every pass is the same query with one more
column in the `GROUP BY`, so the washout, person-time, at-risk rule and
intervals are unchanged and each stratification is a partition of the line;
`mod_patterns()` stops if `S_TX_ATTRITION`'s strata do not sum back to it.

- **Margins, not a cross.** A row is cut by regimen category or by age, never
  both; a query naming a real value in both columns finds no row.
- **Say which grouping you want**, or you read the line and its parts together
  and double count: `WHERE SOC_CATEGORY = '(all categories)' AND AGE_GROUP =
  '(all ages)'` selects the line as a whole.
- **`AGE_GROUP` is not `AGE_BAND`.** `S_DEMOGRAPHICS.AGE_BAND` is Table 4's four
  descriptive bands; `AGE_GROUP` is stratification 2, `<75` / `75+`. The rate
  tables use the second, because a rate is not the sum of its strata's rates.
- `(uncategorised)` is a line `soc` wrote no row for; `(no demographics row)`
  a patient `demographics` wrote none for. Neither is `Unknown`, a real age
  group for a patient whose age could not be read.

## 4. Primary Objective 1 — baseline characteristics (Table 4)

> "**Primary Objective 1:** demographics and clinical characteristics of the NDMM (1L)
> and RRMM (2L and 3L) populations, including background prevalence rates of key
> safety events of interest (i.e., hepatic, infections) and occurrence of healthcare
> utilization events among patients prior to the receipt of 1L, 2L, and 3L"

| variable | definition | timing |
|---|---|---|
| Age | Continuous (years); Categorical 18-44 / 45-64 / 65-74 / ≥ 75. *"Age categories may be adjusted based on age distribution in the study population"* | At index calendar year (1L, 2L, 3L) |
| Sex | Male / Female / Unknown | At index |
| Region | Midwest / South / West / Northeast / Unknown. *"Based on regions defined by US Census Bureau"* | At index |
| Race | Asian / Black / White / Unknown | At index |
| Ethnicity | Hispanic or Latino / Not Hispanic or Latino / Unknown | At index |
| Insurance type | Medicare / Commercial Health Plan | At index |
| Charlson Comorbidity Index (Quan 2011) | Continuous; Categorical 0,1,2,3,4,5+. *"CCI will be adjusted for having received a MM diagnosis, such that a value of 0 indicates no additional comorbidities beyond MM"* | During baseline |
| Kim Frailty Index Score *(pending review of data and mapping)* | Continuous; Categorical **CFI ≥ 0.25 = frail** | During baseline |
| Year of MM diagnosis | number and percent of NDMM patients by year of first MM diagnosis. *"First MM diagnosis is defined as first medical claim for MM within the baseline period on or prior to 1L"* | First recorded diagnosis date |
| Follow-up time from diagnosis | Continuous (months); diagnosis date (included) to follow-up end (included) | Diagnosis to study period |
| Follow-up time from index | Continuous (months); index date (included) to follow-up end (included) | Follow-up period |
| Year of 1L, 2L and 3L initiation | number and percent by year, **from 2019 to latest data availability** | At treatment initiation |
| Types of 1L, 2L, 3L SOCs or classes by line | number and percent by year, **from 2017 to 2025 (or latest data availability)** | At treatment initiation |

**Demographics** (`S_DEMOGRAPHICS`). Age is `year(index) − YRDOB` from the cohort
table (`AGE_YEARS`, `AGE_BAND`, `AGE_GROUP`), and at diagnosis as well
(`AGE_AT_DX_YEARS`, `AGE_AT_DX_BAND`); a birth year outside 1900..index year or
an age outside 0-120 is Unknown. Race, ethnicity, region, insurance and sex
are read off one enrolment row: under `ENROL_ATTR_AT=index_span` (default,
Q16) the row covering the index date, else the baseline row ending nearest it;
ties go to `ELIGEND` descending, then `ELIGEFF` descending, then `PAT_PLANID`.
`ATTR_SOURCE` says which (`index_span`, `baseline_nearest`, `latest_span` under
the comparison reading, or `none`). Sex falls back to the cohort table's
`GDR_CD`. The code mappings are `DATA_MAPPING.md` "9. Variable → source,
analysis variables". A module run where race or ethnicity is Unknown for over
half a cohort logs a warning.

**Charlson, MM-adjusted** (`S_COMORBIDITY`: `CCI`, `CCI_BAND`, `N_CONDITIONS`),
over the comorbidity baseline. Quan's seventeen conditions have no myeloma row -
myeloma is one of the codes under `any_malignancy` - so the adjustment is made
on the **codes**: a diagnosis whose code is on `mm_dx.csv` supports no Charlson
condition. MM alone scores 0; MM and breast cancer still scores
`any_malignancy`. Quan's hierarchy (severe over mild liver disease, diabetes
with over without complications, metastatic solid tumour over any malignancy)
comes from the `supersedes` column of `charlson_quan2011.csv`; a file without
it is summed flat and the run logs that it did. A patient with no qualifying
condition is written as CCI 0, not left out.

**Frailty** (`S_FRAILTY`: `CFI`, `FRAIL`, `N_VARIABLES`) is the sum of the
coefficients of the Kim 2018 variables matched on diagnosis codes over the
comorbidity baseline, frail at `CFI ≥ FRAILTY_FRAIL_CUTOFF` (default 0.25).

**The two year ranges.** No line can start before 2019, so the "Types of SOCs"
2017 and 2018 columns are empty by construction; `S_SOC.LOT_START_YEAR` carries
the year and the table is a count over it (Q12).

**Rows not legible in the protocol.** Table 4 between "Types of 1L, 2L, 3L SOCs
or classes by line" and the Primary Objective 3 block cannot be read. It holds
the rest of Primary Objective 1 - background prevalence of the Table 3 safety
events at baseline (rate per person-year, and patients with at least one event)
and baseline healthcare utilisation (all-cause inpatient hospitalisation,
length of stay, ER visits) - and the head of Primary Objective 2, the
on-treatment incidence of safety events. The build reads them from the
counting rules §7.8.1 states (§5 below). The shells band hospitalisations and
ER visits per patient as 0, 1, 2, 3, 4+; `S_HCRU_RATES` carries no bands, and
the per-patient counts are in `S_HCRU_EVENTS`. The legible Primary Objective 2
rows repeat the discontinuation footnote and give *"Healthcare utilization
events | Same as Primary Objective 1 | During LOT treatment period (1L, 2L,
3L)"*; §7.1 states the objective: *"assess incidence rates of key safety events
while on each LOT (i.e., during the treatment periods)"*.

## 5. Key safety outcomes (Table 3)

> "Key safety events of interest, as defined in **Table 3**, were selected due to their
> association with some MM treatments, and will be defined according to selected
> **ICD-10-CM codes or healthcare visits (Annex 3)**."

All rows are assessed at **baseline and follow-up, for 1L, 2L and 3L**.
`safety_events.csv` carries them as 23 rows (corneal ulcer and keratopathies,
and Parkinson's disease and other movement disorders, as two rows each; Q36).

| group | condition | acute/chronic |
|---|---|---|
| **Hepatologic** | Toxic liver disease | Acute or chronic |
| | Hepatic failure | Acute/Chronic |
| | Acute hepatitis B | Acute |
| | Fibrosis and cirrhosis | Chronic |
| | Non-alcoholic steatohepatitis | Chronic |
| **Renal impairment** | Acute kidney injury or acute kidney disease | Acute |
| | Chronic kidney disease | Chronic |
| | Moderate to severe renal impairment or end stage renal disease | Chronic |
| **Ocular** | Corneal ulcer | Acute |
| | Keratopathies (including ulcerative and infective) | Acute |
| **Cardiovascular** | Myocardial infarction / unstable angina | Acute |
| | Pulmonary hypertension | Chronic |
| | Cerebrovascular events / stroke and transient ischemic attack (TIA) | Acute |
| | Peripheral arterial thromboembolism | Acute |
| | Deep venous thrombosis / pulmonary embolism | Acute |
| **Neurologic** | Peripheral neuropathy | Chronic |
| | Parkinson's disease and other movement disorders | Chronic |
| | Seizures | Acute |
| **Infectious** | Severe infection resulting in hospitalization | Acute |
| | Lower respiratory / lung infection | Acute |
| **Other** | Thrombocytopenia (dependent on data availability) | Chronic |
| | Anemia (dependent on data availability) | Chronic |

The two conditions typed both ways stop the safety module until they are typed
one way (Q36). "Severe infection resulting in hospitalization" is
`setting=inpatient`: it is read only from diagnoses on medical claims carrying
a confinement id that `CONFINEMENT` knows, dated at the admission. `S_SAFETY_RATES`
carries a row per condition and period (`BASELINE`, `TREATMENT`), a
`<condition> (hospitalisation)` series per chronic condition (its admissions,
typed acute), and an `(any in domain)` row per domain - the domain's conditions'
events, each patient once. `S_SAFETY_COUNTED` holds the events that survived
the washout, the chain's own answer kept under `PERIOD = TIMELINE`.

### Counting rules

§7.3.2 and §7.8.1 state these once. They apply to baseline prevalence and
on-treatment incidence alike, through the same machinery (`R/person_time.R`),
and to secondary malignancies as a chronic condition. Settings are in
`config.csv`.

1. **Claims on the same day are one event; claims more than 1 day apart are
   distinct events.** At baseline the acute washout (rule 2) also applies, so two
   acute events of one type fewer than 30 days apart count once there too - a
   reading not yet put to the study team.
2. **Acute events may recur, with a ≥ 30-day washout between events of the same
   type** (`ACUTE_WASHOUT_DAYS`). The washout is between **counted** events:
   events on days 0, 20 and 40 are two counted events (comparing each event with
   its predecessor would give one). The chain runs once per cohort over the
   patient's timeline, baseline start to follow-up end, and each period takes
   the counted events dated inside it, so the washout crosses the index and
   lines (Q34).
3. **Chronic events count once, at first instance**, and *"no further
   person-time at risk will be considered"*. On treatment, a patient with the
   condition before the treatment period is **removed from both numerator and
   person-time denominator**, and `N_AT_RISK` says how many were left. The
   baseline denominator is the window's own person-time *"irrespective of prior
   event history"*, the same for every patient. §7.8.1 names chronic kidney
   disease, moderate-to-severe renal impairment or ESRD, pulmonary
   hypertension, peripheral neuropathy, Parkinson's disease, other movement
   disorders, malignancies, thrombocytopenia and anaemia; the code list's own
   acute/chronic column governs, and a list that types one of those names
   acute stops the run (Q36).
4. **A hospitalisation due to a chronic condition is an acute event** and may be
   counted more than once - the `(hospitalisation)` series.
5. **Hospitalisations are assigned by admit date**, whichever period the
   discharge falls in. LOS runs from admit (included) to discharge (**excluded**),
   computed rather than read from `CONFINEMENT.LOS`.
6. **A hospitalisation with no discharge date** counts towards patient and event
   counts but not LOS (`N_LOS_EXCLUDED`).
7. **An event belongs to a LOT** if it occurs *"between the LOT's start date
   (included) and the start date (excluded) of a subsequent LOT, or
   discontinuation date of the prior LOT + 30 days of discontinuation, whichever
   comes first. If the patient experiences an event > 30 days after
   discontinuation, the event will not be counted (even if the patient
   eventually started a subsequent LOT)."* That is the **LOT treatment period**:
   `[LOT start, min(next LOT start − 1, discontinuation + 30)]`
   (`LOT_POST_DISCON_DAYS`), with the line's own end date + 30 where it did not
   protocol-discontinue, clipped to `FU_END`.
8. **Baseline characteristics are taken at the index date where possible**, else
   the value nearest the index within the baseline (`ENROL_ATTR_AT`, Q16).
   **Comorbidities are assessed over the baseline including the index date**
   (`COMORBIDITY_BASELINE_INCLUDES_INDEX`, Q14).
9. **Rates are per person-year, reported per 100,000** (`RATE_MULTIPLIER`,
   recorded on the run; the TFLS shells are labelled per 100,000 and refuse a
   run that recorded another). Person-years are days / 365.25, both ends
   included. A rate's 95% interval is a Poisson interval on the log scale; a
   zero-event rate carries the exact limits, 0 and 3.688879 / PY.
10. **< 25 patients in a stratification or cohort ⇒ no analysis** - the
    `release` module (`MODULES.md` "Suppression and release"). §7.8 exempts
    analyses "specific to SOC"; the build does not (Q29).
11. **No imputation.** Missing values are reported and dropped where necessary.
12. **No p-values, no log-rank, no hypothesis tests.**

### Healthcare utilisation outcomes

> "Health care utilization outcomes include: (1) **All-cause inpatient
> hospitalizations** and (2) **Emergency visits**."

`S_HCRU_RATES` measures: `ALL_CAUSE_HOSPITALISATION` (a `CONFINEMENT` row),
`MM_RELATED_HOSPITALISATION` - §7.8.1's *"MM diagnosis in first or second
position"*, by the route `MM_HOSP_POSITION` names (Q27) - and `ED_VISIT`. The CDM
has no emergency-visit flag, so an ED visit is a claims construction
(`ED_DEFINITION`, `ED_ADMITTED`, Q11), one per patient per day. `CLAIM_STATUS`
filters the ED arm only (Q25). Each row has `N_PATIENTS`, `N_EVENTS`,
`N_AT_RISK`, person-years, the rate, and mean and median LOS.

## 6. Primary Objective 3 — secondary malignancies (Table 4 cont.)

> "**Primary Objective 3:** describe the occurrence of secondary malignancies following
> the receipt of therapy"

| variable | definition | timing |
|---|---|---|
| Time from diagnosis to secondary malignancy | Continuous (months); diagnosis date (included) until date of secondary malignancy (included) | Diagnosis to occurrence |
| Time from 1L/2L index to secondary malignancy | Continuous (months); 1L or 2L index (included) until date of secondary malignancy (included) | 2L only where the malignancy occurred after 2L |
| Prevalence and incidence of secondary malignancy | "To be calculated in the same manner as Objectives 1 and 2, adhering to rules for chronic conditions. *For nested cohort, no background prevalence is needed; for 2L cohort prevalence and incidence are needed*" | Follow-up period |
| Type of malignancy | "defined according to ICD-10-CM codes. Occurrence of malignancy to be **confirmed through the presence of at least 2 diagnosis codes occurring on separate dates. The date of the first ICD code will be used**" | Follow-up period |
| Secondary malignancy category | by type, per Table 2 | Follow-up period |
| LoT after which the malignancy occurred | "Defined according to the LoT after which the malignancy is identified" | Follow-up period |
| Top treatment sequences among those with malignancy | "Tabulation of the **top 5-10 sequences** among those with a malignancy occurring after treatment. For sensitivity analysis — this will be tabulated among those with a new malignancy occurring only after 2L" | Follow-up period |

| Table 2 category | examples |
|---|---|
| Hematological (**will not include other myeloma types**) | leukemia, lymphoma |
| Genitourinary (GU) | Prostate, renal/kidney, bladder/urothelial, testicular, other GU |
| Gynecological (Gyn) | Ovarian, endometrial/uterine, cervical, vulvar, other gyn |
| Head and Neck (H&N) | Mucosal squamous cell, nasopharyngeal carcinoma, salivary gland malignancies, other H&N |
| Gastrointestinal (GI) | Colorectal, gastric/esophageal, pancreatic and hepatobiliary, other GI |
| Thoracic (Non-H&N) | Lung, other thoracic |
| Breast cancer | Any breast cancer as standalone |
| Melanoma | Any melanoma |
| Non-melanoma skin cancer | Basal cell carcinoma, squamous cell carcinoma |
| Other | Other category dependent on final categorization |

As built: a malignancy is confirmed at **subtype** grain by two codes on
separate dates, both on or before the cohort's follow-up end, dated at the
first (Q35). `S_MALIGNANCY` carries each one with `CATEGORY`, `SUBTYPE`,
`FIRST_DT`, `CONFIRM_DT`, `AFTER_INDEX`, `LOT_AFTER_WHICH`, `MONTHS_FROM_DX`
(on `S_PERIODS.DX_DT`) and `MONTHS_FROM_INDEX` (NULL before the index);
`S_MALIGNANCY_DATES` keeps every qualifying date. `S_MALIGNANCY_RATES` counts
them as a chronic condition per category - prior history per category - plus
an `(any malignancy)` row: a first malignancy of any kind, with a patient who
had any before the period out of numerator and denominator. A malignancy is
attributed to a line for the rates only inside the treatment period. Where a
cohort permits prior malignancy (SEC2L), background prevalence is taken over
`MALIG_PREVALENCE_WINDOW` (default `since_diagnosis`, Q31).
`S_MALIGNANCY_SEQUENCES`, written where `soc` ran, carries three readings on
`LINES` (`to_malignancy`, `after_malignancy`, `all_observed`), each with its own
denominator, in both scopes `after_index` and `after_2l` (Q32). A code on
`mm_dx.csv` may not be on the malignancy list.

## 7. Secondary Objective — treatment patterns and outcomes (Table 5)

> "**Secondary Objective 1:** describe treatment patterns and treatment-related outcomes
> (e.g., treatment attrition, TTNT, TTD, OS) as a proxy for effectiveness and
> tolerability by LOT, overall and by SOC, and by patient subgroups of interest"

| outcome | definition | written as |
|---|---|---|
| Patients receiving each line | number and percent receiving each 1L-4L regimen | `S_PATTERNS` (by regimen category) |
| Treatment regimens received | regimen categories (§7.2.2), overall sequence 1L to 4L | `S_SOC`, `S_PATTERNS` |
| Switch between successive LOTs | **Sankey diagram** of switch between regimen categories | `S_SWITCH`, one row per transition, with `(died)` and `(no further therapy)` as terminal nodes |
| Treatment attrition | number and percent who received each subsequent LOT, discontinued and did not receive another, were lost to follow-up, or died; 1L up to 4L start | `S_TX_ATTRITION`: `received_next_lot`, `died`, `discontinued_no_further`, `lost_to_followup`, in that precedence |
| Time from diagnosis to 1L initiation | Continuous (months); diagnosis (included) until index (**excluded**) | `S_PERIODS.DX_TO_INDEX_DAYS/MONTHS` |
| Time from prior LOT to next LOT initiation | Continuous (months); among patients initiating a subsequent LOT, prior LOT start (included) to next LOT start (excluded) | `S_LOT_PERIODS.NEXT_LOT_DAYS/MONTHS`, only where the next line starts inside follow-up |

A next line starting after `FU_END` is not one the cohort observed: patterns,
switching and attrition treat the patient as censored there, as TTNT does.

### Time-to-event conventions

| outcome | definition (Table 5) |
|---|---|
| **TTNT** | index LOT start (included) to the earliest of the next LOT start **or death** (excluded); without either, censored at follow-up end |
| **TTD** | index LOT start (included) to treatment discontinuation (excluded) - the **earliest of** discontinuation (end of current LOT), next LOT start, or death; without any, censored at follow-up end. *"per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new agent/qualifying SCT event is introduced"* |
| **OS** | LOT start (included) to death (excluded); without a death date, censored at follow-up end |

`S_TTE` holds one row per cohort row with `*_DT`, `*_DAYS`, `*_MONTHS` and
`*_EVENT` for each outcome, and `TTE_ELIGIBLE` beside them.

- **Intervals** open on the index (included) and close before the event
  (excluded), so every duration is `datediff(event, index)`. Reported months
  are days / 30.4375, whatever `MONTHS_AS` says - it governs window
  construction, not reported durations.
- **Censoring.** Every event date is clipped to `S_PERIODS.FU_END`
  (`IE_CRITERIA.md` "Follow-up: three different things"); an event after it is
  a censoring.
- **TTD's event is a union.** The engine records the footnote's three branches
  as different `LOT_BASE_END_REASON` values, so `S_SPINE.IS_PROTOCOL_DISCON` is
  1 for `DISCONTINUATION`, `MED_ADD`, `CART_INIT`, `SCT_AUTO`, `SCT_ALLO`,
  `SCT_CART` and `SCT_AUTO_CONT`. Reading `DISCONTINUATION` alone would
  undercount TTD badly.
- **The discontinuation day** (`PROTOCOL_DISCON_DT`, Q33) is the confirmed
  run-out for `DISCONTINUATION`, the transplant for `SCT_AUTO_CONT` (an
  autologous transplant inside the line's own window, which opens no line), and
  the introduction day - the engine's end + 1 - for `MED_ADD`, `CART_INIT`,
  `SCT_AUTO`, `SCT_ALLO` and `SCT_CART`, so TTD and TTNT date the same event on
  the same day.
- **The analysis set.** The analyses are the rows with `TTE_ELIGIBLE = 1`, the
  ≥ 3-month potential follow-up set (`IE_CRITERIA.md` "7a. The analysis-set
  restriction that is not an eligibility criterion").

## 8. Exploratory Objective (Table 6)

> "**Exploratory Objective 1:** assess trends in the use of SCT over time, overall and
> according to SOC."

| outcome | definition | written as |
|---|---|---|
| Trends in the use of SCT | number of patients with an SCT in 1L-4L by year, according to SOC type | a count over `S_SOC` (`AUTO_SCT`, `ALLO_SCT`, `CART`, `AUTO_SCT_YEAR`, `SOC_CATEGORY`) |

## 9. Confounders and effect modifiers (§7.3.3)

> "N/A: This analysis is descriptive only."

Nothing is derived for confounding control.
