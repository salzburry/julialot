# NDMM cohort - recorded decisions

Choices that change who is in the cohort. Each says what was decided, what the
code does, and what still needs confirming.

A decision here is only as good as the person who made it. Pending sign-off
means the code is written and the number is reported, but nobody has signed the
record.

---

## 1. Follow-up enrolment - one day, this cohort only

Decided: the enrolment span must cover the 1L index date itself. One day,
not the three months used elsewhere.

Scope: this cohort only. Others keep three months unless changed separately.

Code: `NDMM_FU_CE_DAYS = 0`, pinned in `CONTRACT`, so changing it is a
deliberate edit rather than a setting anyone can pass. The flag is `CE_lot1_fu`
in `R/steps/06_flags.R`, built over no-gap spans and bounded by death and the
study end.

Effect: a larger cohort than three months would give. Every patient it adds
was enrolled on their index date but not for three months after. The difference
lands on attrition step 5.

Measured: `<prefix>NDMM_FU_CE_COUNTS` gives the cohort size at 0, 30, 60 and
90 days and at three calendar months, with the applied row marked.

Status: signed off. The one-day rule is the study team's decision for this
cohort. Three months is written elsewhere and anyone checking will find the
difference, so `NDMM_FU_CE_COUNTS` reports both numbers on every run and the
applied row is marked - the divergence is visible rather than argued about.

---

## 2. Belantamab - split across two packages

Decided: the exclusion runs in two halves, because no one package can see
all of it.

| half | where | why |
|---|---|---|
| before the 1L index | here, criterion 9 (`NO_BELANTAMAB_PRE_LOT1`) | `lot` cannot see it: `map_stacked` starts at the cohort's `INDEX_DATE` |
| index onward | `lot`, criterion `no_belantamab` | this package has no lines yet |

Neither half is a proxy. A belantamab claim before the index is belantamab
before the index; a belantamab treatment episode after it is belantamab in a
line.

Why the split. Lines do not exist when this cohort is built - the LOT
algorithm runs over it. A rule here standing in for LOT membership could only
approximate, and its mistakes would be unauditable: a patient wrongly removed
never gets lines, so nobody could check. Asking about a date has no such
problem, which is why the pre-index half stays here.

Bounded to the study period. The rule names no period, which read literally
means all of history. The CDM reaches back well before the study start, so an
unbounded scan would act on claims outside the window every other criterion is
bounded to - and `lot`, which settles the other half, cannot see outside it
either. The scan runs `NDMM_STUDY_START` to `study_end`. For the literal
reading, remove the lower bound in `build_ndmm_belantamab_tx()`.

What it catches: belantamab more than 365 days before the index. Such a
patient cannot be indexed on it, passes the 12-month prior-therapy criterion,
and reaches `lot` with the claim invisible. Criterion 9 overlaps
`NO_PRIOR_MM_TX` deliberately, so its incremental drop is exactly that group.

Both packages spell it the same way. One whole `CL_MED_ABBR`, matched
exactly - `BELA` by default in each. `build_ndmm_belantamab_codes()` stops if
the code list carries another `BEL*` abbreviation it does not name, because
those rows would fall outside the exclusion while the two packages still agreed
with each other. It also stops if the configured abbreviation matches nothing:
"no patient had belantamab" and "the abbreviation is wrong" give the same empty
result. `check_belantamab_abbr()` in `lot` does the same on its side, when
`APPLY_NO_BELANTAMAB` is on.

In `lot`: criterion `no_belantamab` in `R/line_criteria.R`. Patient-level -
false on every line of an affected patient - so `first_failed_lot` lands on
their earliest line and `truncate` leaves them with none. It matches a whole
`MED_ABBR` on treatment episodes in `map_stacked`, not the built lines, which
is what keeps "any LOT" literal: reading `LOT_BASE_MEDS` would bound the
question by `MAX_LOT` and by position within a line.

