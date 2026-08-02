# NDMM cohort — recorded decisions

Decisions that change who is in the cohort, where the protocol is silent,
ambiguous, or deliberately overridden. Each says what was decided, what the
code does about it, and what still needs a counter-signature.

This file is the record. It is not the authority: a decision here is only as
good as the person who made it, and the "recorded by" line says who that was.
Anything marked **pending sign-off** has been implemented and reported but not
yet confirmed in a controlled study document.

---

## 1. Follow-up continuous enrolment — one day, LOT1 only

**Decided:** the 1L follow-up CE requirement is **one day** — the enrolment
span must cover the 1L index date itself. It is *not* the three months the
protocol text asks for.

**Scope:** the LOT1 / 1L NDMM cohort only. The 2L/3L cohorts keep the
protocol's three months unless changed separately.

**Protocol text it overrides** — Rev Round 2, §6.2.1.1:

> CE during follow-up: CE from index date until the earliest of 3-months post
> index or death, with no gaps in enrollment.

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

**Recorded by:** the study team, relayed through the build request, and
re-confirmed on 2026-08-02 against the protocol PDF in
`Questions/July 30 2026/` — one day is the intended rule and the three-month
sentence in §6.2.1.1 is **superseded**, not overridden by accident.

**Status: confirmed, pending a controlled record.** The rule is the one
intended and the code implements it. What is still missing is a study decision
record naming the approver and the date, because §6.2.1.1 as circulated still
reads three months and anyone checking the build against that text will find a
difference. `<prefix>NDMM_FU_CE_COUNTS` gives both numbers on every run.

---

## 2. Belantamab "in any LOT" — applied over lines, not here

**Decided:** this build does **not** apply §6.2.1.2's belantamab exclusion. It
is a line criterion in the `lot` package, applied after `LOT_LONG` exists.

**Why the proxy went.** §6.2.1.2 excludes a patient who received belantamab in
any line of therapy. Lines do not exist when this cohort is built — the LOT
algorithm runs *over* it — so anything applied here could only ever be a claims
proxy standing in for LOT membership. Worse, its errors were asymmetric and
one of them was permanently unauditable: a patient the proxy wrongly removed
never reached the LOT run, so nobody could ever check whether they really had
belantamab in a line.

Deferring it removes both problems at once. Every candidate gets lines, the
criterion is evaluated against actual LOT membership, and it is the protocol's
sentence rather than an approximation of it. Nothing needs approving, because
there is no longer an operational definition to approve.

**What the cohort build still does:**

- **`NO_BELANTAMAB` is still computed** and still ships on the cohort table, as
  an advisory flag. Nothing filters on it. It is computed over the whole study
  period — the widest net — because its only job now is to say who carries a
  belantamab claim at all. `NDMM_BELANTAMAB_SCOPE` is gone; there is no scope to
  choose.
- **`<prefix>NDMM_BELANTAMAB_RECONCILE`** lists every cohort member with a
  belantamab claim, with dates. That is the handover list.
- **§6.2.1.1's "other than belantamab" stays here**, and must. That is a
  different rule — belantamab cannot *set* the 1L index — and the index is what
  LOT1 is anchored on, so it has to be settled before the LOT run.

**Where it is applied:** `lot/R/line_criteria.R`, criterion `no_belantamab`,
enabled by `APPLY_NO_BELANTAMAB` in `lot/config.csv`. The predicate is
patient-level — false on *every* line of an affected patient — so
`first_failed_lot` lands on their earliest line and `on_fail = "truncate"`
leaves them with none, which is the exclusion. It matches whole `MED_ABBR`
tokens out of `LOT_BASE_MEDS` and `LOT_BASE_1ST_ADD_MED`, not a substring, so
an abbreviation that merely contains `BELA` cannot match.

**What this changes downstream, and it matters:**

- **`<prefix>NDMM_COHORT` is the NDMM cohort pending one exclusion**, not the
  final study population. Anything reading it as the final N is wrong.
- **The attrition has eight steps, not nine**, and its last row is not the
  study's N. The ninth step now lives in the LOT build's own reporting.
- The LOT run processes slightly more patients. Belantamab is a later-line ADC,
  so in a 1L newly-diagnosed cohort this should be very few.

**Recorded by:** the study team, 2026-08-02.

**Status: decided and implemented.**

---

## 3. Eligible 1L agents — the code list is the list

**Decided:** `cl_mma_codelist.csv` is the study's definition of MM therapy, so
it is the eligible-1L set. No separate eligibility file.

