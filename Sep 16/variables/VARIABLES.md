# Variables — GSK 223926 (Aug 26 2026 protocol)

Everything the protocol asks to be derived, from §7.2.2, §7.2.3, §7.2.4, §7.3 and
Tables 1-6, with the timing each variable is collected at, and where the build
writes it. `DATA_MAPPING.md` says where each one comes from in Optum;
`MODULES.md` says which module writes which table.

Part of Table 4 is not legible in the protocol — §4.

---

## 1. Cohort and exposure variables

The exposure is the cohort itself:

> "The exposure of interest is defined as the LOT-based cohort of eligible patients
> (see Section 7.2.1 for eligibility criteria). Time-to-event treatment outcomes and
> safety rates during each LOT will be assessed according to SOC regimens and select
> patient subgroups." — §7.3.1

| variable | definition | where the build writes it |
|---|---|---|
| patient | Optum patient identifier | `PATID` on every table |
| cohort | 1L / 2L / 3L / secondary 2L | `COHORT` — `1L`, `2L`, `3L`, `SEC2L` |
| MM diagnosis date | first medical claim for MM meeting I1 | `S_PERIODS.MM_DX_DT`; `DX_DT` is the date the diagnosis-anchored rows use, which `DX_DATE_SOURCE` picks (Q30) |
| index date | start date of that cohort's line | `S_PERIODS.INDEX_DATE` |
| baseline | index − 365 … index − 1 (index excluded) | `S_PERIODS.BASELINE_START` / `BASELINE_END`; the comorbidity window, which includes the index, is `COMORB_BASELINE_START` / `COMORB_BASELINE_END` (Q14) |
| follow-up | index … the earliest of end of CE, study end, death | `S_PERIODS.FU_END` — `IE_CRITERIA.md` §2 |
| LOT start (1-4) | start of each line | `S_SPINE.LOT_START_DT`, with `NEXT_LOT_START_DT` beside it |
| LOT discontinuation | "all MM agents in the LOT are stopped or a new agent/qualifying SCT event is introduced" | `S_SPINE.IS_PROTOCOL_DISCON`, `PROTOCOL_DISCON_DT` — `CONFORMANCE.md`, "The LOT engine against the protocol's LOT wording" |
| LOT treatment period | below, under Counting rules | `S_LOT_PERIODS.PERIOD_START` / `PERIOD_END` |
| LOT regimen (1-4) | agents whose episode starts within the induction window (60 d for 1L, 30 d for 2L+, 45 d on a CAR-T-started line) | the engine's `LOT_BASE_MEDS`, on `S_SPINE` and as `S_SOC.REGIMEN` |
| SOC category (1-4) | §7.2.2 categories, below | `S_SOC.SOC_CATEGORY` |
| SCT and CAR-T | autologous / allogeneic transplant; CAR-T | `S_SOC.AUTO_SCT`, `ALLO_SCT`, `CART`, `AUTO_SCT_DT`, `AUTO_SCT_YEAR` |

## 2. SOC categorisation (§7.2.2)

> "To assess treatment patterns and time-to-event treatment outcomes according to
> LOT cohorts and SOC regimen, regimens will potentially be grouped according to
> commonly utilized quadruplets, triplets, doublets, anti-CD38 backbone, and class,
> allowing for potential off-label use."

> "For purposes of inclusion criteria, eligible 1L treatments will include treatments
> commonly used or expected in the 1L setting, inclusive of approved, and off-label
> combination regimens."

> "**Annex 2** contains an exemplary list of potential treatment combinations that may
> be included in each group... Alternative groupings may consider broader
> categorizations such as 'quadruplets, triplets, BMCA vs non-BCMA' or other
> categories."

Tentative categories:

| line | categories |
|---|---|
| **1L (NDMM)** | Quadruplets with anti-CD38 backbone · Triplets with anti-CD38 backbone · Other triplets (non-anti-CD38) · Doublets/monotherapies · Other (if applicable) |
| **Later lines (2L, 3L, 4L)** | Quadruplets with anti-CD38 backbone (off-label; some use expected) · Triplets with anti-CD38 backbone · Other triplets (non-anti-CD38) · Other novel agents (e.g. Selinexor) · CAR-T (inclusive of all targets) · BCMA bispecific · Non-BCMA bispecifics · Doublets/monotherapies (expected to be rare in 2L+) · Other (if applicable) |