Downstream, and this matters:

- `<prefix>NDMM_COHORT` is the cohort pending half of one exclusion, not the
  final study population. Reading its count as the final N is wrong. The final
  population is the patients in `LOT_LONG_FINAL`, and the final count is the
  last row of `LOT_ATTRITION`.
- The attrition has nine steps and its last row is still not the study's N.
  Its ninth step removes belantamab BEFORE the 1L index only - the row is
  labelled that way in the table - because the index-onward half has no lines
  to look at yet.
- `NO_BELANTAMAB` is an advisory flag over the whole study period on
  `<prefix>NDMM_FLAGS_ALL` - not on the cohort table, which carries only the
  ten columns LOT reads. Nothing filters on it.
- `<prefix>NDMM_BELANTAMAB_RECONCILE` lists every cohort member with a
  belantamab claim and its date. That is the handover list.
- Belantamab cannot set the 1L index. Different rule, and it stays here,
  because the index is what LOT1 anchors on.

Status: decided and implemented.

---

## 3. Eligible 1L agents - the code list is the list

Decided: `cl_mma_codelist.csv` is the study's definition of MM therapy, so
it is also the eligible-1L set. There is no separate eligibility file.

Code: any agent on that list may set the index, less steroids (dropped where
`NDMM_MMA_CODELIST` is built) and less belantamab. The earliest such claim on or
after the MM diagnosis and on or after `LOT1_FROM` is the index.

On the production file: 26 agents, so 25 can set an index. The steroid drop
removes nothing - none of `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`
is in `CL_MED_ABBR` - and stays as a guard against a later list that carries
them.

To bar an agent: `NDMM_INDEX_EXCLUDED_ABBRS`, empty by default. Every entry
is checked against the code list, so a name matching nothing stops the run.

What it gives up: narrowing the set now needs code rather than a file. That
is the point - the code list is authoritative.

Status: decided and implemented.

---

## 4. Other malignancy - grouping and bone metastasis

Two questions, both decided. What remains is data-dependent: the review tables
say how much each moved, and those are read after the first run.

### Grain - pair on the ICD category

Two outpatient claims confirm another cancer only if they are the same cancer.
`other_malig.csv` has 1,643 code rows and 1,618 distinct `tumor_group` values,
so the label is one per code, not a grouping - pairing on it reduces to needing
the same diagnosis code twice, and the criterion under-detects.

Code: claims pair on the first three characters of the ICD code, which
is the primary tumour type: every `C50.x` is breast, `C34.x` lung, `C79.x` a
secondary neoplasm. The cohort gets smaller, because claims that never
paired now do.

`C44` (skin), `C76` and `C80` (ill-defined sites) are broad categories, but in
each the two claims are still the same broad cancer type, which is the unit the
rule asks for.

Measured: `<prefix>NDMM_OTHER_MALIG_GROUPS` lists every category with its
code and label counts; `<prefix>NDMM_OTHER_MALIG_GRAIN` prices the change
against the per-label grain.

### Both claims inside baseline, not just the first

The pair has to fall inside the 1L baseline window. The source bounded only the
first claim, so a claim the day before the index and its confirmation a month
*after* it excluded the patient - on one baseline claim, from a pair the
baseline never contained. The criterion is another cancer **in** the 1L
baseline, so both `first_dt` and `next_dt` are bounded to
`[index - 365, index - 1]`.

This makes the cohort larger, and it is the one change in this section that
moves it that way. A pair straddling the index no longer excludes anyone, so
patients the source dropped are now in. Two claims 30 days apart still confirm,
and the 30-day pairing rule is unchanged - what changed is where the pair has
to sit.

Code: `04_other_malig.R`, the join to `outpatient_pairs`. `next_dt` is always
after `first_dt`, so its lower bound is arithmetically redundant; it is written
out anyway so the condition reads as one statement about a pair rather than two
unrelated ones.

