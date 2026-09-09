# The LOT rules, with worked examples

Every rule the engine applies, each with a patient whose timeline shows it
working. `LOT_RULES.md` is the same set as a reference, with the protocol
section and the file each rule lives in; this document is the illustrated
version.

Days are offsets from the first line's start, which is how the engine reasons —
`d+0` is the day 1L begins. Every number in an example is the shipped default;
`engine/config.csv` holds them all, and the settings are named beside each rule
so you can see what moves when one changes.

The examples are the catalogue in `validation/`, which is regenerated from the
settings rather than typed — so if a setting changes, the examples change with
it. `validation/out/lot_edge_case_vignettes.md` is the generated version.

---

## What a line is

A line of therapy is a **regimen and the period it was given over**. The engine
builds it in four movements:

1. **Claims become exposure.** Pharmacy fills and medical administrations
   become episodes with a start and an end.
2. **Line 1 opens** on the first eligible therapy, and takes an induction
   window in which further agents join its regimen.
3. **A line ends** for one of a fixed set of reasons, and the next line opens.
4. **Patient-level criteria** are applied last, and can remove a patient
   entirely.

Two tables come out. `LOT_LONG` is every line built. `LOT_LONG_FINAL` is the
same after step 4 — a patient excluded there is **absent from it**, not
shortened.

---

## 1. Claims become exposure

### An oral fill covers the days it supplies

A pharmacy claim carries its own days of supply. A medical administration does
not, so one is assumed to cover `MEDICAL_DAY_SUPPLY` = **28** days.

### Overlapping refills accumulate

> **d+0** oral agent dispensed, 30-day supply · **d+20** refilled early ·
> **d+40** refilled early again

Exposure runs to the **accumulated** run-out, not to the last fill date plus
one supply. Refilling early pushes the end of cover later, which moves the gap
that would otherwise end the line.

*Why it matters:* patients refill early. Reading each fill as a fresh 28 days
from its own date shortens every chain and ends lines that never stopped.

### A gap ends an agent's exposure — at 90 days, inclusive

`MAP_DISCON_GAP_DAYS` = **90**, and the threshold day itself counts as a gap.

> **d+0** 1L starts · **d+59** last day covered · **d+148** same agent resumes
> → **89 days**. No discontinuation; exposure continues across the gap.

> **d+0** 1L starts · **d+59** last day covered · **d+149** same agent resumes
> → **90 days**. Discontinuation.

*Why it matters:* prior-authorisation holds and hospital stays both produce
silence in claims, and neither is a decision to stop treatment. One day
separates the two readings.

---

## 2. Line 1 and its induction window

An agent starting inside the induction window **joins the regimen**. One
starting after it is an **addition**, which is a different thing — an addition
can end the line.

`INDUCTION_WINDOW_DAYS` = **60** for line 1, and the window is inclusive of
day 0, so the last day inside is d+59.

> **d+0** 1L starts · **d+59** agent added
> → joins line 1's regimen. Line 1 is a four-drug regimen.

> **d+0** 1L starts · **d+60** agent added
> → **not** part of the regimen. It is an addition.

Later lines get a shorter window: `LOT_N_INDUCTION_WINDOW_DAYS` = **30**.

> **d+0** LOT2 starts · **d+29** agent added → joins LOT2's regimen
> **d+0** LOT2 starts · **d+30** agent added → an addition

*Why it matters:* the `-1` is the difference between a regimen of four drugs
and one of three, and two different windows in one algorithm is a standing
source of error.

### A biosimilar is the same agent

> **d+0** 1L starts with the reference product · **d+70** the biosimilar is
> dispensed instead
> → **no new line**. A permissible substitute is the same agent for line
> purposes.

Which pairs count is declared in `permissible_subs.csv`, so whether this holds
for a given pair depends on that file rather than on the rule. A substitution
the code list does not know about looks like a regimen change, and starts a
line that did not happen.

### Steroids do not carry a line

> **d+0** 1L regimen · **d+150** dexamethasone alone for several weeks ·
> **d+220** the next regimen begins
> → the steroid stretch neither starts a line nor continues one.

---

## 3. Transplants and CAR-T

