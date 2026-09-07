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
  counts for nobody **and** P1's person-time leaves the denominator. The chronic
  denominator is **2.5544** person-years against the acute **3.5154**;
- **P2** has it *on* 2019-06-01, its period start. The prior-history window is
  `< PERIOD_START`, so this is **not** prior history and it counts.

Every one of the 23 conditions gets an incidence row whether or not it had an
event, because the rate is driven from the denominator.

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

### Time to event

P1's TTNT is **366** days: 2019-03-01 to 2020-03-01, index included and the
event day excluded, with `TTNT_EVENT = 1`.

## What this cannot check

The statements are transpiled to DuckDB. DuckDB is not Spark: a statement Spark
would reject can still run here, and a Spark-specific behaviour (Delta
semantics, `percentile_approx`'s approximation) is not reproduced. This checks
the **arithmetic**, and `tests/parse_sql.py` checks the dialect. Neither
replaces a run against the warehouse.
