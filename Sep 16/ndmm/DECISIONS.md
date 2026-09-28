# NDMM cohort - decision register

Each rule that decides who is in the cohort: the rule as the code applies it,
why, what it moves, and its status. How to run and configure the build, and
the criteria in full, are in `README.md`; `RULES.md` is the plain-language
summary.

Statuses. **Signed off**: settled. **Open**: the code applies one reading and
the study team still has to confirm it. **Measured**: nothing to decide until
the first run's number is read. **Not built**: the code does not do it.

---

## 1. Follow-up enrolment - one day, this cohort only

Rule: criterion 5 needs a no-gap enrolment span covering the 1L index date
itself. `FU_CE_DAYS = 0`, pinned in `CONTRACT`; the flag is `CE_lot1_fu` in
`R/steps/06_flags.R`, over the no-gap spans. The window is cut at death and the
study end, but the span must still reach the index date. Other cohorts keep
three months.

Why: the study team's decision for this cohort.

Moves: a larger cohort than three months would give - patients enrolled on
their index date but not for three months after it. The difference lands on
attrition step 5. `NDMM_FU_CE_COUNTS` gives the cohort size at 0, 30, 60 and 90
days and at three calendar months on every run, with the applied row marked.

Status: signed off.

---

## 2. Belantamab - split across two packages

Rule: the exclusion is belantamab in any line, and it runs in two halves.

| half | where |
|---|---|
| before the 1L index | here, criterion 9 (`NO_BELANTAMAB_PRE_LOT1`) |
| from the index onward | `lot`, line criterion `no_belantamab` in `lot/engine/R/line_criteria.R`, on while `APPLY_NO_BELANTAMAB` is |

Why: lines do not exist when this cohort is built, and `lot` cannot see claims
before the cohort's `INDEX_DATE`, where its `map_stacked` starts. A rule here
standing in for line membership could only approximate, and a patient wrongly
removed never gets lines, so nobody could check it. Asking about a date has no
such problem, so the pre-index half stays here. Neither half is a proxy.