`cl_mma_rollup.csv` carries `CL_MED_CLASS` and `CL_MED_ABBR`, the raw material for
these groupings. The study package's `soc` module categorises each line by the
**set** of agents it contains against `soc_regimen_categories.csv` (Annex 2) and
writes `S_SOC.SOC_CATEGORY`; a size category (triplet, doublet) is decided by the
regimen's own agent count and backbone, so it holds for an unlisted agent too, and
a modality category (CAR-T, a bispecific) by the agent. `CODELISTS.md` §2,
`MODULES.md`.

## 3. Subgroup stratifications (§7.2.3, Table 1)

> "results from the primary and secondary objectives will be stratified by patient
> subgroups of interest **among the 1L and 2L primary nested patient cohorts only**...
> **Stratifications with < 25 patients will not be performed** or may be regrouped due
> to low volumes."

| # | stratification | outcomes and cohorts for assessment |
|---|---|---|
| 1 | SOC category | All primary and secondary (SOCs within each LOT) |
| 2 | Age ≥ 75 vs < 75 years | All primary and secondary by LOT only, 1L and 2L safety and healthcare utilization events at baseline and follow-up only. Age stratification is intended to serve as a proxy for transplant status (where TIE ≥ 75 years) |
| 3 | Neuropathy | Secondary objective by LOT only, 1L and 2L outcomes |
| 4 | Frailty status (dependent on data use and mapping availability) | Secondary objective by LOT only, 1L and 2L outcomes |

Comorbidities of interest named in the body text, which the stratification needs as
derived baseline flags:

- Baseline history of **neuropathy**
- Baseline history of **lung parenchymal disease** (COPD, asthma, bronchiectasis, emphysema)
- Baseline history of **any event of interest** (cardio, neuro, etc.)
- Baseline **frailty status** — Claims-Based Frailty Index (CFI), Kim 2018, **Annex 7**
- "Potentially other conditions of interest, as determined by review of data"

`Age ≥ 75` is explicitly a proxy for transplant-ineligible (TI) status, `< 75` for
transplant-eligible (TE).

## 4. Primary Objective 1 — baseline characteristics (Table 4)

> "**Primary Objective 1:** demographics and clinical characteristics of the NDMM (1L)
> and RRMM (2L and 3L) populations, including background prevalence rates of key
> safety events of interest (i.e., hepatic, infections) and occurrence of healthcare
> utilization events among patients prior to the receipt of 1L, 2L, and 3L"

### Baseline demographic characteristics

| variable | definition | timing |
|---|---|---|
| Age | Continuous (years); Categorical 18-44 / 45-64 / 65-74 / ≥ 75. *"Age categories may be adjusted based on age distribution in the study population"* | At index calendar year (1L, 2L, 3L) |
| Sex | Male / Female / Unknown | At index (1L, 2L, 3L) |
| Region | Midwest / South / West / Northeast / Unknown. *"Based on regions defined by US Census Bureau"* | At index (1L, 2L, 3L) |
| Race | Asian / Black / White / Unknown | At index (1L, 2L, 3L) |
| Ethnicity | Hispanic or Latino / Not Hispanic or Latino / Unknown | At index (1L, 2L, 3L) |
| Insurance type | Medicare / Commercial Health Plan | At index (1L, 2L, 3L) |

### Baseline comorbidities and clinical characteristics

| variable | definition | timing |
|---|---|---|
| Charlson Comorbidity Index (Quan 2011) | Continuous; Categorical 0,1,2,3,4,5+. *"CCI will be adjusted for having received a MM diagnosis, such that a value of 0 indicates no additional comorbidities beyond MM"* | During baseline (1L, 2L, 3L) |
| Kim Frailty Index Score *(only included pending review of data and mapping)* | Continuous; Categorical **CFI ≥ 0.25 = frail**. *"CFI will only be assessed pending feasibility of inclusion"* | During baseline (1L, 2L, 3L) |
| Year of MM diagnosis | Categorical; number and percent of NDMM patients by year of first MM diagnosis. *"First MM diagnosis is defined as first medical claim for MM within the baseline period on or prior to 1L"* | First recorded diagnosis date |
| Follow-up time from diagnosis | Continuous (months); diagnosis date (included) to follow-up end date (included) | Diagnosis to study period |
| Follow-up time from index | Continuous (months); index date (included) to follow-up end date (included) | Follow-up period (1L, 2L, 3L) |
| Year of 1L, 2L and 3L initiation | Categorical; number and percent by year, **from 2019 to latest data availability** | At treatment initiation date (1L, 2L, 3L) |
| Types of 1L, 2L, 3L SOCs or classes by line | Categorical; number and percent by year, **from 2017 to 2025 (or latest data availability)** | At treatment initiation date (1L, 2L, 3L) |