### Two codes close together are one transplant

`SCT_AUTO_WINDOW_DAYS` = **13**, and the test is `<=`, so the window is 14
calendar days inclusive of the first.

> **d+40** AUTO code · **d+53** second code → **one** transplant
> **d+40** AUTO code · **d+54** second code → **two** events

*Why it matters:* a single admission often bills more than one code.

### A second transplant within 180 days is a planned tandem

`SCT_TANDEM_DAYS` = **180**.

> **d+30** first AUTO · **d+210** second AUTO → one **tandem pair**. A tandem
> is allowed, so line 1 is not ended by the second transplant.

> **d+30** first AUTO · **d+211** second AUTO → not a tandem. The second is
> **excess**, and excess AUTO ends line 1.

> **d+30**, **d+210**, **d+400** → the first two are a tandem inside line 1;
> the third is excess and ends it.

*Why it matters:* a planned tandem and an unplanned second transplant look
identical in claims. The only thing separating them is the gap, and a patient
sitting on it goes either way. This is one of the readings marked
**to confirm** — the first warehouse run settles it.

### An allograft is a one-day line

> **d+0** LOT1 · **d+200** allogeneic transplant · **d+201** medication
> → the ALLO line **starts and ends on d+200**. The next day's medication
> starts the line after it.

An allograft line carries **no regimen string** — its induction rows are
suppressed. Anything reading `LOT_BASE_MEDS` to decide whether a line exists
will miss it, which is the shape that broke the earlier transition diagrams.

> **d+0** 1L · **d+40** AUTO · **d+240** ALLO after relapse
> → the AUTO sits inside line 1; the ALLO ends the line it falls in and opens
> its own one-day line.

### CAR-T closes the line it consolidates

`CART_CONSOLIDATION_DAYS` = **45**, counted from the addition.

> **d+0** 1L · **d+60** bridging agent added · **d+105** CAR-T
> → line 1 ends with reason **CART_INIT**. The bridging agent stays part of
> line 1 rather than starting a line of its own.

> **d+0** 1L · **d+60** agent added · **d+106** CAR-T
> → not CART_INIT. The addition is an ordinary regimen change, and the CAR-T
> is handled by the ordinary rules.

*Why it matters:* bridging therapy holds a patient until CAR-T. Counted as its
own line it inflates every downstream line number.

---

## 4. Melphalan

High-dose melphalan is usually transplant conditioning, not a new therapy.
Counted as an added medication it opens a line of therapy nobody gave.

The rule: a melphalan course covering `MELP_SIMPLE_COURSE_DAYS` = **28** days
or fewer, **outside** any induction window, does not advance the line on its
own.

> **d+0** 1L · **d+100** one melphalan administration · covers to **d+127**
> → 28 days, exactly the cap. **No new line.** The course neither ends line 1
> nor starts line 2, and line 1 is **carried to d+127** — the last day the
> course covers — rather than ending on the melphalan date.

> **d+0** 1L · **d+100** melphalan covering past d+127
> → past the cap the rule stands aside, and melphalan is an added medication
> like any other agent. **A new line at d+100.**

### A new agent inside the course confirms it

> **d+0** 1L · **d+100** melphalan (short course) · **d+105** a new agent
> → **a new line, starting d+100** — the melphalan date, not d+105.

The agent inside the course is what tells us treatment changed; the melphalan
is *where* it changed.

### One course, one boundary

> **d+90** melphalan · **d+110** a second dose of the same course
> → the course opens a line on **d+90**. The d+110 dose opens nothing: only the
> first day of a course is a boundary.

### A transplant inside a course changes nothing

> **d+90** melphalan · a transplant between · **d+110** second dose
> → no line starts on either dose. The course is under the cap and began
> outside any induction window, so it does not advance the line wherever the
> transplant sits.

Suppressing a course and **owning** it are two halves of one statement: the
line that refused the course a boundary is carried to the course's last covered
day, so no melphalan dose is left in no line at all.

---

## 5. A drug that comes back

A drug from an earlier line reappearing is "the returning drug", not a new
agent — but only if the line has not moved on twice.

