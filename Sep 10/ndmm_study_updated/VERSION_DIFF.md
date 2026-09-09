# What changed since the June 2026 protocol

The version this one supersedes is
`Belantamab_Optum LoT_Unmet_Need_CoAuth Rev Round 2 (June 16 2026).docx`, 58 pages.

It matters for two reasons. Several of the current build's settings are correct
against **that** version and wrong against this one, which saves arguing about
whether the build has a bug. And its Table 3 is the best available stand-in for
the rows this version does not carry (§3).

An older version exists too, marked superseded. It is not used here.

---

## 1. What changed

### Periods and index windows

| | June 16 2026 | **Aug 26 2026** |
|---|---|---|
| Study period | 01 Jan **2016** → 31 Mar 2026 | 01 Jan **2018** → 31 Mar 2026 |
| 1L index floor | on or after **01 Jan 2017** | on or after **01 Jan 2019** |
| Secondary 2L cohort | — | **new**: 2L initiation ≥ 01 Jan 2020, non-nested |

Both versions print **"Study start 01 Jan 2016"** on Figure 1. In the June version that
agreed with the body text. In this one it does not — so the figure is a leftover, not a
second opinion. `OPEN_QUESTIONS.md` Q1.

### Follow-up — the one that explains the build

| | June 16 2026 | **Aug 26 2026** |
|---|---|---|
| 1L follow-up | *"CE from index date until the earliest of **3-months post index or death** with no gaps in enrollment"* | *"at least one claim (pharmacy or medical) from index date or death"* |
| 2L/3L follow-up | *"CE of at least **3-months** during follow-up or death with no gaps in enrollment"* | *"at least one claim (pharmacy or medical) from index date"* |

`SUBSEQ_FU_CE_DAYS = 90` in `Jul 28/ndmm/config.csv` is a faithful implementation of
the **June** rule. It is not a bug; it is the previous protocol. The new protocol drops
the enrolment test to a claims-presence test, and moves the 90 days to §7.8.2 as an
analysis-set restriction on the time-to-event outcomes only —
*"≥ 3 months of **potential** follow-up (or die before 3 months)"*, which is calendar
time in the database rather than observed enrolment. `BUILD_DELTA.md` §2.

### Criteria

| | June 16 2026 | **Aug 26 2026** |
|---|---|---|
| MM diagnosis | identical wording | identical wording |
| Adult age | identical | identical |
| Eligible 1L treatment | "excluding those restricted to later LOTs (see exclusion criteria)" | same, **plus named exclusions: panobinostat and elotuzumab**, and "other potential therapies pending review of data may be considered" |
| 12-month CE before index | identical | identical |
| MM therapy in baseline (X1) | identical | identical |
| Another cancer (X2) | identical, including the 30-day window | identical |
| Pregnancy (X3) | identical | identical |
| Belantamab in any LOT (X4) | identical | identical |
| 2L/3L: received the line | identical | identical |
| 2L/3L: 12-month CE | identical | identical |

So the **exclusion criteria did not change at all**, and the only inclusion change
outside the dates is the two named agents.

### Timing boundaries — a systematic flip

Every duration in the tables had its endpoint conventions reversed. Carried forward
unchanged, each one shifts a duration by a day.

| metric | June 16 2026 | **Aug 26 2026** |
|---|---|---|
| Follow-up time from diagnosis | diagnosis (**excluded**) → follow-up end (included) | diagnosis (**included**) → follow-up end (included) |
| Follow-up time from index | index (**excluded**) → follow-up end (included) | index (**included**) → follow-up end (included) |
| Time from diagnosis to 1L | diagnosis (excluded) → index (**included**) | diagnosis (included) → index (**excluded**) |
| Time from prior LOT to next | prior start (excluded) → next start (**included**) | prior start (included) → next start (**excluded**) |
| TTNT | index start (excluded) → next LOT or death (**included**) | index start (included) → next LOT or death (**excluded**) |
| TTD | index start (excluded) → discontinuation (**included**) | index start (included) → discontinuation (**excluded**) |
| OS | LOT start (excluded) → death (**included**) | LOT start (included) → death (**excluded**) |

The new convention is internally consistent: the interval opens on the index and closes
before the event. The June convention was the other way round.

One inherited error is also fixed: the June version said *"Time zero, or the index
date, will be **2L start** for all TTE outcomes in the primary analyses"* — in a
document whose primary cohorts are 1L, 2L and 3L. The new version reads *"will be
**LOT start/LOT cohort**"*.

### What is entirely new in this version