### Bone metastasis excludes

The rule excludes on the same primary tumour type or metastatic cancer, and
`C79.51`, `C79.52` and `198.5` are metastatic cancers. All three exclude.

Code: `NDMM_MM_ADJACENT_OVERRIDE` is four labels - monoclonal gammopathy and
the three plasma-cell disorders. Those stay because they are the index disease
or its precursor, not another cancer. Secondary neoplasm of bone is not among
them, so `C79.51` now reaches the other-cancer scan and pairs under `C79` with
the rest of the secondary-neoplasm block.

What it costs: myeloma bone disease is commonly coded `C79.51`, so some
patients removed by this will be MM patients whose lesions were coded as
metastases. That concern is real; the decision is that the stated rule governs.
`<prefix>NDMM_MM_ADJACENT_CODES` lists what the four labels still keep, and
attrition step 7 is where the change lands.

### Metastatic codes group together

The category rule works for primaries - every `C34.x` is lung - but not for
metastases. `C78.7` (liver) and `C79.51` (bone) are different categories, so two
outpatient claims documenting metastases at two sites never confirmed each
other, and the patient stayed in the cohort.

That is the wrong question to ask of them. The rule excludes on the same primary
tumour type or metastatic cancer, and metastatic cancer qualifies in its own
right - pairing two mets on site asks for the same metastasis twice.

Code: `NDMM_METASTATIC_PREFIXES` in `standalone_constants.R`. Codes matching
any prefix collapse to one group `MET`; everything else keeps the ICD category.

| in the group | | |
|---|---|---|
| `C77` | secondary and unspecified neoplasm of lymph nodes | `196` |
| `C78` | secondary neoplasm of respiratory and digestive organs | `197` |
| `C79` | secondary neoplasm of other and unspecified sites | `198` |
| `C7B` | secondary neuroendocrine tumours | - |
| `C800` | disseminated malignant neoplasm, unspecified | `1990` |

`C800` and `1990`, not `C80` and `199`: `C80.1` is a primary of unknown site and
`C80.2` a transplant case, and neither is secondary. They keep the category
rule.

What it does not do: add anything to the exclusion. This regroups codes
already on `other_malig.csv` - a code not on that file was never in scope.
`report_metastatic_group()` logs how many codes the group actually claimed and
warns if that is zero, so a prefix matching nothing is visible.

Two things to watch on the first run.

`C79.51` and `C79.52` are in this group, per the decision above, so a myeloma
patient whose bone lesions are coded that way now pairs with any metastatic
code rather than only another `C79`. Myeloma does not usually produce nodal or
visceral secondaries, so this should be small - but it is not zero and it falls
on patients the study wants to keep.

`C77` is "secondary and unspecified" neoplasm of lymph nodes, and `C800` is
used when nothing is localised. Both are weaker evidence than a sited
metastasis. If the numbers below show either doing real work, they are the two
to reconsider.

Measured: `<prefix>NDMM_OTHER_MALIG_GRAIN` has a row where metastatic codes
are kept apart by the prefix each matched instead of collapsed. The gap between
that row and the configured one is exactly what this decision costs.

It is not plain `substr(dx, 1, 3)` for that row, which would be the obvious
thing to write and would be wrong: `C800` would fall back to `C80` and rejoin
`C80.1` and `C80.2`, which are deliberately outside the group. The difference
would then net a pair the collapse adds against one it removes and
report the two as a single number.

`report_metastatic_group()` logs the code count per prefix, which says whether
a tier is represented on the code list at all - a prefix matching nothing is
named rather than silently inert. It does not say whether that tier
excluded anybody; a code count cannot.

For that, the grain table holds each watch-list tier out of the collapse while
the rest stays configured: `collapse without C77/196` and
`collapse without C800/1990`. The gap between either and the configured row is
that tier's own contribution, in patients. Those two because they are the ones
this record says to watch; `C78`/`C79`/`C7B` and their ICD-9 equivalents are
not in question, and a row each would be four more scans for a number nobody
is going to act on.

