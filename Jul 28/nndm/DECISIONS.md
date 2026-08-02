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

*Bone metastasis.* `C79.51`, `C79.52` and `198.5` say a cancer spread to bone,
not which cancer. Treating them all as myeloma bone disease keeps patients
with another primary; treating them all as another cancer removes genuine MM
patients. `mm_adjacent_overrides.csv` decides it per code and ships empty, so
today the tumour-group label decides for all of them.
`<prefix>NDMM_MM_ADJACENT_CODES` lists every affected code in the shape that
file wants.

**This one needs clinical judgement.** No file in this repository can answer
which primary a `C79.5x` belongs to. It is the only one of the four that
cannot be resolved by deriving from something already governed.

**Status: pending decision.**
