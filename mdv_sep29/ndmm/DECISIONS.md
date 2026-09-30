# NDMM cohort on MDV - decision register

Each rule that decides who is in the cohort: the rule as the code applies it,
why, what it moves, and its status. How to run and configure the build, and
the criteria in full, are in `README.md`. Section numbers are stable; the code
cites them.

Statuses. **Signed off**: settled. **Open**: the code applies one reading and
the study team still has to confirm it. **Measured**: nothing to decide until
the first run's number is read. **Not built**: the code does not do it.

This is the Optum cohort build's register, carried over whole, with one
section added at the top, **MDV**, for the decisions the port makes. Sections 1 to 12 are the
Optum decisions, carried over because the rules are the same study's. "Signed
off" there means signed off **for Optum**; the whole MDV build is a deviation
until the study team signs the port off (`../MDV_RULES.md`). Four sections
describe Optum's data rather than a rule and do not apply on MDV, and each
says so where it starts: 6 (the CDM checks), 7 (month windows; on MDV the
diagnosis windows are counted in months), 8 (constructed death dates) and 11
(`ICD_FLAG`).

---

## MDV. What the port decides

Each item has a default the build applies and, where it is open, a table that
prices the alternative on every run. `../MDV_RULES.md` has the full
Optum-to-MDV table.

**M1. A diagnosis is dated to the first day of its claim month.** *Signed off
as the team's MDV convention (the OC rules); its consequences are open (M5).*
MDV dates a diagnosis only to `datamonth`. The OC rules use `diagnosis_date =
first calendar day of datamonth`, and so does every diagnosis rule here:
criterion 1, other cancer, pregnancy, the trial flag, and transplant
diagnoses.

**M2. Only confirmed diagnoses count.** *Signed off as the team's MDV
convention.* `utagaiflg` is the confirmed value (0) in every diagnosis rule.
Japanese claims carry suspected diagnoses entered to justify tests.
`NDMM_MM_DX_RULES` counts criterion 1 with them included.

**M3. MM and other-cancer diagnoses must carry `cancerflg`.** *Open.* This is
the OC rules' base population, and the default. `NDMM_MDV_REQUIRE_CANCERFLG`;
priced in `NDMM_MM_DX_RULES`.