One assumption, untested. Coding guidance says a secondary neoplasm is
reported alongside its primary where the primary is known. If that holds in this
extract, most metastatic patients are already reachable through their primary
code and this group adds little. Whether it holds in Optum claims is not
something this package has checked.

Status: decided and implemented; magnitude pending the first run.

### The remission and relapse states stay in the override

The override above says four labels - monoclonal gammopathy and the three
plasma-cell disorders. The default adds six more: plasma cell leukemia,
extramedullary plasmacytoma and solitary plasmacytoma, each "IN REMISSION" and
"IN RELAPSE". A plasma-cell disorder coded in remission or relapse is still a
manifestation of the index disease, not another cancer, so excluding a patient
for it would exclude them for having the disease the study is about.

Code: `NDMM_MM_ADJACENT_STATE_LABELS` in `R/standalone_constants.R`, folded in
when `NDMM_MM_ADJACENT_STATES=override` (the default).
`NDMM_MM_ADJACENT_STATES=exclude` keeps all six in the filter, for comparison,
and `<prefix>NDMM_MM_ADJACENT_GROUPS` records every plasma-cell-looking group
the code list carried and whether the override reached it.

Effect: a larger cohort. Every patient it keeps has one of the six state codes
in baseline and no other exclusion.

Status: implemented as the default; the six states are PENDING SIGN-OFF. The
four core labels were agreed; the states rest on the reasoning above and
nobody has signed it. `NDMM_MM_ADJACENT_GROUPS` and attrition step 7 are where
a reviewer sees what they cost.

---

## 5. Study window and data vintage

Decided: `lot` takes the study window as a run argument, and defaults to
this cohort's: `2016-01-01` to `2026-03-31`.

The window is not in `lot`'s `CONTRACT`. `CONTRACT` fixes what a LOT run
means - induction windows, gap days, transplant rules - and a different value
there is a different algorithm. The window is not that: the algorithm is
unchanged and the dates belong to the cohort.

```
Rscript build.R ndmm_NDMM_COHORT ndmm_ 2016-01-01 2026-03-31
Rscript build.R MM_COH_FINAL       mm_   2015-07-01 2025-06-30
```

Both dates go to `LOT_RUN_METADATA`, so an output says which window, and
therefore which CDM vintage, produced it.

Why it has to match. `lot` bounds every claim scan by the cohort's
`INDEX_DATE` and `OBS_END_DT`, which come from the cohort table. A cohort built
to 2026-03-31 read against 2025q2 tables loses nine months of every patient's
follow-up: lines end early, treatment episodes discontinue where the patient was
still being treated, and the end reason comes out `STUDY_END`. Nothing errors
and no count looks wrong.

Made fatal. `check_cohort_window()` reads the cohort's actual date range and
stops if it falls outside the window the run was given, naming the count, the
date and the CDM vintage it would have read. `check_settings()` rejects a window
that runs backwards; `pin_study_window()` rejects dates that will not parse.

Vintage. `2026q1` is the same tables and column names as `2025q2` with data
extended through 2026-03-31 - a wider read of the same structures, so a window
that moves between them has nothing to re-validate first.

Line criteria are recorded, not just applied. `APPLY_NO_BELANTAMAB=TRUE` is
right for this cohort and wrong for one with no such exclusion, and passing a
different cohort does not change it. `report_line_criteria()` logs and records
every criterion, applied or not, with the patients it catches
(`LINE_CRITERIA_APPLIED`, e.g. `no_belantamab=on:truncate:37`). Without it,
"no patient had belantamab", "the criterion was off" and "this is not that
cohort" all produce the same `LOT_LONG_FINAL`.

Status: decided and implemented.

---

## 6. What was checked about the CDM