> **d+0** 1L on drug A and drug B · **d+200** drug C opens LOT2 ·
> **d+450** drug B comes back, while LOT2 is still running
> → **no new line.** One agent advanced the line between B's two appearances,
> so B joins LOT2 and its regimen string.

> Two agents advance the line between B's two appearances
> → **a new line at the return.** The fold set is the *immediately* previous
> line's regimen, so a drug last seen two lines back is not in it at all, and
> it opens a line as any other agent would.

> Two drugs start LOT2 together while B is away, then B returns
> → **no new line.** Two agents started LOT2, but they advanced the line
> **once** between them.

*Why it matters:* "how many times has the line moved" and "how many drugs
started it" are different questions, and treating them as one gives a patient
an extra line every time a doublet starts a line.

---

## 6. How a line ends

A line ends for exactly one reason, and the reasons have a priority:

| reason | what happened |
|---|---|
| `DEATH` | the patient died |
| `SCT_ALLO` | an allogeneic transplant |
| `SCT_CART` / `CART_INIT` | a CAR-T infusion |
| `SCT_AUTO` | an autologous transplant that breaks the line |
| `MED_ADD` | an agent was added after the induction window |
| `DISCONTINUATION` | every agent's cover ran out and the gap confirmed it |
| `STUDY_END` | still on treatment when observation stopped |

A line ended by `DISCONTINUATION` ends on the **run-out**, not on the day the
gap was confirmed — the patient stopped when their drugs did.

`STUDY_END` matters for what it prevents: a patient still covered at the end of
observation has **not** discontinued, and recording one there would turn
treatment-active-at-censoring into a stop that did not happen.

---

## 7. Patient-level criteria

Applied after every line is built, and they remove the **patient**, not the
line.

> **d+0** 1L · **d+300** LOT2 · **d+500** belantamab given at LOT3
> → the patient loses **every** line, not just LOT3 onward. They are absent
> from `LOT_LONG_FINAL` and present in `LOT_LONG`.

Keeping both tables is what makes this checkable: the difference between them
is exactly what the criteria removed.

---

## 8. What the engine does not do

**Maintenance is not a line.** It is a flag on the line it belongs to
(`contains_mtx_reg`). A patient moving from maintenance into relapse is handled
by the ordinary rules, so a line count does not include a maintenance line.

**Nothing above line 5 is built.** `MAX_LOT` = **5**.

> New agents at **d+200**, **d+400**, **d+600**, **d+800** and **d+1000**
> → the last one would open LOT6, and no line above 5 is built. That therapy
> is not represented, so a count of lines is a count of lines **built**, not
> of lines received.

---

## 9. Which readings are settled

The catalogue marks each case `derived` or `to_confirm`:

- **derived** — follows from the rule as written; reading the code is enough.
- **to_confirm** — the rules interact and this is our reading. The first
  warehouse run settles it. A claim about us, not about the algorithm.

Of the thirty cases, fourteen are derived and sixteen are to confirm. The ones
to confirm cluster where clinical intent is not visible in claims: tandem
versus salvage transplant, bridging versus a new regimen, melphalan as
conditioning versus as therapy, and a returning drug versus a re-challenge.

`validation/out/lot_edge_case_vignettes.md` lists all thirty with their
timelines. Every one of them is also a test: `validation/tests/test_vignettes.R`
requires each boundary pair to straddle its setting, to be **adjacent** — the
last day inside and the first day outside — and to expect different things on
the two sides. A pair that stops being a boundary fails the suite.

---

## 10. Changing a rule

Every number above is a setting in `engine/config.csv`, and the environment
beats the file:

```bash
INDUCTION_WINDOW_DAYS=90 INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  OBJECT_PREFIX=lot_ind90_ Rscript engine/build.R
```

A build that changes one of these is a **different algorithm**, and the engine
treats it that way. It records what it used in `LOT_RUN_METADATA`, stamps the
departure in `LOT_BUILD_STATUS`, and every reader that resolves run ownership
refuses it as the study's numbers. That is deliberate: a sensitivity analysis
should not be able to be mistaken for the study.

The vignette catalogue regenerates against whatever settings a run used, so the
examples in this document are the examples for the shipped defaults — not
prose that has to be edited when a number moves.
