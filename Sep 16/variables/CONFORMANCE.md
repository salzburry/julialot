# Conformance of study 223926's code to the protocol

The protocol-conformance matrix: the requirements of the study protocol, the
Optum data dictionary and the Optum business rules, each set against what this
package's R and the SQL it emits do, with its status. It is the documented
evidence §7.9 asks for.

**Sources.** The non-interventional study protocol for study 223926, *Unmet
Needs and Rates of Key Background Safety Events of Interest Relating to
Treatment Use among Newly Treated and Relapsed/Refractory Patients with
Multiple Myeloma*, effective date **26 August 2026**; the Optum Clinformatics
Data Mart V9.0 data dictionary; the Optum business rules (30 August 2022); the
Optum enrolment documentation.

**Page references.** `d19` is page 19 of the protocol's document pages. `p03`
is a page of the Optum document named beside it: the data dictionary,
`optumrules` (the business rules) or `optumenrol` (the enrolment
documentation). Rule numbers are the business rules' own. Q-numbers are
`OPEN_QUESTIONS.md`.

**Status.**

- *matches* — the code does what the sentence says.
- *ambiguous* — the sentence admits more than one reading. The reading taken
  is a setting or a column, with the protocol's most specific text as its
  default, and the note names the question that records it, or says none does
  yet.
- *partially* — part of the requirement is met; the note says what is missing.
- *upstream* — the rule is applied by the cohort build (`../ndmm/`) or the LOT
  engine (`../lot/`); this package reads back and records its contract where
  it can be read.
- *deviates* — the code does something else; the note says what.
- *not implemented* — nothing produces it. *not buildable* — it waits on an
  annex.
- *not applicable* — no protocol text asks for it.

## What is not settled

- **Code lists** (`SAF-CODES-ANNEX3`, `MAL-CODES`, `STRAT-ANY-EVENT`, and the
  frailty and subgroup lists): Annexes 2, 3 and 7 are outstanding (Q15). The
  lists ship with the protocol's concepts and no codes; a run stops on an empty
  list rather than reporting zero.
- **The secondary 2L cohort** (`SEC2L-NOT-NESTED`, `X2-SEC2L-WAIVER`,
  `SENS-SEC2L`) needs a cohort and LOT run built without the other-cancer
  exclusion and the 1L index floor. Over the primary cohort, selecting it stops
  the run (`MODULES.md`, "The secondary 2L cohort needs a wide input").
- **Readings recorded as open questions**, each taken as a setting or a column:
  Q2 and Q6 (upstream), Q11 (emergency visits), Q13 (disenrolment as
  censoring), Q27 (MM-related hospitalisation), Q28 (low-confidence death
  dates), Q29 (the floor and SOC strata), Q30 (diagnosis date), Q31
  (prevalence window), Q32 (sequence reading), Q33 (discontinuation day), Q34
  (washout across boundaries), Q35 (malignancy confirmation grain) and Q36
  (Table 3's 22 rows against the list's 23, and the two dual-typed
  conditions).
- **Readings not yet put to the study team** — the *ambiguous* rows whose note
  names no question: `SAF-BASELINE-NUMERATOR`, `OUT-TTE-ANALYSIS-SET`,
  `DICT-SEVERE-INFECTION`, `HCRU-OVERLAP-EXAMPLE`, `STAT-HCRU-CI`.
- **The LOT rules the protocol does not state** — "The LOT engine against the
  protocol's LOT wording", below.
- **Upstream rules** (the *upstream* rows): the cohort build's diagnosis,
  therapy-source, death-date and X1–X4 rules, and the LOT engine's lines, are
  theirs. This package reads their recorded contract and flags and records
  what it applied.
- **Reporting gaps** in the shells — the *partially* and *deviates* rows under
  "Time to event, KM and treatment patterns" and "Analysis, disclosure and
  reporting".

## The matrix

One row per requirement. The requirement column quotes the protocol, cut
short (…) where it is long; the note says how the code meets it or what is
missing.

### Eligibility and the cohorts (§7.1, §7.2.1, §7.4)