Assumptions this build makes, and what the vendor documentation says about
them. Check here before asking the warehouse.

`ICD_FLAG` is `'9'` or `'10'` and nothing else. The column is `VARCHAR(2)`,
so longer spellings cannot appear. Both real values are covered and anything
else yields NULL, which matches no code list. Reading every non-ICD-9 spelling
as ICD-10 would mis-class a blank flag on a genuine ICD-9 claim.

Diagnosis position is not filtered, and should not be. `DIAG_POSITION` runs
1 to 25. An MM diagnosis counts in any position, so no step reads the column.

Enrolment spans come from `member_enrollment`, not the rollup.
`member_cont_enrollment` bridges breaks of less than 30 days; the study counts
gaps of 30 days or fewer as continuous. A day's difference at the boundary,
and the rollup is stricter, so it would drop patients the study keeps. Building
the spans here bridges 30 or fewer - and only a raw build reveals the true gaps
`NDMM_ENROLL_SPANS_STRICT` needs.

Medical and pharmacy benefits are satisfied by construction. The extract
does not separate them: `member_enrollment` has 27 columns and none is a benefit
indicator. `ASO`, `BUS`, `CDHP`, `PRODUCT`, `HEALTH_EXCH` and `GROUP_NBR` are
plan structure and funding, not coverage type. A span carries both, so
`ELIGEFF`/`ELIGEND` already express the requirement and a predicate would filter
on nothing.

Do not re-derive this from claims. Enrolled patients with no pharmacy fill look
like a coverage signal and are not: that count is dominated by short spans and
by patients whose only MM code is a rule-out.

The therapy scan needs every source. `rx` holds outpatient prescriptions
only; `medical` holds professional claims coded CPT/HCPCS and facility claims.
An administered agent and a dispensed one arrive by different routes.

`med_procedure.PROC` is read as a medication source, in `overall` and here.
It finds a drug given as a procedure under a HCPCS or CPT code. The scan has
five arms: `PROC_CD`, `BILL_PROC_CD` and `NDC` in `medical`, `NDC` in `rx`, and
`PROC` in `med_procedure`.

Measured over the study period, `PROC` is 43,137,224 of ~43.2M rows at
`ICD_FLAG='10'` and seven characters - ICD-10-PCS. The five-character tail, the
only shape a HCPCS or CPT code could occupy, is about 15,000 rows: 0.035%. So it
adds very few events. It is read because the failure it guards is asymmetric - a
therapy the scan cannot see lets a patient pass the no-prior-therapy criterion
on missing data, and can move the index later than it belongs.

No `ICD_FLAG` condition, matching how `05_sct.R` reads the same column, so a
J-code with an unexpected flag is not dropped. The join is self-limiting anyway:
ICD-10-PCS is seven characters and ICD-9 procedures three or four, so only a
five-character `PROC` can equal a HCPCS or CPT code.

Adding a source can only add therapy events, so the cohort can only get smaller
and index dates can move earlier but never later. Size it from
`<prefix>NDMM_INDEX_AGENTS` and the attrition.

The SCT HCPCS branch matches little. `05_sct.R` joins `CL_CODE_TYPE =
'HCPCS'` against `mp.PROC`. Given the profile above, the HCPCS SCT codes - CPT
`38240`/`38241`, `S2150`, CAR-T `Q2042`/`Q2054`/`Q2055`/`Q2056` - are found
through `medical` in practice. Left in place as a safety net.

`CONFINEMENT` is one undeduplicated row per hospitalisation, with facility
detail bundled in. That is what makes `cf.CONF_ID IS NOT NULL` a sound inpatient
test.

Pregnancy reads diagnosis, procedure and revenue codes in both packages.
`RVNU_CD` and `BILL_PROC_CD` are unstacked from `medical` alongside `PROC_CD`.
`BILL_PROC_CD` is the facility-claim procedure code and the therapy and SCT
scans already read it; pregnancy did not, so a pregnancy HCPCS code populated
only there kept the patient. Of 5,318 codes on `pregnancy.csv`, only the 185
typed `HCPCS` can appear there. A source can only add exclusions.