> **Note the two different year ranges.** "Year of 1L/2L/3L initiation" starts 2019;
> "Types of SOCs by line" starts **2017**. No line can start before 2019, so the
> 2017 and 2018 columns are empty by construction; `S_SOC.LOT_START_YEAR` carries
> the year (Q12).

> **Rows not legible in the protocol.** Table 4 between "Types of 1L, 2L, 3L
> SOCs or classes by line" and the Primary Objective 3 block cannot be read. It
> holds the rest of Primary Objective 1 — **background prevalence of the Table 3
> key safety events at baseline** (the rate per person-year, and the number of
> patients with at least one event) and **baseline healthcare utilisation**
> (all-cause inpatient hospitalisation, inpatient length of stay, ER visits) —
> and the head of **Primary Objective 2**: its banner and the **on-treatment
> incidence of safety events** row. The build reads them from the counting
> rules §7.8.1 states (§5 below), and reports the baseline hospitalisation and
> ER-visit rows in the bands 0, 1, 2, 3, 4+. The
> Primary Objective 2 rows that can be read are:
>
> | variable | definition | timing |
> |---|---|---|
> | *(footnote carried over)* | *"per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new agent/qualifying SCT event is introduced"*; *"See Primary Objective 3 for similar calculation of secondary malignancies"* | |
> | Healthcare utilization events | Same as Primary Objective 1 | During LOT treatment period (1L, 2L, 3L) |
>
> Primary Objective 2 itself is stated in §7.1: *"assess incidence rates of key
> safety events while on each LOT (i.e., during the treatment periods)"*.

## 5. Key safety outcomes (Table 3)

> "Key safety events of interest, as defined in **Table 3**, were selected due to their
> association with some MM treatments, and will be defined according to selected
> **ICD-10-CM codes or healthcare visits (Annex 3)**."

All 22 rows are assessed at **baseline and follow-up, for 1L, 2L and 3L**.

| group | condition | acute/chronic |
|---|---|---|
| **Hepatologic conditions** | Toxic liver disease | Acute or chronic |
| | Hepatic failure | Acute/Chronic |
| | Acute hepatitis B | Acute |
| | Fibrosis and cirrhosis | Chronic |
| | Non-alcoholic steatohepatitis | Chronic |
| **Renal impairment** | Acute kidney injury or acute kidney disease | Acute |
| | Chronic kidney disease | Chronic |
| | Moderate to severe renal impairment or end stage renal disease | Chronic |
| **Ocular events** | Corneal ulcer | Acute |
| | Keratopathies (including ulcerative and infective) | Acute |
| **Cardiovascular conditions** | Myocardial infarction / unstable angina | Acute |
| | Pulmonary hypertension | Chronic |
| | Cerebrovascular events / stroke and transient ischemic attack (TIA) | Acute |
| | Peripheral arterial thromboembolism | Acute |
| | Deep venous thrombosis / pulmonary embolism | Acute |
| **Neurologic conditions** | Peripheral neuropathy | Chronic |
| | Parkinson's disease and other movement disorders | Chronic |
| | Seizures | Acute |
| **Infectious** | Severe infection resulting in hospitalization | Acute |
| | Lower respiratory / lung infection | Acute |
| **Other** | Thrombocytopenia (dependent on data availability) | Chronic |
| | Anemia (dependent on data availability) | Chronic |

### Counting rules

§7.3.2 and §7.8.1 state these once. The build applies them to baseline
prevalence and on-treatment incidence alike, and to secondary malignancies as
a chronic condition; how is `MODULES.md`, "Counting rules, as implemented".
The settings named below are in `config.csv`.

1. **Multiple claims on the same day are one event; claims more than 1 day
   apart are distinct events.** At baseline the build also applies the acute
   washout (rule 2), so two acute events of one type fewer than 30 days apart
   count once there too — a reading not yet put to the study team
   (`CONFORMANCE.md`, `SAF-BASELINE-NUMERATOR`).
2. **Acute events may occur more than once, with a ≥ 30-day washout between
   events of the same type** (`ACUTE_WASHOUT_DAYS`). The build runs the
   washout across the index and across lines (Q34).
