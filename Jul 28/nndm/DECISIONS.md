# NDMM cohort — recorded decisions

Decisions that change who is in the cohort, where the study definition is silent,
ambiguous, or deliberately overridden. Each says what was decided, what the
code does about it, and what still needs a counter-signature.

This file is the record. It is not the authority: a decision here is only as
good as the person who made it, and the "recorded by" line says who that was.
Anything marked **pending sign-off** has been implemented and reported but is
still waiting on a formal record.

---

## 1. Follow-up continuous enrolment — one day, LOT1 only

**Decided:** the 1L follow-up CE requirement is **one day** — the enrolment
span must cover the 1L index date itself. It is *not* the three months named
elsewhere for this study.

**Scope:** the LOT1 / 1L NDMM cohort only. Other cohorts keep three months
unless changed separately.

**What it replaces:** the follow-up enrolment requirement of three months from
the index date, or death if sooner, with no gaps.

**What the code does:** `NDMM_FU_CE_DAYS = 0`, pinned in `CONTRACT` so changing
it is a deliberate contract edit rather than a setting anyone can pass. Zero
means the span must cover `[index, index + 0]` — the index date, one inclusive
day. The flag is `CE_lot1_fu`, built in `R/steps/06_flags.R` over no-gap spans
(`NDMM_ENROLL_SPANS_STRICT`) and bounded by death and the study end.

**Effect on the cohort:** larger than the three-month rule. Every patient this
adds is one who was enrolled on their index date but not for three months
after it. The difference lands entirely on attrition step 5.

**What it costs, measured:** every run writes `<prefix>NDMM_FU_CE_COUNTS`,
giving the final cohort size at 0, 30, 60 and 90 days and at exactly three
calendar months, with the applied row marked. That table is the evidence for
this decision, not a justification of it — read it on the first production run
and confirm the number is the one intended.

**Recorded by:** the study team, through the build request, and re-confirmed
on 2026-08-02 — one day is the intended rule, and the three-month figure is
**superseded** rather than overridden by accident.

**Status: confirmed, pending a formal record.** The rule is the one
intended and the code implements it. What is still missing is a study decision
record naming the approver and the date, because the inclusion criteria as circulated still
reads three months and anyone checking the build against that text will find a
difference. `<prefix>NDMM_FU_CE_COUNTS` gives both numbers on every run.

---

## 2. Belantamab "in any LOT" — split across the two packages

**Decided:** the exclusion criteria's belantamab exclusion runs in two halves, because no one
package can see the whole of it.

| half | where | why it has to be there |
|---|---|---|
| belantamab **before** the 1L index | here, criterion 9 (`NO_BELANTAMAB_PRE_LOT1`) | `lot` cannot see it at any price — `map_stacked` is built from claims on or after the cohort's `INDEX_DATE` |
| belantamab **from the index onward** | `lot`, criterion `no_belantamab` | this package has no lines, and the criterion is asked over the patient's whole LOT span |

Together they are the study's sentence. Neither is a proxy: a belantamab
claim before the index *is* a belantamab line before the index, and a
belantamab MAP after it *is* belantamab in a LOT.

**Why the pre-index half exists.** Read the exclusion bullets in the exclusion criteria beside
each other and the scoping is deliberate:

> - Evidence of an MM oncology therapy **during the 12-month 1L baseline period**
> - Evidence of another cancer **in the 1L baseline period**
> - Evidence of pregnancy … **during the study period**
> - Received belantamab mafodotin (i.e., an ADC) **in any LOT**

Three carry a period. The fourth does not, and the wording was checked
carefully — the bullet is complete, with no period clause missing from it.

And reading it as post-index makes it redundant: the first bullet already
removes any MM oncology therapy, belantamab included, throughout the 12-month
baseline. A post-index-only belantamab rule would add nothing for the window the
two share. It carries no period of its own — a belantamab line anywhere in the
study period disqualifies them.

