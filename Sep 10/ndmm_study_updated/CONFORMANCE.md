# Conformance of study 223926's code to the protocol

**Protocol:** the non-interventional study protocol for study 223926, *Unmet
Needs and Rates of Key Background Safety Events of Interest Relating to
Treatment Use among Newly Treated and Relapsed/Refractory Patients with
Multiple Myeloma*, effective date **26 August 2026**, in the copy supplied on
7 September 2026 (60 document pages).
**Reference documents:** the Optum Clinformatics Data Mart V9.0 data
dictionary, the Optum business rules (30 August 2022) and the Optum
enrolment documentation.

**Method.** Every page of the protocol was transcribed verbatim by one reader
and corrected in place by a second, and the transcript stitched into one
document. Nine independent reviews then read the transcript
against the study package's R and the SQL it emits (`tests/emit_sql.R`
captures every statement; `tests/run_duckdb.py` executes them against the
fixtures), each covering one area: eligibility; periods and windows; baseline
and follow-up; demographics, SOC and stratification; safety and HCRU;
secondary malignancy; time to event and patterns; the business rules; the
data dictionary. Every non-trivial finding was then verified by a second,
independent review against the code and, where it could be, executed. This report is the
reconciliation of those findings with the changes made in response, and is
the documented evidence §7.9 asks for.

**Counts.** 291 requirements were checked. The audits' own verdicts, before this pass's changes: 149 match, 36 ambiguous (a reading the protocol does not settle), 41 partially met, 27 upstream (applied by the cohort build, not here), 19 not implemented, 11 deviating, 8 not applicable. The **after this pass** column below says what was done about each one that was not a match.

**Verdict vocabulary.** *matches* — the code does what the sentence says.
*ambiguous* — the sentence admits more than one reading; the reading taken is
a setting with the protocol's most specific text as its default, and an open
question records it. *partially* — part of the requirement is met. *upstream*
— the rule is the cohort build's, read back and recorded here where its
contract can be read. *not implemented* — nothing produced it. *deviates* —
the code did something else. *not applicable* — no protocol text.

## What changed in this pass

Each item names the requirement id in the matrix below.

1. **Diagnosis-anchored rows** (FU-TIME-FROM-DX, DX-TO-1L, PRIOR-TO-NEXT-LOT,
   VAR-DX-YEAR, VAR-INDEX-YEAR): `S_PERIODS` carries the diagnosis date, its
   source, its year, the index year, diagnosis→index and diagnosis→follow-up
   end; `S_LOT_PERIODS` carries prior LOT→next LOT. Which diagnosis date is
   `DX_DATE_SOURCE` (Q30).
2. **Demographics at index, else nearest** (§7.8.1): the enrolment row
   covering the index, else the baseline row ending nearest it; sex from the
   same row (DEMO-SEX); age at diagnosis beside age at index.
3. **Safety counting** (SAF-SEVERE-INFECTION-HOSP, SAF-CHRONIC-HOSP,
   SAF-AGGREGATE, SAF-WASHOUT-BOUNDARY, SAF-CI): inpatient-defined
   conditions from admissions via `CONF_ID` (business rule 14); a
   hospitalisation series per chronic condition (Figure 3's note); an
   `(any in domain)` aggregate row; one washout chain over the whole timeline
   (Q34); exact limits at zero events.
4. **Secondary malignancy** (MALIG-TIME-FROM-DX-INDEX, MAL-PREV-SEC2L-WINDOW,
   MAL-PREV-SEC2L-ANY, MAL-RATE-CI, MAL-HEME-NO-MYELOMA, MAL-SEQUENCES):
   `AFTER_INDEX`; the prevalence window as a setting (Q31); an
   `(any malignancy)` aggregate; confidence limits; a myeloma-code guard on the
   list; the treatment sequences in three readings (Q32).
5. **Discontinuation date** (LOT-DISCON-DATE, OUT-TTD-SWITCH-DAY,
   OUT-TTD-SCT-CONT): the introduction day for an added agent or transplant,
   the run-out day for a run-out (Q33).
6. **SOC** (SOC-SIZE-RULE, SOC-TRANSPLANT-LINE, VAR-SOC-BY-YEAR,
   EXP-SCT-BY-YEAR): size categories hold for unlisted agents; a NULL regimen
   keeps its row; the line's start year and the engine's transplant flags and
   year are on the SOC row, so Table 4's SOC by year and Table 6's SCT by year
   by SOC are counts over `S_SOC`.
7. **The cohort build's rules, checked** (IE-I3-EXCLUDED-AGENTS,
   PERIOD-STUDY, INDEX-1L-FLOOR): the build's recorded index exclusions,
   study period and 1L index floor are read back; a build that barred
   different agents, or was built under a different period or floor, stops
   the run unless `SETTINGS_OVERRIDE` says to go on and record it.
8. **Rates per 100,000** (RPT-RATE-UNIT): the shells said per 1,000 while the
   package wrote per 100,000. The shells are relabelled, the run records
   `RATE_MULTIPLIER`, and TFLS refuses a run scaled otherwise.

## What this pass could not settle

- **Code lists** (SAF-CODES-ANNEX3, MAL-CODES, STRAT-ANY-EVENT, and the
  frailty and subgroup lists): Annexes 2, 3 and 7 are outstanding (Q15). The
  lists ship with the protocol's concepts and no codes; a run stops on an
  empty list rather than reporting zero.
- **The study period** (Q1): the text says 2018, both figures say 2016. The
  package now refuses to run over a cohort built under a different period than
  it is set to, but which period is the study team's to say.
- **Seven readings** recorded as open questions with the reading taken as a
  setting or a column: Q30 diagnosis date, Q31 prevalence window, Q32 sequence
  reading, Q33 discontinuation day, Q34 washout across boundaries, Q35
  malignancy confirmation grain, and Q36, which is Table 3's 22 rows against
  the list's 23, the two dual-typed conditions, and the unreadable pages
  33–34.
- **Upstream rules** (the `upstream` rows): the cohort build's diagnosis,
  therapy-source, death-date and X1–X4 rules are its own; this package reads
  its recorded contract and flags and records what it applied.

## The matrix

One row per requirement the reviews checked. *Audit verdict* is the review's
own, on the code as it stood when it ran; *after this pass* is what this pass
did about it. Page references are to the document pages of the transcript
(`d01`–`d60`).