`pregnancy.csv` stops the run on a code type nothing reads. The scan emits
six - `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV` - and a
row typed anything else would load, join, match nothing and keep the patient
with no error. The file carries exactly those six (3,049 / 1,549 / 447 / 69 /
185 / 19), so the guard passes today. It is there because the file is production
and can be re-issued, and a `CPT`-typed delivery code would otherwise be silent.

Still assumed, not documented: that NDCs match once both sides are stripped
to digits and left-padded to 11. Nothing states the width. The join guards the
failure that matters - a code with no digits and a NULL `NDC` both pad to
`00000000000` - by requiring digits on the code-list side, and
`check_ndc_shape()` profiles it every run.

`LOC_CD` marks a facility versus non-facility claim. Used only as part of
the claim key here; inpatient is classified from `POS`, `TOS_CD` and `CONF_ID`.
Changing that would change who counts as inpatient.

---

## 7. Month windows are day counts

Decided: every "months" window in this package is a fixed day count. Twelve
months of baseline is 365 days - `[index - 365, index - 1]` - at 1L, 2L and
3L alike. Three months of 2L/3L follow-up is 90 days.

Why days: `add_months()` moves by calendar months, so the window's length
would depend on which month the index fell in - 90 to 92 days for three
months, 365 or 366 across a leap day. Two patients indexed a day apart would
face different windows. A fixed count asks every patient for the same
evidence. 90 is the shortest three calendar months, so it is the more
permissive reading; the 1L build's own sensitivity table put 90 days and
three calendar months seven patients apart.

Code: `NDMM_PRE_LOT1_DAYS = 365` pinned in `CONTRACT`;
`SUBSEQ_PRE_DAYS = 365` and `SUBSEQ_FU_CE_DAYS = 90` pinned by
`subseq_check_windows()` in `R/build_subsequent.R`. Any other pair stops the
2L/3L build unless `NDMM_SUBSEQ_OVERRIDE=TRUE` names it a sensitivity, and
whatever was used is written into every output as `CE_PRE_DAYS` and
`CE_FU_DAYS`.

Status: implemented and pinned; the day-count reading is PENDING SIGN-OFF as
a recorded interpretation of "12 months" and "3 months".

---

## 8. Death dates are constructed, not read

The CDM records death as year and month (`YMDOD`), sometimes year alone. A
date is built from it in `R/steps/00_mm_cohort.R`:

- year and month: the 15th of that month - unless the qualifying diagnosis
  falls later in that same month, in which case the last day of the month, so
  death does not land before the diagnosis that put the patient in the study.
- year only: July 15th - unless the diagnosis falls after it that year, in
  which case December 31st.
- either way, never before `MM_DX_DT`: a constructed date earlier than the
  diagnosis is set to the diagnosis date.

The protocol states only the 15th-of-month rule. The month-end, mid-year and
clamping rules exist to keep a constructed date from contradicting an
observed one, and they move follow-up and death-based eligibility for the
patients they touch.

Status: implemented; the construction rules beyond the 15th are PENDING
SIGN-OFF as recorded data-construction conventions.

## 9. Pregnancy - which window, when two documents disagree

The exclusion is applied over the **whole study period**, `NDMM_STUDY_START` to
`STUDY_END`. `05_pregnancy.R` bounds all three claim sources - diagnosis,
procedure and revenue - on that window.

Two authorities say different things and neither had been recorded as winning:

| | says |
|---|---|
| the current protocol, 6.2.1.2 Exclusion Criteria | "Evidence of pregnancy: ... indicating pregnancy or childbirth **during the study period**" |
| the validated program spec, citing an earlier protocol 4.2 Exclusion 3 | ">=1 medical claim ... **during the baseline or follow-up period**", and "Spans baseline + follow-up period" |