| requirement | protocol | status | note |
|---|---|---|---|
| `PERIOD-STUDY` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) … | §7.1 body text d19; Figure 1 d21 and Figure 2 d39; synopsis … | matches | Q1 is answered: 01 Jan 2018, the body text; the figures' 2016 is a leftover. `STUDY_START` defaults to 2018-01-01. A cohort built under a different study period or 1L index floor stops the run (`read_upstream_settings()`, `BINDING_UPSTREAM_SETTINGS`); `SETTINGS_OVERRIDE=TRUE` proceeds and records it as a deviation. |
| `PERIOD-END` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) | §7.1 d19; synopsis d10 | matches | — |
| `INDEX-DEF` — The index date will be defined as the start date of a LOT regimen (i.e., 1L, 2L, 3L; each LOT has its own index date) [d19]. The 1L cohort … | §7.1 d19; §7.2.1.1 d23 | matches | — |
| `INDEX-1L-FLOOR` — all patients will be required to have initiated their first qualifying line of treatment from 01 Jan 2019 [d19]. Received an eligible or … | §7.1 d19; §7.2.1.1 d23; synopsis d10 | matches | `LOT1_INDEX_FROM` = 2019-01-01. The cohort build's `LOT1_FROM` is read back and compared; a disagreement stops the run unless overridden, and is then recorded. |
| `LOT-1L-DEF` — 1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date | §7.1 d20 | upstream | The LOT engine's line-1 induction window is 60 days inclusive of day 0 (`date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})`). |
| `LOT-2L-START-DEF` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | §7.1 d20 | upstream | The engine opens a later line on the earliest of the four candidates the protocol names and reads a 30-day window (`lot_n_induction_window_days` = 30). The LOT section below has where it goes beyond the wording. |
| `IE-I1-WINDOW` — At least one inpatient medical claim with a diagnosis code for MM in any position ... or >= 2 outpatient medical claims for MM in any … | §7.2.1.1 d22 | upstream | The study package does not re-derive I1 (`1 AS MET_I1`, EVIDENCE says the patient passed by being on the input). |
| `IE-I1-INPATIENT` — At least one inpatient medical claim with a diagnosis code for MM in any position (any ICD-9-CM=203.0x or ICD-10-CM code=C90.0x) | §7.2.1.1 d22 | upstream | One inpatient claim with a strict 203.0x/C90.0x code qualifies on its own, in any diagnosis position. |
| `IE-I1-OUTPATIENT` — >= 2 outpatient medical claims for MM in any position on the claim, on separate days within 90 days ... As data in Optum CDM is collected … | §7.2.1.1 d22 | upstream | Two outpatient claims on distinct service dates, the second at most 90 days after the first (`<= 90`, inclusive), in any position, qualify; both are bounded to the study period. |
| `IE-I2` — Adult age: Aged >=18 years at the time of MM diagnosis according to calendar year | §7.2.1.1 d22 | upstream | Age is year of diagnosis minus year of birth, i.e. calendar-year arithmetic, with the threshold >= 18 - exactly the protocol's rule. |
| `IE-I3-ON-AFTER-DX` — Received an eligible or expected treatment for MM on or after MM diagnosis (other than belantamab) | §7.2.1.1 d23 | upstream | The index scan is restricted to claims on or after the patient's `MM_DX_DT`, and belantamab codes cannot set it. |
| `IE-I3-EXCLUDED-AGENTS` — Eligible/expected treatments include MM regimens commonly used in the first line setting, excluding those restricted to later LOTs. … | §7.2.1.1 d23 | upstream | Applied by the cohort build (`NDMM_INDEX_EXCLUDED_ABBRS`) and checked here: `check_cohort_index_exclusions()` reads the build's recorded `INDEX_EXCLUDED` and stops unless panobinostat and elotuzumab (`COHORT_INDEX_EXCLUSIONS`) were barred from setting the 1L index. |
| `IE-I3-ANNEX2-LIST` — For a full list of eligible/expected MM therapies, see Annex 2 [d23]. For purposes of inclusion criteria, eligible 1L treatments will … | §7.2.1.1 d23; §7.2.2 d25 | ambiguous | Annex 2 is outstanding (Q15). When it arrives, compare it with the production `cl_mma_codelist.csv` abbreviations and bar anything it restricts to later lines through the cohort build's `NDMM_INDEX_EXCLUDED_ABBRS`. |
| `IE-I4` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date. Patients with gaps … | §7.2.1.1 d23 | matches | — |
| `IE-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death | §7.2.1.1 d23 | matches | The literal reading (`FU_EVIDENCE_RULE=claim_from_index`) excludes nobody, because the index claim is on the index date; Q5 is answered. `claim_after_index` is the strict reading. |
| `IE-N1` — Received a subsequent LOT required to qualify for a specific cohort (i.e., received a 2L treatment for 2L, 3L for 3L cohort) | §7.2.1.1 d23 | matches | — |
| `IE-N2` — Continuous enrollment (CE) for each cohort: CE of at least 12-months with medical and pharmacy benefits before the cohort index date (2L or … | §7.2.1.1 d23-d24 | matches | — |
| `IE-N3` — CE during follow-up for each cohort: at least one claim (pharmacy or medical) from index date | §7.2.1.1 d24 | matches | As `IE-I5`. |
| `NEST-2L-3L` — 2L Cohort (i.e., RRMM): subset of 1L patients who received 2+ lines of therapy; 3L Cohort (i.e., RRMM): subset of 2L patients who received … | synopsis d10; §6.1 d17; Figure 1 note [1] d21; §7.2.1 d22 | matches | — |
| `NEST-1L-BASELINE-ONLY` — Only the 1L baseline period will be used to assess study eligibility. [d19] The exclusions are stated on 'the 12-month 1L baseline period' … | §7.1 d19; §7.2.1.2 d24 | matches | — |
| `IE-X1` — Evidence of an MM oncology therapy during the 12-month 1L baseline period: >= 1 medical or pharmacy claim for any MM oncology therapy | §7.2.1.2 d24 | upstream | Any claim for an agent on `cl_mma_codelist.csv` in the 365 days before the index, medical or pharmacy, excludes. Steroids are dropped from the scan (Q6). |
| `IE-X2` — Evidence of another cancer in the 1L baseline period: Patients with either >= 1 inpatient or >=2 outpatient ICD-9-CM or ICD-10-CM codes on … | §7.2.1.2 d24 | upstream | Count (>=1 IP or >=2 OP), 'separate days' (DISTINCT event_dt), 'within 30 days' (`<= 30`) and the 1L baseline window all match the text. |
| `IE-X3` — Evidence of pregnancy: >= 1 of medical claim with a diagnosis, procedure, or revenue code indicating pregnancy or childbirth during the … | §7.2.1.2 d24 | upstream | Diagnosis, procedure (HCPCS and ICD) and revenue codes are all read, one claim excludes, and the window is the study period rather than the patient's baseline (Q23). |
| `IE-X4` — Received belantamab mafodotin (i.e., an ADC) in any LOT. Note: at the time of study belantamab mafodotin was the only ADC in use for MM | §7.2.1.2 d24 | upstream | Two halves cover the rule: the cohort build excludes belantamab before the 1L index (`NO_BELANTAMAB_PRE_LOT1`), and the engine removes every line of a patient with a belantamab episode from their first line to the end of observation (`../lot/LOT_RULES.md` §8). |
| `SEC2L-INDEX` — patients with an eligible 2L index date on or after 01 January 2020 [d39]. A sensitivity analysis in which all patients initiating an … | §7.4.1 d38-d39; §7.4.1.1 d39; synopsis d10 | matches | — |
| `SEC2L-NOT-NESTED` — a secondary, non-nested 2L+ RRMM cohort will be evaluated ... irrespective of whether their 1L initiation occurred during the primary … | §7.4.1 d38-d39; §7.4.1.1 d39 | not implemented | Needs a cohort and LOT run built without the other-cancer exclusion and the 1L index floor (`NDMM_FLAGS_ALL` retains the flags but not the cohort schema). Over the primary cohort, selecting SEC2L without `SEC2L_INPUT_IS_WIDE=TRUE` stops the run - `MODULES.md`, "The secondary 2L cohort needs a wide input". |
| `SEC2L-CRITERIA` — All inclusion/exclusion criteria will be the same as the primary cohort, with the exception of the index date. Patients in this analysis … | §7.4.1.1 d39; Figure 2 d39; §7.8.1 d49 | partially | Q7 is answered by §7.4.1.2: prior malignancy is permitted, and SEC2L's list drops X2 (`SEC2L_APPLY_OTHER_CANCER=FALSE`). It takes effect only over a wide input - `SEC2L-NOT-NESTED`. |
| `NO-4L-COHORT` — There is no 4L cohort. Only the 4L start date and 4L regimen received will be assessed. | Figure 1 note [4] d21; Table 5 d37 | matches | — |
| `ATTRITION-TABLE` — Overall patient attrition will be depicted and tabulated. [d50] Treatment attrition: Number and percent of patients who received each … | §7.8.2 d50; Table 5 d37; §7.6 d40-d41 | partially | `S_ATTRITION` opens where the cohort build's funnel ends (`IE_CRITERIA_APPLIED.md` §3). No run-level table stitches the cohort build's `NDMM_ATTRITION`, the engine's `LOT_ATTRITION` and `S_ATTRITION` into one funnel with the protocol's criterion labels. |
| `BASELINE-ELIG-WINDOW` — The baseline period will be defined as the 12-month period prior to the index date for each LOT (does not include index date). ... Only the … | §7.1 d19 | matches | — |

### Study period, index, windows and the diagnosis-anchored rows (§7.1, Tables 4–5)

| requirement | protocol | status | note |
|---|---|---|---|
| `PER-STUDY-START` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) … | s2 Synopsis and s7.1, d10/d19; Figure 1 d21; Figure 2 d39 | matches | As `PERIOD-STUDY`. |
| `PER-STUDY-END` — through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) | s7.1, d19 | matches | — |
| `IDX-DEF` — The index date will be defined as the start date of a LOT regimen (i.e., 1L, 2L, 3L; each LOT has its own index date) [d19]. The 1L cohort … | s7.1 d19; s7.2.1.1 d23; s7.8.2 d50 | matches | — |
| `IDX-1L-FLOOR` — all patients will be required to have initiated their first qualifying line of treatment from 01 Jan 2019 [d19]; Received an eligible or … | s7.1 d19; s7.2.1.1 d23 | matches | — |
| `IDX-SEC2L-FLOOR` — A separate secondary RRMM cohort in which the 2L index date is defined as 2L initiation >=01 Jan 2020 [d22]; will include patients with an … | s2 d10; s7.2 d22; s7.4.1 d38-d39; Figure 2 d39 | matches | — |
| `WIN-BASELINE` — The baseline period will be defined as the 12-month period prior to the index date for each LOT (does not include index date). Patient … | s7.1 d19; Figure 1 note [1] d21 | matches | — |
| `WIN-BASELINE-COMORB` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | s7.8.1 d44 | matches | — |
| `WIN-BASELINE-ELIG-1L-ONLY` — Only the 1L baseline period will be used to assess study eligibility [d19]. To be eligible for each 2L or 3L cohorts ... Continuous … | s7.1 d19; s7.2.1.1 d23-d24 | matches | — |
| `WIN-BASELINE-OVERLAP` — The baseline periods for 2L and 3L may overlap with time on a prior LOT, depending on the dates of treatment. | Figure 1 note [3] d21; Figure 3 d47 | matches | — |
| `WIN-BASELINE-PY` — The denominator will represent the total amount of PY present in the baseline period (i.e., 12 months prior to each LOT), irrespective of … | s7.8.1 d44 | matches | — |
| `FU-PERIOD` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | s7.1 d19 | matches | — |
| `FU-CENSOR-LOTEND-MIX` — until the end of continuous enrollment or end of study period or death, whichever occurs first [d19]; per GSK LoT algorithm definition, … | s7.1 d19; Table 4/5 footnote d35/d37; s7.3.2 d29 | matches | The engine's `*_CE_SENS` columns are the primary end capped at `ENDDATE_CE`; every event here is already gated at the cohort's own `FU_END`, which is at or before that cap, so reading them would change nothing. |
| `FU-TIME-FROM-INDEX` — Follow-up time from index \| Continuous (months); Time from index date (included) to patient's follow-up end date (included) \| Follow-up … | Table 4, d32 | matches | — |
| `FU-TIME-FROM-DX` — Follow-up time from diagnosis \| Continuous (months); Time from diagnosis date (included) to patient's follow-up end date (included) \| … | Table 4, d32 | matches | `S_PERIODS.FU_FROM_DX_DAYS/MONTHS`, diagnosis included to follow-up end included. |
| `DX-TO-1L` — Time from diagnosis to 1L initiation \| Continuous (months); Time from diagnosis date (included) until index date (excluded) \| 1L index | Table 5, d37 | matches | `S_PERIODS.DX_TO_INDEX_DAYS/MONTHS`, diagnosis included, index excluded. |
| `PRIOR-TO-NEXT-LOT` — Time from prior LOT to next LOT initiation \| Continuous (months); Defined among patients initiating a subsequent LOT as time from prior LOT … | Table 5, d37 | matches | `S_LOT_PERIODS.NEXT_LOT_DAYS/MONTHS`, among lines whose next line starts inside follow-up. |
| `LOT-ATTRIB-WINDOW` — An event will be attributed to a LOT if it occurs between the LOT's start date (included) and the start date (excluded) of a subsequent … | s7.3.2 d29; Figure 1 note [2] d21 | matches | — |
| `LOT-DISCON-DATE` — per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new … | Table 4 footnote d35; Table 5 TTD row d37; LOT_RULES s7.1 … | matches | `PROTOCOL_DISCON_DT` is the run-out day for `DISCONTINUATION` and `SCT_AUTO_CONT`, and the introduction day (engine end + 1) for `MED_ADD`, `CART_INIT`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`. Q33 asks the study team to confirm the day. |
| `TTE-TIME-ZERO-LANDMARKS` — survival probabilities (with 95% CI) at relevant landmarks, such as 6, 9, 12, 18, and 24 months after index date. Time zero, or the index … | s7.8.2, d50 | matches | — |
| `MONTHS-REPORTING` — Continuous (months); [every duration row] | Table 4 d32, Table 4 d35, Table 5 d37 ('Continuous … | matches | — |
| `MONTHS-WINDOWS` — the 12-month period prior to the index date [d19]; CE of at least 12-months [d23]; >=3 months of potential follow-up [d50] | s7.1 d19 ('12-month'), s7.2.1.1 d23 ('at least 12-months'), … | ambiguous | Q21 records the fixed-day reading. Under `MONTHS_AS=calendar` every window follows except the N2 enrolment test in `R/modules/01_cohorts.R`, which stays in days. |
| `CE-PRE-12M` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date [d23]; CE of at … | s7.2.1.1 d23; d23-d24 (2L/3L) | matches | — |
| `CE-GAP-30` — Patients with gaps in enrolment of <= 30 days are considered to be continuously enrolled | s7.2.1.1 d23 and d24 | matches | — |
| `FU-EVIDENCE-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death [d23]; CE during follow-up for each cohort: at … | s7.2.1.1 d23; d24 | matches | As `IE-I5`. |
| `LOT-1L-60D` — 1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date | s7.1 d20 | upstream | The LOT engine's 60-day window (day 0-59) is the protocol's rule. |
| `LOT-N-START-30D` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | s7.1 d20 | upstream | The next line's start used by every window here is the engine's `LOT_START_DT` of the following line. |
| `LOT-4L-ONLY-START` — There is no 4L cohort. Only the 4L start date and 4L regimen received will be assessed. [d21] Number and percent of patients receiving each … | Figure 1 note [4] d21; Table 5 d37 | matches | — |
| `WASHOUT-ACUTE-30` — To ensure that follow-up for events is not counted as an event, a >=30 day washout between acute events of the same type is required. … | s7.3.2 d30-d31; Figure 3 note d47 | matches | — |
| `CHRONIC-PRIOR-HISTORY` — Individuals with a documented history of the chronic condition prior to the treatment period will not be considered at risk and will be … | s7.8.1 d46; Table 3 note d30 | matches | — |
| `HOSP-ADMIT-ASSIGN-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). ... Hospitalizations without a recorded discharge date will … | s7.8.1 d45, d47-d48 | matches | — |
| `MALIG-TIME-FROM-DX-INDEX` — Time from diagnosis to secondary malignancy \| Continuous (months); Time from diagnosis date (included) until date of secondary malignancy … | Table 4, d35 | matches | `AFTER_INDEX` on `S_MALIGNANCY`; `MONTHS_FROM_INDEX` is NULL for a malignancy before the index; `MONTHS_FROM_DX` hangs on `S_PERIODS.DX_DT`. |
| `AGE-INDEX-CALENDAR-YEAR` — Age \| Continuous (years) ... \| At index calendar year (1L, 2L, 3L) | Table 4, d31 | matches | — |
| `YEAR-RANGES` — Year of 1L, 2L and 3L initiation \| Number and percent of patients by year, from 2019 to latest data availability. Types of 1L, 2L, 3L SOCs … | Table 4, d32 | matches | Q12 is answered: no line can start before 2019, so the shell's 2017 and 2018 columns are empty by construction. `S_SOC.LOT_START_YEAR` carries the year. |
| `RATE-UNITS` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier), depending on data availability. | s7.8 d43 | matches | — |
| `ATTRITION-PRECEDENCE` — Treatment attrition \| Number and percent of patients who received each subsequent LOT, discontinued treatment and did not receive another, … | Table 5, d37; s7.8.2 d49 | matches | — |
| `SEC2L-SAME-WINDOWS` — All primary and secondary objectives will apply to the secondary cohort. The same outcome definitions as the primary cohort will be … | s7.4.1.2 d39; s7.8.4 d50-d51; Figure 2 d39 | matches | — |