### Eligibility and the cohorts (§7.1, §7.2.1, §7.4)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `PERIOD-STUDY` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) … | §7.1 body text d19; Figure 1 d21 and Figure 2 d39; synopsis … | ambiguous (P1) | **stops unless overridden** — A cohort built under a different study period or 1L index floor than this run is set to now stops the run (`BINDING_UPSTREAM_SETTINGS`, `read_upstream_settings()`); `SETTINGS_OVERRIDE=TRUE` proceeds and records it as a deviation. Q1 itself is still the study team's. |
| `PERIOD-END` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) | §7.1 d19; synopsis d10 | matches | — |
| `INDEX-DEF` — The index date will be defined as the start date of a LOT regimen (i.e., 1L, 2L, 3L; each LOT has its own index date) [d19]. The 1L cohort … | §7.1 d19; §7.2.1.1 d23 | matches | — |
| `INDEX-1L-FLOOR` — all patients will be required to have initiated their first qualifying line of treatment from 01 Jan 2019 [d19]. Received an eligible or … | §7.1 d19; §7.2.1.1 d23; synopsis d10 | partially (P1) | **stops unless overridden** — The cohort build's `lot1_from` is read back and compared with `LOT1_INDEX_FROM`; a disagreement stops the run unless overridden, and is then recorded. |
| `LOT-1L-DEF` — 1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date | §7.1 d20 | upstream (P3) | upstream — The LOT engine's line-1 induction window is 60 days inclusive of day 0 (`date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})`). Two readings the engine … |
| `LOT-2L-START-DEF` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | §7.1 d20 | upstream (P3) | upstream — The engine opens a later line on the earliest of the four candidates the protocol names and reads a 30-day window (`lot_n_induction_window_days` = 30). … |
| `IE-I1-WINDOW` — At least one inpatient medical claim with a diagnosis code for MM in any position ... or >= 2 outpatient medical claims for MM in any … | §7.2.1.1 d22 | upstream (P1) | upstream — The study package does not re-derive I1 (`1 AS MET_I1`, EVIDENCE says the patient passed by being on the input). Upstream bounds qualifying MM claims to … |
| `IE-I1-INPATIENT` — At least one inpatient medical claim with a diagnosis code for MM in any position (any ICD-9-CM=203.0x or ICD-10-CM code=C90.0x) | §7.2.1.1 d22 | upstream | upstream — One inpatient claim with a strict 203.0x/C90.0x code qualifies on its own; any diagnosis position (no DIAG_POSITION predicate on the join at :76-86); inpatient … |
| `IE-I1-OUTPATIENT` — >= 2 outpatient medical claims for MM in any position on the claim, on separate days within 90 days ... As data in Optum CDM is collected … | §7.2.1.1 d22 | upstream (P2) | upstream — Two outpatient claims on DISTINCT service dates with the next date at most 90 days later qualify (`<= 90`, inclusive), any position, both bounded to the study … |
| `IE-I2` — Adult age: Aged >=18 years at the time of MM diagnosis according to calendar year | §7.2.1.1 d22 | upstream | upstream — Age is year of diagnosis minus year of birth, i.e. calendar-year arithmetic, with the threshold >= 18 - exactly the protocol's rule. Two readings the build … |
| `IE-I3-ON-AFTER-DX` — Received an eligible or expected treatment for MM on or after MM diagnosis (other than belantamab) | §7.2.1.1 d23 | upstream | upstream — The index scan is restricted to claims on or after the patient's MM_DX_DT and belantamab codes cannot set it; the run refuses to proceed if the belantamab … |
| `IE-I3-EXCLUDED-AGENTS` — Eligible/expected treatments include MM regimens commonly used in the first line setting, excluding those restricted to later LOTs. … | §7.2.1.1 d23 | not implemented (P1) | **fixed** — `check_cohort_index_exclusions()` reads the cohort build's recorded `INDEX_EXCLUDED` and stops unless panobinostat and elotuzumab (`COHORT_INDEX_EXCLUSIONS`) were barred from setting the 1L index. |
| `IE-I3-ANNEX2-LIST` — For a full list of eligible/expected MM therapies, see Annex 2 [d23]. For purposes of inclusion criteria, eligible 1L treatments will … | §7.2.1.1 d23; §7.2.2 d25 | ambiguous (P2) | documented — Obtain Annex 2; compare it to the production cl_mma_codelist.csv abbreviations and bar anything on the list that Annex 2 restricts to later lines. |
| `IE-I4` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date. Patients with gaps … | §7.2.1.1 d23 | matches (P3) | — |
| `IE-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death | §7.2.1.1 d23 | ambiguous (P2) | documented — Ask the study team whether a claim strictly after the index is meant (Q5); if so set FU_EVIDENCE_RULE=claim_after_index. |
| `IE-N1` — Received a subsequent LOT required to qualify for a specific cohort (i.e., received a 2L treatment for 2L, 3L for 3L cohort) | §7.2.1.1 d23 | matches | — |
| `IE-N2` — Continuous enrollment (CE) for each cohort: CE of at least 12-months with medical and pharmacy benefits before the cohort index date (2L or … | §7.2.1.1 d23-d24 | matches | — |
| `IE-N3` — CE during follow-up for each cohort: at least one claim (pharmacy or medical) from index date | §7.2.1.1 d24 | ambiguous (P2) | documented — Resolve with Q5. |
| `NEST-2L-3L` — 2L Cohort (i.e., RRMM): subset of 1L patients who received 2+ lines of therapy; 3L Cohort (i.e., RRMM): subset of 2L patients who received … | synopsis d10; §6.1 d17; Figure 1 note [1] d21; §7.2.1 d22 | matches (P3) | — |
| `NEST-1L-BASELINE-ONLY` — Only the 1L baseline period will be used to assess study eligibility. [d19] The exclusions are stated on 'the 12-month 1L baseline period' … | §7.1 d19; §7.2.1.2 d24 | matches | — |
| `IE-X1` — Evidence of an MM oncology therapy during the 12-month 1L baseline period: >= 1 medical or pharmacy claim for any MM oncology therapy | §7.2.1.2 d24 | upstream (P3) | upstream — Any claim for an agent on cl_mma_codelist.csv in the 365 days before the index, on medical or pharmacy claims, excludes - matching '>= 1 medical or pharmacy … |
| `IE-X2` — Evidence of another cancer in the 1L baseline period: Patients with either >= 1 inpatient or >=2 outpatient ICD-9-CM or ICD-10-CM codes on … | §7.2.1.2 d24 | upstream (P3) | upstream — Count (>=1 IP or >=2 OP), 'separate days' (DISTINCT event_dt), 'within 30 days' (`<= 30`) and the 1L baseline window all match the text. 'Same primary tumor … |
| `IE-X3` — Evidence of pregnancy: >= 1 of medical claim with a diagnosis, procedure, or revenue code indicating pregnancy or childbirth during the … | §7.2.1.2 d24 | upstream (P2) | upstream — Diagnosis, procedure (HCPCS and ICD) and revenue codes are all read, one claim excludes, and the window is the study period rather than the patient's baseline … |
| `IE-X4` — Received belantamab mafodotin (i.e., an ADC) in any LOT. Note: at the time of study belantamab mafodotin was the only ADC in use for MM | §7.2.1.2 d24 | upstream (P3) | upstream — Two halves cover the rule: the engine removes every line of a patient with a belantamab episode anywhere from their first line to the end of observation … |
| `SEC2L-INDEX` — patients with an eligible 2L index date on or after 01 January 2020 [d39]. A sensitivity analysis in which all patients initiating an … | §7.4.1 d38-d39; §7.4.1.1 d39; synopsis d10 | matches | — |
| `SEC2L-NOT-NESTED` — a secondary, non-nested 2L+ RRMM cohort will be evaluated ... irrespective of whether their 1L initiation occurred during the primary … | §7.4.1 d38-d39; §7.4.1.1 d39 | not implemented (P2) | documented — Build the wide-cohort adapter: an NDMM cohort run without the other-cancer exclusion and without the 1L floor (NDMM_FLAGS_ALL retains the flags but not the cohort schema), run the LOT engine over it, … |
| `SEC2L-CRITERIA` — All inclusion/exclusion criteria will be the same as the primary cohort, with the exception of the index date. Patients in this analysis … | §7.4.1.1 d39; Figure 2 d39; §7.8.1 d49 | ambiguous (P3) | documented — Confirm Q7 in writing; the 1L-anchored enrolment tests fall away once the wide adapter exists. |
| `NO-4L-COHORT` — There is no 4L cohort. Only the 4L start date and 4L regimen received will be assessed. | Figure 1 note [4] d21; Table 5 d37 | matches | — |
| `ATTRITION-TABLE` — Overall patient attrition will be depicted and tabulated. [d50] Treatment attrition: Number and percent of patients who received each … | §7.8.2 d50; Table 5 d37; §7.6 d40-d41 | partially (P3) | documented — Add a run-level reconciliation that stitches NDMM_ATTRITION (recomputed under the protocol's floor and start), LOT_ATTRITION and S_ATTRITION into one funnel with the protocol's criterion labels; … |
| `BASELINE-ELIG-WINDOW` — The baseline period will be defined as the 12-month period prior to the index date for each LOT (does not include index date). ... Only the … | §7.1 d19 | matches | — |

### Study period, index, windows and the diagnosis-anchored rows (§7.1, Tables 4–5)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `PER-STUDY-START` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) … | s2 Synopsis and s7.1, d10/d19; Figure 1 d21; Figure 2 d39 | ambiguous (P1) | **stops unless overridden** — As PERIOD-STUDY. |
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
| `FU-CENSOR-LOTEND-MIX` — until the end of continuous enrollment or end of study period or death, whichever occurs first [d19]; per GSK LoT algorithm definition, … | s7.1 d19; Table 4/5 footnote d35/d37; s7.3.2 d29 | partially (P2) | **no change needed** — The engine's `*_CE_SENS` columns are the primary end capped at `ENDDATE_CE`; every event here is already gated at the cohort's own `FU_END`, which is at or before that cap, so reading them would change nothing. Documented. |
| `FU-TIME-FROM-INDEX` — Follow-up time from index \| Continuous (months); Time from index date (included) to patient's follow-up end date (included) \| Follow-up … | Table 4, d32 | matches | — |
| `FU-TIME-FROM-DX` — Follow-up time from diagnosis \| Continuous (months); Time from diagnosis date (included) to patient's follow-up end date (included) \| … | Table 4, d32 | not implemented (P2) | **fixed** — `S_PERIODS.FU_FROM_DX_DAYS/MONTHS`, diagnosis included to follow-up end included. |
| `DX-TO-1L` — Time from diagnosis to 1L initiation \| Continuous (months); Time from diagnosis date (included) until index date (excluded) \| 1L index | Table 5, d37 | not implemented (P2) | **fixed** — `S_PERIODS.DX_TO_INDEX_DAYS/MONTHS`, diagnosis included, index excluded. |
| `PRIOR-TO-NEXT-LOT` — Time from prior LOT to next LOT initiation \| Continuous (months); Defined among patients initiating a subsequent LOT as time from prior LOT … | Table 5, d37 | not implemented (P2) | **fixed** — `S_LOT_PERIODS.NEXT_LOT_DAYS/MONTHS`, among lines whose next line starts inside follow-up. |
| `LOT-ATTRIB-WINDOW` — An event will be attributed to a LOT if it occurs between the LOT's start date (included) and the start date (excluded) of a subsequent … | s7.3.2 d29; Figure 1 note [2] d21 | matches | — |
| `LOT-DISCON-DATE` — per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new … | Table 4 footnote d35; Table 5 TTD row d37; LOT_RULES s7.1 … | deviates (P3) | **fixed** — `PROTOCOL_DISCON_DT` is the run-out day for `DISCONTINUATION` and `SCT_AUTO_CONT`, and the introduction day (engine end + 1) for `MED_ADD`, `CART_INIT`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`. Q33. |
| `OUT-TTNT` — Time to next treatment (TTNT) \| Time-to-event outcome, Time from index LOT start date (included) to the earliest between the start of the … | Table 5, d37 | matches | — |
| `OUT-TTD` — Time to treatment discontinuation (TTD) \| ... The discontinuation date is the earliest of the date of treatment discontinuation (end of … | Table 5, d37 | partially | **fixed** — As LOT-DISCON-DATE. |
| `OUT-OS` — Overall survival (OS) \| Time-to-event outcome, Time from LOT start date (included) to date of death (excluded). Patients without a recorded … | Table 5, d38 | matches | — |
| `TTE-ANALYSIS-SET` — Outcomes will only be assessed in the subset of patients who have >=3 months of potential follow-up (or die before 3 months) from their … | s7.8.2, d50 | matches | — |
| `TTE-TIME-ZERO-LANDMARKS` — survival probabilities (with 95% CI) at relevant landmarks, such as 6, 9, 12, 18, and 24 months after index date. Time zero, or the index … | s7.8.2, d50 | matches | — |
| `MONTHS-REPORTING` — Continuous (months); [every duration row] | Table 4 d32, Table 4 d35, Table 5 d37 ('Continuous … | matches | — |
| `MONTHS-WINDOWS` — the 12-month period prior to the index date [d19]; CE of at least 12-months [d23]; >=3 months of potential follow-up [d50] | s7.1 d19 ('12-month'), s7.2.1.1 d23 ('at least 12-months'), … | ambiguous (P3) | documented — Confirm with the sponsor; if calendar months are chosen, route ce_pre in 01_cohorts.R through window_start_sql() as well. |
| `CE-PRE-12M` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date [d23]; CE of at … | s7.2.1.1 d23; d23-d24 (2L/3L) | matches | — |
| `CE-GAP-30` — Patients with gaps in enrolment of <= 30 days are considered to be continuously enrolled | s7.2.1.1 d23 and d24 | matches | — |
| `FU-EVIDENCE-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death [d23]; CE during follow-up for each cohort: at … | s7.2.1.1 d23; d24 | ambiguous (P2) | documented — Ask the sponsor whether 'from index date' means strictly after; if so set FU_EVIDENCE_RULE=claim_after_index. |
| `LOT-1L-60D` — 1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date | s7.1 d20 | upstream | upstream — The LOT engine's 60-day window (day 0-59) is the protocol's rule; BUILD_DELTA.md section 1 marks it 'matches' and that is correct. Two engine refinements the … |
| `LOT-N-START-30D` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | s7.1 d20 | upstream (P3) | upstream — The next line's start used by every window here is the engine's LOT_START_DT of the following line (executed: P5 line 4 sees line 5's 2023-01-15 although … |
| `LOT-4L-ONLY-START` — There is no 4L cohort. Only the 4L start date and 4L regimen received will be assessed. [d21] Number and percent of patients receiving each … | Figure 1 note [4] d21; Table 5 d37 | matches | — |
| `WASHOUT-ACUTE-30` — To ensure that follow-up for events is not counted as an event, a >=30 day washout between acute events of the same type is required. … | s7.3.2 d30-d31; Figure 3 note d47 | matches | — |
| `CHRONIC-PRIOR-HISTORY` — Individuals with a documented history of the chronic condition prior to the treatment period will not be considered at risk and will be … | s7.8.1 d46; Table 3 note d30 | matches | — |
| `HOSP-ADMIT-ASSIGN-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). ... Hospitalizations without a recorded discharge date will … | s7.8.1 d45, d47-d48 | matches | — |
| `MALIG-TIME-FROM-DX-INDEX` — Time from diagnosis to secondary malignancy \| Continuous (months); Time from diagnosis date (included) until date of secondary malignancy … | Table 4, d35 | partially (P3) | **fixed** — `AFTER_INDEX` on `S_MALIGNANCY`; `MONTHS_FROM_INDEX` is NULL for a malignancy before the index; `MONTHS_FROM_DX` hangs on `S_PERIODS.DX_DT`. |
| `AGE-INDEX-CALENDAR-YEAR` — Age \| Continuous (years) ... \| At index calendar year (1L, 2L, 3L) | Table 4, d31 | matches | — |
| `YEAR-RANGES` — Year of 1L, 2L and 3L initiation \| Number and percent of patients by year, from 2019 to latest data availability. Types of 1L, 2L, 3L SOCs … | Table 4, d32 | ambiguous (P3) | documented — Ask whether 2017 is a leftover from the June version (whose floor was 2017). |
| `RATE-UNITS` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier), depending on data availability. | s7.8 d43 | matches | — |
| `ATTRITION-PRECEDENCE` — Treatment attrition \| Number and percent of patients who received each subsequent LOT, discontinued treatment and did not receive another, … | Table 5, d37; s7.8.2 d49 | matches | — |
| `SEC2L-SAME-WINDOWS` — All primary and secondary objectives will apply to the secondary cohort. The same outcome definitions as the primary cohort will be … | s7.4.1.2 d39; s7.8.4 d50-d51; Figure 2 d39 | matches | — |
| `CLAIM-VERSION-FLIP` — VERSION_DIFF.md section 1 claims: 'Every duration in the tables had its endpoint conventions reversed' between June 16 and Aug 26 2026, … | Table 4 d32, d35; Table 5 d37-d38; s7.3.2 d29 - versus the … | matches (P3) | — |