**What the code does:** any agent on that code list may set the 1L index, less
steroids (dropped where `NDMM_MMA_CODELIST` is built) and less belantamab
(barred always, per §6.2.1.1's "other than belantamab"). The earliest such
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

**Decided:** not yet. Both parts are gaps against §6.2.1.2, not open design
questions — see the protocol quote below.

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
three characters of the code — which is the protocol's "same primary tumor
type": every `C50.x` is breast, every `C34.x` lung, every `C79.x` a secondary
neoplasm. `primary_tumor_groups.csv` and its loader are gone; there is nothing
a hand-written map could say that the category does not, and leaving it empty
was itself a choice about how the criterion read. The cohort gets **smaller** —
claims that never paired now do. `<prefix>NDMM_OTHER_MALIG_GROUPS` lists every
category with its code and label counts; `<prefix>NDMM_OTHER_MALIG_GRAIN`
prices it against the old per-label grain.

Where the category over-groups: `C44` (skin), `C76` and `C80` (ill-defined and
unspecified sites) are broad. In each the two claims are still the same broad
cancer type, which is the unit the protocol asks for.

*Bone metastasis.* **Decided: follow the protocol.** §6.2.1.2 excludes on

> ≥1 inpatient or ≥2 outpatient ICD-9-CM or ICD-10-CM codes on separate days,
> within 30 days, for the same primary tumor type **and/or metastatic cancer**

`C79.51`, `C79.52` and `198.5` are metastatic cancers. The protocol names
metastatic cancer as exclusionary in its own right, so all three exclude.

**What changed:** `SECONDARY MALIGNANT NEOPLASM OF BONE` is removed from
`NDMM_MM_ADJACENT_OVERRIDE`, which is now four labels rather than five —
monoclonal gammopathy and the three plasma-cell disorders. Those four stay
because they are the index disease or its precursor, not *another* cancer;
`C79.5x` is another cancer by the protocol's own wording. `C79.51` previously
never reached the other-cancer scan; it does now, and pairs under ICD category
`C79` alongside `C79.52` and the rest of the secondary-neoplasm block.

**What it costs:** the source overrode the group because myeloma bone disease is
commonly miscoded as `C79.51`, and that concern is real — some patients removed
by this will be MM patients whose bone lesions were coded as metastases. The
decision is that the protocol text governs. The cohort is **smaller** than both
the source's and the previous build's. `<prefix>NDMM_MM_ADJACENT_CODES` lists
what the four remaining labels still keep, and the attrition step 7 count is
where the change lands.

**Recorded by:** the study team, 2026-08-02 — "follow the protocol to the tee".

**Status: decided and implemented.**

---

## 5. Open against the protocol, not yet decided

Read off *Belantamab_Optum LoT_Unmet_Need_CoAuth Rev Round 2 (June 16 2026)*,
§6.1, §6.2.1.1 and §6.2.1.2. These are unrecorded gaps, listed so they are not
found again from scratch.

**Continuous enrolment with medical *and* pharmacy benefits — satisfied by
construction, nothing to implement.** §6.2.1.1 asks for "CE of at least
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
`ELIGEFF` / `ELIGEND` already express the protocol's requirement and adding a
predicate would filter on nothing. Source: `docs/optum enrolment.pdf`, which is
a `DESCRIBE` of the same table. The parent build's `CE_b` / `CE_f` are correct
for the same reason.

Do not re-derive this from claims. A count of enrolled patients with no
pharmacy fill looks like a coverage signal and is not one: it is dominated by
short enrolment spans and by patients whose only MM code is a rule-out. The
column list is the answer and it is in `docs/`.

**The study period was never wrong, but its defaults disagreed.** §6.1's design
figure gives study start **01 Jan 2016**, 1L from 01 Jan 2017, end of data
31 Mar 2026. `config.csv` supplies `STUDY_START=2016-01-01` and is loaded before
the constants, so a real run always used the protocol's date. The *defaults*
disagreed — `NDMM_STUDY_START` fell back to `2015-07-01`, `cfg$study_start` to
`2016-01-01` — which `check_constants()` would have caught by stopping the
build. **Fixed:** both defaults are now `2016-01-01`, so a missing `config.csv`
cannot widen the pregnancy and MM-diagnosis scans, and the comment on
`cfg$study_start` no longer claims the pregnancy scan reads it.

**Annex 2 is cited both ways.** §6.2.1.1 says "For a full list of
eligible/expected MM therapies, see Annex 2"; §6.2.2 says "Annex 2 contains an
**exemplary** list of potential treatment combinations… may be recategorized".
Decision #3 took the code list as authoritative, which is the permissive
reading. That remains defensible, but the README's claim that Annex 2 "is not
that list" overstates it: §6.2.1.1 does point at Annex 2 for eligibility.

---

## 6. Checked against the Optum documentation

`docs/` carries `optum business rules.pdf`, `optum data dict.pdf` and
`optum enrolment.pdf`. Assumptions this build makes about the CDM, and what
those say about them. Check here before asking the warehouse.

**`ICD_FLAG` is `'9'` or `'10'`, and nothing else.** The business rules state it
five times, and the column is `VARCHAR(2)`, so the longer spellings in
`RAW_ICD9` / `RAW_ICD10` can never appear. They are harmless and left as a
guard. What matters is that both real values are covered and anything else
yields NULL, which matches no code list - the source read every non-ICD-9
spelling as ICD-10, so a blank flag on a genuine ICD-9 claim was mis-classed.

**Diagnosis position is not filtered, and should not be.** `DIAG_POSITION` runs
1 to 25 with 1 as the primary diagnosis. §6.2.1.1 asks for an MM diagnosis "in
any position", so no step reads that column. Confirmed absent from the whole
package.

**Enrolment spans are built from `member_enrollment`, not the rollup, and the
documentation is a better reason than the one the code gave.**
`member_cont_enrollment` is Optum's own rollup, one row per span of continuous
enrolment at **"less than 30 day break in coverage"**. §6.2.1.1 says gaps "of
**<= 30 days** are considered to be continuously enrolled". Those differ by a
day at the boundary and Optum's is the stricter, so the prebuilt table would
drop patients the protocol keeps. Building the spans here bridges `<= 30`,
which is the protocol's rule - and only a raw build can reveal the true gaps
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
which is what §6.2.1.2 asks for. `RVNU_CD` is unstacked from `medical` in the
same pass as `PROC_CD`.

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