### Baseline and follow-up (§7.1, §7.3.2)

| requirement | protocol | status | note |
|---|---|---|---|
| `WIN-BASELINE-DEMO` — The baseline period will be defined as the 12-month period prior to the index date for each LOT (does not include index date). Patient … | s7.1 baseline period, d19; s7.8.1 d44 | matches | — |
| `DEMO-AGE` — Age: Continuous (years); Categorical 18-44 years / 45-64 / 65-74 years / >=75 years. Age categories may be adjusted based on age … | Table 4 Age, d31 | matches | — |
| `DEMO-SEX` — Sex: Categorical: Male / Female / Unknown. Timing: At index (1L, 2L, 3L). All baseline characteristics, except for MM diagnosis date, and … | Table 4 Sex, d31; s7.8.1 d44 | matches | Sex is read off the enrolment row that supplies race, region and insurance, with the cohort table's copy behind it. |
| `DEMO-REGION` — Region: Categorical: Midwest / South / West / Northeast / Unknown. Based on regions defined by US Census Bureau. Timing: At index (1L, 2L, … | Table 4 Region, d31 | matches | — |
| `DEMO-RACE` — Race: Categorical: Asian / Black / White / Unknown. Timing: At index (1L, 2L, 3L) | Table 4 Race, d31 | matches | — |
| `DEMO-ETHNICITY` — Ethnicity: Categorical: Hispanic or Latino / Not Hispanic or Latino / Unknown. Timing: At index (1L, 2L, 3L) | Table 4 Ethnicity, d32 | matches | — |
| `DEMO-INSURANCE` — Insurance type: Categorical: Medicare / Commercial Health Plan. Timing: At index (1L, 2L, 3L) | Table 4 Insurance type, d32 | matches | — |
| `DEMO-AT-INDEX` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | s7.8.1 d44; Table 4 timing column d31-d32 | matches | — |
| `VAR-CCI` — Charlson Comorbidity Index (CCI)(Quan 2011): Continuous; Categorical: 0,1,2,3,4,5+. CCI will be adjusted for having received a MM … | Table 4 Charlson Comorbidity Index (CCI)(Quan 2011), d32; … | partially | `charlson_quan2011.csv` ships Quan's conditions, weights and hierarchy with no codes. The ICD-9-CM and ICD-10 codes, to the full-code level the CDM stores, are still to be written, and whether C90.1-C90.3 count as 'MM diagnosis' for the adjustment is undecided. |
| `VAR-CFI` — Kim Frailty Index Score (only included pending review of data and mapping): Continuous; Categorical: CFI >= 0.25 = frail. *CFI will only be … | Table 4 Kim Frailty Index Score, d32; s7.2.3 d27 | partially | Waits on Annex 7. The intercept has to be added as an all-patient constant and the non-diagnosis features (`MEDICAL.PROC_CD` / HCPCS, RX) routed to their own source tables; the 0.25 cut-point is a setting (`FRAILTY_FRAIL_CUTOFF`). |
| `VAR-DX-YEAR` — Year of MM diagnosis: Categorical; number and percent of NDMM patients by Year of first MM diagnosis. First MM diagnosis is defined as … | Table 4 Year of MM diagnosis, d32 | ambiguous | `S_PERIODS.DX_YEAR`; which diagnosis date is Q30 (`DX_DATE_SOURCE`). |
| `VAR-FU-FROM-DX` — Follow-up time from diagnosis: Continuous (months); Time from diagnosis date (included) to patient's follow-up end date (included). Timing: … | Table 4 Follow-up time from diagnosis, d32 | matches | — |
| `VAR-FU-FROM-INDEX` — Follow-up time from index: Continuous (months); Time from index date (included) to patient's follow-up end date (included). Timing: … | Table 4 Follow-up time from index, d32 | matches | — |
| `VAR-INDEX-YEAR` — Year of 1L, 2L and 3L initiation: Categorical; Number and percent of patients by year, from 2019 to latest data availability. Timing: At … | Table 4 Year of 1L, 2L and 3L initiation, d32 | matches | `S_PERIODS.INDEX_YEAR`. |
| `VAR-SOC-BY-YEAR` — Types of 1L, 2L, 3L SOCs or classes by line: Categorical; Number and percent of patients by year, from 2017 to 2025 (or latest data … | Table 4 Types of 1L, 2L, 3L SOCs or classes by line, d32 | matches | `S_SOC.LOT_START_YEAR` beside `SOC_CATEGORY`. |
| `VAR-BASELINE-BY-SOC` — Baseline demographic and clinical characteristics will be summarized according to the 1L, 2L, and 3L cohorts. These results will be further … | s7.8.1 d44 | matches | — |
| `SOC-CATEGORIES` — Tentatively, the following SOC categories are proposed: 1L (NDMM): Quadruplets with anti-CD38 backbone / Triplets with anti-CD38 backbone / … | s7.2.2, d24-d26 | partially | The categories ship without agents: the list is filled from Annex 2 (one row per agent, role backbone or component, both scopes), and the precedence between categories is for the study team to confirm. |
| `SOC-SIZE-RULE` — regimens will potentially be grouped according to commonly utilized quadruplets, triplets, doublets, anti-CD38 backbone, and class, … | s7.2.2, d24-d25 | matches | The size arms decide a regimen whose agents are on no list row; `MATCHED` stays 0. |
| `SOC-TRANSPLANT-LINE` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | s7.2.2 d24-d26; s7.1 d20 (Start of 2L and subsequent LOTs … | matches | A NULL regimen string is coalesced before the split, so the transplant line keeps its row. |
| `STRAT-SOC` — By SOC category (described in Section 7.2.2) - Table 1: 1 \| SOC category \| All primary and secondary (SOCS within each LOT) | s7.2.3 d26; Table 1 row 1, d27 | partially | Waits on Annex 2 (Q15); Q29 asks whether the floor exempts SOC strata. |
| `STRAT-AGE` — Age >= 75 vs <75 years: Age >= 75 years to be defined as proxy for TI status during baseline, to be compared to age <75 years as proxy for … | s7.2.3 d26; Table 1 row 2, d27 | deviates | The by-age strata are written for every cohort, 3L included, and for every stratified table; Table 1 row 2 names 1L and 2L. Either they are skipped for 3L, or the report says they are produced and not published. |
| `STRAT-NEUROPATHY` — Comorbidities of interest: Baseline history of neuropathy. Table 1: 3 \| Neuropathy \| Secondary objective by LOT only, 1L and 2L outcomes | s7.2.3 d26; Table 1 row 3, d27 | partially | Waits on Annex 3 (Q15). |
| `STRAT-LUNG` — Baseline history of lung parenchymal disease (i.e., COPD, asthma, bronchiectasis, emphysema) | s7.2.3 d26 | partially | Waits on Annex 3 (Q15). |
| `STRAT-ANY-EVENT` — Baseline history of any event of interest (i.e., cardio, neuro, etc.) | s7.2.3 d26 | not buildable | The 'any event of interest' subgroup needs Annex 3's codes, which are outstanding (Q15). |
| `STRAT-FRAILTY` — 4 \| Frailty status (dependent on data use and mapping availability) \| Secondary objective by LOT only, 1L and 2L outcomes | Table 1 row 4, d27 | partially | Waits on Annex 7 (Q15). |
| `STRAT-FLOOR` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. / If there are less than 25 patients in a … | s7.2.3 d26; s7.8 d43 | matches | Applied by the release module, not by the baseline modules: `SUPPRESSION_SPEC` names the population column tested (`N_AT_RISK` for rates, `N_PATIENTS` for counts). |
| `VAR-PRIOR-TX-SCT` — [No legible Table 4 row asks for prior treatments, SCT history or MM-related clinical features as baseline characteristics; the only SCT … | Table 4 d31-d32 (legible rows); d33-d34 not legible; s6.2.3 … | not applicable | — |

### Safety events, HCRU and the counting rules (§7.3.2, §7.8.1, Table 3)

| requirement | protocol | status | note |
|---|---|---|---|
| `SAF-TABLE3-LIST` — Table 3 lists 22 conditions under Hepatologic / Renal impairment / Ocular events / Cardiovascular / Neurologic / Infectious / Other, each … | s7.3.2 Table 3, d29-d30 … | matches | — |
| `SAF-CODES-ANNEX3` — Key safety events of interest, as defined in Table 3, ... will be defined according to selected ICD-10-CM codes or healthcare visits (Annex … | s7.3.2 d29; s7.8.5 d51 | not buildable | Annex 3 outstanding (Q15); a run stops before any SQL on the empty list rather than reporting zero. |
| `SAF-DUAL-TYPE` — Toxic liver disease \| Acute or chronic ; Hepatic failure \| Acute/Chronic | Table 3, d29 | ambiguous | Two conditions the protocol types 'Acute or chronic' stop the safety module until typed. Q36. |
| `SAF-CHRONIC-SET` — Chronic events that should only be captured once, at first instance: Chronic kidney disease, Moderate to severe renal impairment or end … | Table 3, d29 (Fibrosis and cirrhosis: Chronic; … | ambiguous | Table 3's chronic set is wider than §7.8.1's list; the list's own column is the authority and the §7.8.1 names are cross-checked. Q36. |
| `SAF-CHRONIC-ONCE` — Chronic events will be assumed to be chronic in nature such that only the first occurrence with count, and no further person-time at risk … | s7.3.2 d30; s7.8.1 d46; Fig 3 note d47 | matches | — |
| `SAF-CHRONIC-PRIOR` — Individuals with a documented history of the chronic condition prior to the treatment period will not be considered at risk and will be … | s7.8.1 d46 | matches | — |
| `SAF-ACUTE-WASHOUT` — Acute events may occur more than once. To ensure that follow-up for events is not counted as an event, a >=30 day washout between acute … | s7.3.2 d30-d31; Fig 3 note d47; s7.8.1 d46 | matches | — |
| `SAF-WASHOUT-BOUNDARY` — To ensure that follow-up for events is not counted as an event, a >=30 day washout between acute events of the same type is required. | s7.3.2 d31 (washout sentence, unqualified by period); Fig 3 … | matches | One washout chain per cohort over the whole timeline; periods take the distinct events dated inside them. Q34. |
| `SAF-SAMEDAY` — Multiple claims occurring on the same day will be treated as a single event. | s7.8.1 d44 | matches | — |
| `SAF-BASELINE-NUMERATOR` — The numerator will represent the total number of qualifying events for a given outcome. Multiple claims occurring on the same day will be … | s7.8.1 d44 (baseline prevalence numerator) vs s7.3.2 … | ambiguous | The build applies the acute washout at baseline too, so two acute events of one type fewer than 30 days apart count once; the other reading counts every distinct service day. Not yet put to the study team. `VARIABLES.md` §5, Counting rules. |
| `SAF-BASELINE-DENOM` — The denominator will represent the total amount of PY present in the baseline period (i.e., 12 months prior to each LOT), irrespective of … | s7.8.1 d44 | matches | — |
| `SAF-INCIDENCE-DENOM` — Incidence of event type X = No.of new event type X occuring LOT Y treatment period / Total PY at risk | s7.8.1 d46 | matches | — |
| `SAF-ONTREATMENT-WINDOW` — An event will be attributed to a LOT if it occurs between the LOT's start date (included) and the start date (excluded) of a subsequent … | s7.3.2 d29; Fig 1 note [2] d21; Table 4 footnote d35 | upstream | 'On treatment' for both modules is `S_LOT_PERIODS`: `PERIOD_START` = `LOT_START_DT`, `PERIOD_END` = least(coalesce(next start - 1, discontinuation + 30), discontinuation + 30, `FU_END`). The next start and the discontinuation come from the engine's lines. |
| `SAF-CHRONIC-HOSP` — Hospitalizations due to chronic conditions will be considered an acute event and can be counted more than once. | Fig 3 note, d47 | matches | Every chronic `any` condition gets a `<condition> (hospitalisation)` series — its admissions, typed acute — from the confinement join. |
| `SAF-SEVERE-INFECTION-HOSP` — Severe infection resulting in hospitalization \| Acute \| Baseline and follow-up (1L, 2L, 3L) | Table 3, d30; s7.3.2 d29 ('ICD-10-CM codes or healthcare … | matches | `setting = inpatient` on the list; the condition is its admissions (business rule 14), dated at the admission; a hospitalisation-named condition not typed inpatient stops the run. |
| `SAF-AGGREGATE` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome (to be calculated as … | s7.8.1 d44; Synopsis d13 (Hepatic toxicity, Renal … | matches | An `(any in domain)` row per domain and period: the domain's own conditions' events, each patient once. |
| `SAF-CI` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome / Incidence rates of … | s7.8.1 d44 and d45 | matches | A zero-event row carries the exact Poisson limits (0 and 3.688879 / PY, scaled). |
| `SAF-COUNT-PCT` — The total count and percentage of patients experiencing each event will be summarized. | s7.8.1 d44 | matches | — |
| `SAF-STRATA` — event rates will be presented for each overall LOT and according to key subgroups of interest / Incidence rates ... in each LOT, SOC, and … | s7.8.1 d44-d45; Table 1 d27; s7.2.3 d26 | matches | — |
| `SAF-RATE-UNITS` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier), depending on data availability. | s7.8 d43 | matches | — |
| `RPT-RATE-UNIT` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier) | s7.8 d43; s7.8.1 d44-d46 | matches | The shells are labelled per 100,000; the run records `RATE_MULTIPLIER` and TFLS refuses a run scaled otherwise. |
| `HCRU-OUTCOMES` — Health care utilization outcomes include: (1) All-cause inpatient hospitalizations and (2) Emergency visits. / The number and proportion of … | s7.3.2 d31; s7.8.1 d45; Synopsis d13 | matches | — |
| `HCRU-INPATIENT-DEF` — All-cause inpatient hospitalizations ... The number of all-cause hospitalizations, and LOS will be counted according to admit and discharge … | s7.3.2 d31; s7.8.1 d47 ('counted according to admit and … | matches | — |
| `HCRU-MM-RELATED` — >=1 hospitalization related to MM (defined as having a MM diagnosis in first or second position) | s7.8.1 d45 | ambiguous | Q27, open. Both routes are selectable (`MM_HOSP_POSITION`). |
| `HCRU-ED-DEF` — (2) Emergency visits | s7.3.2 d31; s7.8.1 d45 ('an ER visit'); s7.5 d40 | ambiguous | Q11, open. `hcru.csv` is filled once the construction is chosen. |
| `HCRU-ED-ADMITTED` — (1) All-cause inpatient hospitalizations and (2) Emergency visits. | s7.3.2 d31; s7.8.1 d45 (no rule given for an ED visit that … | ambiguous | Q11, open (`ED_ADMITTED`). |
| `HCRU-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). | s7.8.1 d45 | matches | — |
| `HCRU-NO-DISCHARGE` — Hospitalizations without a recorded discharge date will be counted when summarizing the number of patients with more than 1 hospitalization … | s7.8.1 d45 | matches | — |
| `HCRU-ADMIT-ASSIGN` — In the event of a hospitalization that overlaps baseline/index windows, the assignment will be based on the admit start date. ... if a … | s7.8.1 d45 and d47-d48 | matches | — |
| `HCRU-OVERLAP-EXAMPLE` — Hospitalizations that begin before the baseline start date or end after the baseline period will be counted at the overall visit level and … | s7.8.1 d45 | ambiguous | Open: whether a stay overlapping the baseline start is a baseline event. If so, a stay whose [admit, discharge] intersects the baseline counts there (baseline only), keeping admit-date assignment between later periods. |
| `HCRU-BASELINE-STAT` — The number and proportion of patients with >=1 hospitalization from any cause, >=1 hospitalization related to MM ..., or an ER visit during … | s7.8.1 d45 | matches | — |
| `HCRU-ONTREATMENT` — Healthcare utilization events \| Same as Primary Objective 1 \| During LOT treatment period (1L, 2L, 3L) / The number of all-cause … | Table 4 d35; s7.8.1 d47; Fig 1 note [2] d21 | matches | — |
| `HCRU-CLAIM-STATUS` — Information for diagnoses of interest ... will be collected through claims-based diagnosis tables | s7.5 d40; s7.7 d42 (no rule on paid or denied claims) | not applicable | — |
| `SUPPRESS-25` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. / If there are less than 25 patients in a … | s7.2.3 d26; s7.8 d43 | matches | — |
| `TABLE4-D33-D34` — [illegible] - by sequence, the Primary Objective 1 rows for baseline safety events and healthcare utilization and the first Primary … | Table 4, d33-d34 (not legible) | ambiguous | Not legible in the protocol. The rows follow the June 2026 version's wording - `VARIABLES.md` §4. Q15, Q36. |

### Secondary malignancy (Objective 3, Table 2, Table 4)

| requirement | protocol | status | note |
|---|---|---|---|
| `MAL-OBJ3-SCOPE` — "To describe the occurrence of secondary malignancies following the receipt of therapy" ... "The occurrence of secondary malignancies will … | §6.2.1 objective 3 (d18); §7.8.1 Primary objective 3 box … | matches | — |
| `MAL-CONFIRM` — "Type of malignancy, defined according to ICD-10-CM codes. Occurrence of malignancy to be confirmed through the presence of at least 2 … | Table 4, 'Type of malignancy' row (d35) | matches | — |
| `MAL-CONFIRM-FUEND` — "Occurrence of malignancy to be confirmed through the presence of at least 2 diagnosis codes occurring on separate dates. The date of the … | Table 4 'Type of malignancy' (d35), timing "Follow-up … | ambiguous | Q35. |
| `MAL-CONFIRM-GRAIN` — "Occurrence of malignancy to be confirmed through the presence of at least 2 diagnosis codes occurring on separate dates." (the unit the … | Table 4 'Type of malignancy' (d35); Table 2 (d28) | ambiguous | Q35. |
| `MAL-CATEGORIES` — "Occurrence of secondary malignancies will be categorized according to clinical relevance. The final groupings will be dependent on review … | §7.2.4 and Table 2 (d27-d28); Table 4 'Secondary malignancy … | matches | — |
| `MAL-CODES` — "Type of malignancy, defined according to ICD-10-CM codes." ... "All study outcomes relating to diagnoses will be defined according to … | Table 4 'Type of malignancy' (d35); §7.8.5 (d51); Annex 1 … | not buildable | As `SAF-CODES-ANNEX3`. |
| `MAL-HEME-NO-MYELOMA` — "Hematological (will not include other myeloma types) \| leukemia, lymphoma" | Table 2 (d28) | matches | `check_malignancy_list()` refuses a code `mm_dx.csv` names as myeloma, before the connection is opened. |
| `MAL-CHRONIC` — "To be calculated in the same manner as Objectives 1 and 2, adhering to rules for chronic conditions." ... "Individuals with a documented … | Table 4 'Prevalence and incidence' (d35); §7.8.1 Objective … | matches | — |
| `MAL-CHRONIC-GRAIN` — "...will not be considered at risk and will be excluded from both the numerator and the person-time denominator for that condition." ... … | §7.8.1 Objective 2 (d46); §7.8.1 Objective 3 (d48-d49) | ambiguous | The one-condition reading is on the table as `(any malignancy)`; the per-category reading stays. Q35. |
| `MAL-WINDOW-INC` — "identifying any new malignancy diagnosed after the initiation of each line of therapy (LoT)" / "Follow-up period (1L, 2L, 3L)" vs "An … | §7.8.1 Objective 3 (d48); Table 4 timing (d35) vs §7.3.2 … | ambiguous | Q35. |
| `MAL-PREV-NESTED` — "*For nested cohort, no background prevalence is needed; for 2L cohort prevalence and incidence are needed" ... "1L nested cohort: because … | Table 4 footnote (d35); §7.8.1 Objective 3, 1L nested … | matches | — |
| `MAL-PREV-SEC2L-WINDOW` — "For this objective, all malignancies occurring after diagnosis but prior to 2L will be tabulated as the background prevalence, and new … | §7.4.1.2 (d39) and §7.8.4 (d51) vs §7.8.1 2L cohort bullet … | ambiguous | `MALIG_PREVALENCE_WINDOW`: `since_diagnosis` (§7.4.1.2, §7.8.4) by default, `baseline` (§7.8.1) as the alternative. Q31. |
| `MAL-PREV-METHOD` — "To be calculated in the same manner as Objectives 1 and 2, adhering to rules for chronic conditions." ... "The numerator will represent … | Table 4 'Prevalence and incidence' (d35); §7.8.1 Objective … | matches | — |
| `MAL-PREV-SEC2L-ANY` — "the baseline prevalence of any malignancy will be summarized" ... "to be calculated as individual conditions within categories, and … | §7.8.1 2L cohort bullet (d49); §7.8.1 Objective 1 (d44) | matches | An `(any malignancy)` category through the same views: first malignancy of any kind, prior history of any kind, at-risk time to the first. |
| `MAL-RATE-CI` — "Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome" ... "Incidence … | §7.8.1 Objective 1 (d44) and Objective 2 (d45); Table 4 … | matches | `RATE_LO`/`RATE_HI` on `S_MALIGNANCY_RATES`, suppressed with the rate. |
| `MAL-SEC2L-INC` — "Additionally, the incidence of new secondary malignancies occurring after 2L will be summarized by malignancy type" ... "new malignancies … | §7.8.1 2L cohort bullet (d49); §7.8.4 (d51) | matches | — |
| `MAL-TIME-DX` — "Continuous (months); Time from diagnosis date (included) until date of secondary malignancy (included)" ... "Time from first observed MM … | Table 4 'Time from diagnosis to secondary malignancy' … | matches | — |
| `MAL-TIME-INDEX` — "Continuous (months); Time from 1L or 2L index (included) until date of secondary malignancy (included) \| 1L and 2L index time to … | Table 4 'Time from 1L/2L index to secondary malignancy' … | matches | As `MALIG-TIME-FROM-DX-INDEX`. |
| `MAL-LOT-AFTER` — "Defined according to the LoT after which the malignancy is identified." | Table 4 'LoT after which where malignancy occurred' (d36) | matches | — |
| `MAL-SEQUENCES` — "Tabulation of the top 5-10 sequences among those with a malignancy occurring after treatment. For sensitivity analysis – this will be … | Table 4 'Top treatment sequences among those with … | ambiguous | `S_MALIGNANCY_SEQUENCES` carries three readings on `LINES`; nothing chosen in code. Q32. |
| `MAL-BY-SOC` — "Occurrence of secondary malignancy will be described according to SOC for each LoT" | §7.8.1 SOC and treatment sequences (d49) | matches | — |
| `MAL-AGE-STRATA` — "Age ≥ 75 vs <75 years \| All primary and secondary by LOT only, 1L and 2L safety and healthcare utilization events at baseline and … | Table 1 row 2 (d27); §7.2.3 (d26) | matches | — |
| `MAL-SUPPRESS` — "If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC)." | §7.8 (d43); §7.2.3 (d26) | matches | — |
| `X2-RULE` — "Evidence of another cancer in the 1L baseline period: Patients with either ≥ 1 inpatient or ≥2 outpatient ICD-9-CM or ICD-10-CM codes on … | §7.2.1.2 exclusion 2 (d24); §7.1 baseline definition (d19) | upstream | It applies the protocol's rule as written: one inpatient other-cancer claim in the 12-month pre-1L window, or two outpatient claims within 30 days - `IE_CRITERIA.md` §6. |
| `X2-NESTED` — "Additional eligibility criteria will be applied to the 1L cohort to create the subset cohorts of patients who received 2+ (2L cohort) and … | §7.2.1 (d22); §7.2.1.1 'Additional eligibility for primary … | matches | — |
| `X2-SEC2L-WAIVER` — "All inclusion/exclusion criteria will be the same as the primary cohort, with the exception of the index date. Patients in this analysis … | §7.4.1.1 (d39); §7.4.1.2 (d39); §7.8.1 2L cohort bullet … | upstream | The study package can waive X2 for SEC2L, but only over an input that retained the patients X2 removes with the flag NO_OTHER_CANCER_PRE_LOT1 on the row. |

### Time to event, KM and treatment patterns (§7.8.2, Table 5, Table 6)

| requirement | protocol | status | note |
|---|---|---|---|
| `OUT-TTNT` — Time-to-event outcome, Time from index LOT start date (included) to the earliest between the start of the next LOT or death (excluded). … | s7.3.2.1 Table 5, row 'Time to next treatment (TTNT)', page … | matches | — |
| `OUT-TTD` — Time-to-event outcome, Time from index LOT start date (included)) to the date of treatment discontinuation (excluded). The discontinuation … | s7.3.2.1 Table 5, row 'Time to treatment discontinuation … | matches | As `LOT-DISCON-DATE`. |
| `OUT-TTD-DISCON-DEF` — *per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new … | Table 4 footnote page d35 and Table 5 TTD footnote page d37 | matches | — |
| `OUT-TTD-SWITCH-DAY` — The discontinuation date is the earliest of the date of treatment discontinuation (end of current LOT), initiation of the next LOT, or … | Table 5 TTD row page d37 ('initiation of the next LOT') and … | matches | As `LOT-DISCON-DATE`: TTD lands on the day the agent or transplant was introduced, the same day TTNT reads. |
| `OUT-TTD-SCT-CONT` — discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new agent/qualifying SCT event is introduced | Table 5 TTD footnote page d37; s7.1 page d20 ('a stem cell … | ambiguous | `SCT_AUTO_CONT` is a discontinuation: an in-window autologous transplant is the line's consolidation and opens no line, so it is the footnote's 'all agents stopped' branch, dated on the transplant. Q33. |
| `OUT-TTD-RUNOUT-UNCONFIRMED` — The discontinuation date is the earliest of the date of treatment discontinuation (end of current LOT) ... Patients without treatment … | Table 5 TTD row page d37 ('Patients without treatment … | upstream | A run-out within 90 days of `OBS_END_DT` with no later trigger is not a `DISCONTINUATION`; the line ends `DEATH` or `STUDY_END` at the end of observation (`../lot/LOT_RULES.md` §5.3). |
| `OUT-OS` — Time-to-event outcome, Time from LOT start date (included) to date of death (excluded). Patients without a recorded date of death will be … | s7.3.2.1 Table 5, row 'Overall survival (OS)', page d38 … | matches | — |
| `OUT-FU-END` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | s7.1 page d19 | matches | — |
| `OUT-TTE-CONVENTION` — Time from index LOT start date (included) to the earliest between the start of the next LOT or death (excluded) | Table 5 pages d37-d38 ('(included) ... (excluded)' on TTNT, … | matches | — |
| `OUT-TIME-ZERO` — Time zero, or the index date, will be LOT start/LOT cohort for all TTE outcomes in the primary analyses (i.e., 1L, 2L, 3L). | s7.8.2 page d50 | matches | — |
| `OUT-TTE-COHORTS` — During each LOT (1L, 2L, 3L) ... All primary and secondary objectives will apply to the secondary cohort. The same outcome definitions as … | Table 5 timing column pages d37-d38 ('During each LOT (1L, … | matches | — |
| `OUT-TTE-ANALYSIS-SET` — Outcomes will only be assessed in the subset of patients who have >=3 months of potential follow-up (or die before 3 months) from their … | s7.8.2 page d50 | ambiguous | `S_PERIODS.TTE_ELIGIBLE` is a flag, not a filter. 'Potential follow-up' is read as calendar time in the database - index + 90 days on or before `STUDY_END`, or death before it - not observed enrolment (`IE_CRITERIA.md` §7a). The reading is not yet an open question; the alternative is one extra arm in `tte_eligible_sql()` on the enrolment end. |
| `OUT-KM-ESTIMATOR` — Treatment related time-to-event analyses (e.g., TTNT, TTD, OS) will be performed using the Kaplan-Meier (KM) product limit estimator. | s7.8.2 page d50; Synopsis page d13 | matches | — |
| `OUT-KM-MEDIAN-CI` — Median survival estimates and Brookmeyer-Crowley 95% CI will be the primary estimate reported.(Brookmeyer R 1982) | s7.8.2 page d50 | matches | — |
| `OUT-KM-LANDMARKS` — Additionally, the number and percentage of patients at risk, with an event and censored will be reported along with survival probabilities … | s7.8.2 page d50 | partially | Survival at each landmark, events and censored counts are reported (`km_prob`, `km_events`, `km_censored`); the number at risk at each landmark is not. |
| `OUT-KM-CURVES` — Results will be reported in a tabular format along with corresponding KM curves. | s7.8.2 page d50; Synopsis page d13 | partially | The dashboard draws KM curves (`plot_km()`); TFLS writes tables only. |
| `OUT-NO-LOGRANK` — No log-rank or hypotheses testing will be performed to assess for differences across strata. | s7.8.2 page d50 | matches | — |
| `OUT-TTE-BY-SOC` — by LOT, overall and by SOC ... SOC category \| All primary and secondary (SOCS within each LOT) | s6.2.2 page d18; Table 1 row 1 page d27; s7.2.2 page d24 | partially | TFLS groups regimens by `regimen_classes.csv`, which is not yet aligned with §7.2.2's categories; either align it or record the re-grouping as an Annex 2 decision. |
| `OUT-TTE-BY-SUBGROUP` — Age >= 75 vs <75 years \| All primary and secondary by LOT only ... Neuropathy \| Secondary objective by LOT only, 1L and 2L outcomes ... … | Table 1 rows 2-4 page d27; s7.2.3 page d26 | partially | The neuropathy and frailty strata wait on Annexes 3 and 7 (`COMORBID_SUBGROUPS`, `FRAILTY`, both off); until then the T5c neuropathy and frailty columns cannot be filled. |
| `OUT-TTE-FLOOR25` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. ... If there are less than 25 patients in a … | s7.2.3 page d26; s7.8 page d43 | matches | — |
| `PAT-RECEIVING-EACH-LINE` — Number and percent of patients receiving each 1L, 2L, 3L, and 4L regimens \| Follow-up period ... The proportion of each 1L through 4L … | Table 5 row 'Patients receiving each line' page d37; s7.8.2 … | matches | — |
| `PAT-REGIMEN-SEQUENCE` — Categorical: regimen categories (Section 7.2.2) \| Described for overall sequence from 1L to 4L | Table 5 row 'Treatment regimens received' page d37 | matches | — |
| `PAT-SANKEY` — Sankey diagram of switch between regimen categories ... The Sankey diagram will illustrate transitions between SOC treatments from one LOT … | Table 5 row 'Switch between successive LOTs' page d37; … | partially | `S_SWITCH` carries the transitions between regimen categories, with `(died)` and `(no further therapy)` as terminal nodes. No Sankey renderer ships, `S_SWITCH` has no percentage column, and the terminal node does not separate discontinued from censored. |
| `PAT-ATTRITION` — Number and percent of patients who received each subsequent LOT, discontinued treatment and did not receive another, were lost to … | Table 5 row 'Treatment attrition' page d37; s7.8.2 page d50 | ambiguous | `S_TX_ATTRITION` has four outcomes, in this precedence: `received_next_lot`, `died`, `discontinued_no_further`, `lost_to_followup`. `lost_to_followup` holds both patients censored at study end on therapy and patients who disenrolled on therapy. |
| `PAT-ATTRITION-STRATA` — These analyses may be stratified by SOC and patient subgroups. | s7.8.2 page d50 | matches | — |
| `PAT-DX-TO-1L` — Continuous (months); Time from diagnosis date (included) until index date (excluded) \| 1L index | Table 5 row 'Time from diagnosis to 1L initiation' page d37 | matches | As `DX-TO-1L`; the T1 shell rows read it. |
| `PAT-PRIOR-TO-NEXT` — Continuous (months); Defined among patients initiating a subsequent LOT as time from prior LOT start date (included) to next LOT start date … | Table 5 row 'Time from prior LOT to next LOT initiation' … | matches | — |
| `PAT-4L-SCOPE` — There is no 4L cohort. Only the 4L start date and 4L regimen received will be assessed. | Figure 1 note [4] page d21; Table 5 'up to 4L start' page … | matches | — |
| `PAT-SOC-BY-YEAR` — To assess use of SOC regimens/categories and SCT over time (i.e., SOC type by year) ... Types of 1L, 2L, 3L SOCs or classes by line \| … | s6.2.3 page d18; Table 4 row 'Types of 1L, 2L, 3L SOCs or … | matches | As `VAR-SOC-BY-YEAR`. |
| `EXP-SCT-BY-YEAR` — Exploratory Objective 1: assess trends in the use of SCT over time, overall and according to SOC ... Trends in the use of SCT \| Number of … | s7.3.2.2 Table 6 page d38; s6.2.3 page d18; … | matches | `S_SOC.AUTO_SCT`, `ALLO_SCT`, `CART`, `AUTO_SCT_DT`, `AUTO_SCT_YEAR`: Table 6 is a count over `S_SOC`. |
| `EXP-SCT-12M` — (no protocol text: the protocol defines no 'SCT within 12 months of 1L index' measure) | none | not applicable | — |
| `UP-LOT-START-RULE` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | s7.1 page d20 | upstream | The next-line start that TTNT, TTD, the attrition and `S_SWITCH` all use is the LOT engine's `LOT_START_DT`. |

### The LOT engine against the protocol's LOT wording (§7.1, §7.2.1.1, the Table 4 and 5 footnotes)

The protocol summarises the GSK claims-based LOT algorithm in four sentences
and leaves the algorithm itself to Annex 6. The engine in `../lot/` implements
it; `LOT-1L-60D`, `LOT-N-START-30D`, `UP-LOT-START-RULE` and `DAYS-SUPPLY`
above are its rows.

**Where they agree.** The windows agree exactly: line 1 takes the agents whose
episode starts from its start date through day 59 (`induction_window_days` =
60), a later line those from its start through day 29
(`lot_n_induction_window_days` = 30). A later line opens on the earliest of an
allogeneic transplant, an unplanned autologous transplant, a CAR-T, or an agent
not in the previous regimen (`../lot/LOT_RULES.md` §4.1); "unplanned" means
outside the previous line's own window and not a planned tandem (§6.3, §6.5).
The engine builds five lines and this package describes four (`MAX_LOT`),
which covers the protocol's 4L start date and regimen.

**Where they differ.** Each of these is a decision, not a detail, and each
changes which agents are in a line:

| the protocol says | the engine does | `LOT_RULES.md` |
|---|---|---|
| therapies "received" within the window | an agent joins a regimen only when an **episode starts** in the window. A refill under live cover extends the episode it is in, so an agent taken without a break since an earlier line never appears in a later line's regimen. The engine lists this as open | §2.3, §4.2 |
| "pre-specified MM therapies" | steroids are excluded everywhere. If Annex 2 counts dexamethasone, the regimens will not match it | §2.1 |
| within 60 / 30 days of the start | the window closes early at `REGIMEN_CUTOFF_DT`, the day before an allogeneic transplant (any line) or a CAR-T (lines 2-5; line 1 only with `apply_cart_induction_rule` off), so a regimen can be assembled over fewer days | §3.3 |
| 30 days for each subsequent line | 45 days on a CAR-T-started line (`cart_consolidation_days`); an allogeneic-started line spans one day and carries no regimen | §4.2, §4.6 |
| "a new MM agent that was not part of the previous LOT regimen" | a permissible biosimilar substitute is the same agent in both directions and never starts a line. One the patient actually received inside the window is listed and counted in the regimen under its own abbreviation; whether the pair should collapse is open | §4.4, §3.2 |
| "the earliest of" | same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED`. The date decides first; the order sets only the line's start type | §4.5 |
| CAR-T cellular therapy starts a line | a CAR-T inside line 1's 60-day window, while line 1 is still running, is part of line 1 and starts nothing | §6.4 |

**Discontinuation, and so TTD.** The footnote treats "all MM agents in the LOT
are stopped", "a new agent" and "a qualifying SCT event" as one concept. The
engine records them as different end reasons: `DISCONTINUATION` is only the
first; an added agent is `MED_ADD` or `CART_INIT`; a transplant is `SCT_AUTO`,
`SCT_ALLO`, `SCT_CART` or `SCT_AUTO_CONT`. TTD's event set is the union of all
of them (`IS_PROTOCOL_DISCON`, `R/modules/00_spine.R`), not the rows whose
`LOT_BASE_END_REASON` is `DISCONTINUATION`, and the day it falls on is
`PROTOCOL_DISCON_DT` (`LOT-DISCON-DATE`, Q33).

**The 90-day run-out confirmation**, which the protocol has no concept of. A
run-out is a discontinuation only once confirmed, by 90 days of observation
after it (`lot_discon_confirm_days`) or by a line-opening trigger. Unconfirmed,
the line ends `DEATH` or `STUDY_END` at the end of observation (§5.3). It moves
end reasons and end dates, not line counts, and most in the lines nearest the
data cutoff (`OUT-TTD-RUNOUT-UNCONFIRMED`).

**Follow-up end.** The engine's primary reading does not censor at
disenrolment (§7.6); this package ends follow-up there by default —
`FU-END-DISENROL`, `IE_CRITERIA.md` §2, Q13.

**Three rules the protocol does not state.** §4.3 (a drug of the previous
regimen never starts a line), §4.7 (a short melphalan course outside induction
does not start a line) and §4.8 (a drug returning from the previous line
joins the line it returns in, after one agent) were agreed with the study
team. They are compatible with "a new MM agent that was not part of the
previous LOT regimen" but not derivable from it: under §4.3 a same-drug
re-challenge after any gap, a three-month treatment holiday included, is one
line and not a discontinuation. They should go into Annex 6, or the protocol
and the code disagree on the record.

**Which engine built the lines.** LOT numbers built before the engine's last
rule change are superseded. `LOT_RULES_EPOCH` (`config.csv`, default
2026-09-22) refuses a LOT run that finished on or before that date, by date as
well as by status (`R/lineage.R`). It is a setting, not part of the contract,
and `S_RUN_METADATA.LOT_RULES_EPOCH` records the floor a run was accepted
against. `LOT_CODE_MD5`, blank by default, pins the exact engine code instead.

### Optum CDM V9.0 data dictionary (§7.5, §7.7, §7.8.5)

| requirement | protocol | status | note |
|---|---|---|---|
| `DICT-DATASOURCE` — The Optum CDM database will be utilized for this study. ... The database includes the following: (1) patient enrollment; (2) physician, … | §7.5 Data sources, d40; §12 References, d57 | partially | No preflight check describes the CDM tables the run reads (member_enrollment: STATE or REGION; medical: PAID_STATUS, CONF_ID, RVNU_CD, POS, PROC_CD; confinement: ICD_FLAG, DIAG1-2; rx: FILL_DT); a missing column is found by Spark mid-run. |
| `DICT-AGE` — Age \| • Continuous (years) • Categorical ○ 18-44 years ○ 45-64 ○ 65-74 years ○ ≥75 years *Age categories may be adjusted based on age … | §7.3.2 Table 4 Age, d31; §7.2.1.1 Adult age, d22 | matches | — |
| `DICT-YRDOB-ZERO` — Adult age: Aged ≥18 years at the time of MM diagnosis according to calendar year [d22] / Observations where data is missing will be dropped … | §7.2.1.1 Adult age, d22; §7.8.5, d51 | upstream | Dictionary p03 types YRDOB INT with no sentinel documented, and 614 warehouse rows carry YRDOB = 0 (`OPEN_QUESTIONS.md`, 'Also settled'). `03_demographics.R` returns a NULL age and an Unknown band outside a plausible range. |
| `DICT-SEX` — Sex \| Categorical: • Male • Female • Unknown \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Sex, d31 | matches | — |
| `DICT-REGION` — Region \| Categorical: • Midwest • South • West • Northeast • Unknown *Based on regions defined by US Census Bureau* \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Region, d31 | matches | Region comes from the STATE crosswalk to the Census Bureau regions (`REGION_SOURCE=state_crosswalk`). The deployed enrolment table has no REGION column, so `region_column` is refused before the connection is opened (Q9). |
| `DICT-RACE` — Race \| Categorical: • Asian • Black • White • Unknown \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Race, d31 | matches | — |
| `DICT-ETHNICITY` — Ethnicity \| Categorical: • Hispanic or Latino • Not Hispanic or Latino • Unknown \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Ethnicity, d32 | matches | — |
| `DICT-INSURANCE` — Insurance type \| Categorical: • Medicare • Commercial Health Plan \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Insurance type, d32 | matches | — |
| `DICT-CE` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date. Patients with gaps … | §7.2.1.1 Continuous enrollment, d23-d24 | matches | — |
| `DICT-BENEFITS` — CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date [d23] / All patients in this database have both … | §7.2.1.1 Continuous enrollment, d23; §7.5, d40 | not applicable | — |
| `DICT-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death [d23] / CE during follow-up for each cohort: at … | §7.2.1.1 Evidence of follow-up, d23; d24 | matches | — |
| `DICT-MMDX-INPATIENT` — MM diagnosis: At least one inpatient medical claim with a diagnosis code for MM in any position (any ICD-9-CM=203.0x or ICD-10-CM … | §7.2.1.1 MM diagnosis, d22 | upstream | The columns conform to V9.0: diagnoses come from `MED_DIAGNOSIS.DIAG`/`ICD_FLAG`/`FST_DT` (p09). |
| `DICT-TREATMENT` — Information for diagnoses of interest, including MM will be collected through claims-based diagnosis tables, while treatment data will … | §7.5, d40; §7.7, d42 | upstream | Every column exists in V9.0: `RX.NDC` Char 11, `FILL_DT` DATE, `DAYS_SUP` INT. |
| `DICT-SAFETY-DX` — Key safety events of interest, as defined in Table 3, were selected due to their association with some MM treatments, and will be defined … | §7.3.2, d29; Table 3, d29-d30 | matches | — |
| `DICT-SEVERE-INFECTION` — Severe infection resulting in hospitalization \| Acute \| Baseline and follow-up (1L, 2L, 3L) [d30] / ... will be defined according to … | Table 3, d30; §7.3.2, d29 | ambiguous | Read from admissions (`setting = inpatient`, `SAF-SEVERE-INFECTION-HOSP`). Present-on-admission against any inpatient claim, and CONF_ID alone against POS/TOS or CONF_ID, are readings not yet put to the study team. |
| `DICT-HOSP-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). Hospitalizations that begin before the baseline start date or … | §7.8.1 Background rates of health care utilization events, … | matches | — |
| `DICT-MMHOSP` — The number and proportion of patients with ≥1 hospitalization from any cause, ≥1 hospitalization related to MM (defined as having a MM … | §7.8.1, d45 | ambiguous | Q27, open. The table names the route it used. |
| `DICT-ED` — Health care utilization outcomes include: (1) All-cause inpatient hospitalizations and (2) Emergency visits. [d31] / ... or an ER visit … | §7.3.2, d31; Table 4 / §7.8.1, d45 | ambiguous | Q11, open. |
| `DICT-PAID_STATUS` — All study outcomes relating to diagnoses will be defined according to pre-defined code lists, as specified in Annex 3. Observations where … | §7.8.5 Data handling conventions, d51 (protocol is silent … | not applicable | — |
| `DICT-MALIG` — Type of malignancy, defined according to ICD-10-CM codes. Occurrence of malignancy to be confirmed through the presence of at least 2 … | Table 4 Type of malignancy, d35 | matches | — |
| `DICT-CCI` — Charlson Comorbidity Index (CCI)(Quan 2011) \| Continuous; Categorical: 0,1,2,3,4,5+ CCI will be adjusted for having received a MM … | Table 4 Charlson Comorbidity Index, d32 | matches | — |
| `DICT-FRAILTY` — Kim Frailty Index Score (only included pending review of data and mapping) \| Continuous; Categorical: CFI ≥ 0.25 = frail *CFI will only be … | Table 4 Kim Frailty Index Score, d32; §7.2.3, d27 | partially | Waits on Annex 7: `frailty_index()` has to route ICD-procedure, CPT/HCPCS and NDC features to `MED_PROCEDURE.PROC`, `MEDICAL.PROC_CD`/`BILL_PROC_CD` and `RX.NDC`, and add the intercept. |
| `DICT-DEATH` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | §7.1, d19; Table 5 Overall survival, d38; §7.8.5, d51 | upstream | The V9.0 dictionary has no DOD/mortality tab (tabs p01-p24 end at LU_PROCEDURE); the death date on the cohort table is the cohort build's (`DEATH-YMDOD-RULE12`). |
| `DICT-LAB` — Thrombocytopenia (dependent on data availability) \| Chronic \| Baseline and follow-up (1L, 2L, 3L) / Anemia (dependent on data availability) … | Table 3, d30; §7.7, d42 | not implemented | Thrombocytopenia and anaemia are diagnosis-defined; there is no LABRESULT-based version, though `DATA_MAPPING.md` §9 lists `lab` as an optional source. |
| `DICT-DXDATE` — Year of MM diagnosis \| Categorical; number and percent of NDMM patients by Year of first MM diagnosis First MM diagnosis is defined as … | Table 4 Year of MM diagnosis, d32 | matches | — |
| `DICT-ICD_FLAG` — any ICD-9-CM=203.0x or ICD-10-CM code=C90.0x [d22] / ICD-10-CM codes used to identify eligible diagnoses ... will be extracted [d42] | §7.2.1.1, d22 (ICD-9-CM=203.0x or ICD-10-CM code=C90.0x); … | matches | — |
| `DICT-DIAG_POSITION` — a diagnosis code for MM in any position [d22] / a MM diagnosis in first or second position [d45] | §7.2.1.1, d22; §7.8.1, d45 | matches | — |
| `DICT-CLMSEQ` — Information for diagnoses of interest, including MM will be collected through claims-based diagnosis tables | §7.5, d40 (claims-based diagnosis tables) | matches | — |
| `DICT-ENROL-TABLES` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | Table 4, d31-d32 (demographics 'At index'); §7.8.1, d44 | matches | — |
| `DICT-DOC-CLAIMS` — This procedure requires documented evidence that the study protocol has been correctly interpreted and executed. | §7.9 Quality control, d51 (documented evidence that the … | matches | This matrix is the documented evidence §7.9 asks for. |

### Optum business rules (join keys, rules 5, 12, 13, 14)

| requirement | protocol | status | note |
|---|---|---|---|
| `ENROL-STITCH-RULE10` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date. Patients with gaps … | s7.2.1.1 Inclusion Criteria, d23 (vendor rule 10, … | matches | — |
| `ENROL-ROLLUP-RULE11` — Patients with gaps in enrolment of ≤ 30 days are considered to be continuously enrolled | s7.2.1.1 d23-d24 (vendor rule 11 and table list p02 row 2) | matches | — |
| `ENROL-JOIN-KEY` — Patients with gaps in enrolment of ≤ 30 days are considered to be continuously enrolled | s7.2.1.1 d23; vendor join diagram optumrules p01 legend | matches | — |
| `CE-INDEX-DAY-N2` — Continuous enrollment (CE) for each cohort: CE of at least 12-months with medical and pharmacy benefits before the cohort index date (2L or … | s7.2.1.1 Additional eligibility for 2L and 3L, d23-d24 | deviates | N2 joins the enrolment span covering the index date itself, so a patient enrolled through the day before the index but not on it fails N2; the protocol asks only for 12 months before. Either N2 tests the span ending on or after the day before the index, or enrolment on the index date becomes its own funnel step. |
| `CE-BENEFITS-FLAG` — CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date | s7.2.1.1 d23; s7.5 d40; enrolment schema optumenrol p01-p03 | matches | Satisfied by construction: the extract carries no per-benefit flag and §7.5 says every patient has both (Q4, `DATA_MAPPING.md` §7). |
| `CE-12M-2L3L` — Continuous enrollment (CE) for each cohort: CE of at least 12-months with medical and pharmacy benefits before the cohort index date (2L or … | s7.2.1.1 d23-d24 | matches | — |
| `FU-END-DISENROL` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | s7.1 d19 | matches | — |
| `FU-CLAIM-EVIDENCE-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death | s7.2.1.1 d23 and d24 | matches | As `IE-I5`. |
| `ENROL-ATTR-AT-INDEX` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | s7.8.1 d44; Table 4 d31-d32; vendor table list p02 row 1 | matches | — |
| `INSURANCE-BUS` — Insurance type \| Categorical: Medicare, Commercial Health Plan \| At index (1L, 2L, 3L) | Table 4 d32; enrolment value distribution optumenrol p04 | matches | — |
| `REGION-NO-COLUMN` — Region \| Categorical: Midwest, South, West, Northeast, Unknown \| Based on regions defined by US Census Bureau | Table 4 d31; enrolment schema optumenrol p01-p03 | matches | — |
| `INPATIENT-RULE14-STUDY` — Hospitalizations without a recorded discharge date will be counted when summarizing the number of patients with more than 1 hospitalization … | s7.8.1 d45, d47; vendor rule 14 approach 2 (optumrules p07) | matches | — |
| `INPATIENT-RULE14-UPSTREAM` — At least one inpatient medical claim with a diagnosis code for MM in any position (any ICD-9-CM=203.0x or ICD-10-CM code=C90.0x) or ≥ 2 … | s7.2.1.1 d22; s7.2.1.2 d24; vendor rule 14 approach 1 … | upstream | The protocol never defines 'inpatient medical claim'; the cohort build applies vendor approach 1 or approach 2 - a place-of-service or type-of-service flag, or a valid confinement. |
| `HOSP-DX-RULE13` — ≥ 1 hospitalization related to MM (defined as having a MM diagnosis in first or second position) | s7.8.1 d45; vendor rule 13 (optumrules p07 row 13); join … | ambiguous | Q27, open. |
| `ED-IDENTIFICATION` — Health care utilization outcomes include: (1) All-cause inpatient hospitalizations and (2) Emergency visits. | s7.3.2 d31; s7.8.1 d45; vendor rule 14 'Additional … | ambiguous | Q11, open. |
| `CLAIM-STATUS-DENIED` — (none - the protocol and the business rules are silent on paid vs denied claims) | no protocol text; not in the vendor rules (PAID_STATUS is a … | partially | `CLAIM_STATUS=paid_only` filters only the HCRU medical read (`claim_status_sql()`); the safety, malignancy, comorbidity and follow-up-claim reads ignore it. Q25 records the reading: all claims count. |
| `DUP-SAME-DAY` — Multiple claims occurring on the same day will be treated as a single event. Events identified on claims occurring more than 1 day apart … | s7.8.1 d44; vendor table list p02 row 6 (CONFINEMENT) | matches | — |
| `DEATH-YMDOD-RULE12` — Overall survival (OS) \| Time-to-event outcome, Time from LOT start date (included) to date of death (excluded). Patients without a recorded … | Table 5 d38; s7.1 d19; vendor rule 12 and table list p03 … | upstream | Vendor: 'Date of Death (DOD) table contains month and year of death'; rule 12: 'YMDOD column from T_DOD table can be used to find death month and year'. The cohort build dates death from it. |
| `DRUG-SOURCES-RULE5` — Information for diagnoses of interest, including MM will be collected through claims-based diagnosis tables, while treatment data will … | s7.5 d40; s7.7 d42; vendor rule 5 (optumrules p05-p06) | upstream | Vendor rule 5 lists four routes: NDC+FILL_DT (T_RX), NDC+FST_DT (T_MEDICAL), PROC_CD+FST_DT (T_MEDICAL, HCPCS/CPT), PROC+FST_DT (T_MED_PROCEDURE). |
| `DAYS-SUPPLY` — 1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date ... Each subsequent LOT includes all MM … | s7.1 d19-d20 (LOT assignment per GSK 2026, Annex 6); vendor … | upstream | Neither vendor document states a days-supply rule; the protocol delegates line construction to Annex 6. |
| `QUARTERLY-TABLES` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) | s7.1 d19; s2 Synopsis d10; enrolment documentation optumenrol … | matches | — |
| `DIAG-ICDFLAG-POSITION-RULE1` — At least one inpatient medical claim with a diagnosis code for MM in any position ... ≥ 1 hospitalization related to MM (defined as having … | s7.2.1.1 d22; s7.8.1 d45; vendor rule 1 (optumrules p04-p05) | matches | — |
| `PROC-CD-VS-PROC-RULE3` — ICD-10-CM codes used to identify eligible diagnoses, and NDC codes to identify treatments will be extracted to define indexes, cohorts, and … | s7.7 d42; vendor rule 3 (optumrules p04-p05) | matches | — |
| `LABS-RULES-8-9` — Where applicable, lab values and healthcare utilization data may also be used to defined outcomes. | s7.7 d42; vendor rules 8-9 and table list p02 row 8 | not applicable | — |
| `PROVIDER-POS` — (none - the protocol names no provider-level variable) | vendor join diagram p01 (Provider Bridge / Provider); no … | not applicable | — |
| `SES-DOD-JOIN-NOTE` — Race \| Categorical: Asian, Black, White, Unknown \| At index (1L, 2L, 3L) | vendor note optumrules p03; Table 4 d31 (Race) | matches | — |
| `GAP-DAYS-PERSON-TIME` — The denominator will represent the total amount of PY present in the baseline period (i.e., 12 months prior to each LOT), irrespective of … | s7.8.1 d44 | ambiguous | Q19 records the reading: bridged gap days count as person-time. |

### Analysis, disclosure and reporting (§7.8, §7.9, Annexes)

| requirement | protocol | status | note |
|---|---|---|---|
| `STAT-RATE-UNIT` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier), depending on data availability. | s7.8 Data analysis, d43 | matches | As `RPT-RATE-UNIT`. |
| `STAT-RATE-CI` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome ... Incidence rates … | s7.8.1 Primary objective 1 and 2, d44 and d45 | matches | A Poisson interval on the log scale; a zero-event row carries the exact limits (0 and 3.688879 / PY, scaled). The protocol names no method. |
| `OUT-RATE-CI-TEXT` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome | s7.8.1, d44-d45 (95% CI reported with each rate); s7.8 d43 … | partially | The interval is written to the filled table's `LOW` and `HIGH` columns but not into the cell's text (`stat_rate()`), and no footnote names the method. |
| `STAT-RATE-CI-MALIG` — Prevalence and incidence of secondary malignancy* \| To be calculated in the same manner as Objectives 1 and 2, adhering to rules for … | Table 4, Primary Objective 3, d35; s7.8.1 d49 | matches | As `MAL-RATE-CI`. |
| `STAT-HCRU-CI` — Primary Objective 2: incidence of key safety and healthcare utilization events while on 1L, 2L, and 3L ... Incidence rates of safety events … | s7.8.1 Primary Objective 2 box, d45; d47 'Incidence of … | ambiguous | HCRU rates carry no interval (`R/modules/07_hcru.R` does not apply `rate_ci_sql()`). Either add it or drop the CI wording from the HCRU shell notes. |
| `STAT-DESC-CONT` — For continuous variables, the descriptive statistics will include means, standard deviations (SD), medians, interquartile ranges (IQR), and … | s7.8, d43 | matches | — |
| `STAT-DESC-CAT` — For categorical variables, frequencies and percentages (%) will be generated. | s7.8, d43; Synopsis d13 | matches | — |
| `STAT-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). ... For continuous variables, the descriptive statistics will … | s7.8 d43 with s7.8.1 d45/d47 (LOS) | partially | `S_HCRU_RATES` carries mean and median LOS only; SD, IQR, min and max are not computed. |
| `STAT-BASELINE-RATE` — The numerator will represent the total number of qualifying events for a given outcome. Multiple claims occurring on the same day will be … | s7.8.1 Primary objective 1, d44 | matches | — |
| `STAT-INCIDENCE-RATE` — Incidence of event type X = (No.of new event type X occuring LOT Y treatment period) / (Total PY at risk) ... Individuals with a documented … | s7.8.1 Primary Objective 2, d46 | matches | — |
| `STAT-HCRU-BASELINE` — The number and proportion of patients with >=1 hospitalization from any cause, >=1 hospitalization related to MM ..., or an ER visit during … | s7.8.1 'Background rates of health care utilization … | matches | — |
| `STAT-PVALUES` — No statistical comparisons or p-values will be reported. ... No log-rank or hypotheses testing will be performed to assess for differences … | s7.8 d43; s7.8.2 d50; Synopsis d13 | matches | — |
| `STAT-MISSING` — The number of patients with unknown/missing values for continuous and categorical variables will be reported. | s7.8, d43 | partially | The shells have Unknown rows for race, ethnicity and region, but none for sex, age band or insurance although the study tables carry Unknown there, and no 'Missing, n' row under a continuous variable. |
| `STAT-NO-IMPUTE` — Observations where data is missing will be dropped when necessary. No imputation for missing data will be performed. | s7.8.5 Data handling conventions, d51 | matches | — |
| `DISC-FLOOR-25` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC). / … | s7.8 d43; s7.2.3 d26 | matches | — |
| `DISC-SOC-EXEMPT` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC). | s7.8, d43 | ambiguous | Q29, open. Every stratum under 25 is suppressed, SOC included; an exemption is one predicate in `SUPPRESSION_SPEC`, mirrored in TFLS. |
| `DISC-FLOOR-BASIS` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted | s7.8 d43; s7.2.3 d26 | deviates | A rate is suppressed on `N_AT_RISK` - patients still at risk - rather than on the stratum's size, which is stricter than §7.8. |
| `DISC-CELL-FLOOR` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC). / … | s7.8 d43; s7.2.3 d26 | deviates | TFLS applies a count floor to cell statistics too (`TFLS_COUNT_FLOOR_STATS`), stricter than the package's denominator floor. Open: whether a cell-level rule is a data-licence requirement. |
| `DISC-REGROUP` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. | s7.2.3, d26 | matches | — |
| `DISC-COVERAGE` — Study results will be in tabular form and aggregate analyses that omits subject identification ... If there are less than 25 patients in a … | s8.1 d53; s7.8 d43 | matches | — |
| `TTE-KM` — Treatment related time-to-event analyses (e.g., TTNT, TTD, OS) will be performed using the Kaplan-Meier (KM) product limit estimator. | s7.8.2, d50; Synopsis d13 | matches | — |
| `TTE-MEDIAN-BC` — Median survival estimates and Brookmeyer-Crowley 95% CI will be the primary estimate reported.(Brookmeyer R 1982) | s7.8.2, d50 | matches | — |
| `TTE-LANDMARKS` — survival probabilities (with 95% CI) at relevant landmarks, such as 6, 9, 12, 18, and 24 months after index date | s7.8.2, d50 | matches | — |
| `TTE-NRISK-EVENTS` — the number and percentage of patients at risk, with an event and censored will be reported | s7.8.2, d50 | partially | As `OUT-KM-LANDMARKS`. |
| `TTE-TIME-ZERO-CENSOR` — Time zero, or the index date, will be LOT start/LOT cohort for all TTE outcomes ... Patients without a subsequent LOT or date of death will … | s7.8.2 d50; Table 5 d37-38 | matches | — |
| `TTE-CURVES` — Results will be reported in a tabular format along with corresponding KM curves. | s7.8.2, d50; Synopsis d13 | partially | As `OUT-KM-CURVES`. |
| `PAT-REGIMENS` — The proportion of each 1L through 4L regimens received will be described descriptively, as the count and percentage of each regimen. | s7.8.2, d49 | matches | — |
| `STRAT-SOC-AGE` — SOC category \| All primary and secondary (SOCS within each LOT). Age >= 75 vs <75 years \| All primary and secondary by LOT only, 1L and 2L … | s7.2.3 Table 1 rows 1-2, d27; s7.8.1 d44-45 | matches | — |
| `STRAT-NEURO-FRAILTY` — Neuropathy \| Secondary objective by LOT only, 1L and 2L outcomes. Frailty status (dependent on data use and mapping availability) \| … | s7.2.3 Table 1 rows 3-4, d27; s7.8.4 d50 | partially | Waits on Annex 3 (neuropathy codes) and Annex 7 (the CFI): `comorbid_subgroups.csv` and `frailty_kim2018.csv` ship without codes and both switches are off. |
| `STRAT-LUNG-ANYEVENT` — Comorbidities of interest: Baseline history of neuropathy; Baseline history of lung parenchymal disease (i.e., COPD, asthma, … | s7.2.3, d26 | not implemented | Table 1 has no lung or any-event row; §7.2.3 lists both. Open: which governs. If §7.2.3, T5c needs a lung column and an any-domain baseline flag from `S_SAFETY_COUNTED` (`PERIOD = BASELINE`). |
| `STRAT-1L2L-ONLY` — results from the primary and secondary objectives will be stratified by patient subgroups of interest among the 1L and 2L primary nested … | s7.2.3, d26 | matches | — |
| `SENS-SEC2L` — A sensitivity analysis in which all patients initiating an assumed 2L therapy on >=01 Jan 2020 will be assessed. ... all primary and … | s7.4.1.1-7.4.1.2 d39; s7.8.4 d50-51 | partially | As `SEC2L-NOT-NESTED`; the T1, T2 and T4-type shells also have no SEC2L column. |
| `SENS-MALIG-SEQ-2L` — Tabulation of the top 5-10 sequences among those with a malignancy occurring after treatment. For sensitivity analysis - this will be … | Table 4 Primary Objective 3, d36 | matches | — |
| `SIZE-3L` — Analyses for the primary 3L nested cohort may be limited or excluded pending sample size among SOCs. | s7.1 d19; Figure 1 note 1 d21; s7.6 d41 | matches | — |
| `SIZE-TABLE7` — The precision levels were computed using PASS 2019 based on the two-sided 95% Clopper-Pearson exact confidence interval for a single … | s7.6 Study size, d40-41 (Table 7) | not applicable | — |
| `EXPLOR-SCT-YEAR` — Trends in the use of SCT \| Number of patients with an SCT in 1L-4L by year, according to SOC type ... Exploratory analyses will be … | s7.3.2.2 Table 6 d38; s7.8.3 d50 | matches | As `EXP-SCT-BY-YEAR`. |
| `OUT-EXPLORER` — Results not prioritized for formal reporting will remain available for internal review only, via a fit-for-purpose Explorer Tool, and are … | s7.8, d42-43 | matches | — |
| `DATA-R-VERSION` — All data analysis will be conducted using R version 4.5.2.(R Core Team 2025) | s7.7 Data management, d41 | partially | The R version is not recorded in `S_RUN_METADATA` or the TFLS caption. |