The code follows the protocol: a later version supersedes a spec sheet built
against an earlier one. Recorded here because the spec sheet is still on disk
saying otherwise.

It is the wider window, so it EXCLUDES MORE. The study period is about ten years
and a patient's own baseline and follow-up is a fraction of it, so a pregnancy
claim years from a patient's index date drops them under this reading and would
not under the other.

Measured: `<prefix>NDMM_PREG_WINDOW_COUNTS`, one row per reading with the
applied one marked - the same shape `NDMM_FU_CE_COUNTS` uses for the follow-up
window. Three counts, and the distinction between them matters:

| column | what it is |
|---|---|
| `N_WITH_PREG_CLAIM` | indexed candidates carrying a claim in that window. NOT the number excluded - a patient already failing continuous enrolment or prior therapy is not additionally excluded by pregnancy. |
| `N_EXCL_INCREMENTAL` | those the criterion actually removes: carrying a claim AND passing every other criterion. This is the incremental effect. |
| `N_COHORT` | the cohort under that window, the whole conjunction with this criterion recomputed. |

The gap between the two `N_COHORT` rows is what this decision costs. Kept plus
excluded is the cohort with the criterion removed and does not depend on the
window, so the two rows have to agree on it - checked on every run, along with
the containment (the narrower window can only leave a larger cohort and can
only find fewer claims) and against `NDMM_PATIDS`: the applied row recomputes
the conjunction the published cohort count comes from, so it has to equal it.

**What the alternative row is, exactly.** It varies the window and nothing else:
this build's 365-day baseline, not calendar months, and follow-up running to
death or the study end. **It does not stop at disenrolment.**

The program spec says "baseline or follow-up period" without defining where
follow-up ends. If the study team means it to stop where continuous enrolment
stops, this row bounds the narrower reading rather than being it - and in which
direction depends on the column:

| | if follow-up should stop at disenrolment |
|---|---|
| `N_WITH_PREG_CLAIM`, `N_EXCL_INCREMENTAL` | this row is an **upper** bound |
| `N_COHORT`, and the patients recovered against the study-period rule | this row is a **lower** bound |

So the true alternative cohort is at least as large as this row says. That is
the question to settle at sign-off, and the reason this is a sensitivity rather
than a re-creation of the older pipeline.

One scan serves both: the claim scan writes `NDMM_PREGNANCY_EVENTS` with dates,
the exclusion takes distinct patients of it over the study period, and the
review table filters the same events to `[index - 365, follow-up end]`.

Status: implemented as the current protocol says. PENDING SIGN-OFF on the
precedence itself - if the study team means the patient-specific window, it is
the three `BETWEEN` bounds in `05_pregnancy.R` and the cohort gets larger.

## 10. Maintenance is a flag, not a period

The protocol (5.1.1, and `maintenance_validated.csv`) defines a maintenance
regimen: a period of 120 days or longer during which only a valid maintenance
therapy is available; 30 days instead of 120 following an autologous SCT, or
after the second of a tandem pair, with whatever days are available where
follow-up ends first; the initial regimen transitioning into maintenance as
other agents are discontinued; and named valid mono and dual regimens.

**None of that is built.** The engine derives `contains_mtx_reg`, a descriptive
0/1 on the line, and constructs no maintenance period, start, end, type or end
reason. The validation sheet records every row of the definition as not yet
implemented, and `lot/validation/R/definitions.R` states the resulting behaviour
as this build's answer - that maintenance is never a line.

That is not a decision that maintenance should not be a line. The period the
protocol defines does not exist here, so the question has not been put. A line
whose regimen reduces to a single maintenance agent continues as the same line.

Status: NOT IMPLEMENTED. This is the largest single gap between the protocol and
the build outside safety and HCRU, and it changes line counts wherever the
protocol would have opened a maintenance period.
