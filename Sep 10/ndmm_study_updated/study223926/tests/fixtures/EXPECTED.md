# The fixtures, and where every golden number comes from

`tests/expectations.py` asserts numbers. This file derives them, so a number
that changes can be checked against the rule rather than re-blessed.

Nothing here is real data. Six patients, chosen so that each one makes a
protocol rule *visible* — a rule you could break without any other patient
noticing.

## Settings these are computed under

The shipped defaults: study period ends **2026-03-31**, 1L index floor
**2019-01-01**, secondary-2L floor **2020-01-01**, baseline **365 days ending
the day before index**, comorbidity baseline **including** the index day,
continuous enrolment **365 days before index**, enrolment gaps of **≤ 30 days**
bridged, acute washout **30 days**, `MAX_LOT=4`, follow-up censored at
disenrolment.

## The patients

| id | enrolment | lines | death | what it is for |
|---|---|---|---|---|
| **P1** | 2017-01-01 → 2026-12-31 | 1L 2019-03-01, 2L 2020-03-01, 3L 2021-03-01 | — | the ordinary case: every window, every rate |
| **P2** | 2018-01-01 → 2020-06-30 | 1L 2019-06-01 | 2020-07-15 | death **after** follow-up ends |
| **P3** | 2018-01-01 → 2019-12-31 **and** 2020-01-10 → 2021-12-31 | 1L 2020-02-01, 2L 2020-09-01 | — | a 9-day enrolment gap, which the protocol bridges |
| **P4** | 2016-01-01 → 2026-12-31 | 1L 2018-06-01 | — | indexes **before** the 2019 floor |
| **P5** | 2017-01-01 → 2026-12-31 | five lines, 2019→2023 | — | a fifth line, above `MAX_LOT` |
| **P6** | 2018-01-01 → 2019-12-31 **and** 2020-03-01 → 2026-12-31 | 1L 2019-03-01, 2L 2022-06-01 | — | a 60-day gap, which is **not** bridged: its two cohorts have different follow-up |

## Derivations

### Enrolment spans — the ≤ 30 day bridge

P3's rows end 2019-12-31 and resume 2020-01-10: a gap of **9 days**, bridged,
so one span `2018-01-01 → 2021-12-31`. P6's gap is 2020-01-01 → 2020-02-29,
**60 days**, not bridged, so two spans survive. §7.2.1.1 allows gaps of 30 days
or fewer; the CDM's own rollup bridges gaps of *less than* 30, which is why the
package rebuilds spans rather than reading that column.

### The spine — `lead()` above `MAX_LOT`