- **Matched by drug**, not by class: one whole `CL_MED_ABBR`, `BELA` by default
  here and in `lot`. The build stops if that abbreviation matches nothing ("no
  patient had belantamab" and "the abbreviation is wrong" look the same), or if
  the list carries another `BEL*` abbreviation, whose rows would otherwise fall
  outside the exclusion in both packages. `lot`'s `check_belantamab_abbr()`
  stops on an abbreviation matching nothing while `APPLY_NO_BELANTAMAB` is on.
- **Bounded to the study period.** The rule names no period, but every other
  criterion is bounded to `STUDY_START`-`STUDY_END` and `lot` cannot see outside
  it. For the literal reading, remove the lower bound in
  `build_ndmm_belantamab_patids()`.
- **What criterion 9 adds.** It overlaps criterion 6 by design, which already
  removes belantamab in the 365-day baseline, so its own drop is the patients
  whose belantamab is earlier than that.
- **In `lot`**, `no_belantamab` is patient-level: it reads treatment episodes in
  `map_stacked` over the patient's whole line-covered span, so it is not bounded
  by `MAX_LOT` or by where the drug sat in a regimen, and it removes every line
  of an affected patient. `LOT_RUN_METADATA.LINE_CRITERIA_APPLIED` records
  whether it was on and whom it caught.
- **Belantamab cannot set the 1L index.** A different rule, and it stays here
  because the index is what line 1 anchors on.

Moves: `NDMM_COHORT` is the cohort pending half of one exclusion. Its count and
the attrition's last row are not the study's N; the final population is the
patients in `LOT_LONG_FINAL`, and the final count is the last row of
`LOT_ATTRITION`. `NDMM_BELANTAMAB_RECONCILE` lists the cohort members `lot`
will remove. `NO_BELANTAMAB` on `NDMM_FLAGS_ALL` is an advisory flag over the
whole study period; nothing filters on it.

Status: signed off.

---

## 3. Eligible 1L agents - the code list, less the barred ones

Rule: `cl_mma_codelist.csv` is the study's definition of MM therapy, so it is
also the eligible-1L set. Any agent on it may set the index except steroids
(dropped where the code list is built), belantamab, and whatever
`NDMM_INDEX_EXCLUDED_ABBRS` / `NDMM_INDEX_EXCLUDED_CODES` name. The earliest
remaining claim on or after the MM diagnosis and on or after `LOT1_FROM` is the
index.

Why: there is no separate list of first-line regimens, and inventing one would
shrink the cohort by a rule nobody could reproduce. The study's I3 names the
agents restricted to later lines - panobinostat and elotuzumab
(`variables/IE_CRITERIA.md`, I3) - and those are barred by name through
`NDMM_INDEX_EXCLUDED_ABBRS` (`README.md`, "Barring agents from the 1L index").
Every entry must match the code list or the build stops, and the study package
refuses a cohort that did not bar the agents its `COHORT_INDEX_EXCLUSIONS`
names.

Moves: barring an agent moves those patients' index to their next eligible
claim, or out of the cohort if there is none. The barred agent is still MM
therapy, so its claims in the 365 days before the new index exclude the patient
under criterion 6. The steroid drop removes nothing
on the production file - none of `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`,
`PREDNISONE` is a `CL_MED_ABBR` there - and stays as a guard against a list
that carries them. `NDMM_INDEX_AGENTS` shows, per agent, whether it was barred
and how many indexes it set.

Status: signed off for the code list as the eligible set. I3 allows "other
potential therapies pending review of data"; `NDMM_INDEX_AGENTS` is that review.

---

## 4. Other malignancy - grouping, bone metastasis, plasma-cell labels

Criterion 7: one inpatient claim, or two outpatient claims within 30 days for
the same cancer, in the baseline. The questions below decide what "the same
cancer" and "another cancer" mean against `other_malig.csv`. The review tables
carry what each costs.

### Grain - pair on the ICD category

Rule: two outpatient claims pair on the first three characters of the
punctuation-stripped ICD code - the primary tumour type: every `C50.x` is
breast, every `C34.x` lung. ICD-10 codes start with a letter and ICD-9 never
do, so the families cannot share a group.

Why: `other_malig.csv` has 1,643 codes and 1,618 distinct `tumor_group`
labels, so a label is effectively one code. Pairing on it would need the
identical code twice, and one cancer coded at two subsites, or once in
remission and once not, would never confirm itself.

Moves: a smaller cohort than pairing on the label. `C44` (skin), `C76` and
`C80` (ill-defined sites) are broad, but both claims are still the same broad
cancer type, which is the unit the rule names.

Status: measured - `NDMM_OTHER_MALIG_GROUPS` and `NDMM_OTHER_MALIG_GRAIN`.

### Both claims inside baseline, not just the first

Rule: both claims of an outpatient pair fall in `[index - 365, index - 1]`
(`04_other_malig.R`, the join to `outpatient_pairs`). The inpatient claim is
bounded by the same window.

Why: the criterion is another cancer in the 1L baseline. Bounding only the
first claim would let a claim the day before the index and its confirmation a
month after it exclude the patient on one baseline claim.

Moves: a larger cohort; a pair straddling the index excludes nobody. The
30-day pairing rule is unchanged. Lands on attrition step 7.

Status: open. If the study team means a post-index claim to be able to confirm
baseline disease, the bound on the second claim comes out and the cohort gets
smaller.

### Bone metastasis excludes

Rule: `C79.51`, `C79.52` and `198.5` (secondary neoplasm of bone and bone
marrow) are metastatic cancers and exclude. They are not override labels.

Why: the rule excludes on the same primary tumour type or metastatic cancer,
and these are metastatic cancer.

Moves: a smaller cohort. Myeloma bone disease is commonly coded `C79.51`, so
some patients removed are myeloma patients whose lesions were coded as
metastases. That cost is accepted. Lands on attrition step 7.

Status: decided - the stated rule governs.

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
metastases at different sites confirm each other; pairing them on site would
ask for the same metastasis twice.

Moves: only regroups codes already on `other_malig.csv`; adds none. The log
names how many codes each prefix claimed, and warns if the group is empty.
Two tiers to watch: `C77` ("secondary and unspecified") and `C800` (nothing
localised) are weaker evidence than a sited metastasis, and `C79.51` / `C79.52`
now pair with any metastatic code. `NDMM_OTHER_MALIG_GRAIN` holds each watched
tier out of the collapse (`collapse without C77/196`, `collapse without
C800/1990`) and keeps all metastatic codes apart by prefix (`mets kept apart by
prefix`); the gap between each row and `as configured` is that choice's cost in
patients.

One assumption is untested: coding guidance reports a secondary neoplasm with
its primary where the primary is known. If that holds in these claims, most
metastatic patients are already reachable through the primary code and this
group adds little.

Status: measured.

### Plasma-cell labels are the index disease

Rule: a code does not count as another cancer if it is on `mm_dx.csv` (the
index disease by definition, whatever its label says), or if its label is one
of the overridden plasma-cell labels. `NDMM_MM_ADJACENT_STATES` chooses the
labels:

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

Why: `other_malig.csv` is a generic other-cancer list, so it can carry codes
that are the index disease, and excluding on them would remove patients for
having the disease that put them in the cohort. The three plasma-cell disorders
sit in C90, where the fourth digit is the disease state, not the disease:

| condition | not achieved remission | in remission | in relapse |
|---|---|---|---|
| Plasma cell leukemia | `C90.10` | `C90.11` | `C90.12` |
| Extramedullary plasmacytoma | `C90.20` | `C90.21` | `C90.22` |
| Solitary plasmacytoma | `C90.30` | `C90.31` | `C90.32` |

Overriding only the first column would exclude a patient whose plasma cell
leukemia is in remission and keep an identical one whose disease has not
achieved it, so the default overrides all nine. Monoclonal gammopathy is
premalignant and reaches the list only because the list is generic.

Moves: a larger cohort under `override`; the other modes exclude more. Lands on
attrition step 7. `NDMM_MM_ADJACENT_GROUPS` and `NDMM_MM_ADJACENT_CODES` show
what was kept and what still excludes.

Status: open. One question decides all nine C90 labels: is a patient with
solitary plasmacytoma, extramedullary plasmacytoma or plasma cell leukemia
carrying a second plasma-cell neoplasm, or one disease? If one disease, all
nine stay overridden; if separate cancers, `mgus_only`, under which every C90
label excludes. Whether
`other_malig.csv` carries myeloma's own codes - and so whether the `mm_dx.csv`
rule is doing real work - is unverified: `other_malig_overlap.R` answers it from
the CSVs without the warehouse, and `NDMM_MM_ADJACENT_GROUPS` (which selects
`MYELOMA` labels) answers it on the first run.

---

## 5. Study window and data vintage

Rule: the study period is 2018-01-01 to 2026-03-31, pinned in `CONTRACT`, read
from the cumulative `2026q1` CDM tables. A LOT run over this cohort must use the
same window. `lot` takes it from its own `config.csv` (the same defaults) or as
run arguments, and records it in `LOT_RUN_METADATA`:

```
Rscript lot/engine/build.R ndmm_NDMM_COHORT ndmm_ 2018-01-01 2026-03-31
```

Why: `lot` bounds every claim scan by the cohort's `INDEX_DATE` and end of
observation, and the study end picks the quarterly tables. A cohort observed
past the window `lot` reads would lose follow-up with nothing erroring: lines
end early and discontinuations appear that did not happen. `lot`'s
`check_cohort_window()` stops a cohort indexed before its study start or
observed past its study end. The window is not in `lot`'s own `CONTRACT`: the
algorithm is unchanged and the dates belong to the cohort.

Moves: nothing, if the windows agree; the check stops them disagreeing. The
study package holds its own window to the cohort's recorded one
(`README.md`, "Settings").

Status: signed off.

---

## 6. What was checked about the CDM

Assumptions this build makes, and what the vendor documentation says. Check
here before asking the warehouse.

- **`ICD_FLAG`** is `'9'`, `'10'` or blank (`VARCHAR(2)`). `9`/`ICD9`/`ICD-9`
  and `10`/`ICD10`/`ICD-10` map to a family; anything else is NULL and matches
  no code list. It is not read as ICD-10, which would mis-class a genuine ICD-9
  claim with a blank flag. What a blank costs is section 11.
- **Diagnosis position is not filtered.** `DIAG_POSITION` runs 1 to 25, and an
  MM diagnosis counts in any position.
- **Enrolment spans come from `member_enrollment`**, not the
  `member_cont_enrollment` rollup. The rollup bridges gaps of less than 30
  days; the study counts 30 or fewer as continuous, so the rollup would drop
  patients the study keeps. Only the raw table shows the true gaps the no-gap
  spans need.
- **Medical and pharmacy benefits are satisfied by construction.**
  `member_enrollment` has no benefit indicator (`ASO`, `BUS`, `CDHP`,
  `PRODUCT`, `HEALTH_EXCH` and `GROUP_NBR` are plan structure and funding), so a
  span carries both and there is nothing to filter on. Do not re-derive it from
  claims: enrolled patients with no pharmacy fill are mostly short spans and
  rule-out MM codes, not a coverage signal.
- **The therapy scans read every source.** `rx` holds outpatient prescriptions
  only; `medical` holds professional claims coded CPT/HCPCS and facility
  claims; `med_procedure.PROC` finds a drug given as a procedure. `PROC` is
  almost all seven-character ICD-10-PCS; about 15,000 rows (0.035%) have the
  five-character shape a HCPCS or CPT code needs, so it adds few events. It is
  read because a therapy the scan cannot see lets a patient pass criterion 6
  and can move the index later. No `ICD_FLAG` condition on that arm; code
  length keeps the join to HCPCS/CPT. A source can only add therapy events:
  the cohort can only get smaller, and index dates move earlier, never later.
- **`lot`'s transplant HCPCS branch** (`lot/engine/R/steps/05_sct.R`) joins
  HCPCS codes against `med_procedure.PROC`; given the profile above, those
  codes are found through `medical` in practice.
- **`CONFINEMENT`** is one row per hospitalisation, so a joined `CONF_ID` is a
  sound inpatient test.
- **Pregnancy reads diagnosis, procedure and revenue codes**: `med_diagnosis`,
  `medical` (`PROC_CD` and `BILL_PROC_CD` as HCPCS, `RVNU_CD`) and ICD
  procedures in `med_procedure`. `pregnancy.csv` carries exactly the six code
  types the scan produces; any other type stops the run.
- **NDCs** are assumed to match once both sides are stripped to digits and a
  ten-digit value is padded to eleven (the 4-4-2 layout). Nothing documents the
  width; `check_ndc_shape()` profiles it on every run.
- **`LOC_CD`** marks a facility versus non-facility claim and is used only as
  part of the claim key. Inpatient is classified from `POS`, `TOS_CD` and
  `CONF_ID`.

---

## 7. Month windows are day counts

Rule: every "months" window is a fixed day count. Twelve months of baseline is
365 days, `[index - 365, index - 1]`, at 1L, 2L and 3L. Three months of 2L/3L
follow-up is 90 days. `PRE_LOT1_DAYS = 365` is pinned in `CONTRACT`;
`SUBSEQ_PRE_DAYS = 365` and `SUBSEQ_FU_CE_DAYS = 90` are pinned by
`subseq_check_windows()` in `R/build_subsequent.R` (`NDMM_SUBSEQ_OVERRIDE=TRUE`
builds others as a sensitivity), and the values used are written on every 2L/3L
output as `CE_PRE_DAYS` and `CE_FU_DAYS`.

Why: calendar months would make the window depend on the index month - 90 to 92
days for three months, 365 or 366 across a leap day - so two patients indexed a
day apart would face different windows. 90 days is the shortest three calendar
months, so it is the more permissive reading.

Moves: the 1L sensitivity table (`NDMM_FU_CE_COUNTS`) put 90 days and three
calendar months seven patients apart.

Status: open. The study text says months; the code uses days.

---

## 8. Death dates are constructed, not read

Rule: the CDM records death as year and month (`YMDOD`), sometimes year alone.
`R/steps/00_mm_cohort.R` builds a date:

- year and month: the 15th, or the last day of the month if the qualifying
  diagnosis falls later in that month;
- year only: 15 July, or 31 December if the diagnosis falls after 15 July that
  year;
- never before the MM diagnosis: an earlier constructed date is set to it.

`NDMM_COHORT` then sets a death date before the 1L index to the index, and
criterion 5 requires enrolment on the index date whatever the death date says.

Why: the 15th-of-month rule is the base convention. The other rules keep a
constructed date from contradicting an observed one - a death before the
diagnosis or the treatment that put the patient in the study.

Moves: follow-up and death-based eligibility for the patients they touch.
Treatment dated after a constructed death in the same month is outside the
patient's observation (`ENDDATE` is the earlier of the study end and death).

Status: open. The 15th-of-month rule does not cover a year-only record or a
diagnosis after the constructed date; both occur and needed a convention.

---

## 9. Pregnancy - which window

Rule: the exclusion runs over the whole study period, `STUDY_START` to
`STUDY_END`, on all three claim sources (`R/steps/05_pregnancy.R`).

Why: the code applies the study period; the alternative reading is the
patient's own baseline and follow-up. Which is right is open.

Moves: the study period is the wider window, so it excludes more - a claim
years from a patient's index drops them here and would not under the other
reading. `NDMM_PREG_WINDOW_COUNTS` prices it, one row per window with the
applied row marked:

| column | |
|---|---|
| `N_WITH_PREG_CLAIM` | indexed candidates with a claim in that window - not the number excluded |
| `N_EXCL_INCREMENTAL` | those the criterion actually removes: a claim, and every other criterion passed |
| `N_COHORT` | the cohort with this criterion under that window |

The gap between the two `N_COHORT` rows is what the decision costs. The
alternative row varies only the window: the 365-day baseline, and follow-up to
death or the study end - it does not stop at disenrolment. If the study team
means follow-up to stop there, this row is an upper bound for
`N_WITH_PREG_CLAIM` and `N_EXCL_INCREMENTAL` and a lower bound for `N_COHORT`.

Status: open. The patient-specific window is the three `BETWEEN` bounds in
`05_pregnancy.R`, and would make the cohort larger.

---

## 10. Maintenance is a flag, not a period

Rule: no maintenance period is built - no start, end, type or end reason. The
LOT engine derives `contains_mtx_reg`, a descriptive 0/1 on a line, and a line
whose regimen reduces to a single maintenance agent continues as the same line.
`lot/LOT_RULES.md` section 10 is the home of this rule.

Why: a full definition (a period of 120 days or more with only a valid
maintenance therapy, 30 days after an autologous transplant, the initial
regimen tapering into it, and named valid regimens in
`maintenance_validated.csv`) has not been built. That maintenance is never a
line is the consequence, not a decision that it should not be.

Moves: line counts wherever a maintenance period would have opened.

Status: not built.

---

## 11. An ICD_FLAG naming neither family - reported, not gated

Rule: `check_icd_flag()` in `R/build_ndmm.R` finds claims whose `ICD_FLAG`
names neither family and whose normalised code is on a list this cohort reads,
names each code and its list, writes the finding with its counts to
`FINDINGS`, and continues. On the 2026q1 data, 16 rows across two CDM tables:
15 diagnosis, 1 procedure.

Why: those rows match no code list entry, so nothing about the cohort turns on
them directly, but the miss cuts both ways. On an MM diagnosis code a lost match
can exclude a patient who should be in; on an other-cancer or pregnancy code it
can keep one who should be out; on a clinical-trial code it moves nobody. The
finding's list column says which applies.

- `NDMM_ICD_FLAG_MAX_ROWS` stops the build above a row count. It ships empty,
  so the build reports at any volume; every run records `icd_ceiling(...)`.
  Setting it is one config line.
- A ceiling bounds volume, not composition: the same count on different codes
  still passes. That is what reading `FINDINGS` is for - it carries the row
  count, a patient figure, the number of codes and each code's list.
- The patient figure is summed over codes and both CDM tables, so it bounds
  distinct patients from above (`patient-hits (summed, >= distinct)`).
- A completed run writes `NDMM_RUN_METADATA.FINDINGS`. A run the ceiling stops
  never reaches that write, so the same string is on its
  `NDMM_BUILD_STATUS.FINDINGS` row.

Status: accepted for 2026q1, unbounded by default. Re-read on each data
refresh. Setting a ceiling is the study team's call.

---

## 12. Age is tested at the earliest qualifying diagnosis

Rule: the diagnosis date is the patient's earliest qualifying date, chosen
before age is looked at; then `year(diagnosis) - YRDOB >= 18` keeps or drops the
patient. A patient who qualifies at 17 and again at 18 is excluded, not moved to
the later date.

Why: I2 is age at the time of MM diagnosis, and "newly diagnosed" is the
earliest one. The diagnosis date also gates the 1L index - the first therapy
claim on or after it - so advancing it would let a later claim be recorded as
first line for a patient whose real first line was at 17.

Moves: can only drop a patient, never change a diagnosis date. Lands on
attrition step 2.

Status: no open question is recorded against it.