3. **Chronic events are counted once, at first instance**, and *"no further
   person-time at risk will be considered"*. On treatment, a patient with the
   condition before the treatment period is **removed from both the numerator
   and the person-time denominator** for it; the baseline denominator is
   *"irrespective of prior event history"*. §7.8.1 names chronic kidney
   disease, moderate-to-severe renal impairment or ESRD, pulmonary
   hypertension, peripheral neuropathy, Parkinson's disease, other movement
   disorders, malignancies, thrombocytopenia and anaemia. Table 3 types more
   conditions chronic; the code list's own acute/chronic column governs and the
   §7.8.1 names are checked against it (Q36).
4. **A hospitalisation due to a chronic condition is an acute event** and may be
   counted more than once — each chronic condition also has a
   `<condition> (hospitalisation)` series.
5. **Hospitalisations are assigned by admit date**, whichever period the
   discharge falls in. LOS runs from admit (included) to discharge
   (**excluded**).
6. **A hospitalisation with no discharge date** counts towards patient and event
   counts but is excluded from LOS summaries.
7. **An event belongs to a LOT** if it occurs *"between the LOT's start date
   (included) and the start date (excluded) of a subsequent LOT, or
   discontinuation date of the prior LOT + 30 days of discontinuation, whichever
   comes first. If the patient experiences an event > 30 days after
   discontinuation, the event will not be counted (even if the patient
   eventually started a subsequent LOT)."* That is the **LOT treatment period**,
   the risk window for Primary Objective 2:
   `[LOT start, min(next LOT start − 1 day, discontinuation + 30 days)]`
   (`LOT_POST_DISCON_DAYS`), clipped to the follow-up end.
8. **Baseline characteristics are taken at the index date where possible**; if
   missing at index, the value nearest the index within the baseline
   (`ENROL_ATTR_AT`, Q16). **Comorbidities are assessed over the 12-month
   baseline including the index date**, where §7.1's baseline excludes it
   (`COMORBIDITY_BASELINE_INCLUDES_INDEX`, Q14).
9. **Rates are per person-year, reported per 100,000** (`RATE_MULTIPLIER`,
   recorded on the run's metadata row; the TFLS shells are labelled per 100,000
   and refuse a run that recorded another multiplier). A rate's 95% interval is
   a Poisson interval on the log scale; a rate of zero events carries the exact
   limits, 0 and 3.688879 / PY.
10. **< 25 patients in a stratification or cohort ⇒ no analysis.** The release
    module suppresses such rows in the `_RELEASE` tables (`SUPPRESS_MIN_N`).
    §7.8 exempts analyses "specific to SOC"; the build does not (Q29).
11. **No imputation.** Missing values are reported and dropped where necessary.
12. **No p-values, no log-rank, no hypothesis tests.**

### Healthcare utilisation outcomes

> "Health care utilization outcomes include: (1) **All-cause inpatient
> hospitalizations** and (2) **Emergency visits**."

§7.8.1 adds hospitalisation **related to MM** — a MM diagnosis in first or
second position (Q27). The CDM has no emergency-visit flag, so an ER visit is a
construction (`ED_DEFINITION`, Q11).

## 6. Primary Objective 3 — secondary malignancies (Table 4 cont.)

> "**Primary Objective 3:** describe the occurrence of secondary malignancies following
> the receipt of therapy"

| variable | definition | timing |
|---|---|---|
| Time from diagnosis to secondary malignancy | Continuous (months); diagnosis date (included) until date of secondary malignancy (included) | Diagnosis to occurrence of malignancy |
| Time from 1L/2L index to secondary malignancy | Continuous (months); 1L or 2L index (included) until date of secondary malignancy (included) | 1L and 2L index time to malignancy occurring (2L only among those where the malignancy occurred after 2L) |
| Prevalence and incidence of secondary malignancy | "To be calculated in the same manner as Objectives 1 and 2, adhering to rules for chronic conditions. *For nested cohort, no background prevalence is needed; for 2L cohort prevalence and incidence are needed*" | Follow-up period (1L, 2L, 3L) |
| Type of malignancy | "defined according to ICD-10-CM codes. Occurrence of malignancy to be **confirmed through the presence of at least 2 diagnosis codes occurring on separate dates. The date of the first ICD code will be used**" | Follow-up period (1L, 2L, 3L) |
| Secondary malignancy category | categorised by type, depending on data — see Table 2 | Follow-up period (1L, 2L, 3L) |
| LoT after which the malignancy occurred | "Defined according to the LoT after which the malignancy is identified" | Follow-up period (1L, 2L, 3L) |
| Top treatment sequences among those with malignancy | "Tabulation of the **top 5-10 sequences** among those with a malignancy occurring after treatment. For sensitivity analysis — this will be tabulated among those with a new malignancy occurring only after 2L" | Follow-up period (1L, 2L, 3L) |