### Baseline and follow-up (§7.1, §7.3.2)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `WIN-BASELINE-DEMO` — The baseline period will be defined as the 12-month period prior to the index date for each LOT (does not include index date). Patient … | s7.1 baseline period, d19; s7.8.1 d44 | matches | — |
| `DEMO-AGE` — Age: Continuous (years); Categorical 18-44 years / 45-64 / 65-74 years / >=75 years. Age categories may be adjusted based on age … | Table 4 Age, d31 | matches | — |
| `DEMO-SEX` — Sex: Categorical: Male / Female / Unknown. Timing: At index (1L, 2L, 3L). All baseline characteristics, except for MM diagnosis date, and … | Table 4 Sex, d31; s7.8.1 d44 | deviates (P3) | **fixed** — Sex is read off the enrolment row that supplies race, region and insurance, with the cohort table's copy behind it. |
| `DEMO-REGION` — Region: Categorical: Midwest / South / West / Northeast / Unknown. Based on regions defined by US Census Bureau. Timing: At index (1L, 2L, … | Table 4 Region, d31 | matches | — |
| `DEMO-RACE` — Race: Categorical: Asian / Black / White / Unknown. Timing: At index (1L, 2L, 3L) | Table 4 Race, d31 | matches | — |
| `DEMO-ETHNICITY` — Ethnicity: Categorical: Hispanic or Latino / Not Hispanic or Latino / Unknown. Timing: At index (1L, 2L, 3L) | Table 4 Ethnicity, d32 | matches | — |
| `DEMO-INSURANCE` — Insurance type: Categorical: Medicare / Commercial Health Plan. Timing: At index (1L, 2L, 3L) | Table 4 Insurance type, d32 | matches | — |
| `DEMO-AT-INDEX` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | s7.8.1 d44; Table 4 timing column d31-d32 | matches | — |
| `VAR-CCI` — Charlson Comorbidity Index (CCI)(Quan 2011): Continuous; Categorical: 0,1,2,3,4,5+. CCI will be adjusted for having received a MM … | Table 4 Charlson Comorbidity Index (CCI)(Quan 2011), d32; … | partially (P1) | documented — Author charlson_quan2011.csv from Quan 2011 Table 1 (ICD-9-CM and ICD-10) enumerated to the full-code level the CDM stores, and decide whether C90.1-C90.3 count as 'MM diagnosis' for the adjustment; … |
| `VAR-CFI` — Kim Frailty Index Score (only included pending review of data and mapping): Continuous; Categorical: CFI >= 0.25 = frail. *CFI will only be … | Table 4 Kim Frailty Index Score, d32; s7.2.3 d27 | partially (P2) | documented — When Annex 7 arrives: add the intercept as an all-patient constant and route non-diagnosis features (MEDICAL.PROC_CD / HCPCS, RX) to their own source tables; keep the 0.25 cut-point as a setting. |
| `VAR-DX-YEAR` — Year of MM diagnosis: Categorical; number and percent of NDMM patients by Year of first MM diagnosis. First MM diagnosis is defined as … | Table 4 Year of MM diagnosis, d32 | ambiguous (P2) | **fixed, reading open** — `S_PERIODS.DX_YEAR`; which diagnosis date is Q30 (`DX_DATE_SOURCE`). |
| `VAR-FU-FROM-DX` — Follow-up time from diagnosis: Continuous (months); Time from diagnosis date (included) to patient's follow-up end date (included). Timing: … | Table 4 Follow-up time from diagnosis, d32 | matches | — |
| `VAR-FU-FROM-INDEX` — Follow-up time from index: Continuous (months); Time from index date (included) to patient's follow-up end date (included). Timing: … | Table 4 Follow-up time from index, d32 | matches | — |
| `VAR-INDEX-YEAR` — Year of 1L, 2L and 3L initiation: Categorical; Number and percent of patients by year, from 2019 to latest data availability. Timing: At … | Table 4 Year of 1L, 2L and 3L initiation, d32 | partially (P3) | **fixed** — `S_PERIODS.INDEX_YEAR`. |
| `VAR-SOC-BY-YEAR` — Types of 1L, 2L, 3L SOCs or classes by line: Categorical; Number and percent of patients by year, from 2017 to 2025 (or latest data … | Table 4 Types of 1L, 2L, 3L SOCs or classes by line, d32 | not implemented (P3) | **fixed** — `S_SOC.LOT_START_YEAR` beside `SOC_CATEGORY`. |
| `VAR-BASELINE-BY-SOC` — Baseline demographic and clinical characteristics will be summarized according to the 1L, 2L, and 3L cohorts. These results will be further … | s7.8.1 d44 | matches | — |
| `SOC-CATEGORIES` — Tentatively, the following SOC categories are proposed: 1L (NDMM): Quadruplets with anti-CD38 backbone / Triplets with anti-CD38 backbone / … | s7.2.2, d24-d26 | partially (P2) | documented — Fill the list from Annex 2 (one row per agent, role backbone/component, both scopes) and add the precedence rule to OPEN_QUESTIONS/VARIABLES.md for the study team to confirm. |
| `SOC-SIZE-RULE` — regimens will potentially be grouped according to commonly utilized quadruplets, triplets, doublets, anti-CD38 backbone, and class, … | s7.2.2, d24-d25 | partially (P2) | **fixed** — The size arms decide a regimen whose agents are on no list row; `MATCHED` stays 0. |
| `SOC-TRANSPLANT-LINE` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | s7.2.2 d24-d26; s7.1 d20 (Start of 2L and subsequent LOTs … | deviates (P2) | **fixed** — A NULL regimen string is coalesced before the split, so the transplant line keeps its row. |
| `STRAT-SOC` — By SOC category (described in Section 7.2.2) - Table 1: 1 \| SOC category \| All primary and secondary (SOCS within each LOT) | s7.2.3 d26; Table 1 row 1, d27 | partially (P2) | documented — Q15 (Annex 2); Q29 (open) asks whether the <25 floor exempts SOC strata |
| `STRAT-AGE` — Age >= 75 vs <75 years: Age >= 75 years to be defined as proxy for TI status during baseline, to be compared to age <75 years as proxy for … | s7.2.3 d26; Table 1 row 2, d27 | deviates (P3) | documented — Skip the by_age pass for the 3L cohort (and, if the row-2 wording is read narrowly, for S_MALIGNANCY_RATES and S_TX_ATTRITION), or document that the extra strata are produced but not published. |
| `STRAT-NEUROPATHY` — Comorbidities of interest: Baseline history of neuropathy. Table 1: 3 \| Neuropathy \| Secondary objective by LOT only, 1L and 2L outcomes | s7.2.3 d26; Table 1 row 3, d27 | partially (P2) | documented — Q15 (open, Annex 3) |
| `STRAT-LUNG` — Baseline history of lung parenchymal disease (i.e., COPD, asthma, bronchiectasis, emphysema) | s7.2.3 d26 | partially (P2) | documented — Q15 (open, Annex 3) |
| `STRAT-ANY-EVENT` — Baseline history of any event of interest (i.e., cardio, neuro, etc.) | s7.2.3 d26 | not implemented (P2) | **not buildable** — The 'any event of interest' subgroup needs Annex 3's codes, which are outstanding (Q15). |
| `STRAT-FRAILTY` — 4 \| Frailty status (dependent on data use and mapping availability) \| Secondary objective by LOT only, 1L and 2L outcomes | Table 1 row 4, d27 | partially (P2) | documented — Q15 (open, Annex 7) |
| `STRAT-FLOOR` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. / If there are less than 25 patients in a … | s7.2.3 d26; s7.8 d43 | upstream | upstream — Applied by the release module, not by the baseline modules: SUPPRESSION_SPEC names the population column (N_AT_RISK for rates, N_PATIENTS for counts) tested … |
| `VAR-PRIOR-TX-SCT` — [No legible Table 4 row asks for prior treatments, SCT history or MM-related clinical features as baseline characteristics; the only SCT … | Table 4 d31-d32 (legible rows); d33-d34 unreadable; s6.2.3 … | not applicable | — |
| `DOC-CLAIMS` — [Delivery documents checked against the code] | VARIABLES.md s2/s4/s10, CODELISTS.md, OPEN_QUESTIONS.md, … | partially (P3) | documented — Update VARIABLES.md s2, add Q30 to OPEN_QUESTIONS.md (or drop the citation), and re-point the TFLS diagnosis-year and time-from-diagnosis rows at S_PERIODS. |

### Safety events, HCRU and the counting rules (§7.3.2, §7.8.1, Table 3)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `SAF-TABLE3-LIST` — Table 3 lists 22 conditions under Hepatologic / Renal impairment / Ocular events / Cardiovascular / Neurologic / Infectious / Other, each … | s7.3.2 Table 3, d29-d30 (image-verified crops/d29_t3.png, … | matches | — |
| `SAF-CODES-ANNEX3` — Key safety events of interest, as defined in Table 3, ... will be defined according to selected ICD-10-CM codes or healthcare visits (Annex … | s7.3.2 d29; s7.8.5 d51 | not implemented (P1) | **not buildable** — Annex 3 outstanding (Q15); a run stops before any SQL on the empty list rather than reporting zero. |
| `SAF-DUAL-TYPE` — Toxic liver disease \| Acute or chronic ; Hepatic failure \| Acute/Chronic | Table 3, d29 | ambiguous (P1) | **documented** — Two conditions the protocol types 'Acute or chronic' stop the safety module until typed. Q36. |
| `SAF-CHRONIC-SET` — Chronic events that should only be captured once, at first instance: Chronic kidney disease, Moderate to severe renal impairment or end … | Table 3, d29 (Fibrosis and cirrhosis: Chronic; … | ambiguous (P2) | **documented** — Table 3's chronic set is wider than §7.8.1's list; the list's own column is the authority and the §7.8.1 names are cross-checked. Q36. |
| `SAF-CHRONIC-ONCE` — Chronic events will be assumed to be chronic in nature such that only the first occurrence with count, and no further person-time at risk … | s7.3.2 d30; s7.8.1 d46; Fig 3 note d47 | matches | — |
| `SAF-CHRONIC-PRIOR` — Individuals with a documented history of the chronic condition prior to the treatment period will not be considered at risk and will be … | s7.8.1 d46 | matches | — |
| `SAF-ACUTE-WASHOUT` — Acute events may occur more than once. To ensure that follow-up for events is not counted as an event, a >=30 day washout between acute … | s7.3.2 d30-d31; Fig 3 note d47; s7.8.1 d46 | matches | — |
| `SAF-WASHOUT-BOUNDARY` — To ensure that follow-up for events is not counted as an event, a >=30 day washout between acute events of the same type is required. | s7.3.2 d31 (washout sentence, unqualified by period); Fig 3 … | partially (P1) | **fixed** — One washout chain per cohort over the whole timeline; periods take the distinct events dated inside them. Q34. |
| `SAF-SAMEDAY` — Multiple claims occurring on the same day will be treated as a single event. | s7.8.1 d44 | matches | — |
| `SAF-BASELINE-NUMERATOR` — The numerator will represent the total number of qualifying events for a given outcome. Multiple claims occurring on the same day will be … | s7.8.1 d44 (baseline prevalence numerator) vs s7.3.2 … | ambiguous (P2) | documented — Ask whether 'qualifying events' at baseline means washout-applied events (current) or every distinct service day; correct BUILD_DELTA.md s7 item 1 to say what the code does. |
| `SAF-BASELINE-DENOM` — The denominator will represent the total amount of PY present in the baseline period (i.e., 12 months prior to each LOT), irrespective of … | s7.8.1 d44 | matches | — |
| `SAF-INCIDENCE-DENOM` — Incidence of event type X = No.of new event type X occuring LOT Y treatment period / Total PY at risk | s7.8.1 d46 | matches | — |
| `SAF-ONTREATMENT-WINDOW` — An event will be attributed to a LOT if it occurs between the LOT's start date (included) and the start date (excluded) of a subsequent … | s7.3.2 d29; Fig 1 note [2] d21; Table 4 footnote d35 | upstream | upstream — 'On treatment' for both modules is S_LOT_PERIODS: PERIOD_START = LOT_START_DT, PERIOD_END = least(coalesce(next start - 1, discon + 30), discon + 30, FU_END) … |
| `SAF-CHRONIC-HOSP` — Hospitalizations due to chronic conditions will be considered an acute event and can be counted more than once. | Fig 3 note, d47 | not implemented (P1) | **fixed** — Every chronic `any` condition gets a `<condition> (hospitalisation)` series — its admissions, typed acute — from the confinement join. |
| `SAF-SEVERE-INFECTION-HOSP` — Severe infection resulting in hospitalization \| Acute \| Baseline and follow-up (1L, 2L, 3L) | Table 3, d30; s7.3.2 d29 ('ICD-10-CM codes or healthcare … | not implemented (P1) | **fixed** — `setting = inpatient` on the list; the condition is its admissions (business rule 14), dated at the admission; a hospitalisation-named condition not typed inpatient stops the run. |
| `SAF-AGGREGATE` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome (to be calculated as … | s7.8.1 d44; Synopsis d13 (Hepatic toxicity, Renal … | not implemented (P2) | **fixed** — An `(any in domain)` row per domain and period: the domain's own conditions' events, each patient once. |
| `SAF-CI` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome / Incidence rates of … | s7.8.1 d44 and d45 | partially (P3) | **fixed** — A zero-event row carries the exact Poisson limits (0 and 3.688879 / PY, scaled). |
| `SAF-COUNT-PCT` — The total count and percentage of patients experiencing each event will be summarized. | s7.8.1 d44 | matches | — |
| `SAF-STRATA` — event rates will be presented for each overall LOT and according to key subgroups of interest / Incidence rates ... in each LOT, SOC, and … | s7.8.1 d44-d45; Table 1 d27; s7.2.3 d26 | matches | — |
| `SAF-RATE-UNITS` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier), depending on data availability. | s7.8 d43 | matches | — |
| `RPT-RATE-UNIT` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier) | s7.8 d43; s7.8.1 d44-d46 | deviates (P1) | **fixed** — Shells relabelled per 100,000; the run records `RATE_MULTIPLIER` and TFLS refuses a run scaled otherwise. |
| `HCRU-OUTCOMES` — Health care utilization outcomes include: (1) All-cause inpatient hospitalizations and (2) Emergency visits. / The number and proportion of … | s7.3.2 d31; s7.8.1 d45; Synopsis d13 | matches | — |
| `HCRU-INPATIENT-DEF` — All-cause inpatient hospitalizations ... The number of all-cause hospitalizations, and LOS will be counted according to admit and discharge … | s7.3.2 d31; s7.8.1 d47 ('counted according to admit and … | matches (P3) | — |
| `HCRU-MM-RELATED` — >=1 hospitalization related to MM (defined as having a MM diagnosis in first or second position) | s7.8.1 d45 | ambiguous (P2) | documented — Get the sponsor's answer to Q27; keep both routes selectable. |
| `HCRU-ED-DEF` — (2) Emergency visits | s7.3.2 d31; s7.8.1 d45 ('an ER visit'); s7.5 d40 | ambiguous (P2) | documented — Sponsor decision on the construction; then fill hcru.csv. |
| `HCRU-ED-ADMITTED` — (1) All-cause inpatient hospitalizations and (2) Emergency visits. | s7.3.2 d31; s7.8.1 d45 (no rule given for an ED visit that … | ambiguous (P2) | documented — Q11 (second half) - still open |
| `HCRU-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). | s7.8.1 d45 | matches | — |
| `HCRU-NO-DISCHARGE` — Hospitalizations without a recorded discharge date will be counted when summarizing the number of patients with more than 1 hospitalization … | s7.8.1 d45 | matches | — |
| `HCRU-ADMIT-ASSIGN` — In the event of a hospitalization that overlaps baseline/index windows, the assignment will be based on the admit start date. ... if a … | s7.8.1 d45 and d47-d48 | matches | — |
| `HCRU-OVERLAP-EXAMPLE` — Hospitalizations that begin before the baseline start date or end after the baseline period will be counted at the overall visit level and … | s7.8.1 d45 | ambiguous (P2) | documented — Ask whether a stay overlapping the baseline start is a baseline event; if so, count a stay whose [admit, discharge] intersects the baseline (baseline only), keeping admit-date assignment between … |
| `HCRU-BASELINE-STAT` — The number and proportion of patients with >=1 hospitalization from any cause, >=1 hospitalization related to MM ..., or an ER visit during … | s7.8.1 d45 | matches | — |
| `HCRU-ONTREATMENT` — Healthcare utilization events \| Same as Primary Objective 1 \| During LOT treatment period (1L, 2L, 3L) / The number of all-cause … | Table 4 d35; s7.8.1 d47; Fig 1 note [2] d21 | matches | — |
| `HCRU-CLAIM-STATUS` — Information for diagnoses of interest ... will be collected through claims-based diagnosis tables | s7.5 d40; s7.7 d42 (no rule on paid or denied claims) | not applicable | — |
| `SUPPRESS-25` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. / If there are less than 25 patients in a … | s7.2.3 d26; s7.8 d43 | matches (P3) | — |
| `TABLE4-D33-D34` — [illegible] - by sequence, the Primary Objective 1 rows for baseline safety events and healthcare utilization and the first Primary … | Table 4, d33-d34 (source images corrupted; see protocol.md … | ambiguous | **documented** — Pages 33–34 are unreadable in the supplied copy; their rows are mapped from the June version. Q36. |

### Secondary malignancy (Objective 3, Table 2, Table 4)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `MAL-OBJ3-SCOPE` — "To describe the occurrence of secondary malignancies following the receipt of therapy" ... "The occurrence of secondary malignancies will … | §6.2.1 objective 3 (d18); §7.8.1 Primary objective 3 box … | matches | — |
| `MAL-CONFIRM` — "Type of malignancy, defined according to ICD-10-CM codes. Occurrence of malignancy to be confirmed through the presence of at least 2 … | Table 4, 'Type of malignancy' row (d35) | matches | — |
| `MAL-CONFIRM-FUEND` — "Occurrence of malignancy to be confirmed through the presence of at least 2 diagnosis codes occurring on separate dates. The date of the … | Table 4 'Type of malignancy' (d35), timing "Follow-up … | ambiguous (P3) | **documented** — Q35. |
| `MAL-CONFIRM-GRAIN` — "Occurrence of malignancy to be confirmed through the presence of at least 2 diagnosis codes occurring on separate dates." (the unit the … | Table 4 'Type of malignancy' (d35); Table 2 (d28) | ambiguous (P2) | **documented** — Q35. |
| `MAL-CATEGORIES` — "Occurrence of secondary malignancies will be categorized according to clinical relevance. The final groupings will be dependent on review … | §7.2.4 and Table 2 (d27-d28); Table 4 'Secondary malignancy … | matches | — |
| `MAL-CODES` — "Type of malignancy, defined according to ICD-10-CM codes." ... "All study outcomes relating to diagnoses will be defined according to … | Table 4 'Type of malignancy' (d35); §7.8.5 (d51); Annex 1 … | not implemented (P1) | **not buildable** — As SAF-CODES-ANNEX3. |
| `MAL-HEME-NO-MYELOMA` — "Hematological (will not include other myeloma types) \| leukemia, lymphoma" | Table 2 (d28) | not implemented (P2) | **fixed** — `check_malignancy_list()` refuses a code `mm_dx.csv` names as myeloma, before the connection is opened. |
| `MAL-CHRONIC` — "To be calculated in the same manner as Objectives 1 and 2, adhering to rules for chronic conditions." ... "Individuals with a documented … | Table 4 'Prevalence and incidence' (d35); §7.8.1 Objective … | matches | — |
| `MAL-CHRONIC-GRAIN` — "...will not be considered at risk and will be excluded from both the numerator and the person-time denominator for that condition." ... … | §7.8.1 Objective 2 (d46); §7.8.1 Objective 3 (d48-d49) | ambiguous (P2) | **documented, aggregate added** — The one-condition reading is on the table as `(any malignancy)`; the per-category reading stays. Q35. |
| `MAL-WINDOW-INC` — "identifying any new malignancy diagnosed after the initiation of each line of therapy (LoT)" / "Follow-up period (1L, 2L, 3L)" vs "An … | §7.8.1 Objective 3 (d48); Table 4 timing (d35) vs §7.3.2 … | ambiguous (P2) | **documented** — Q35. |
| `MAL-PREV-NESTED` — "*For nested cohort, no background prevalence is needed; for 2L cohort prevalence and incidence are needed" ... "1L nested cohort: because … | Table 4 footnote (d35); §7.8.1 Objective 3, 1L nested … | matches | — |
| `MAL-PREV-SEC2L-WINDOW` — "For this objective, all malignancies occurring after diagnosis but prior to 2L will be tabulated as the background prevalence, and new … | §7.4.1.2 (d39) and §7.8.4 (d51) vs §7.8.1 2L cohort bullet … | ambiguous (P2) | **setting, reading open** — `MALIG_PREVALENCE_WINDOW`: `since_diagnosis` (§7.4.1.2, §7.8.4) by default, `baseline` (§7.8.1) as the alternative. Q31. |
| `MAL-PREV-METHOD` — "To be calculated in the same manner as Objectives 1 and 2, adhering to rules for chronic conditions." ... "The numerator will represent … | Table 4 'Prevalence and incidence' (d35); §7.8.1 Objective … | matches | — |
| `MAL-PREV-SEC2L-ANY` — "the baseline prevalence of any malignancy will be summarized" ... "to be calculated as individual conditions within categories, and … | §7.8.1 2L cohort bullet (d49); §7.8.1 Objective 1 (d44) | partially (P2) | **fixed** — An `(any malignancy)` category through the same views: first malignancy of any kind, prior history of any kind, at-risk time to the first. |
| `MAL-RATE-CI` — "Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome" ... "Incidence … | §7.8.1 Objective 1 (d44) and Objective 2 (d45); Table 4 … | partially (P3) | **fixed** — `RATE_LO`/`RATE_HI` on `S_MALIGNANCY_RATES`, suppressed with the rate. |
| `MAL-SEC2L-INC` — "Additionally, the incidence of new secondary malignancies occurring after 2L will be summarized by malignancy type" ... "new malignancies … | §7.8.1 2L cohort bullet (d49); §7.8.4 (d51) | matches | — |
| `MAL-TIME-DX` — "Continuous (months); Time from diagnosis date (included) until date of secondary malignancy (included)" ... "Time from first observed MM … | Table 4 'Time from diagnosis to secondary malignancy' … | matches (P3) | — |
| `MAL-TIME-INDEX` — "Continuous (months); Time from 1L or 2L index (included) until date of secondary malignancy (included) \| 1L and 2L index time to … | Table 4 'Time from 1L/2L index to secondary malignancy' … | partially (P3) | **fixed** — As MALIG-TIME-FROM-DX-INDEX. |
| `MAL-LOT-AFTER` — "Defined according to the LoT after which the malignancy is identified." | Table 4 'LoT after which where malignancy occurred' (d36) | matches | — |
| `MAL-SEQUENCES` — "Tabulation of the top 5-10 sequences among those with a malignancy occurring after treatment. For sensitivity analysis – this will be … | Table 4 'Top treatment sequences among those with … | partially (P3) | **revised, reading open** — `S_MALIGNANCY_SEQUENCES` carries three readings on `LINES`; nothing chosen in code. Q32. |
| `MAL-BY-SOC` — "Occurrence of secondary malignancy will be described according to SOC for each LoT" | §7.8.1 SOC and treatment sequences (d49) | matches | — |
| `MAL-AGE-STRATA` — "Age ≥ 75 vs <75 years \| All primary and secondary by LOT only, 1L and 2L safety and healthcare utilization events at baseline and … | Table 1 row 2 (d27); §7.2.3 (d26) | matches | — |
| `MAL-SUPPRESS` — "If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC)." | §7.8 (d43); §7.2.3 (d26) | matches | — |
| `X2-RULE` — "Evidence of another cancer in the 1L baseline period: Patients with either ≥ 1 inpatient or ≥2 outpatient ICD-9-CM or ICD-10-CM codes on … | §7.2.1.2 exclusion 2 (d24); §7.1 baseline definition (d19) | upstream | upstream — Verdict on the upstream code: it applies the protocol's rule as written — one inpatient other-cancer claim in the 12-month pre-1L window, or two outpatient … |
| `X2-NESTED` — "Additional eligibility criteria will be applied to the 1L cohort to create the subset cohorts of patients who received 2+ (2L cohort) and … | §7.2.1 (d22); §7.2.1.1 'Additional eligibility for primary … | matches | — |
| `X2-SEC2L-WAIVER` — "All inclusion/exclusion criteria will be the same as the primary cohort, with the exception of the index date. Patients in this analysis … | §7.4.1.1 (d39); §7.4.1.2 (d39); §7.8.1 2L cohort bullet … | upstream (P1) | upstream — The study package can waive X2 for SEC2L, but only over an input that retained the patients X2 removes with the flag NO_OTHER_CANCER_PRE_LOT1 on the row. The … |
| `MAL-CLAIMS-DOCS` — (claims checked against the protocol transcription and page images d27-d28, d35-d36, d39, d48-d49, d51) | VARIABLES.md §6, OPEN_QUESTIONS.md Q7, CODELISTS.md 174 … | matches (P3) | — |

### Time to event, KM and treatment patterns (§7.8.2, Table 5, Table 6)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `OUT-TTNT` — Time-to-event outcome, Time from index LOT start date (included) to the earliest between the start of the next LOT or death (excluded). … | s7.3.2.1 Table 5, row 'Time to next treatment (TTNT)', page … | matches | — |
| `OUT-TTD` — Time-to-event outcome, Time from index LOT start date (included)) to the date of treatment discontinuation (excluded). The discontinuation … | s7.3.2.1 Table 5, row 'Time to treatment discontinuation … | matches | **fixed** — As LOT-DISCON-DATE. |
| `OUT-TTD-DISCON-DEF` — *per GSK LoT algorithm definition, discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new … | Table 4 footnote page d35 and Table 5 TTD footnote page d37 | matches | — |
| `OUT-TTD-SWITCH-DAY` — The discontinuation date is the earliest of the date of treatment discontinuation (end of current LOT), initiation of the next LOT, or … | Table 5 TTD row page d37 ('initiation of the next LOT') and … | ambiguous (P3) | **fixed** — As LOT-DISCON-DATE: TTD now lands on the day the agent or transplant was introduced, the same day TTNT reads. |
| `OUT-TTD-SCT-CONT` — discontinuation of a regimen occurs when all MM agents in the LOT are stopped or when a new agent/qualifying SCT event is introduced | Table 5 TTD footnote page d37; s7.1 page d20 ('a stem cell … | ambiguous (P2) | **kept, documented** — `SCT_AUTO_CONT` stays a discontinuation: an in-window autologous transplant is the line's consolidation and opens no line, so it is the footnote's 'all agents stopped' branch, dated on the transplant. Q33. |
| `OUT-TTD-RUNOUT-UNCONFIRMED` — The discontinuation date is the earliest of the date of treatment discontinuation (end of current LOT) ... Patients without treatment … | Table 5 TTD row page d37 ('Patients without treatment … | upstream (P3) | upstream — A run-out within 90 days of OBS_END_DT with no later trigger is not a DISCONTINUATION; the engine writes STUDY_END at the end of observation, so the study … |
| `OUT-OS` — Time-to-event outcome, Time from LOT start date (included) to date of death (excluded). Patients without a recorded date of death will be … | s7.3.2.1 Table 5, row 'Overall survival (OS)', page d38 … | matches | — |
| `OUT-FU-END` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | s7.1 page d19 | matches | — |
| `OUT-TTE-CONVENTION` — Time from index LOT start date (included) to the earliest between the start of the next LOT or death (excluded) | Table 5 pages d37-d38 ('(included) ... (excluded)' on TTNT, … | matches | — |
| `OUT-TIME-ZERO` — Time zero, or the index date, will be LOT start/LOT cohort for all TTE outcomes in the primary analyses (i.e., 1L, 2L, 3L). | s7.8.2 page d50 | matches | — |
| `OUT-TTE-COHORTS` — During each LOT (1L, 2L, 3L) ... All primary and secondary objectives will apply to the secondary cohort. The same outcome definitions as … | Table 5 timing column pages d37-d38 ('During each LOT (1L, … | matches | — |
| `OUT-TTE-ANALYSIS-SET` — Outcomes will only be assessed in the subset of patients who have >=3 months of potential follow-up (or die before 3 months) from their … | s7.8.2 page d50 (pages/p25.png) | ambiguous (P3) | documented — Record the reading in OPEN_QUESTIONS.md and confirm with the study team; the alternative is one extra arm in tte_eligible_sql on the enrolment end. |
| `OUT-KM-ESTIMATOR` — Treatment related time-to-event analyses (e.g., TTNT, TTD, OS) will be performed using the Kaplan-Meier (KM) product limit estimator. | s7.8.2 page d50; Synopsis page d13 | matches | — |
| `OUT-KM-MEDIAN-CI` — Median survival estimates and Brookmeyer-Crowley 95% CI will be the primary estimate reported.(Brookmeyer R 1982) | s7.8.2 page d50 | matches (P3) | — |
| `OUT-KM-LANDMARKS` — Additionally, the number and percentage of patients at risk, with an event and censored will be reported along with survival probabilities … | s7.8.2 page d50 | partially (P3) | documented — Add an at-risk row per landmark (stat reading km_prob_at()$n_risk) and a baseline 'at risk' row to T4/T5c. |
| `OUT-KM-CURVES` — Results will be reported in a tabular format along with corresponding KM curves. | s7.8.2 page d50; Synopsis page d13 | partially (P3) | documented — Add KM figure outputs (per endpoint x line x SOC / subgroup) to TFLS or a figure script that reads S_TTE with TTE_ELIGIBLE=1. |
| `OUT-NO-LOGRANK` — No log-rank or hypotheses testing will be performed to assess for differences across strata. | s7.8.2 page d50 | matches | — |
| `OUT-TTE-BY-SOC` — by LOT, overall and by SOC ... SOC category \| All primary and secondary (SOCS within each LOT) | s6.2.2 page d18; Table 1 row 1 page d27; s7.2.2 page d24 | partially (P3) | documented — Either align regimen_classes.csv with s7.2.2's categories or document the re-grouping as a deliberate Annex 2 decision. |
| `OUT-TTE-BY-SUBGROUP` — Age >= 75 vs <75 years \| All primary and secondary by LOT only ... Neuropathy \| Secondary objective by LOT only, 1L and 2L outcomes ... … | Table 1 rows 2-4 page d27; s7.2.3 page d26 | partially (P2) | documented — Populate the neuropathy and frailty code lists when the annexes arrive and turn the switches on; until then the T5c neuropathy/frailty columns are unfillable and the report should say so. |
| `OUT-TTE-FLOOR25` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. ... If there are less than 25 patients in a … | s7.2.3 page d26; s7.8 page d43 | matches | — |
| `PAT-RECEIVING-EACH-LINE` — Number and percent of patients receiving each 1L, 2L, 3L, and 4L regimens \| Follow-up period ... The proportion of each 1L through 4L … | Table 5 row 'Patients receiving each line' page d37; s7.8.2 … | matches | — |
| `PAT-REGIMEN-SEQUENCE` — Categorical: regimen categories (Section 7.2.2) \| Described for overall sequence from 1L to 4L | Table 5 row 'Treatment regimens received' page d37 | matches | — |
| `PAT-SANKEY` — Sankey diagram of switch between regimen categories ... The Sankey diagram will illustrate transitions between SOC treatments from one LOT … | Table 5 row 'Switch between successive LOTs' page d37; … | partially (P3) | documented — Add a Sankey figure reading S_SWITCH_RELEASE; consider splitting the terminal node into discontinued vs censored using s_line_end's IS_PROTOCOL_DISCON. |
| `PAT-ATTRITION` — Number and percent of patients who received each subsequent LOT, discontinued treatment and did not receive another, were lost to … | Table 5 row 'Treatment attrition' page d37; s7.8.2 page d50 | ambiguous (P3) | documented — Split lost_to_followup into 'censored at study end while on therapy' and 'disenrolled while on therapy' (FU_END = STUDY_END vs enrolment end), or relabel; record the died-vs-discontinued precedence. |
| `PAT-ATTRITION-STRATA` — These analyses may be stratified by SOC and patient subgroups. | s7.8.2 page d50 | matches | — |
| `PAT-DX-TO-1L` — Continuous (months); Time from diagnosis date (included) until index date (excluded) \| 1L index | Table 5 row 'Time from diagnosis to 1L initiation' page d37 | partially (P3) | **fixed** — As DX-TO-1L; the T1 shell rows read it. |
| `PAT-PRIOR-TO-NEXT` — Continuous (months); Defined among patients initiating a subsequent LOT as time from prior LOT start date (included) to next LOT start date … | Table 5 row 'Time from prior LOT to next LOT initiation' … | matches | — |
| `PAT-4L-SCOPE` — There is no 4L cohort. Only the 4L start date and 4L regimen received will be assessed. | Figure 1 note [4] page d21; Table 5 'up to 4L start' page … | matches | — |
| `PAT-SOC-BY-YEAR` — To assess use of SOC regimens/categories and SCT over time (i.e., SOC type by year) ... Types of 1L, 2L, 3L SOCs or classes by line \| … | s6.2.3 page d18; Table 4 row 'Types of 1L, 2L, 3L SOCs or … | not implemented (P2) | **fixed** — As VAR-SOC-BY-YEAR. |
| `EXP-SCT-BY-YEAR` — Exploratory Objective 1: assess trends in the use of SCT over time, overall and according to SOC ... Trends in the use of SCT \| Number of … | s7.3.2.2 Table 6 page d38 (pages/p19.png); s6.2.3 page d18; … | not implemented (P2) | **fixed** — `S_SOC.AUTO_SCT`, `ALLO_SCT`, `CART`, `AUTO_SCT_DT`, `AUTO_SCT_YEAR`: Table 6 is a count over `S_SOC`. |
| `EXP-SCT-12M` — (no protocol text: the audit brief names 'SCT within 12 months of 1L index', but the 26 Aug 2026 protocol defines no such measure; its SCT … | none - grep of protocol.md for 'SCT' finds only d07 … | not applicable | — |
| `UP-LOT-START-RULE` — Start of 2L and subsequent LOTs are defined as the earliest of: a stem cell transplant (SCT; allogeneic or an unplanned autologous SCT), … | s7.1 page d20 | upstream | upstream — The next-line start that TTNT, TTD, the attrition and the Sankey all use is the LOT engine's LOT_START_DT. Verdict on the engine's reading: a new non-regimen … |

### Optum CDM V9.0 data dictionary (§7.5, §7.7, §7.8.5)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `DICT-DATASOURCE` — The Optum CDM database will be utilized for this study. ... The database includes the following: (1) patient enrollment; (2) physician, … | §7.5 Data sources, d40; §12 References, d57 | partially (P3) | documented — Add a preflight DESCRIBE of each CDM table the run reads (member_enrollment: STATE or REGION; medical: PAID_STATUS, CONF_ID, RVNU_CD, POS, PROC_CD; confinement: ICD_FLAG, DIAG1-2; rx: FILL_DT) and … |
| `DICT-AGE` — Age \| • Continuous (years) • Categorical ○ 18-44 years ○ 45-64 ○ 65-74 years ○ ≥75 years *Age categories may be adjusted based on age … | §7.3.2 Table 4 Age, d31; §7.2.1.1 Adult age, d22 | matches | — |
| `DICT-YRDOB-ZERO` — Adult age: Aged ≥18 years at the time of MM diagnosis according to calendar year [d22] / Observations where data is missing will be dropped … | §7.2.1.1 Adult age, d22; §7.8.5, d51 | upstream (P3) | upstream — Dictionary p03 types YRDOB INT with no sentinel documented; OPEN_QUESTIONS.md 'Also settled' records 614 warehouse rows with YRDOB = 0. The study package … |
| `DICT-SEX` — Sex \| Categorical: • Male • Female • Unknown \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Sex, d31 | matches | — |
| `DICT-REGION` — Region \| Categorical: • Midwest • South • West • Northeast • Unknown *Based on regions defined by US Census Bureau* \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Region, d31 | deviates (P3) | documented — Make REGION_SOURCE resolve from a DESCRIBE of member_enrollment at preflight (REGION present -> read it; else STATE crosswalk), remove the hard refusal, and record which source fed the run. |
| `DICT-RACE` — Race \| Categorical: • Asian • Black • White • Unknown \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Race, d31 | matches | — |
| `DICT-ETHNICITY` — Ethnicity \| Categorical: • Hispanic or Latino • Not Hispanic or Latino • Unknown \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Ethnicity, d32 | matches | — |
| `DICT-INSURANCE` — Insurance type \| Categorical: • Medicare • Commercial Health Plan \| At index (1L, 2L, 3L) | §7.3.2 Table 4 Insurance type, d32 | matches | — |
| `DICT-CE` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date. Patients with gaps … | §7.2.1.1 Continuous enrollment, d23-d24 | matches | — |
| `DICT-BENEFITS` — CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date [d23] / All patients in this database have both … | §7.2.1.1 Continuous enrollment, d23; §7.5, d40 | not applicable | — |
| `DICT-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death [d23] / CE during follow-up for each cohort: at … | §7.2.1.1 Evidence of follow-up, d23; d24 | matches | — |
| `DICT-MMDX-INPATIENT` — MM diagnosis: At least one inpatient medical claim with a diagnosis code for MM in any position (any ICD-9-CM=203.0x or ICD-10-CM … | §7.2.1.1 MM diagnosis, d22 | upstream (P2) | upstream — Verdict on the upstream code: the columns conform to V9.0 - diagnoses come from MED_DIAGNOSIS.DIAG/ICD_FLAG/FST_DT (p09; MEDICAL carries no DIAG columns in … |
| `DICT-TREATMENT` — Information for diagnoses of interest, including MM will be collected through claims-based diagnosis tables, while treatment data will … | §7.5, d40; §7.7, d42 | upstream (P3) | upstream — Verdict on the upstream code: every column exists in V9.0 - RX.NDC Char 11, FILL_DT DATE, DAYS_SUP INT 'Estimated day count the drug supply should last' … |
| `DICT-SAFETY-DX` — Key safety events of interest, as defined in Table 3, were selected due to their association with some MM treatments, and will be defined … | §7.3.2, d29; Table 3, d29-d30 | matches | — |
| `DICT-SEVERE-INFECTION` — Severe infection resulting in hospitalization \| Acute \| Baseline and follow-up (1L, 2L, 3L) [d30] / ... will be defined according to … | Table 3, d30; §7.3.2, d29 | ambiguous (P2) | documented — Record the reading in OPEN_QUESTIONS (POA-based vs any inpatient claim, and CONF_ID-only vs POS/TOS OR CONF_ID) and expose a setting so the sensitivity can be run; align the inpatient definition with … |
| `DICT-HOSP-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). Hospitalizations that begin before the baseline start date or … | §7.8.1 Background rates of health care utilization events, … | matches | — |
| `DICT-MMHOSP` — The number and proportion of patients with ≥1 hospitalization from any cause, ≥1 hospitalization related to MM (defined as having a MM … | §7.8.1, d45 | ambiguous (P2) | documented — Get the study team's answer to Q27; until then publish the MM-related hospitalisation number with the route named on the table. |
| `DICT-ED` — Health care utilization outcomes include: (1) All-cause inpatient hospitalizations and (2) Emergency visits. [d31] / ... or an ER visit … | §7.3.2, d31; Table 4 / §7.8.1, d45 | ambiguous (P2) | documented — Get Q11 answered (construction and admitted-ED handling); profile TOS_EXT values for an ED category as a fourth candidate. |
| `DICT-PAID_STATUS` — All study outcomes relating to diagnoses will be defined according to pre-defined code lists, as specified in Annex 3. Observations where … | §7.8.5 Data handling conventions, d51 (protocol is silent … | not applicable (P3) | — |
| `DICT-MALIG` — Type of malignancy, defined according to ICD-10-CM codes. Occurrence of malignancy to be confirmed through the presence of at least 2 … | Table 4 Type of malignancy, d35 | matches | — |
| `DICT-CCI` — Charlson Comorbidity Index (CCI)(Quan 2011) \| Continuous; Categorical: 0,1,2,3,4,5+ CCI will be adjusted for having received a MM … | Table 4 Charlson Comorbidity Index, d32 | matches | — |
| `DICT-FRAILTY` — Kim Frailty Index Score (only included pending review of data and mapping) \| Continuous; Categorical: CFI ≥ 0.25 = frail *CFI will only be … | Table 4 Kim Frailty Index Score, d32; §7.2.3, d27 | partially (P3) | documented — Extend frailty_index() to route ICD-procedure, CPT/HCPCS and NDC features to MED_PROCEDURE.PROC, MEDICAL.PROC_CD/BILL_PROC_CD and RX.NDC, and add the intercept, once Annex 7 arrives. |
| `DICT-DEATH` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | §7.1, d19; Table 5 Overall survival, d38; §7.8.5, d51 | upstream (P2) | upstream — The V9.0 dictionary has no DOD/mortality tab (tabs p01-p24 end at LU_PROCEDURE; CONFINEMENT.DSTATUS p12 'Patient status code (01-99) ... expired' is the only … |
| `DICT-LAB` — Thrombocytopenia (dependent on data availability) \| Chronic \| Baseline and follow-up (1L, 2L, 3L) / Anemia (dependent on data availability) … | Table 3, d30; §7.7, d42 | not implemented (P3) | documented — Either add a LABRESULT-based sensitivity for the two conditions (LOINC platelet/haemoglobin, RSLT_NBR against LOW_NRML) or remove `lab` from DATA_MAPPING §9 and state that both are diagnosis-defined. |
| `DICT-DXDATE` — Year of MM diagnosis \| Categorical; number and percent of NDMM patients by Year of first MM diagnosis First MM diagnosis is defined as … | Table 4 Year of MM diagnosis, d32 | matches | — |
| `DICT-ICD_FLAG` — any ICD-9-CM=203.0x or ICD-10-CM code=C90.0x [d22] / ICD-10-CM codes used to identify eligible diagnoses ... will be extracted [d42] | §7.2.1.1, d22 (ICD-9-CM=203.0x or ICD-10-CM code=C90.0x); … | matches | — |
| `DICT-DIAG_POSITION` — a diagnosis code for MM in any position [d22] / a MM diagnosis in first or second position [d45] | §7.2.1.1, d22; §7.8.1, d45 | matches | — |
| `DICT-CLMSEQ` — Information for diagnoses of interest, including MM will be collected through claims-based diagnosis tables | §7.5, d40 (claims-based diagnosis tables) | matches | — |
| `DICT-ENROL-TABLES` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | Table 4, d31-d32 (demographics 'At index'); §7.8.1, d44 | matches | — |
| `DICT-DOC-CLAIMS` — This procedure requires documented evidence that the study protocol has been correctly interpreted and executed. | §7.9 Quality control, d51 (documented evidence that the … | deviates (P3) | **documented** — This report is the documented evidence §7.9 asks for. |

### Optum business rules (join keys, rules 5, 12, 13, 14)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `ENROL-STITCH-RULE10` — Continuous enrollment (CE): CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date. Patients with gaps … | s7.2.1.1 Inclusion Criteria, d23 (vendor rule 10, … | matches | — |
| `ENROL-ROLLUP-RULE11` — Patients with gaps in enrolment of ≤ 30 days are considered to be continuously enrolled | s7.2.1.1 d23-d24 (vendor rule 11 and table list p02 row 2) | matches | — |
| `ENROL-JOIN-KEY` — Patients with gaps in enrolment of ≤ 30 days are considered to be continuously enrolled | s7.2.1.1 d23; vendor join diagram optumrules p01 legend | matches | — |
| `CE-INDEX-DAY-N2` — Continuous enrollment (CE) for each cohort: CE of at least 12-months with medical and pharmacy benefits before the cohort index date (2L or … | s7.2.1.1 Additional eligibility for 2L and 3L, d23-d24 | deviates (P2) | documented — Either join the span with COV_END >= date_sub(LOT_START_DT, 1) and let ce_pre alone decide N2, or declare 'enrolled on the index date' as its own criterion (as the cohort build does) so the funnel … |
| `CE-BENEFITS-FLAG` — CE of at least 12-months with medical and pharmacy benefits before the 1L cohort index date | s7.2.1.1 d23; s7.5 d40; enrolment schema optumenrol p01-p03 | not implemented (P3) | documented — Record the requirement as untestable on this extract in the study report and have the study team confirm s7.5's assertion for the plan types present (ASO, HEALTH_EXCH, CDHP). |
| `CE-12M-2L3L` — Continuous enrollment (CE) for each cohort: CE of at least 12-months with medical and pharmacy benefits before the cohort index date (2L or … | s7.2.1.1 d23-d24 | matches | — |
| `FU-END-DISENROL` — The patient follow-up period will be defined as the period starting from the index date (i.e., including index) until the end of continuous … | s7.1 d19 | matches | — |
| `FU-CLAIM-EVIDENCE-I5` — Evidence of follow-up: at least one claim (pharmacy or medical) from index date or death | s7.2.1.1 d23 and d24 | ambiguous (P3) | documented — Q5 - open |
| `ENROL-ATTR-AT-INDEX` — All baseline characteristics, except for MM diagnosis date, and comorbidities will be assessed at the time of index date where possible. If … | s7.8.1 d44; Table 4 d31-d32; vendor table list p02 row 1 | matches | — |
| `INSURANCE-BUS` — Insurance type \| Categorical: Medicare, Commercial Health Plan \| At index (1L, 2L, 3L) | Table 4 d32; enrolment value distribution optumenrol p04 | matches | — |
| `REGION-NO-COLUMN` — Region \| Categorical: Midwest, South, West, Northeast, Unknown \| Based on regions defined by US Census Bureau | Table 4 d31; enrolment schema optumenrol p01-p03 | matches | — |
| `INPATIENT-RULE14-STUDY` — Hospitalizations without a recorded discharge date will be counted when summarizing the number of patients with more than 1 hospitalization … | s7.8.1 d45, d47; vendor rule 14 approach 2 (optumrules p07) | matches | — |
| `INPATIENT-RULE14-UPSTREAM` — At least one inpatient medical claim with a diagnosis code for MM in any position (any ICD-9-CM=203.0x or ICD-10-CM code=C90.0x) or ≥ 2 … | s7.2.1.1 d22; s7.2.1.2 d24; vendor rule 14 approach 1 … | upstream | upstream — The protocol never defines 'inpatient medical claim'; the cohort build applies vendor approach 1 OR approach 2: POS IN ('21','51','61') OR TOS_CD IN … |
| `HOSP-DX-RULE13` — ≥ 1 hospitalization related to MM (defined as having a MM diagnosis in first or second position) | s7.8.1 d45; vendor rule 13 (optumrules p07 row 13); join … | ambiguous (P2) | documented — Q27 - open |
| `ED-IDENTIFICATION` — Health care utilization outcomes include: (1) All-cause inpatient hospitalizations and (2) Emergency visits. | s7.3.2 d31; s7.8.1 d45; vendor rule 14 'Additional … | ambiguous (P2) | documented — Q11 - open |
| `CLAIM-STATUS-DENIED` — (none - the protocol and the business rules are silent on paid vs denied claims) | no protocol text; not in the vendor rules (PAID_STATUS is a … | partially (P2) | documented — Either rename the setting to say it governs ED visits only, or apply it at the diagnosis/claim reads too (safety, malignancy, comorbidity, HCRU MM-related route B, fu_claims) and record the run's … |
| `DUP-SAME-DAY` — Multiple claims occurring on the same day will be treated as a single event. Events identified on claims occurring more than 1 day apart … | s7.8.1 d44; vendor table list p02 row 6 (CONFINEMENT) | matches | — |
| `DEATH-YMDOD-RULE12` — Overall survival (OS) \| Time-to-event outcome, Time from LOT start date (included) to date of death (excluded). Patients without a recorded … | Table 5 d38; s7.1 d19; vendor rule 12 and table list p03 … | upstream (P2) | upstream — Vendor: 'Date of Death (DOD) table contains month and year of death'; rule 12 'YMDOD column from T_DOD table can be used to find death month and year'; note … |
| `DRUG-SOURCES-RULE5` — Information for diagnoses of interest, including MM will be collected through claims-based diagnosis tables, while treatment data will … | s7.5 d40; s7.7 d42; vendor rule 5 (optumrules p05-p06) | upstream (P3) | upstream — Vendor rule 5 lists four routes: NDC+FILL_DT (T_RX), NDC+FST_DT (T_MEDICAL), PROC_CD+FST_DT (T_MEDICAL, HCPCS/CPT), PROC+FST_DT (T_MED_PROCEDURE). The cohort … |
| `DAYS-SUPPLY` — 1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date ... Each subsequent LOT includes all MM … | s7.1 d19-d20 (LOT assignment per GSK 2026, Annex 6); vendor … | upstream | upstream — Neither vendor document states a days-supply rule; the protocol delegates line construction to Annex 6. The engine's medication cover is FILL_DT + DAYS_SUP for … |
| `QUARTERLY-TABLES` — The study period will span from 01 Jan 2018 through 31 Mar 2026 (i.e., the most recent date of data availability at time of analysis) | s7.1 d19; s2 Synopsis d10; enrolment screenshot optumenrol … | matches | — |
| `DIAG-ICDFLAG-POSITION-RULE1` — At least one inpatient medical claim with a diagnosis code for MM in any position ... ≥ 1 hospitalization related to MM (defined as having … | s7.2.1.1 d22; s7.8.1 d45; vendor rule 1 (optumrules p04-p05) | matches | — |
| `PROC-CD-VS-PROC-RULE3` — ICD-10-CM codes used to identify eligible diagnoses, and NDC codes to identify treatments will be extracted to define indexes, cohorts, and … | s7.7 d42; vendor rule 3 (optumrules p04-p05) | matches | — |
| `LABS-RULES-8-9` — Where applicable, lab values and healthcare utilization data may also be used to defined outcomes. | s7.7 d42; vendor rules 8-9 and table list p02 row 8 | not applicable | — |
| `PROVIDER-POS` — (none - the protocol names no provider-level variable) | vendor join diagram p01 (Provider Bridge / Provider); no … | not applicable | — |
| `SES-DOD-JOIN-NOTE` — Race \| Categorical: Asian, Black, White, Unknown \| At index (1L, 2L, 3L) | vendor note optumrules p03; Table 4 d31 (Race) | matches | — |
| `GAP-DAYS-PERSON-TIME` — The denominator will represent the total amount of PY present in the baseline period (i.e., 12 months prior to each LOT), irrespective of … | s7.8.1 d44 | ambiguous (P3) | documented — Q19 - open |

### Analysis, disclosure and reporting (§7.8, §7.9, Annexes)

| requirement | protocol | audit verdict | after this pass |
|---|---|---|---|
| `STAT-RATE-UNIT` — Rates will be described in units of PYs, defined as per 10,000 or 100,000 (or other multiplier), depending on data availability. | s7.8 Data analysis, d43 | deviates (P1) | documented — Record RATE_MULTIPLIER in S_RUN_METADATA and the contract; make TFLS read it and label headings/notes from it (or fix the shells to "per 100,000 person-years" and the stat_rate fallback to the same … |
| `STAT-RATE-CI` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome ... Incidence rates … | s7.8.1 Primary objective 1 and 2, d44 and d45 | partially (P2) | documented — Use an exact (Garwood/chi-square) or Byar interval so zero-event rows carry (0, upper); name the method in the output footnote and in a SAP note since the protocol does not. |
| `OUT-RATE-CI-TEXT` — Background prevalence event rates and corresponding 95% confidence intervals (CIs) will be calculated for each outcome | s7.8.1, d44-d45 (95% CI reported with each rate); s7.8 d43 … | partially (P2) | documented — Print the interval in stat_rate's text ("rate (lo, hi)"), with "n/a" where the package wrote NULL, and add a footnote naming the CI method. |
| `STAT-RATE-CI-MALIG` — Prevalence and incidence of secondary malignancy* \| To be calculated in the same manner as Objectives 1 and 2, adhering to rules for … | Table 4, Primary Objective 3, d35; s7.8.1 d49 | partially (P2) | documented — Add RATE_LO/RATE_HI via rate_ci_sql to both malignancy INSERTs, extend SUPPRESSION_SPEC value_cols, and add a golden in tests/expectations.py. |
| `STAT-HCRU-CI` — Primary Objective 2: incidence of key safety and healthcare utilization events while on 1L, 2L, and 3L ... Incidence rates of safety events … | s7.8.1 Primary Objective 2 box, d45; d47 'Incidence of … | ambiguous (P3) | documented — Either add rate_ci_sql to the HCRU rate INSERT (cheap, consistent with the safety table) or drop the CI wording from the HCRU shell notes; record the reading in OPEN_QUESTIONS.md. |
| `STAT-DESC-CONT` — For continuous variables, the descriptive statistics will include means, standard deviations (SD), medians, interquartile ranges (IQR), and … | s7.8, d43 | matches | — |
| `STAT-DESC-CAT` — For categorical variables, frequencies and percentages (%) will be generated. | s7.8, d43; Synopsis d13 | matches | — |
| `STAT-LOS` — LOS will be computed from admit date (included) to discharge date (excluded). ... For continuous variables, the descriptive statistics will … | s7.8 d43 with s7.8.1 d45/d47 (LOS) | partially (P3) | documented — Add stddev, percentile 0.25/0.75, min and max of LOS_DAYS to the agg CTE (and a per-patient visit-count table if the shell's count bands are wanted). |
| `STAT-BASELINE-RATE` — The numerator will represent the total number of qualifying events for a given outcome. Multiple claims occurring on the same day will be … | s7.8.1 Primary objective 1, d44 | matches | — |
| `STAT-INCIDENCE-RATE` — Incidence of event type X = (No.of new event type X occuring LOT Y treatment period) / (Total PY at risk) ... Individuals with a documented … | s7.8.1 Primary Objective 2, d46 | matches | — |
| `STAT-HCRU-BASELINE` — The number and proportion of patients with >=1 hospitalization from any cause, >=1 hospitalization related to MM ..., or an ER visit during … | s7.8.1 'Background rates of health care utilization … | matches | — |
| `STAT-PVALUES` — No statistical comparisons or p-values will be reported. ... No log-rank or hypotheses testing will be performed to assess for differences … | s7.8 d43; s7.8.2 d50; Synopsis d13 | matches | — |
| `STAT-MISSING` — The number of patients with unknown/missing values for continuous and categorical variables will be reported. | s7.8, d43 | partially (P3) | documented — Add Unknown rows for sex, age and insurance and a 'Missing, n' row under each continuous variable (stat n on is.na of the column). |
| `STAT-NO-IMPUTE` — Observations where data is missing will be dropped when necessary. No imputation for missing data will be performed. | s7.8.5 Data handling conventions, d51 | matches | — |
| `DISC-FLOOR-25` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC). / … | s7.8 d43; s7.2.3 d26 | matches | — |
| `DISC-SOC-EXEMPT` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC). | s7.8, d43 | ambiguous (P2) | documented — Get the sponsor's reading; if SOC-specific tables are exempt, add an exemption predicate to SUPPRESSION_SPEC (the header says it is a one-line change) and mirror it in TFLS. |
| `DISC-FLOOR-BASIS` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted | s7.8 d43; s7.2.3 d26 | deviates (P3) | documented — Test the floor on the stratum size (count of patients in the period stratum) and keep N_AT_RISK as a value column; or record the stricter reading in OPEN_QUESTIONS.md. |
| `DISC-CELL-FLOOR` — If there are less than 25 patients in a particular stratifications or cohort, analyses will not be conducted (unless specific to SOC). / … | s7.8 d43; s7.2.3 d26 | deviates (P2) | documented — Confirm whether a cell-level small-count rule is a data-licence requirement; if not, restrict TFLS to the denominator floor (drop the TFLS_COUNT_FLOOR_STATS test) so it matches the package and the … |
| `DISC-REGROUP` — Stratifications with <25 patients will not be performed or may be regrouped due to low volumes. | s7.2.3, d26 | matches | — |
| `DISC-COVERAGE` — Study results will be in tabular form and aggregate analyses that omits subject identification ... If there are less than 25 patients in a … | s8.1 d53; s7.8 d43 | matches | — |
| `TTE-KM` — Treatment related time-to-event analyses (e.g., TTNT, TTD, OS) will be performed using the Kaplan-Meier (KM) product limit estimator. | s7.8.2, d50; Synopsis d13 | matches | — |
| `TTE-MEDIAN-BC` — Median survival estimates and Brookmeyer-Crowley 95% CI will be the primary estimate reported.(Brookmeyer R 1982) | s7.8.2, d50 | matches | — |
| `TTE-LANDMARKS` — survival probabilities (with 95% CI) at relevant landmarks, such as 6, 9, 12, 18, and 24 months after index date | s7.8.2, d50 | matches | — |
| `TTE-NRISK-EVENTS` — the number and percentage of patients at risk, with an event and censored will be reported | s7.8.2, d50 | partially (P3) | documented — Add a km_n_risk statistic (at time zero and at each MONTHS= landmark) and shell rows for it, or print N in the T4/T5c column headers. |
| `TTE-ANALYSIS-SET` — Outcomes will only be assessed in the subset of patients who have >=3 months of potential follow-up (or die before 3 months) from their … | s7.8.2, d50 | matches | — |
| `TTE-TIME-ZERO-CENSOR` — Time zero, or the index date, will be LOT start/LOT cohort for all TTE outcomes ... Patients without a subsequent LOT or date of death will … | s7.8.2 d50; Table 5 d37-38 | matches | — |
| `TTE-CURVES` — Results will be reported in a tabular format along with corresponding KM curves. | s7.8.2, d50; Synopsis d13 | partially (P3) | documented — Add a figure export (e.g. base-R png of the km_estimate steps per T4/T5c column) beside the tables, or document that curves are served by the dashboard. |
| `PAT-SANKEY` — Treatment sequencing in the overall study sample starting from 1L will be presented using Sankey diagrams, with corresponding tables … | s7.8.2, d49 | partially (P3) | documented — Add PCT (of the FROM stratum) to S_SWITCH and its SUPPRESSION_SPEC, a shell table over it, and a Sankey renderer (or state that the diagram is drawn elsewhere from S_SWITCH_RELEASE). |
| `PAT-ATTRITION` — Overall patient attrition will be depicted and tabulated. These analyses may be stratified by SOC and patient subgroups. | s7.8.2, d50; Table 5 d37 | matches | — |
| `PAT-REGIMENS` — The proportion of each 1L through 4L regimens received will be described descriptively, as the count and percentage of each regimen. | s7.8.2, d49 | matches | — |
| `STRAT-SOC-AGE` — SOC category \| All primary and secondary (SOCS within each LOT). Age >= 75 vs <75 years \| All primary and secondary by LOT only, 1L and 2L … | s7.2.3 Table 1 rows 1-2, d27; s7.8.1 d44-45 | matches | — |
| `STRAT-NEURO-FRAILTY` — Neuropathy \| Secondary objective by LOT only, 1L and 2L outcomes. Frailty status (dependent on data use and mapping availability) \| … | s7.2.3 Table 1 rows 3-4, d27; s7.8.4 d50 | partially (P2) | documented — Obtain Annex 3 (neuropathy codes) and Annex 7 (CFI mapping), populate comorbid_subgroups.csv and frailty_kim2018.csv, and switch both on; until then the SAP should say these strata are pending. |
| `STRAT-LUNG-ANYEVENT` — Comorbidities of interest: Baseline history of neuropathy; Baseline history of lung parenchymal disease (i.e., COPD, asthma, … | s7.2.3, d26 | not implemented (P3) | documented — Decide with the sponsor whether Table 1 or the s7.2.3 list governs; if the latter, add a lung column to T5c and an any-domain baseline flag derived from S_SAFETY_COUNTED (PERIOD = BASELINE). |
| `STRAT-1L2L-ONLY` — results from the primary and secondary objectives will be stratified by patient subgroups of interest among the 1L and 2L primary nested … | s7.2.3, d26 | matches | — |
| `SENS-SEC2L` — A sensitivity analysis in which all patients initiating an assumed 2L therapy on >=01 Jan 2020 will be assessed. ... all primary and … | s7.4.1.1-7.4.1.2 d39; s7.8.4 d50-51 | partially (P2) | documented — Rebuild the cohort/LOT input without X2 and the 1L index floor for the secondary cohort (or agree the nested version), select SEC2L, and add SEC2L columns to T1/T2/T4-type shells. |
| `SENS-MALIG-SEQ-2L` — Tabulation of the top 5-10 sequences among those with a malignancy occurring after treatment. For sensitivity analysis - this will be … | Table 4 Primary Objective 3, d36 | matches | — |
| `SIZE-3L` — Analyses for the primary 3L nested cohort may be limited or excluded pending sample size among SOCs. | s7.1 d19; Figure 1 note 1 d21; s7.6 d41 | matches | — |
| `SIZE-TABLE7` — The precision levels were computed using PASS 2019 based on the two-sided 95% Clopper-Pearson exact confidence interval for a single … | s7.6 Study size, d40-41 (Table 7) | not applicable | — |
| `EXPLOR-SCT-YEAR` — Trends in the use of SCT \| Number of patients with an SCT in 1L-4L by year, according to SOC type ... Exploratory analyses will be … | s7.3.2.2 Table 6 d38; s7.8.3 d50 | not implemented (P3) | documented — Add an exploratory module: count of patients with any SCT procedure (cl_sct_codelist) per line, per year of line start, per SOC category, released through SUPPRESSION_SPEC. |
| `OUT-EXPLORER` — Results not prioritized for formal reporting will remain available for internal review only, via a fit-for-purpose Explorer Tool, and are … | s7.8, d42-43 | matches | — |
| `DATA-R-VERSION` — All data analysis will be conducted using R version 4.5.2.(R Core Team 2025) | s7.7 Data management, d41 | partially (P3) | documented — Record R.version.string in S_RUN_METADATA and the TFLS caption; pin 4.5.2 in the production environment. |