- **Primary Objective 3** — secondary malignancies: §7.2.4, Table 2's ten categories,
  seven Table 4 rows, the §7.8.1 analyses, and the confirmation rule (*"at least 2
  diagnosis codes occurring on separate dates. The date of the first ICD code will be
  used"*).
- **The secondary 2L RRMM cohort** — §7.4, Figure 2, §7.4.1.1, §7.4.1.2, §7.8.4, with
  the other-cancer exclusion waived and the index ≥ 01 Jan 2020 "irrespective of
  whether their 1L initiation occurred during the primary cohort ascertainment period".
- **Kim Frailty Index as a baseline variable**, promoted out of the exploratory table,
  with an explicit **CFI ≥ 0.25** cut-point the June version never states.
- **"Types of 1L, 2L, 3L SOCs or classes by line"** as a new Table 4 row — and it still
  says *"from 2017 to 2025"*, unreconciled with the 2019 floor in the row directly
  above it (`OPEN_QUESTIONS.md` Q12).
- **Lower respiratory / lung infection** as a safety outcome.
- **Lung parenchymal disease** and **baseline history of any event of interest** as
  subgroups.
- The 3L viability caveat: *"analyses for the primary 3L nested cohort may be limited
  or excluded pending sample size among SOCs"*.
- Hospitalisations with **no discharge date** counted for N but excluded from LOS.
- Named exclusions **panobinostat** and **elotuzumab**.

### What did not change

The nested 1L/2L/3L structure; "no 4L cohort, only the 4L start date and regimen"; the
12-month baseline excluding the index date; "only the 1L baseline period will be used
to assess study eligibility"; and the follow-up period definition (index → end of CE,
end of study, or death, whichever first).

---

## 2. Why this matters for the build

Three settings in `Jul 28/` that look like divergences are actually the June protocol
faithfully implemented:

| setting | implements | now needs |
|---|---|---|
| `LOT1_FROM = 2017-01-01` | June's 1L index floor | `2019-01-01` |
| `STUDY_START = 2016-01-01` | June's study period | 2018, if Q1 resolves to the text |
| `SUBSEQ_FU_CE_DAYS = 90` | June's 3-month gap-free CE follow-up | replace with the claims test; move 90 days to a `TTE_ELIGIBLE` flag |

None of them is a defect. All three are a protocol version behind.

---

## 3. The rows missing from pages 31-32, reconstructed

Pages 31-32 are unreadable in the copy supplied, with no partial text at either
edge. The gap is bounded exactly:

- **last readable row before the gap**: Table 4's *"Types of 1L, 2L, 3L SOCs or
  classes by line"*
- **first readable row after it**: the two footnotes belonging to the on-treatment
  incidence row, then *"Healthcare utilization events / Same as Primary Objective 1"*

So the gap holds: the background-rates block, the baseline healthcare-utilisation
block, the Primary Objective 2 banner, and the body of the on-treatment incidence row.

The June version's Table 3 covers exactly that span. **This is a reconstruction, not
the wording itself** — treat it as the shape of what is missing.

| variable / outcome (June wording) | definition | timing |
|---|---|---|
| *Background rates of key safety events* (banner) | | |
| Background prevalence of key safety events of interest | Numerical, reported as events per unit person-years (PY); calculated as the number of events for an outcome during the baseline period divided by the persons at risk (12 months total for patient for each baseline period). Categories: hepatologic toxicity, renal impairment, serious infection, ocular events, cardiovascular conditions, neurologic conditions, other conditions (dependent on availability) | During baseline (1L, 2L, 3L) |
| Number of patients experiencing at least 1 key safety event of interest | Categorical; number and percent of patients with occurrence of event of interest | During baseline (1L, 2L, 3L) |
| *Occurrence of healthcare utilization events, as defined according to evidence of a claim* (banner) | | |
| Proportion of all-cause inpatient hospitalizations | Continuous and categorical: 0, 1, 2, 3, 4+ hospitalisation(s) | Any hospitalisation starting during baseline (1L, 2L, 3L) |
| Inpatient length of stay (LOS) | Continuous; calculated among those with an inpatient hospitalisation from admit date to discharge date (can extend over several LoT). LOS per visit, assigned to the study period in which the admit occurred; calculated separately for all-cause and MM-related hospitalisations | Hospitalisation starting during baseline (1L, 2L, 3L) |
| Proportion of ER visits | Continuous and categorical: 0, 1, 2, 3, 4+ visit(s) | During baseline (1L, 2L, 3L) |
| **Primary Objective 2** (banner) | incidence of key safety and healthcare utilization events while on 1L, 2L, and 3L, within each LOT, by categories of SOC regimens, and by patient subgroups of interest | |
| On-treatment incidence of safety events | Numerator = number of each new event; denominator = total person-time at risk. Chronic conditions counted at first occurrence only and stop contributing person-time at that point. Acute conditions may occur at any time and contribute multiple events, separated by ≥ 30 days. An event is attributed to a LOT if it occurs between the LOT's start date and the start of a subsequent LOT, or discontinuation + 30 days, whichever comes first | During LOT treatment period (1L, 2L, 3L) |

Three reasons the lost rows are **not** a byte-for-byte copy of the above:

1. The Primary Objective 2 statement lost the phrase *"by categories of SOC regimens"*
   in the new version (§6.2.1 objective 2 now reads *"within each LOT and by patient
   subgroups of interest"*); SOC stratification moved to Table 1.
2. The on-treatment-incidence row gained a second footnote in the new version —
   *"See Primary Objective 3 for similar calculation of secondary malignancies"* — whose
   tail is visible at the top of p18.
3. The included/excluded conventions were flipped throughout (above), so the counting
   prose was almost certainly re-cast the same way.

Everything in the gap is also stated, in different words, in **§7.8.1** of the new
protocol (document pages 41-46), which *is* readable and which `VARIABLES.md` §5 and
`BUILD_DELTA.md` §7 take their counting rules from. So the loss costs wording, not
substance — with one exception: the exact **functional forms** of the baseline
hospitalisation and ER-visit variables (the June version's "0, 1, 2, 3, 4+" banding) are
not restated anywhere readable in the new protocol.
