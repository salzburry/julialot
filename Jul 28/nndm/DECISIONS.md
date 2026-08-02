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

**Recorded by:** the study team, relayed through the build request and
confirmed in the implementation thread of 2026-08-02. It is **not** written in
any controlled document that this repository can see.

**Status: pending sign-off.** Implemented and correct for the rule as stated.
Needs a controlled study decision record naming the approver and the date,
because the number it produces is not the number the protocol text produces.

---

## 2. Belantamab "in any LOT" — claims proxy

**Decided:** not yet.

**The problem is sequencing, not data.** §6.2.1.2 excludes a patient who
received belantamab in any line of therapy. Lines do not exist when this
cohort is built — the LOT algorithm runs *over* this cohort. So the criterion
cannot be applied exactly at the time it has to be applied.

**What the code does:** a claims-based proxy. Any belantamab claim within the
configured scope excludes the patient. `NDMM_BELANTAMAB_SCOPE` selects the
reading — `study_period` (default) or `from_index`.

**Confirmed against the production code list:** `cl_mma_codelist.csv` carries
26 distinct `CL_MED_ABBR` values and belantamab is `BELA`, the only one
beginning `BEL`. So `NDMM_BELANTAMAB_ABBR = 'BEL%'` resolves to exactly
belantamab, and the run-stopping guard in `00_lot1_index.R` — which fires if
that pattern matches no row — will not fire. The exclusion flag itself is built
from `MAP_MED_TYPE` on the stacked map, a different source; that side is still
unverified.

**What it costs, measured:** `<prefix>NDMM_BELANTAMAB_SCOPE_COUNTS` gives the
cohort size under each reading. `<prefix>NDMM_BELANTAMAB_RECONCILE` lists every
patient whose membership turns on this criterion alone — both those the proxy
kept and those it excluded — with claim dates and which way it went.

**Needs:** approval of the proxy as the operational implementation of the
criterion, and of which scope. Note that a later `LOT_LONG` join can confirm
the proxy's *misses* but cannot fully confirm its *over-exclusions*, because a
patient the proxy removed never reaches the LOT run. Approving the proxy is
therefore approving an operational definition, not deferring to a later exact
check.

**Status: pending decision.**

---

## 3. Eligible 1L agents — the code list is the list

**Decided:** `cl_mma_codelist.csv` is the study's definition of MM therapy, so
it is the eligible-1L set. No separate eligibility file.

**What the code does:** any agent on that code list may set the 1L index, less
steroids (dropped where `NDMM_MMA_CODELIST` is built) and less belantamab
(barred always, per §6.2.1.1's "other than belantamab"). The earliest such
claim on or after the MM diagnosis and on or after `LOT1_FROM` is the index.

**What was removed:** `codelists/eligible_1l_agents.csv`, its loader and
validation, the allowlist branch, its `NDMM_ELIGIBLE_1L_CSV` setting, and the
five mutations that guarded it. `NDMM_INDEX_EXCLUDED_ABBRS` remains for barring
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

**Decided:** not yet.

**Two separate questions.**

*Grain.* Two outpatient claims confirm another cancer only if they share a
label. With `primary_tumor_groups.csv` empty, the label is the code list's own
`tumor_group`, which is a diagnosis description rather than a primary-tumour
grouping — so one cancer written two ways does not confirm itself and the
criterion under-detects. `<prefix>NDMM_OTHER_MALIG_GRAIN` measures what the
grain costs.

**Measured on the production file:** `other_malig.csv` has 1,643 code rows and
1,618 distinct `tumor_group` values. The label is therefore one per code, not a
grouping, and the two-outpatient-claims rule reduces in practice to *the same
diagnosis code twice*. The direction is known — the cohort is larger than a
per-primary reading would give. `primary_tumor_groups.csv` is the lever, and on
this file it is not optional polish: leaving it empty is itself a choice about
how the criterion reads.

*Bone metastasis.* `C79.51`, `C79.52` and `198.5` say a cancer spread to bone,
not which cancer. Treating them all as myeloma bone disease keeps patients
with another primary; treating them all as another cancer removes genuine MM
patients. `mm_adjacent_overrides.csv` decides it per code and ships empty, so
today the tumour-group label decides for all of them.
`<prefix>NDMM_MM_ADJACENT_CODES` lists every affected code in the shape that
file wants.

**What the production file actually says.** Three rows carry these codes, and
they do not all land the same way:

| icd_family | dx | tumor_group | in the override list? |
|---|---|---|---|
| ICD10DIAG | C7951 | Secondary malignant neoplasm of bone | **yes** — kept |
| ICD10DIAG | C7952 | Secondary malignant neoplasm of bone marrow | no — excludes |
| ICD9DIAG | 1985 | Secondary malignant neoplasm of bone and bone marrow | no — excludes |

`NDMM_MM_ADJACENT_OVERRIDE` already carries `SECONDARY MALIGNANT NEOPLASM OF
BONE`, so `C79.51` — the common myeloma-bone-disease miscode — is already
treated as the index disease and does **not** exclude. The comparison is string
equality on the whole label, so `… OF BONE MARROW` is a different label and is
not reached by that entry.

So the open part is narrower than it looked, and it has a shape this build has
already seen once. The source overrode the first of the three plasma-cell
states and not the other two, and that was corrected here as
`NDMM_MM_ADJACENT_STATE_LABELS`. This is the same omission: bone was overridden,
bone marrow was not. Myeloma is a plasma-cell malignancy *of the bone marrow*,
so if `C79.51` is miscoded myeloma often enough to warrant an override,
`C79.52` is at least as likely to be.

**The recommendation, for a clinician to accept or reject:** add the two
remaining labels to the same list, exactly as the remission and relapse states
were added:

```r
"SECONDARY MALIGNANT NEOPLASM OF BONE MARROW",
"SECONDARY MALIGNANT NEOPLASM OF BONE AND BONE MARROW"
```

Both exist on the code list, so the required-label check in `04_other_malig.R`
passes. The ICD-9 one changes nothing on its own — see the code-length note
below — and is there so the two families agree.

The argument for is consistency with the `C79.51` entry that is already there
and with the states fix. The argument against is that these are not free: a
patient with a solid tumour metastatic to bone marrow, whose primary was never
coded in the baseline window, would be kept.

**This one needs clinical judgement.** No file in this repository can answer
which primary a `C79.5x` belongs to. It is the only one of the four that
cannot be resolved by deriving from something already governed.

**Status: pending decision**, on `C79.52` only. `C79.51` needs nothing.

---

## Note on code lengths in `other_malig.csv`

Matching is exact equality on the punctuation-stripped code, both sides. The
ICD-10 rows are 3/4/5/6 characters (14 / 318 / 672 / 82), which is the normal
spread for billable ICD-10-CM and needs nothing.

The ICD-9 rows are a different story: they are truncated to the three-character
category while keeping the *first child's* description — `141` is labelled
"Malignant neoplasm of base of tongue", which is `141.0`. A claim coded `1410`
therefore matches nothing. This is harmless here only because of the window:
the other-cancer scan reads claims from `2017-01-01` less the 12-month baseline
— `2016-01-01` — and US claims stopped carrying ICD-9 in October 2015. Worth
re-checking if the study period is ever moved earlier.