**Bounded to the study period, deliberately.** The rule names no period, and
read literally that would mean all of history. The CDM tables reach back well
before the study start, so an unbounded scan would act on claims outside the
window every other criterion in this build is bounded to — and `lot`, which
settles the other half, cannot see outside it either. The scan runs from
`NDMM_STUDY_START` to `study_end`. Anyone who wants the literal reading removes
the lower bound in `build_ndmm_belantamab_tx()`; nothing else changes.

The gap this closed: belantamab **more than 365 days before the index**. Such a
patient was not indexed on the belantamab (it cannot set the index), passed the 12-month prior-therapy criterion, and then reached `lot` with
the claim invisible. Criterion 9 overlaps `NO_PRIOR_MM_TX` deliberately, so its
incremental drop in the attrition is exactly that population.

**Why a whole-cohort proxy went.** Lines do not exist when this cohort is
built — the LOT algorithm runs *over* it — so a rule applied here that tried to
stand in for LOT membership could only ever be an approximation. Its errors were
asymmetric and one was permanently unauditable: a patient it wrongly removed
never reached the LOT run, so nobody could check whether they really had
belantamab in a line. That is why the index-onward half is deferred, and why the
pre-index half is not an instance of the same problem — it asks about a date,
not about a line.

Deferring the index-onward half removes both problems. Every candidate gets
lines, that half is evaluated against actual LOT membership, and there is no
operational definition left to approve.

**What the cohort build still does:**

- **`NO_BELANTAMAB` is still computed** and still ships on the cohort table, as
  an advisory flag. Nothing filters on it. It is computed over the whole study
  period — the widest net — because its only job now is to say who carries a
  belantamab claim at all. `NDMM_BELANTAMAB_SCOPE` is gone; there is no scope to
  choose.
- **`<prefix>NDMM_BELANTAMAB_RECONCILE`** lists every cohort member with a
  belantamab claim, with dates. That is the handover list.
- **the inclusion criteria's "other than belantamab" stays here**, and must. That is a
  different rule — belantamab cannot *set* the 1L index — and the index is what
  LOT1 is anchored on, so it has to be settled before the LOT run.

**Where it is applied:** `lot/R/line_criteria.R`, criterion `no_belantamab`,
enabled by `APPLY_NO_BELANTAMAB` in `lot/config.csv`. The predicate is
patient-level — false on *every* line of an affected patient — so
`first_failed_lot` lands on their earliest line and `on_fail = "truncate"`
leaves them with none, which is the exclusion. It matches a whole `MED_ABBR` on
the patient's treatment episodes in `map_stacked`, not a substring, so an
abbreviation that merely contains `BELA` cannot match — and asking the claims
rather than `LOT_LONG`'s columns is what keeps "any LOT" literal. See section 5.

**Both packages recognise belantamab the same way, and both guard it.** It is
one whole `CL_MED_ABBR`, matched exactly — `BELA` by default in each. This build
used to match the prefix `BEL%` while `lot` matched a whole value, so the two
could disagree on a code list carrying more than one `BEL*` spelling: this one
would take them all, `lot` only its own. Same drug, same rule.

Exactness introduces its own blind spot, so it is guarded too:
`build_ndmm_belantamab_codes()` stops if the list carries another `BEL*`
abbreviation it does not name, because every row under that spelling would fall
outside the exclusion criteria entirely while both packages agreed with each other. And if the
configured abbreviation matches nothing at all, it stops for the older reason —
silently, "no patient had belantamab" and "the abbreviation is wrong" produce
the same empty result.
`check_belantamab_abbr()` in `lot` asks the code list before applying the
criterion and stops if it matches no row, which is the same shape as
`build_ndmm_belantamab_codes()` on the cohort side. It only asks when
`APPLY_NO_BELANTAMAB` is on.

**What this changes downstream, and it matters:**

- **`<prefix>NDMM_COHORT` is the NDMM cohort pending half of one exclusion**,
  not the final study population. Anything reading it as the final N is wrong.
- **The attrition has nine steps** and its last row is still not the study's N.
  Criterion 9 is the pre-index half; the index-onward half is applied in the LOT
  build and reported there.