**M4. Inpatient.** *Open.* The Optum rule is an inpatient claim line or a
valid confinement. The MDV default is the claim's care setting (`nyugaikbn =
2`). `NDMM_MDV_IP_RULE=ff1` adds the OC rules' FF1 alignment (the record's
`fromdate` inside an FF1 episode); `ff1_chemo` adds their first-cancer and
chemotherapy flags. All three are priced in `NDMM_MM_DX_RULES`. The other-cancer
rule uses the care setting alone whatever this says, since the FF1 conditions
are about the myeloma's own treatment. Outpatient is `nyugaikbn = 1`, not
"anything not inpatient", so an inpatient record the FF1 readings refuse does
not become an outpatient one.

**M5. "Different days within N days" at the month grain.** *Open.* Two
outpatient MM diagnoses in different claim months at most
`OUTPATIENT_WINDOW_MONTHS` (3) apart stand for the Optum rule's two claims
within 90 days. Two outpatient other-cancer diagnoses in adjacent months
(`OTHER_MALIG_WINDOW_MONTHS` 1) stand for 30 days. The count is in calendar
months, because the OC rules' `days / 30.44 >= 1` reads February 1 to March 1
as under a month. Two visits in one month cannot pair. Month dating also puts
the index month's diagnoses inside the 12-month baseline, and the month
holding `index - 365` outside it.

**M6. Enrolment becomes observation.** *Open.* MDV has no insurance span.
Criterion 4 is "the first MDV record (any act, diagnosis month or FF1
episode) is at least 365 days before the index", which is the lookback 12
months of enrolment bought. Criterion 5 is "seen on or after `index +
FU_CE_DAYS`", which the index act satisfies at 0 days. `ENDDATE_CE` is the
last MDV record. A patient treated elsewhere before arriving is invisible to
any MDV rule.

**M7. Death is an in-hospital discharge.** *Open; the column is to confirm.*
MDV records death only as a DPC Form 1 discharge outcome (6 or 7 by default).
The date is that discharge. Until `MDV_COL_FF1_OUTCOME` is set nobody dies,
and the run records `death_not_observed`.

**M8. One act source for MM therapy.** *Signed off.* The Optum build's five
claim arms (medical `PROC_CD`, `BILL_PROC_CD`, `NDC`; rx `NDC`;
`med_procedure` `PROC`) are one table on MDV. Drugs are named by receipt code
or by an English-name pattern over the drug master, as the OC rules find
platinum. Both are resolved once to receipt codes, written out as
`NDMM_MMA_RECEIPTS`, and read by the index, the prior-therapy rule and
belantamab alike.

**M9. The patient is the hospital's.** *Measured.* MDV's patient ID is per
hospital. A patient at two contributing hospitals is two patients, each
observed at one.

**M10. A value code that matches nothing stops the run.** *Signed off.* The
check that replaces the Optum NDC and `ICD_FLAG` checks: `check_mdv_values()`
profiles `nyugaikbn`, `utagaiflg`, `cancerflg` and the two date columns on the
records the cohort reads, writes `NDMM_MDV_SOURCE_PROFILE`, and stops if a
configured code matches none of them. It is waivable as `mdv_values`.

---

## 1. Follow-up enrolment - one day, this cohort only

Rule: criterion 5 needs a no-gap enrolment span covering the 1L index date
itself. `FU_CE_DAYS = 0`, pinned in `CONTRACT`; the flag is `CE_lot1_fu` in
`R/steps/06_flags.R`. The window is cut at death and the study end, but the
span must still reach the index date. The 2L and 3L cohorts keep three months
(90 days).

Why: the study team's decision for this cohort.

Moves: a larger cohort than three months would give; the difference lands on
attrition step 5. `NDMM_FU_CE_COUNTS` gives the cohort size at 0, 30, 60 and 90
days and at three calendar months on every run.

Status: signed off.

---

## 2. Belantamab - split across two packages

Rule: the exclusion is belantamab in any line, applied in two halves.

| half | where |
|---|---|
| before the 1L index | here, criterion 9 (`NO_BELANTAMAB_PRE_LOT1`) |
| from the index onward | `lot`, line criterion `no_belantamab` in `lot/engine/R/line_criteria.R`, on while `APPLY_NO_BELANTAMAB` is |

Why: lines do not exist when this cohort is built, and `lot` cannot see claims
before the cohort's `INDEX_DATE`, where its `map_stacked` starts. A proxy for
line membership here could not be checked, because a patient removed here never
gets lines. Neither half is a proxy.

- **Matched by drug**: one whole `CL_MED_ABBR`, `BELA` by default here and in
  `lot`. The build stops if it matches nothing, or if the list carries another
  `BEL*` abbreviation, whose rows would otherwise fall outside the exclusion in
  both packages. `lot`'s `check_belantamab_abbr()` stops on an abbreviation
  matching nothing while `APPLY_NO_BELANTAMAB` is on.
- **Bounded to the study period**, like every other criterion; `lot` cannot see
  outside it. For the literal reading, remove the lower bound in
  `build_ndmm_belantamab_patids()`.
- **Criterion 9 overlaps criterion 6** by design: criterion 6 already removes
  belantamab in the 365-day baseline, so criterion 9's own drop is the patients
  whose belantamab is earlier.
- **In `lot`**, `no_belantamab` is patient-level: it removes every line of a
  patient with belantamab anywhere in the line-covered span, whatever
  `MAX_LOT`. `LOT_RUN_METADATA.LINE_CRITERIA_APPLIED` records whether it was on
  and whom it caught.
- **Belantamab cannot set the 1L index** - a separate rule, kept here because
  the index is what line 1 anchors on.

Moves: `NDMM_COHORT` is the cohort pending half of one exclusion. Its count and
the attrition's last row are not the study's N; the final population is the
patients in `LOT_LONG_FINAL`, and the final count is the last row of
`LOT_ATTRITION`. `NDMM_BELANTAMAB_RECONCILE` lists the cohort members `lot`
will remove. `NO_BELANTAMAB` on `NDMM_FLAGS_ALL` is advisory; nothing filters
on it.

Status: signed off.

---

## 3. Eligible 1L agents - the code list, less the barred ones

Rule: any agent on `cl_mma_codelist.csv` may set the index except steroids
(dropped where the code list is built), belantamab, and whatever
`NDMM_INDEX_EXCLUDED_ABBRS` / `NDMM_INDEX_EXCLUDED_CODES` name. The earliest
remaining claim on or after the MM diagnosis and on or after `LOT1_FROM` is the
index.

Why: the code list is the study's definition of MM therapy, and there is no
separate list of first-line regimens; inventing one would shrink the cohort by
a rule nobody could reproduce. I3 names the agents restricted to later lines,
panobinostat and elotuzumab (protocol inclusion criterion I3, "Eligible 1L
treatment"), and those are barred by name (`README.md` "Barring agents from
the 1L index"). Every entry must match the code list or the build stops, and
the study package refuses a cohort that did not bar the agents its
`COHORT_INDEX_EXCLUSIONS` names.

Moves: barring an agent moves those patients' index to their next eligible
claim, or out of the cohort if there is none. The barred agent is still MM
therapy, so its claims in the 365 days before the new index exclude the patient
under criterion 6. The steroid drop removes nothing on the production file -
none of `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE` is a `CL_MED_ABBR`
there - and stays as a guard. `NDMM_INDEX_AGENTS` shows, per agent, whether it
was barred and how many indexes it set.

Status: signed off for the code list as the eligible set. I3 allows "other
potential therapies pending review of data"; `NDMM_INDEX_AGENTS` is the data
for that.

---

## 4. Other malignancy - grouping, bone metastasis, plasma-cell labels

Criterion 7: one inpatient claim, or two outpatient claims within 30 days for
the same cancer, in the baseline. The rules below decide what "the same
cancer" and "another cancer" mean against `other_malig.csv`. The sensitivity
tables (`README.md` "The sensitivity tables") carry what each costs; all land
on attrition step 7.

### Grain - pair on the ICD category

Rule: two outpatient claims pair on the first three characters of the
punctuation-stripped ICD code - the primary tumour type. ICD-10 codes start
with a letter and ICD-9 codes never do, so the families cannot share a group.

Why: `other_malig.csv` has 1,643 codes and 1,618 distinct `tumor_group`
labels, so pairing on the label would need the identical code twice, and one
cancer coded at two subsites, or once in remission and once not, would never
confirm itself.

Moves: a smaller cohort than pairing on the label. `C44` (skin), `C76` and
`C80` (ill-defined sites) are broad, but both claims are still the same cancer
type, which is the unit the rule names.

Status: measured - `NDMM_OTHER_MALIG_GROUPS` and `NDMM_OTHER_MALIG_GRAIN`.

### Both claims inside baseline, not just the first

Rule: both claims of an outpatient pair fall in `[index - 365, index - 1]`
(`04_other_malig.R`, the join to `outpatient_pairs`). The inpatient claim is
bounded by the same window.

Why: the criterion is another cancer in the 1L baseline. Bounding only the
first claim would let a claim the day before the index and its confirmation a
month after it exclude the patient on one baseline claim.

Moves: a larger cohort; a pair straddling the index excludes nobody.

Status: open. If a post-index claim is meant to be able to confirm baseline
disease, the bound on the second claim comes out and the cohort gets smaller.

### Bone metastasis excludes

Rule: `C79.51`, `C79.52` and `198.5` (secondary neoplasm of bone and bone
marrow) are metastatic cancers and exclude. They are not override labels.

Why: the rule excludes on the same primary tumour type or metastatic cancer,
and these are metastatic cancer.

Moves: a smaller cohort. Myeloma bone disease is commonly coded `C79.51`, so
some patients removed are myeloma patients whose lesions were coded as
metastases. That cost is accepted.

Status: signed off - the stated rule governs.

### Metastatic codes group together

Rule: codes matching any of `NDMM_METASTATIC_PREFIXES`
(`R/standalone_constants.R`) form one pairing group, `MET`; everything else
keeps its ICD category.

| ICD-10 | | ICD-9 |
|---|---|---|
| `C77` | secondary and unspecified neoplasm of lymph nodes | `196` |
| `C78` | secondary neoplasm of respiratory and digestive organs | `197` |
| `C79` | secondary neoplasm of other and unspecified sites | `198` |
| `C7B` | secondary neuroendocrine tumours | - |
| `C800` | disseminated malignant neoplasm, unspecified | `1990` |

`C800` and `1990`, not `C80` and `199`: `C80.1` (primary, unknown site) and
`C80.2` are not secondary and keep the category rule.

Why: metastatic cancer qualifies in its own right, so two claims for
metastases at different sites confirm each other.

Moves: regroups codes already on `other_malig.csv`; adds none. The log names
how many codes each prefix claimed. `C77` and `C800` are weaker evidence than
a sited metastasis, and `C79.51` / `C79.52` pair with any metastatic code;
`NDMM_OTHER_MALIG_GRAIN` prices each (`collapse without C77/196`, `collapse
without C800/1990`, `mets kept apart by prefix`) against `as configured`.
Untested: if secondary neoplasms are coded with their known primary, most
metastatic patients are already reachable through the primary code and this
group adds little.

Status: measured.

### Plasma-cell labels are the index disease

Rule: a code does not count as another cancer if it is on `mm_dx.csv`, or if
its label is one of the overridden plasma-cell labels that
`NDMM_MM_ADJACENT_STATES` chooses:

| mode | labels overridden |
|---|---|
| `override` (default) | monoclonal gammopathy; plasma cell leukemia, extramedullary plasmacytoma and solitary plasmacytoma, each not achieved remission, in remission and in relapse |
| `exclude` | monoclonal gammopathy and the three "not having achieved remission" labels |
| `mgus_only` | monoclonal gammopathy only |
| `none` | none; only `mm_dx.csv` codes are kept |

The labels are `NDMM_MM_ADJACENT_OVERRIDE` (`R/ndmm_constants.R`) and
`NDMM_MM_ADJACENT_STATE_LABELS` (`R/standalone_constants.R`), matched on the
whole label. A core label the mode requires that is missing from the code list
stops the run; the six state labels are only reported if missing.

Why: `other_malig.csv` is a generic list, so it can carry codes that are the
index disease. The three plasma-cell disorders sit in C90, where the fourth
digit is the disease state (`C90.10`/`.11`/`.12` plasma cell leukemia,
`C90.20`-`.22` extramedullary and `C90.30`-`.32` solitary plasmacytoma: not
achieved remission, in remission, in relapse). Overriding only the first state
would exclude a patient in remission and keep an identical one who has not
achieved it, so the default overrides all nine. Monoclonal gammopathy is
premalignant and reaches the list only because the list is generic.

Moves: a larger cohort under `override`; the other modes exclude more.
`NDMM_MM_ADJACENT_GROUPS` and `NDMM_MM_ADJACENT_CODES` show what was kept and
what still excludes.

Status: open. One question decides all nine C90 labels: is a patient with
solitary plasmacytoma, extramedullary plasmacytoma or plasma cell leukemia
carrying a second plasma-cell neoplasm, or one disease? One disease: all nine
stay overridden. Separate cancers: `mgus_only`. Whether `other_malig.csv`
carries myeloma's own codes, and so whether the `mm_dx.csv` rule does real
work, is shown on every run by `NDMM_MM_ADJACENT_GROUPS`.

---

## 5. Study window and data vintage

Rule: the study period is 2018-01-01 to 2026-03-31, pinned in `CONTRACT`, read
from the cumulative `2026q1` CDM tables. A LOT run over this cohort must use the
same window; `lot` takes it from its own `config.csv` (the same defaults) or as
run arguments, and records it in `LOT_RUN_METADATA`:

```
Rscript lot/engine/build.R ndmm_NDMM_COHORT ndmm_ 2018-01-01 2026-03-31
```

Why: `lot` bounds every claim scan by the cohort's `INDEX_DATE` and end of
observation, and the study end picks the quarterly tables. A cohort observed
past the window `lot` reads would lose follow-up silently: lines end early and
discontinuations appear that did not happen. `lot`'s `check_cohort_window()`
stops a cohort indexed before its study start or observed past its study end.

Moves: nothing, while the windows agree. The study package holds its own
window to the cohort's recorded one (`README.md` "Settings").

Status: signed off.

---

## 6. What was checked about the CDM

*Optum only. On MDV the checks are the column preflight and the value profile (M10).*

Assumptions this build makes, against the vendor documentation.

- **`ICD_FLAG`** is `'9'`, `'10'` or blank (`VARCHAR(2)`). `9`/`ICD9`/`ICD-9`
  and `10`/`ICD10`/`ICD-10` map to a family; anything else matches no code
  list. A blank is not read as ICD-10, which would mis-class a genuine ICD-9
  claim. What a blank costs is section 11.
- **Diagnosis position is not filtered.** `DIAG_POSITION` runs 1 to 25; an MM
  diagnosis counts in any position.
- **Enrolment spans come from `member_enrollment`**, not the
  `member_cont_enrollment` rollup, which bridges gaps of less than 30 days; the
  study counts 30 or fewer as continuous, and the no-gap spans need the true
  gaps.
- **Medical and pharmacy benefits are satisfied by construction.**
  `member_enrollment` has no benefit indicator (`ASO`, `BUS`, `CDHP`,
  `PRODUCT`, `HEALTH_EXCH` and `GROUP_NBR` are plan structure and funding).
  Do not re-derive it from claims: enrolled patients with no pharmacy fill are
  mostly short spans and rule-out MM codes, not a coverage signal.
- **The therapy scans read every source.** `rx` holds outpatient prescriptions
  only; `medical` holds professional claims coded CPT/HCPCS and facility
  claims; `med_procedure.PROC` finds a drug given as a procedure. `PROC` is
  almost all seven-character ICD-10-PCS; about 15,000 rows (0.035%) have the
  five-character shape of a HCPCS or CPT code, so that arm adds few events, and
  code length alone keeps the join to HCPCS/CPT. A source can only add therapy
  events: the cohort can only get smaller, and index dates only move earlier.
- **`CONFINEMENT`** is one row per hospitalisation, so a joined `CONF_ID` is a
  sound inpatient test. Inpatient is classified from `POS`, `TOS_CD` and
  `CONF_ID`; `LOC_CD` (facility versus non-facility) is only part of the claim
  key.
- **Pregnancy reads diagnosis, procedure and revenue codes**: `med_diagnosis`,
  `medical` (`PROC_CD` and `BILL_PROC_CD` as HCPCS, `RVNU_CD`) and ICD
  procedures in `med_procedure`. A `pregnancy.csv` code type outside the six
  the scan produces stops the run.
- **NDCs** match once both sides are stripped to digits and a ten-digit value is
  padded to eleven (4-4-2). Nothing documents the width; `check_ndc_shape()`
  profiles it on every run.

---

## 7. Month windows are day counts

*Optum. On MDV the 365-day windows stand, but the diagnosis-pair windows are counted in calendar months (M5).*

Rule: every "months" window is a fixed day count. Twelve months of baseline is
365 days, `[index - 365, index - 1]`, at 1L, 2L and 3L; three months of 2L/3L
follow-up is 90 days. `PRE_LOT1_DAYS = 365` is pinned in `CONTRACT`;
`SUBSEQ_PRE_DAYS = 365` and `SUBSEQ_FU_CE_DAYS = 90` by
`subseq_check_windows()` in the Optum build's 2L/3L cohort builder, which is
not part of this folder, and the values used are on every 2L/3L table as
`CE_PRE_DAYS` and `CE_FU_DAYS`.

Why: calendar months would make the window depend on the index month - 90 to
92 days for three months, 365 or 366 across a leap day. 90 days is the shortest
three calendar months, so it is the more permissive reading.

Moves: `NDMM_FU_CE_COUNTS` put 90 days and three calendar months seven
patients apart.

Status: open. The study text says months; the code uses days.

---

## 8. Death dates are constructed, not read

*Optum only. On MDV death is an FF1 discharge date (M7).*

Rule: the CDM records death as year and month (`YMDOD`), sometimes year alone.
`R/steps/00_mm_cohort.R` builds a date:

- year and month: the 15th, or the last day of the month if the qualifying
  diagnosis falls later in that month;
- year only: 15 July, or 31 December if the diagnosis falls after 15 July that
  year;
- never before the MM diagnosis: an earlier constructed date is set to it.

`NDMM_COHORT` then sets a death date before the 1L index to the index, and
criterion 5 requires enrolment on the index date whatever the death date says.

Why: the 15th of the month is the base convention; the other rules keep a
constructed date from contradicting an observed diagnosis or treatment.

Moves: follow-up and death-based eligibility for the patients they touch.
Treatment dated after a constructed death in the same month is outside the
patient's observation (`ENDDATE` is the earlier of the study end and death).

Status: open. The 15th-of-month rule does not cover a year-only record or a
diagnosis after the constructed date; both occur.

---

## 9. Pregnancy - which window

Rule: the exclusion runs over the whole study period, `STUDY_START` to
`STUDY_END`, on all three claim sources (`R/steps/05_pregnancy.R`).

Why: X3 says "during the study period"; the alternative reading is the
patient's own baseline and follow-up.

Moves: the study period is the wider window, so it excludes more.
`NDMM_PREG_WINDOW_COUNTS` prices it, one row per window with the applied row
marked:

| column | |
|---|---|
| `N_WITH_PREG_CLAIM` | indexed candidates with a claim in that window - not the number excluded |
| `N_EXCL_INCREMENTAL` | those the criterion actually removes: a claim, and every other criterion passed |
| `N_COHORT` | the cohort with this criterion under that window |

The gap between the two `N_COHORT` rows is what the decision costs. The
alternative row's follow-up runs to death or the study end, not to
disenrolment; if follow-up is meant to stop there, that row is an upper bound
for `N_WITH_PREG_CLAIM` and `N_EXCL_INCREMENTAL` and a lower bound for
`N_COHORT`.

Status: open. The patient-specific window is the three `BETWEEN` bounds in
`05_pregnancy.R`, and would make the cohort larger.

---

## 10. Maintenance is a flag, not a period

Rule: no maintenance period is built - no start, end, type or end reason. The
LOT engine derives `contains_mtx_reg`, a descriptive 0/1 on a line.
`lot/LOT_RULES.md` section 10 is the home of this rule.

Why: a full definition (a period of 120 days or more with only a valid
maintenance therapy, 30 days after an autologous transplant, the initial
regimen tapering into it, named valid regimens) is not built. That maintenance
is never a line is the consequence, not a decision.

Moves: line counts wherever a maintenance period would have opened.

Status: not built.

---

## 11. An ICD_FLAG naming neither family - reported, not gated

*Optum only. MDV has one ICD family and no ICD_FLAG; the check is gone (M10).*

Rule: `check_icd_flag()` in `R/build_ndmm.R` finds claims whose `ICD_FLAG`
names neither family and whose normalised code is on a list this cohort reads,
names each code and its list, writes the finding to `FINDINGS`, and continues.
On the 2026q1 data: 16 rows, 15 diagnosis and 1 procedure.

Why: those rows match no code list entry, and the miss cuts both ways. On an
MM diagnosis code it can exclude a patient who should be in; on an
other-cancer or pregnancy code it can keep one who should be out; on a
clinical-trial code it moves nobody. The finding's list column says which.

- `NDMM_ICD_FLAG_MAX_ROWS` stops the build above a row count. It is empty by default,
  so the build reports at any volume; every run records `icd_ceiling(...)`.
- A ceiling bounds volume, not composition: the same count on different codes
  still passes. Reading `FINDINGS` is what checks composition:
  `raw_icd_flag(<rows>, <patient-hits>, <codes>; ...)` with each code's list,
  row and patient counts. The patient figure is summed over codes and both CDM
  tables, so it bounds distinct patients from above.
- A completed run writes `NDMM_RUN_METADATA.FINDINGS`; a run the ceiling stops
  never reaches that write, so the same string is on its
  `NDMM_BUILD_STATUS.FINDINGS` row.

Status: accepted for 2026q1, with no ceiling. Re-read on each data refresh.
Setting a ceiling is the study team's call.

---

## 12. Age is tested at the earliest qualifying diagnosis

Rule: the diagnosis date is the patient's earliest qualifying date, chosen
before age is looked at; then `year(diagnosis) - YRDOB >= 18` keeps or drops the
patient. A patient who qualifies at 17 and again at 18 is excluded, not moved to
the later date.

Why: I2 is age at the time of MM diagnosis, and "newly diagnosed" is the
earliest one. The diagnosis date also gates the 1L index, so advancing it would
let a later claim be recorded as first line for a patient whose real first line
was at 17.

Moves: can only drop a patient, never change a diagnosis date. Lands on
attrition step 2.

Status: no open question recorded.