P5 has five lines and `MAX_LOT=4`. Line 4's `NEXT_LOT_START_DT` must be
**2023-01-15** (line 5's start) and the spine must still stop at line 4. If the
window is evaluated after the `WHERE`, line 4 gets NULL and looks like the last
line: its treatment period then runs to discontinuation + 30 days, past line
5's start.

### Cohort membership

1L is **5** patients: P1, P2, P3, P5, P6. P4 is out — its index is 2018-06-01,
before the floor. 2L is **4**: P1, P3, P5, P6. P2 has no second line.

P6 in 2L is the case that matters: its 2L index is 2022-06-01, and the enrolment
span covering it is the second one, so it has the required 365 days before that
index and qualifies.

### Follow-up — per cohort

P6's **1L** follow-up ends **2019-12-31**, where the span covering its 1L index
ends. Its **2L** follow-up ends **2026-03-31**, the study end, because the span
covering its 2L index runs past it. Read off the cohort table's 1L-anchored
`ENDDATE_CE`, the 2L row would end 2019-12-31 — before its own index — and
follow-up would be negative.

P2's follow-up ends **2020-06-30** (disenrolment), 396 days from its
2019-06-01 index counting the index day. Its death on 2020-07-15 is outside
that, so OS is **censored at 395 days**, not an event.

Baseline person-years are **365 / 365.25 = 0.999316** for everyone: §7.8.1 says
the baseline denominator is the window's own length "irrespective of prior
event history", not observed coverage.

### Treatment periods

P1's line 1 runs 2019-03-01 → **2020-02-14**: discontinuation 2020-01-15 plus
30 days, which falls before the day before line 2 starts.

### The discontinuation date — Table 4's footnote

*"discontinuation of a regimen occurs when all MM agents in the LOT are
stopped OR when a new agent/qualifying SCT event is introduced"*. The engine
dates a line's end by its reason (LOT_RULES §7.1): a `DISCONTINUATION` ends
**on** the confirmed run-out, and `MED_ADD`, `CART_INIT`, `SCT_AUTO`,
`SCT_ALLO` and `SCT_CART` end the **day before** the event that opens the next
line. So the footnote's date is the end date for the first and the day after
it for the rest. `SCT_AUTO_CONT` — an AUTO inside the line's own induction
window, which is the line's consolidation and opens no line — ends on the
transplant and is dated there, as the "all agents stopped" branch.

| line | engine end | reason | discontinuation | TTD |
|---|---|---|---|---|
| P1 1L | 2020-01-15 | DISCONTINUATION | 2020-01-15 | **320** |
| P1 3L | 2022-01-15 | MED_ADD | **2022-01-16** | **321** |

TTD counts from the index, included, to the discontinuation, excluded. Read as
the end date throughout, the 3L row was 320 — a day short of the switch, and
a day off TTNT's convention for the same event.

### The diagnosis date, and what hangs on it

By default the diagnosis date is the cohort table's `MM_DX_DT` — the
qualifying I1 diagnosis, the date age (I2) and the 1L index (I3) are already
measured against — and `DX_DT_SOURCE` reads `cohort_mm_dx` on every row.

The three durations, each with the protocol's own endpoint convention:

- **Time from diagnosis to 1L** (Table 5): diagnosis *included*, index
  *excluded* → a bare `datediff`. P1: 2019-01-05 → 2019-03-01 = **55** days,
  1.81 months.
- **Follow-up from diagnosis** (Table 4): both ends *included* → `datediff + 1`.
  P2: 2019-04-01 → 2020-06-30 (its follow-up end) = **457** days.
- **Prior LOT start to next LOT start** (Table 5): start *included*, next start
  *excluded*, among patients initiating a subsequent LOT. P1 line 1: 2019-03-01
  → 2020-03-01 = **366** days, 12.02 months. P6's 2L starts 2022-06-01, after
  its 1L follow-up ended on 2019-12-31, so its line-1 interval is **NULL**: the
  1L cohort never observed that initiation, which is also why TTNT censors it.

A 2L row carries the same patient-level date, measured to its own index: P1 in
2L is 2019-01-05 and **421** days.

**The other reading** (`DX_DATE_SOURCE=baseline_first_claim`, goldens in
`expectations_alt.py`) is Table 4's own definition: *"first medical claim for
MM within the baseline period on or prior to 1L"* — the 1L baseline with the
index day, `[1L index − 365, 1L index]`, which can differ from `MM_DX_DT`.

| patient | cohort `MM_DX_DT` | 1L index | window | first MM claim in it | `DX_DT` |
|---|---|---|---|---|---|
| P1 | 2019-01-05 | 2019-03-01 | 2018-03-01 → 2019-03-01 | C900 on **2018-06-01** | 2018-06-01, `baseline_claim` |
| P2 | 2019-04-01 | 2019-06-01 | 2018-06-01 → 2019-06-01 | C900 on 2018-08-01 | 2018-08-01 |
| P6 | 2019-01-01 | 2019-03-01 | 2018-03-01 → 2019-03-01 | **no diagnosis row at all** | 2019-01-01, `cohort_mm_dx` |

P6 is the fallback: with no claim in the window the cohort's date stands in,
and `DX_DT_SOURCE` says so. Under this reading P1's time to 1L is **273** days
(8.97 months), P2's follow-up from diagnosis **700** days, and P1 in 2L still
carries 2018-06-01 with **639** days to its 2L index — the definition anchors
on 1L for every cohort.

### Demographics — the row at the index, or the nearest one

§7.8.1: *"assessed at the time of index date where possible. If data is
missing at index, data from the baseline period present nearest index will be
used."*

P7's enrolment ends **2020-05-31** and resumes **2020-06-05**, around its
2020-06-01 index. The 4-day gap is bridged for continuous enrolment, so P7's
span, cohort and follow-up are unchanged — but no `MEMBER_ENROLLMENT` row
covers the index day. The two rows differ on purpose: the earlier is NV /
Medicare, the later NY / commercial.

- default (`ENROL_ATTR_AT=index_span`): the row ending nearest the index —
  **NV → West, Medicare**, `ATTR_SOURCE = baseline_nearest`. Restricted to the
  covering row alone, P7 was reported Unknown on every attribute.
- `ENROL_ATTR_AT=latest_span` (`expectations_alt.py`): the most recent row —
  **NY → Northeast, Commercial Health Plan**, `latest_span`.

P1, whose row covers its index, reads `index_span` either way.

**Sex** is on the enrolment row like race and insurance, and is read off the
same row, with the cohort table's copy behind it. P8's cohort row says `U` and
the enrolment row covering its index says `M` → **Male**.

**Years.** `INDEX_YEAR` is the calendar year of the index and `DX_YEAR` of the
diagnosis date, on the periods row: P3 indexes 2020-02-01 on a 2019-11-01
diagnosis → **2020, 2019**. `LOT_START_YEAR` is on each SOC row: P1's 3L
starts 2021-03-01 → **2021**.

### SOC — the transplant on the row (Table 6)

P5's 1L carries the engine's line-scoped autologous transplant flag with
`LOT_TX_AUTO_MAX_DT = 2019-03-15`, so its SOC row reads `AUTO_SCT = 1,
AUTO_SCT_YEAR = 2019`; P1's 1L reads `0, NULL`. Table 6 — patients with an SCT
in 1L–4L by year, according to SOC type — is a count over `S_SOC`.

### SOC — a size category holds for unlisted agents

§7.2.2's *"Other triplet (non-anti-CD38)"* and *"Doublet/monotherapy"* are
claims about the regimen's size, and hold whether or not Annex 2 names the
agents. P7's 1L is `CARF LEN DEX`, three agents on no row of the fixture list
→ **Other triplet (non-anti-CD38)**, `N_AGENTS = 3`, `MATCHED = 0` (no list
row produced it, so the QC still counts it as uncategorised). A four-agent
regimen with no backbone still falls to `Other`: §7.2.2 has no other
quadruplet.

### Charlson, MM-adjusted

The fixture's `any_malignancy` carries **C50** (breast) and **C900** (myeloma),
as Quan's range C00–C97 does.

- **P1** has only C900 → CCI **0**. Table 4 asks for a CCI "adjusted for having
  received a MM diagnosis, such that a value of 0 indicates no additional
  comorbidities beyond MM", and 0 is reachable only if myeloma codes are
  excluded. Made on the codes, because Quan has no myeloma *condition*.
- **P3** has C900 **and** C50 → CCI **2**. The adjustment must not remove a
  genuine second cancer.
- **P2** has C900 and I50 (congestive heart failure) → CCI **2**, Quan's weight.
- **P5** has K73 (mild liver) and K704 (severe liver) → CCI **4**, not 6:
  `supersedes` carries Quan's hierarchy.

Myocardial infarction is weighted **0** in the fixture because that is Quan
2011's weight; the 1 that shipped first is the original 1987 Charlson.

### Safety counting — §7.8.1

P1's `acute_hepatitis_b` codes fall on 2019-04-01 (**twice**, two claims),
2019-04-10 and 2019-06-01.

- the two claims on 2019-04-01 collapse to **one event** (rule 1);
- 2019-04-01 counts; 2019-04-10 is **9 days** later and is inside the washout;
  2019-06-01 is **61 days** after the last counted event and counts. Two events.

P3's codes are 2020-03-01 and 2020-03-31 — **exactly 30 days** apart. The rule
is "≥ 30 days between acute events", so both count. A `<= 30` washout would
collapse them, which is why this pair is here.

`toxic_liver_disease` is **chronic**:

- **P5** has it twice during treatment → **one** event;
- **P1** has it at 2018-07-01, before its treatment period → not at risk, so it
  counts for nobody **and** P1's person-time leaves the denominator;
- **P2** has it *on* 2019-06-01, its period start. The prior-history window is
  `< PERIOD_START`, so this is **not** prior history and it counts.

A chronic condition is counted once, at first instance, so a patient stops
being at risk of a first event there and the denominator ends with them. The
1L line-1 treatment denominator is therefore, per patient:

| patient | period | at-risk end | person-years |
|---|---|---|---|
| P1 | 2019-03-01 → 2020-02-14 | prior history | **0** |
| P2 | 2019-06-01 → 2020-01-31 | first event 2019-06-01 | 1/365.25 = 0.002738 |
| P3 | 2020-02-01 → 2020-07-01 | no event | 0.416153 |
| P5 | 2019-01-15 → 2019-12-01 | first event 2019-04-01 | 77/365.25 = 0.210815 |
| P6 | 2019-03-01 → 2019-10-01 | no event | 0.588638 |
| P7 | 2020-06-01 → 2021-01-31 | no event | 0.670773 |
| P8 | 2020-06-01 → 2021-01-31 | no event | 0.670773 |

Total **2.5599** person-years, against the acute **4.8569**, which keeps every
patient's whole period because an acute event can recur. Summing `PERIOD_PY`
regardless gave 3.8960 — it counted P2 and P5 for the whole period, including
the part in which a first event was no longer possible.

Baseline is deliberately different: §7.8.1 takes the baseline denominator as
the window's own length "irrespective of prior event history", so it is not
truncated and prior history does not remove anyone from it.

Every one of the 23 conditions gets an incidence row whether or not it had an
event, because the rate is driven from the denominator — and so does the
hospitalisation series of each of the **12** chronic ones (below), and each of
the **7** domains gets an aggregate row, so a period carries **42** rows under
**36** distinct condition names.

### The washout across a period boundary — §7.8.1, Q34

*"A ≥30 day washout between acute events of the same type will be applied."*
A statement about events, not periods, so the chain runs **once** over the
cohort's timeline (baseline start → follow-up end) and each period then takes
the distinct events dated inside it. The chain's own answer stays on
`S_SAFETY_COUNTED` under `PERIOD = TIMELINE`.

P5 (index 2019-01-15) has hepatitis B coded on **2019-01-10** and
**2019-01-20**: ten days apart, one event, and it is baseline's. Counted
period by period it was two — a baseline event *and* a new incident event on
treatment. So in 1L the hepatologic baseline aggregate is **2 patients, 2
events** (P1's toxic liver disease, P5's hepatitis B) and the treatment
aggregate is unchanged at 4 / 6.

Each cohort's chain starts at **its own** baseline: the 2L cohort's timeline
(baseline from 2019-01-15) holds only the second code, so there 2019-01-20 is
a baseline event — §7.8.1 takes the baseline "irrespective of prior event
history".

### A rate of zero, with an interval

The log-normal interval is undefined at zero events, and the row used to carry
none. The exact Poisson limits for a count of 0 are **0** and **3.688879 / PY**,
scaled like the rate: seizures on 1L line 1 treatment, 4.8569 PY →
`RATE 0, RATE_LO 0, RATE_HI 75950.57` per 100,000.

### The domain aggregates — §7.8.1 "and aggregated"

*"Background prevalence event rates ... will be calculated for each outcome (to
be calculated as individual conditions within categories, and aggregated"*.
One row per domain, `CONDITION = (any in domain)`, whose numerator is every
counted event of the domain's own conditions and whose patient count counts
each patient once. Hepatologic, 1L line 1 treatment: acute hepatitis B is
counted **4** times (P1's 2019-04-01 and 2019-06-01, P3's 2020-03-01 and
2020-03-31) and toxic liver disease **2** (P2, P5), so **6 events among 4
patients**. P1's prior toxic liver disease removes it from *that* condition's
denominator, but it is still at risk of the domain's four other conditions,
so the aggregate keeps everyone's whole period: `N_AT_RISK = 7`, **4.8569**
person-years. At baseline: P1's 2018-07-01 alone, over the seven baseline
years (**6.9952**). The derived hospitalisation series is **not** in the
aggregate — P1's admission for toxic liver disease would otherwise be counted
beside the condition it is an admission for — so infectious carries only the
one inpatient severe infection.

### Inpatient claims — business rule 14, and Figure 3's note

A diagnosis is *inpatient* when the claim it sits on carries a confinement id
that `CONFINEMENT` knows (business rule 14), joined on the documented claim key
(`PATID`, `PAT_PLANID`, `CLMID`, `FST_DT`, `LOC_CD`). Two rules turn on it.

**A condition defined by its admissions** (`setting = inpatient`). P1's Z119
(*severe infection resulting in hospitalisation*) is coded on an outpatient
claim on 2019-06-10 and on claim `P120190702Z119`, which carries confinement
**C2** (admitted 2019-07-01). Only the second is an event, and it is dated at
the **admission, 2019-07-01**, not at the claim.

**A hospitalisation due to a chronic condition** (Figure 3: *"will be
considered an acute event and can be counted more than once"*). P1's Z100
(*toxic liver disease*, chronic) is also coded on claim `P120190503Z100`, which
carries confinement **C1** (admitted 2019-05-01). For the condition itself
nothing changes — P1's prior history from 2018-07-01 keeps it out of the
treatment numerator and denominator, so that row is still `N_PATIENTS = 2`,
`N_AT_RISK = 6`, **2.5599** person-years. But `toxic_liver_disease
(hospitalisation)` is a second series, typed **acute**: P1's admission on
**2019-05-01** counts in its 1L line-1 treatment period, everyone stays at
risk (`N_AT_RISK = 7`), and its person-time is the acute **4.8569**.

### HCRU

Three confinements: P1's C1 (2019-05-01 → 2019-05-06, myeloma in DIAG1), P1's
C2 (myeloma in **DIAG3**), P2's C3 (myeloma in DIAG1, **no discharge date**).

- MM-related is **2**: C1 and C3. C2 is not, because "first or second position"
  is the rule and its myeloma is third.
- C1's LOS is **5** days: admit included, discharge excluded.
- C3 is an event with **NULL** LOS and `HAS_DISCHARGE = 0`; the MM-related row
  reports `N_EVENTS = 2`, `MEAN_LOS = 5.0`, `N_LOS_EXCLUDED = 1`.
- P1's two ED claim lines on 2019-05-20 are **one** visit.
- Line 1 all-cause: `N_PATIENTS = 2`, `N_EVENTS = 3` — the two must differ, or a
  `count(*)` where `count(DISTINCT PATID)` belongs is invisible.
- Person-time is **per line**: four distinct values across the four lines, not
  one cohort total repeated.

### Secondary malignancy

P1 has Z200 on 2019-07-01 and 2019-08-01 → **confirmed**, dated at the **first**
code with the second as `CONFIRM_DT`. Z201 appears on one date only and is not
confirmed.

That malignancy falls **after** P1's 1L index (2019-03-01) and **before** its
2L one (2020-03-01). Table 4 measures time from the index *"2L only among
those where the malignancy occurred after 2L"*, so the 1L row carries
`AFTER_INDEX = 1` and **4.04** months from the index (2019-03-01 → 2019-07-01,
both ends included, 123 days), while the 2L-indexed rows (2L, 3L, SEC2L)
carry `AFTER_INDEX = 0` and **NULL** — not a negative duration.

**Background prevalence in the secondary cohort.** §7.4.1.2 and §7.8.4: *"all
malignancies occurring after diagnosis but prior to 2L will be tabulated as the
background prevalence"*. So the window is the diagnosis to the 2L index, both
days excluded, and the person-time is that interval's:

| patient | diagnosis | 2L index | days between, both excluded |
|---|---|---|---|
| P1 | 2019-01-05 | 2020-03-01 | 420 |
| P3 | 2019-11-01 | 2020-09-01 | 304 |
| P5 | 2018-12-01 | 2020-01-15 | 409 |
| P6 | 2019-01-01 | 2022-06-01 | 1246 |

2379 days = **6.5133** person-years, with P1's Hematological malignancy the one
prevalent case. Under `MALIG_PREVALENCE_WINDOW=baseline` (`expectations_alt.py`)
the window is the 12-month baseline instead, **3.9973** person-years for the
four, and P1's 2019-07-01 is inside its 2L baseline too.

**The aggregate.** §7.8.1 names *"malignancies"* as one chronic condition, so
beside the categories `S_MALIGNANCY_RATES` carries `(any malignancy)`: a first
malignancy of any kind, counted once, a patient with any before the period out
of numerator and denominator, and at-risk time ending at the first one. P1's
is the only one in 1L, inside its line-1 window (2019-07-01), so 1L line 1 is
**1 of 7** at risk over **4.2327** person-years (P1's time stops there; the
seven whole windows would be 4.8569). The secondary cohort's prevalence row is
the same **1 / 4 / 6.5133** as its one category. Every malignancy rate row
carries `RATE_LO` / `RATE_HI`, the zero-event rows with the exact limits
above (SEC2L line 2 treatment: 3 at risk, 2.1328 PY → upper 172960.60).

**The myeloma guard.** `check_malignancy_list()` refuses a secondary-malignancy
code that `mm_dx.csv` names as myeloma (C90.0 under ICD-10, 203.0 under
ICD-9), compared the way the SQL joins them; the same digits under the other
family are not a clash.

**Treatment sequences among those with a malignancy** (Table 4, *"top 5-10
sequences among those with a malignancy occurring after treatment"*). P1 is the
one 1L patient with a malignancy after its index; the malignancy (2019-07-01)
fell inside its 1L line, and its lines inside follow-up are 1L triplet → 2L
doublet → 3L quadruplet. "Sequence" is not pinned to a side of the
malignancy, so the table carries three readings on `LINES`, each with its own
denominator (Q32):

| `LINES` | P1's sequence |
|---|---|
| `to_malignancy` — lines started on or before it | Triplet with anti-CD38 backbone |
| `after_malignancy` — lines started after it | Doublet/monotherapy → Quadruplet with anti-CD38 backbone |
| `all_observed` | all three |

each rank 1, 100% of 1. A patient with no line after the malignancy reads
`(no further therapy)`. The sensitivity scope, *"only after 2L"*, is empty for
1L because P1's malignancy came before its 2L; and the secondary cohort has
no row in either scope because its one malignancy precedes its index.

### Time to event

P1's TTNT is **366** days: 2019-03-01 to 2020-03-01, index included and the
event day excluded, with `TTNT_EVENT = 1`.

## What this cannot check

The statements are transpiled to DuckDB. DuckDB is not Spark: a statement Spark
would reject can still run here, and a Spark-specific behaviour (Delta
semantics, `percentile_approx`'s approximation) is not reproduced. This checks
the **arithmetic**, and `tests/parse_sql.py` checks the dialect. Neither
replaces a run against the warehouse.