- The LOT run processes slightly more patients. Belantamab is a later-line ADC,
  so in a 1L newly-diagnosed cohort this should be very few.
- **The two packages must now agree on the study window and on how many lines
  are built.** The window is settled — `lot` takes it as a run argument and
  defaults to this study definition's, so both read `2026q1`. `MAX_LOT` is still a
  stated bound. See section 5.

**Recorded by:** the study team, 2026-08-02.

**Status: decided and implemented.**

---

## 3. Eligible 1L agents — the code list is the list

**Decided:** `cl_mma_codelist.csv` is the study's definition of MM therapy, so
it is the eligible-1L set. No separate eligibility file.

**What the code does:** any agent on that code list may set the 1L index, less
steroids (dropped where `NDMM_MMA_CODELIST` is built) and less belantamab
(barred always, per the inclusion criteria's "other than belantamab"). The earliest such
claim on or after the MM diagnosis and on or after `LOT1_FROM` is the index.

**What was removed:** `codelists/eligible_1l_agents.csv`, its loader and
validation, the allowlist branch, and its `NDMM_ELIGIBLE_1L_CSV` setting. `NDMM_INDEX_EXCLUDED_ABBRS` remains for barring
a named agent operationally - empty by default, and every entry is still
checked against the code list so a name that matches nothing stops the run.

**What that resolves to, on the production file:** 26 agents on the code list,
so the eligible-1L set is the 25 that are not belantamab. The steroid drop
removes nothing — none of `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`
appears in `CL_MED_ABBR`, so `NDMM_STEROID_ABBRS` is a no-op here. It stays in
place as a guard against a later code list that does carry them.

**What it gives up:** narrowing the index-setting set to a named subset now
needs code rather than a file. That is the point of the decision: the code list
is authoritative.

**Recorded by:** the study team, in the implementation thread of 2026-08-02.

**Status: decided and implemented.**

## 4. Other malignancy — grouping and bone metastasis

**Decided:** both parts, below. Neither was an open design question - each was
a gap against the stated rule, so the decision was which reading of the rule to
implement, and both are implemented. What remains is data-dependent: the review
tables say how much each one moved, and that is read after the first run.

**Two separate questions.**

*Grain.* Two outpatient claims confirm another cancer only if they share a
label. With `primary_tumor_groups.csv` empty, the label is the code list's own
`tumor_group`, which is a diagnosis description rather than a primary-tumour
grouping — so one cancer written two ways does not confirm itself and the
criterion under-detects. `<prefix>NDMM_OTHER_MALIG_GRAIN` measures what the
grain costs.

**Measured on the production file:** `other_malig.csv` has 1,643 code rows and
1,618 distinct `tumor_group` values. The label is therefore one per code, not a
grouping, and pairing on it reduced in practice to *the same diagnosis code
twice*.

**Resolved.** Outpatient claims now pair on the **ICD category** — the first
three characters of the code — which is the study's "same primary tumor
type": every `C50.x` is breast, every `C34.x` lung, every `C79.x` a secondary
neoplasm. `primary_tumor_groups.csv` and its loader are gone; there is nothing
a hand-written map could say that the category does not, and leaving it empty
was itself a choice about how the criterion read. The cohort gets **smaller** —
claims that never paired now do. `<prefix>NDMM_OTHER_MALIG_GROUPS` lists every
category with its code and label counts; `<prefix>NDMM_OTHER_MALIG_GRAIN`
prices it against the old per-label grain.

Where the category over-groups: `C44` (skin), `C76` and `C80` (ill-defined and
unspecified sites) are broad. In each the two claims are still the same broad
cancer type, which is the unit the study definition asks for.

*Bone metastasis.* **Decided: follow the study definition.** the exclusion criteria excludes on

> ≥1 inpatient or ≥2 outpatient ICD-9-CM or ICD-10-CM codes on separate days,
> within 30 days, for the same primary tumor type **and/or metastatic cancer**

`C79.51`, `C79.52` and `198.5` are metastatic cancers. The study definition names
metastatic cancer as exclusionary in its own right, so all three exclude.

**What changed:** `SECONDARY MALIGNANT NEOPLASM OF BONE` is removed from
`NDMM_MM_ADJACENT_OVERRIDE`, which is now four labels rather than five —
monoclonal gammopathy and the three plasma-cell disorders. Those four stay
because they are the index disease or its precursor, not *another* cancer;
`C79.5x` is another cancer by the study's own wording. `C79.51` previously
never reached the other-cancer scan; it does now, and pairs under ICD category
`C79` alongside `C79.52` and the rest of the secondary-neoplasm block.

**What it costs:** the group was once overridden because myeloma bone disease
is commonly miscoded as `C79.51`, and that concern is real — some patients
removed by this will be MM patients whose bone lesions were coded as
metastases. The decision is that the study definition governs. The cohort is
**smaller** either way. `<prefix>NDMM_MM_ADJACENT_CODES` lists
what the four remaining labels still keep, and the attrition step 7 count is
where the change lands.

**Recorded by:** the study team, 2026-08-02 — "follow the study definition to the tee".

**Status: decided and implemented.**

---

## 5. Open against the study definition, not yet decided

Read off *Belantamab_Optum LoT_Unmet_Need_CoAuth (June 16 2026)*,
the study period, the inclusion criteria and the exclusion criteria. These are unrecorded gaps, listed so they are not
found again from scratch.

**Continuous enrolment with medical *and* pharmacy benefits — satisfied by
construction, nothing to implement.** the inclusion criteria asks for "CE of at least
12-months with medical and pharmacy benefits before the 1L cohort index date",
and `build_enrollment_spans_ndmm()` filters on no benefit type. That is correct
here: the Optum extract does not separate them. `member_enrollment` has 27
columns and none is a benefit indicator —

```
PATID  PAT_PLANID  ASO  BUS  CDHP
ELIGEFF  ELIGEFF_DAY  ELIGEFF_MONTH  ELIGEFF_YEAR  ELIGEFF_SASDT
ELIGEND  ELIGEND_DAY  ELIGEND_MONTH  ELIGEND_YEAR  ELIGEND_SASDT
FAMILY_ID  GDR_CD  GROUP_NBR  HEALTH_EXCH  PRODUCT
RACE  STATE  YRDOB  EXTRACT_YM  VERSION  ETHNICITY  RACE_SOURCE
```

— `ASO`, `BUS`, `CDHP`, `PRODUCT`, `HEALTH_EXCH` and `GROUP_NBR` are plan
structure and funding, not coverage type. A span carries both benefits, so
`ELIGEFF` / `ELIGEND` already express the study's requirement and adding a
predicate would filter on nothing. Confirmed against a `DESCRIBE` of the same
table. The `overall` build's `CE_b` / `CE_f` are correct for the same reason.

Do not re-derive this from claims. A count of enrolled patients with no
pharmacy fill looks like a coverage signal and is not one: it is dominated by
short enrolment spans and by patients whose only MM code is a rule-out. The
column list is the answer.

**The study period was never wrong, but its defaults disagreed.** The study
design gives study start **01 Jan 2016**, 1L from 01 Jan 2017, end of data
31 Mar 2026. `config.csv` supplies `STUDY_START=2016-01-01` and is loaded before
the constants, so a real run always used the study's date. The *defaults*
disagreed — `NDMM_STUDY_START` fell back to `2015-07-01`, `cfg$study_start` to
`2016-01-01` — which `check_constants()` would have caught by stopping the
build. **Fixed:** both defaults are now `2016-01-01`, so a missing `config.csv`
cannot widen the pregnancy and MM-diagnosis scans, and the comment on
`cfg$study_start` no longer claims the pregnancy scan reads it.

**The two packages read different data vintages, and it is worse than the
belantamab case.** `nndm/config.csv` ends the study at **2026-03-31**, which is
the study period's end of data, so its scans resolve to the `2026q1` CDM tables.
`lot/config.csv` ends at **2025-06-30** and resolves to `2025q2` — the window
`overall` was built and run on.

The belantamab consequence is the obvious one: since #2 the exclusion is
evaluated in `lot`, so a belantamab claim after 2025-06-30 is in the cohort's
window and not in the LOT build's, cannot trigger the exclusion, and the patient
stays. The cohort's own `NDMM_BELANTAMAB_RECONCILE` list would show them.

But the same mismatch damages **every** line, not just belantamab's. LOT bounds
each claim scan by the cohort's `INDEX_DATE` and `OBS_END_DT`, which come from
the cohort table — so with a 2026-03-31 cohort against `2025q2` tables, nine
months of every patient's follow-up is simply absent. Lines end early, MAPs
discontinue where the patient was still being treated, and the end reason comes
out `STUDY_END`. Nothing errors and no count looks wrong.

**Made fatal rather than silent.** `check_cohort_window()` in `lot` reads the
cohort's actual `INDEX_DATE` / `ENDDATE` range and stops if it falls outside the
window the run was given, naming the count, the date and the CDM vintage it
would have read. `check_settings()` rejects a window that runs backwards, and
`pin_study_window()` rejects one whose dates will not parse. A mismatched pair
now fails at preflight instead of producing a plausible wrong answer.

**Decided: `lot` follows the NNDM study definition, and the window is a run argument.**
`lot/config.csv` defaults to the study period's study period — `STUDY_START=2016-01-01`,
`STUDY_END=2026-03-31` — which is the same window `nndm` uses and resolves to the
same `2026q1` CDM tables. The NDMM cohort and the LOT build over it therefore
see one vintage, and the belantamab exclusion is evaluated over the whole of the
cohort's window.

The window is no longer in `CONTRACT`. `CONTRACT` fixes what a LOT run *means* —
induction windows, gap days, transplant rules — and a different value there is a
different algorithm. The study window is not that: the algorithm is unchanged and
the dates belong to the cohort. So it is passed like the cohort table and the
prefix:

```
Rscript build.R NDMM_COHORT ndmm_ 2016-01-01 2026-03-31
Rscript build.R MM_COH_FINAL mm_   2015-07-01 2025-06-30
```

which is what lets the same algorithm run over the broader MM cohort — frozen at
2015-07-01 .. 2025-06-30 — without editing the package. Both dates are written to
`LOT_RUN_METADATA`, so an output says which window and therefore which vintage
produced it.

**The vintage was checked and is not a risk.** `lot` had only ever been run
against `2025q2`, so reading `2026q1` was reading tables nobody here had used.
Confirmed by the study team on 2026-08-02: `2026q1` is the same tables and the
same column names as `2025q2`, with data extended through 2026-03-31. So it is
a wider read of the same structures rather than a different one, and there is
nothing to re-validate before the run.

**"Any LOT" is now literal — the criterion asks the claims, not the constructed
lines. Closed.** Reading `LOT_BASE_MEDS` and `LOT_BASE_1ST_ADD_MED` off
`LOT_LONG`, which bounded it twice over: by `MAX_LOT`, since the build makes five
lines, and by position within a line, since a belantamab given as a line's
*second* addition is in neither column. "Any LOT" then meant "any of the first
five, and only as a base med or the first addition", which is not the exclusion criteria's
sentence.

Two attempts to quantify that gap rather than close it — a count of LOT5s
ending on a non-terminal reason — were both wrong, the second still an
approximation, and are gone.

The criterion now reads `map_stacked`, the per-patient treatment episodes, over
the span from the patient's first line to the end of their observation. A
belantamab MAP inside a built line is that line's, whatever position it held;
after the last built line it is a line the build *would* have started, because a
non-steroid drug that is not a permissible substitute of a prior line's drug
triggers the next LOT. So the answer does not depend on `MAX_LOT` at all, and no
diagnostic is needed to bound it.

`MAX_LOT` still bounds `LOT_LONG` itself, and `LOT_LONG_BY_LINE` in
`LOT_RUN_METADATA` already reports how many patients reach each line. It no
longer bounds this exclusion.

**The other boundary — before the index — is closed in `nndm`, not here.**
`map_stacked` is built from claims on or after the cohort's `INDEX_DATE`, so
`lot` cannot see a belantamab line earlier in the patient's history whatever
this criterion does. That half is criterion 9 of the NDMM funnel; see section 2.

**The shipped line criterion is this study's, and it is on by default.**
`APPLY_NO_BELANTAMAB=TRUE` in `lot/config.csv` is right for `NDMM_COHORT` and
wrong for any cohort whose study definition has no such exclusion — and passing a
different cohort, prefix and window does not change it. That default is a study
decision and stays; what was a defect is that nothing recorded it.
`report_line_criteria()` now logs and records every criterion, applied or not,
with the number of patients it catches (`LINE_CRITERIA_APPLIED`, e.g.
`no_belantamab=on:truncate:37`). Without it, "no patient had belantamab", "the
criterion was switched off" and "this is not that study's cohort" all produced
the same `LOT_LONG_FINAL`.

**Annex 2 is cited both ways.** the inclusion criteria says "For a full list of
eligible/expected MM therapies, see Annex 2"; the regimen categorisation says "Annex 2 contains an
**exemplary** list of potential treatment combinations… may be recategorized".
Decision #3 took the code list as authoritative, which is the permissive
reading. That remains defensible, but the README's claim that Annex 2 "is not
that list" overstates it: the inclusion criteria does point at Annex 2 for eligibility.

---

## 6. Checked against the Optum CDM documentation

Assumptions this build makes about the CDM, and what the vendor's own data
dictionary and business rules say about them. Check here before asking the
warehouse.

**`ICD_FLAG` is `'9'` or `'10'`, and nothing else.** The business rules state it
five times, and the column is `VARCHAR(2)`, so the longer spellings in
`RAW_ICD9` / `RAW_ICD10` can never appear. They are harmless and left as a
guard. What matters is that both real values are covered and anything else
yields NULL, which matches no code list - the source read every non-ICD-9
spelling as ICD-10, so a blank flag on a genuine ICD-9 claim was mis-classed.

**Diagnosis position is not filtered, and should not be.** `DIAG_POSITION` runs
1 to 25 with 1 as the primary diagnosis. the inclusion criteria asks for an MM diagnosis "in
any position", so no step reads that column. Confirmed absent from the whole
package.

**Enrolment spans are built from `member_enrollment`, not the rollup, and the
documentation is a better reason than the one the code gave.**
`member_cont_enrollment` is Optum's own rollup, one row per span of continuous
enrolment at **"less than 30 day break in coverage"**. the inclusion criteria says gaps "of
**<= 30 days** are considered to be continuously enrolled". Those differ by a
day at the boundary and Optum's is the stricter, so the prebuilt table would
drop patients the study definition keeps. Building the spans here bridges `<= 30`,
which is the study's rule - and only a raw build can reveal the true gaps
`NDMM_ENROLL_SPANS_STRICT` needs.

**The four-source therapy scan is necessary, not belt-and-braces.** `RX` holds
"prescriptions filled on an outpatient basis" only, and `MEDICAL` holds both
professional claims coded with CPT/HCPCS and facility claims. So an
administered agent and a dispensed one arrive by different routes and both have
to be read.

**`CONFINEMENT` is one undeduplicated row per hospitalisation**, with the
facility detail records bundled into it. That is what makes
`cf.CONF_ID IS NOT NULL` a sound inpatient test.

**Pregnancy reads diagnosis, procedure and revenue codes** in both packages,
which is what the exclusion criteria asks for. `RVNU_CD` and `BILL_PROC_CD` are unstacked from
`medical` in the same pass as `PROC_CD`.

`BILL_PROC_CD` was added on 2026-08-02. It is the facility-claim procedure code,
and the therapy and SCT scans in this repo already read it — pregnancy did not,
so a pregnancy HCPCS code populated only there kept the patient. Narrow: of the
5,318 codes on `pregnancy.csv`, only the 185 typed `HCPCS` could ever appear in
that column. One-way, since a source can only add exclusions.

**`pregnancy.csv` now stops the run on a code type nothing reads.** The scan
emits six — `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV` —
and a row typed anything else loads, joins, and matches zero, keeping the
patient with no error. Every other named thing here already stops when it
matches nothing; this code list was the exemption. Read on the warehouse
2026-08-02 the file carries exactly those six (3,049 / 1,549 / 447 / 69 / 185 /
19), so the guard passes today. It is there because the file is production and
can be re-issued, and a `CPT`-typed delivery code would otherwise be silent.

**`med_procedure.PROC` is now read as a medication source in `overall` and
`nndm`.** The program spec names the tables joined to `CL_MMA_CODELIST` as
`T_MEDICAL` (`PROC_CD`, `BILL_PROC_CD`, `NDC`, `FST_DT`), `T_RX` (`NDC`,
`FILL_DT`, `DAYS_SUPPLY`) **and `T_MED_PROCEDURE` (`PROC`)**, and Optum's
business rule 5 says `PROC` finds a drug given as a procedure under a HCPCS or
CPT code. Neither package read it, nor does the baseline.

The scan now has **five** arms, not four. Optum names four sources, three of
which the build already had; the fourth is `med_procedure`. The build also
reads `BILL_PROC_CD`, which Optum does not name. Three shared, plus one each
way, is five.

**Measured first, and the count is small.** Profiling `PROC` over the study
period gives 43,137,224 of ~43.2M rows at `ICD_FLAG='10'` and seven characters
— ICD-10-PCS. The five-character tail, the only shape a HCPCS or CPT code could
occupy, is about 15,000 rows: 0.035%. So this is expected to add very few
therapy events. It was added because the spec calls for it and because the
failure it guards against is asymmetric — a therapy the scan cannot see lets a
patient pass the no-prior-therapy criterion on missing data, and can move the
1L index date later than it belongs.

**Where it went:** `overall`'s `18_therapy_events` (fifth `UNION ALL`, source
`MED_PROCEDURE_PROC`, counted in the step's QC), and `nndm`'s three scans — the
1L index (`00_lot1_index.R`), the belantamab scan, and the 12-month prior-
therapy scan (`03_prior_therapy.R`). `lot`'s MMA/MAP pipeline is unchanged.

No `ICD_FLAG` condition, matching how `05_sct.R` reads the same column for
HCPCS: a J-code carrying an unexpected flag would otherwise be dropped. The
join is self-limiting anyway — ICD-10-PCS is seven characters and ICD-9
procedures three or four, so only a five-character `PROC` can equal a HCPCS or
CPT code on the list.

**The direction is one-way.** Adding a source can only add therapy events, so
the cohort can only get smaller: more patients excluded for prior therapy, and
index dates that can move earlier but never later. Read
`<prefix>NDMM_INDEX_AGENTS` and the attrition against a run without this arm to
size it.

**It also explains the SCT branch.** `lot/R/steps/05_sct.R` joins
`CL_CODE_TYPE = 'HCPCS'` against `mp.PROC` and calls it a "HCPCS safety net".
Given the profile above that branch matches little or nothing, so the HCPCS SCT
codes — CPT `38240`/`38241`, `S2150`, CAR-T `Q2042`/`Q2054`/`Q2055`/`Q2056` —
are found through `MEDICAL` in practice. Left in place, comment corrected.

**Still assumed, not documented:** that NDCs match once both sides are stripped
to digits and left-padded to 11. The documentation says nothing about NDC
width. The join guards against the failure mode that matters - a code with no
digits and a NULL `NDC` both pad to `00000000000` - by requiring digits on the
code-list side, and `check_ndc_shape()` profiles it on every run.

**`LOC_CD` identifies a facility versus a non-facility claim.** This build uses
it only as part of the claim key, and classifies inpatient from `POS`, `TOS_CD`
and `CONF_ID`. Changing that would change who is inpatient, so it is an
observation rather than a finding.