### Table 2 — example categorisation of secondary malignancies (§7.2.4)

> "Occurrence of secondary malignancies will be categorized according to clinical
> relevance. The final groupings will be dependent on review of the data but may
> consider the following tentative groupings"

| category | examples |
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

## 7. Secondary Objective — treatment patterns and outcomes (Table 5)

> "**Secondary Objective 1:** describe treatment patterns and treatment-related outcomes
> (e.g., treatment attrition, TTNT, TTD, OS) as a proxy for effectiveness and
> tolerability by LOT, overall and by SOC, and by patient subgroups of interest"

### Treatment patterns

| outcome | definition | timing |
|---|---|---|
| Patients receiving each line | Number and percent of patients receiving each 1L, 2L, 3L, and 4L regimens | Follow-up period |
| Treatment regimens received | Categorical: regimen categories (§7.2.2) | Described for overall sequence from 1L to 4L |
| Switch between successive LOTs | **Sankey diagram** of switch between regimen categories | Follow-up period |
| Treatment attrition | Number and percent of patients who received each subsequent LOT, discontinued treatment and did not receive another, were lost to follow-up, or died | Described for overall sequence from 1L up to 4L start |
| Time from diagnosis to 1L initiation | Continuous (months); diagnosis date (included) until index date (**excluded**) | 1L index |
| Time from prior LOT to next LOT initiation | Continuous (months); among patients initiating a subsequent LOT, prior LOT start date (included) to next LOT start date (excluded) | 1L→2L, 2L→3L, 3L→4L |

### Treatment-related outcomes

| outcome | definition | timing |
|---|---|---|
| **TTNT** — time to next treatment | Time from index LOT start date (included) to the earliest between the start of the next LOT **or death** (excluded). Patients without a subsequent LOT or date of death are **censored at their follow-up end date** | During each LOT (1L, 2L, 3L) |
| **TTD** — time to treatment discontinuation | Time from index LOT start date (included) to the date of treatment discontinuation (excluded). The discontinuation date is the **earliest of** the date of treatment discontinuation (end of current LOT), initiation of the next LOT, or death. Patients without treatment discontinuation, next LOT or death are **censored at their follow-up end date**.<br>*per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new agent/qualifying SCT event is introduced* | During each LOT (1L, 2L, 3L) |
| **OS** — overall survival | Time from LOT start date (included) to date of death (excluded). Patients without a recorded date of death are censored at their follow-up end date | Follow-up period |

The build writes all three to `S_TTE`, censored at `S_PERIODS.FU_END`
(`IE_CRITERIA.md` §2). TTD's discontinuation is the union of the engine's end
reasons the footnote describes, not only `DISCONTINUATION` (`CONFORMANCE.md`,
"The LOT engine against the protocol's LOT wording"). The analyses are
restricted to the rows with `TTE_ELIGIBLE = 1`, the ≥ 3-month potential
follow-up set (`IE_CRITERIA.md` §7a).

## 8. Exploratory Objective (Table 6)

> "**Exploratory Objective 1:** assess trends in the use of SCT over time, overall and
> according to SOC. Rationale: there is internal need to understand SCT trends and
> assess prior results"

| outcome | definition | timing |
|---|---|---|
| Trends in the use of SCT | Number of patients with an SCT in 1L-4L by year, according to SOC type | Follow-up period |

## 9. Confounders and effect modifiers (§7.3.3)

> "N/A: This analysis is descriptive only."

No adjustment set is required. Nothing needs to be derived for confounding control.

## 10. Variables that need something that does not exist yet

`CODELISTS.md` §2 has the code lists behind each row.

| variable | what is missing |
|---|---|
| Charlson Comorbidity Index (Quan 2011) | the Quan 2011 ICD-9 + ICD-10 codes; the conditions, weights and hierarchy ship in `codelists/charlson_quan2011.csv` |
| Kim Frailty Index | Annex 7 — the CFI variable list and coefficients |
| All 22 key safety events | Annex 3 — the ICD-10-CM lists |
| Secondary malignancy categories | Annex 3 — ICD-10-CM lists per Table 2 category |
| Emergency visits | an agreed claims construction (`DATA_MAPPING.md` §6, Q11) |
| SOC regimen categories, and so the Sankey of switching between them | Annex 2 — regimen combinations per category |
| Lung parenchymal disease, neuropathy (as subgroup flags) | Annex 3 code lists |
