# The LOT rules, with worked examples

The rules the engine applies, each shown on a patient timeline. The rule itself
— its exact wording, the setting behind it and the file it lives in — is in
`LOT_RULES.md`, and each heading here names the section.

Days are offsets from the first line's start, which is how the engine reasons —
`d+0` is the day 1L begins. Every number is the shipped default from
`engine/config.csv`, and the setting is named beside it so you can see what
moves when one changes.

The examples are the vignette catalogue in `validation/`, which is generated
from the settings rather than typed: `validation/out/lot_edge_case_vignettes.md`
lists every case with its timeline and expected result.

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

`LOT_LONG` is every line built. `LOT_LONG_FINAL` is the same after step 4 — a
patient excluded there is **absent from it**, not shortened.

---

## 1. Claims become exposure — `LOT_RULES.md` §2, §5.1

A pharmacy claim carries its own days of supply; a medical administration is
assumed to cover `MEDICAL_DAY_SUPPLY` = **28** days.

### Overlapping refills accumulate

> **d+0** oral agent dispensed, 30-day supply · **d+20** refilled early ·
> **d+40** refilled early again
> → exposure runs to the **accumulated** run-out, not to the last fill date
> plus one supply.

Patients refill early. Reading each fill as a fresh supply from its own date
would end lines that never stopped.

### A gap ends an agent's exposure — at 90 days, inclusive

`MAP_DISCON_GAP_DAYS` = **90**, and the threshold day itself counts as a gap.

> **d+0** 1L starts · **d+59** last day covered · **d+148** same agent resumes
> → **89 days**. No discontinuation; exposure continues across the gap.

> **d+0** 1L starts · **d+59** last day covered · **d+149** same agent resumes
> → **90 days**. Discontinuation.

Prior-authorisation holds and hospital stays both produce silence in claims,
and neither is a decision to stop treatment. One day separates the two
readings.

---

## 2. Line 1 and its induction window — §3.2, §4.2, §4.4, §2.1

An agent starting inside the induction window **joins the regimen**. One
starting after it is an **addition**, which can end the line.

`INDUCTION_WINDOW_DAYS` = **60** for line 1, inclusive of day 0, so the last
day inside is d+59.

> **d+0** 1L starts · **d+59** agent added → joins line 1's regimen
> **d+0** 1L starts · **d+60** agent added → an addition

Later lines get a shorter window: `INDUCTION_WINDOW_DAYS_LOT_N` = **30**.

> **d+0** LOT2 starts · **d+29** agent added → joins LOT2's regimen
> **d+0** LOT2 starts · **d+30** agent added → an addition

### A biosimilar is the same agent

> **d+0** 1L starts with the reference product · **d+70** the biosimilar is
> dispensed instead
> → **no new line**.

Which pairs count is declared in `permissible_subs.csv`. A substitution the
file does not list looks like a regimen change, and starts a line that did not
happen.

### Steroids do not carry a line

> **d+0** 1L regimen · **d+150** dexamethasone alone for several weeks ·
> **d+220** the next regimen begins
> → the steroid stretch neither starts a line nor continues one.

---

## 3. Transplants and CAR-T — §6, §4.6, §7.3

### Two codes close together are one transplant

`SCT_AUTO_WINDOW_DAYS` = **13**, and the test is `<=`, so the window is 14
calendar days inclusive of the first.

> **d+40** AUTO code · **d+53** second code → **one** transplant
> **d+40** AUTO code · **d+54** second code → **two** windows

Two windows are not yet two transplants: `SCT_AUTO_GAP_DAYS` = **60**, and a
window closer than 60 days to the last transplant kept is merged into it. So
the d+54 window above is a second billing episode, not a second transplant.

### A second transplant within 180 days is a planned tandem

`SCT_TANDEM_DAYS` = **180**.

> **d+30** first AUTO · **d+210** second AUTO → one **tandem pair**. Line 1 is
> not ended by the second transplant.

> **d+30** first AUTO · **d+211** second AUTO → not a tandem. The second is
> **excess**, and excess AUTO ends line 1.

> **d+30**, **d+209**, **d+400** → the first two are a tandem inside line 1;
> the third is excess and ends it.

A planned tandem and an unplanned second transplant look identical in claims.
The only thing separating them is the gap, so a patient sitting on it goes
either way. This is one of the readings marked **to confirm**.

### An allograft is a one-day line — with one exception

> **d+0** LOT1 · **d+200** allogeneic transplant · **d+201** medication
> → the ALLO line **starts and ends on d+200**. The next day's medication
> starts the line after it.

An allograft line carries **no regimen string**. Anything reading
`LOT_BASE_MEDS` to decide whether a line exists will miss it.

> **d+0** 1L · **d+40** AUTO · **d+240** ALLO after relapse
> → the AUTO sits inside line 1; the ALLO ends the line it falls in and opens
> its own one-day line.

The exception is melphalan. An allograft is usually conditioned with it, and a
short course the allograft's line holds is **owned** by that line, which is
carried to the course's last covered day — in the split-course example in §4
the allograft line runs **d+100 to d+110**, with an empty regimen.

### CAR-T closes the line it consolidates

`CART_CONSOLIDATION_DAYS` = **45**, counted from the addition.

> **d+0** 1L · **d+60** bridging agent added · **d+105** CAR-T
> → line 1 ends with reason **CART_INIT**. The bridging agent stays part of
> line 1 rather than starting a line of its own.

> **d+0** 1L · **d+60** agent added · **d+106** CAR-T
> → not CART_INIT. The addition is an ordinary regimen change, and the CAR-T
> is handled by the ordinary rules.

Bridging therapy holds a patient until CAR-T. Counted as its own line it would
inflate every downstream line number.

---

## 4. Melphalan — §4.7

High-dose melphalan is usually transplant conditioning, not a new therapy. A
melphalan course covering `MELP_SIMPLE_COURSE_DAYS` = **28** days or fewer,
**outside** any induction window, does not advance the line on its own.

> **d+0** 1L · **d+100** one melphalan administration · covers to **d+127**
> → 28 days, exactly the cap. **No new line.** Line 1 is **carried to
> d+127** — the last day the course covers.

> **d+0** 1L · **d+100** melphalan covering past d+127
> → past the cap melphalan is an added medication like any other agent. **A
> new line at d+100.**

### A new agent inside the course confirms it

> **d+0** 1L · **d+100** melphalan (short course) · **d+105** a new agent
> → **a new line, starting d+100** — the melphalan date, not d+105.

The agent inside the course is what tells us treatment changed; the melphalan
is *where* it changed.

### One course, one boundary

> **d+90** melphalan, outside 1L's induction · **d+95** a new agent starts
> inside the course's cover · **d+100** allograft · **d+110** a second dose
> of the same course
> → the agent at d+95 **confirms** the course, so it opens a line on
> **d+90**. The d+110 dose opens nothing: only the first day of a course is a
> boundary. The allograft's line is carried to d+110 and owns that dose.

### A transplant inside a course changes nothing

> **d+90** melphalan · **d+100** allograft · **d+110** second dose
> → no line starts on either dose. The course is under the cap and began
> outside any induction window. The d+90 dose stays in 1L; the allograft's
> line is carried to d+110 and owns the second.

### A returning drug is not a new agent

> **d+0** 1L on drug A and melphalan · **d+200** drug C opens 2L · **d+300**
> melphalan returns for 28 days · **d+305** a different, new agent starts
> → **a new line on d+300**, carrying melphalan and the new agent. 2L does
> not name melphalan: a confirmed course opens a line, so it is not a drug
> folding back into the line before it.

---

## 5. A drug that comes back — §4.3, §4.8

A drug from the line just before reappearing is "the returning drug", not a
new agent.

> **d+0** 1L on drug A and drug B · **d+200** drug C opens LOT2 ·
> **d+450** drug B comes back, while LOT2 is still running
> → **no new line.** One agent advanced the line between B's two appearances,
> so B joins LOT2 and its regimen string.

> **d+0** 1L on A and B · **d+200** C opens LOT2 · **d+300** D opens LOT3 ·
> **d+450** B comes back
> → **a new line at d+450.** B was last in 1L, not in the line just before,
> so it is a new agent like any other.

> **d+0** 1L on A and B · **d+200** C and D start LOT2 together · **d+450** B
> comes back
> → **no new line.** Two drugs started LOT2, but they advanced the line
> **once** between them.

> **d+200** C opens LOT2 · **d+420** C stops covering · **d+520** C comes
> back, 100 days later
> → **LOT2 continues.** A drug of the line's own regimen restarting after a
> gap stays in the line it left, whatever the gap.

> **d+0** 1L on A and B · **d+200** C opens LOT2 · **d+300** B comes back and
> joins LOT2 · **d+500** a transplant opens LOT3 · **d+600** B comes back again
> → **a new line on d+600.** A drug returning across a transplant is not
> returning to the line it left.

"How many times has the line moved" and "how many drugs started it" are
different questions; treating them as one would give a patient an extra line
every time a doublet starts a line.

---

## 6. How a line ends — §7

A line ends on the **earliest** qualifying event — the day before a transplant,
CAR-T or added agent, the confirmed run-out, death, or the end of observation —
and the reason names what that event was: `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`,
`CART_INIT`, `MED_ADD`, `DEATH`, `DISCONTINUATION`, `STUDY_END`. There is no
ranking between kinds; the order the reasons are tested in matters only on an
exact same-day tie.

> Agent A covers **d+0 – d+300** · first AUTO at **d+30** · a second AUTO at
> **d+211** · agent B added at **d+220** · ALLO at **d+250**
> → line 1 ends **`SCT_AUTO` on d+210**. The first AUTO is line 1's own and
> never ends it; the second is 181 days after it, past the tandem window, so
> it is excess. Its day-before, d+210, is earlier than B's (d+219) and the
> ALLO's (d+249), so it wins — an allograft does not reach back to end line 1
> merely for being an allograft. Line 2 opens at the second AUTO and ends
> **`SCT_ALLO` on d+249**; the allograft is line 3, a one-day line on d+250.

**An autologous transplant the line owns holds it open.**

> Agent A covers **d+0 – d+27** · a single AUTO at **d+59**, the last day of
> line 1's 60-day window
> → line 1 ends **`SCT_AUTO_CONT` on d+59**. A's cover ran out on d+27, but
> the transplant is the line's own, so the line is carried to it rather than
> closed before it.

**Death belongs to the line the patient was on.** It outranks an earlier
discontinuation only where nothing that could open the next line happened in
between.

> Agent A covers **d+0 – d+150** · agent B added at **d+100** · death at
> **d+180**
> → line 1 ends **MED_ADD on d+99**, the day before B; line 2 (B) ends
> **DEATH on d+180**.

A line ended by `DISCONTINUATION` ends on the **run-out**, not on the day the
gap was confirmed. A patient still covered at the end of observation has not
discontinued, and ends `STUDY_END`.

**An autograft on the same day as an allograft is not a tie.**

> Agent A covers **d+0 – d+300** · first AUTO at **d+30** · a second AUTO
> **and** an ALLO, both at **d+211**
> → line 1 ends **`SCT_ALLO` on d+210**. The second AUTO is dropped before
> the comparison, not outranked in it. With a CAR-T at d+211 instead of the
> ALLO the line ends `SCT_CART` on d+210.

---

## 7. Patient-level criteria — §8

Applied after every line is built, and they remove the **patient**, not the
line.

> **d+0** 1L · **d+300** LOT2 · **d+500** belantamab given at LOT3
> → the patient loses **every** line, not just LOT3 onward. They are absent
> from `LOT_LONG_FINAL` and present in `LOT_LONG`.

The difference between the two tables is exactly what the criteria removed.

---

## 8. What the engine does not do — §9, §10

**Maintenance is not a line.**

> **d+0** 1L regimen · **d+120** reduced to a single maintenance agent ·
> **d+400** new agents added at relapse
> → the maintenance stretch is part of 1L, flagged by `contains_mtx_reg`, and
> the relapse is handled by the ordinary rules. An algorithm that counts
> maintenance separately numbers every later line one higher.

**Nothing above line 5 is built.** `MAX_LOT` = **5**.

> New agents at **d+200**, **d+400**, **d+600**, **d+800** and **d+1000**
> → the last one would open LOT6, and no line above 5 is built. A count of
> lines is a count of lines **built**, not of lines received.

---

## 9. Which readings are settled

Each case in the catalogue is marked `derived` or `to_confirm`:

- **derived** — follows from the rule as written; reading the code is enough.
- **to_confirm** — the rules interact and this is our reading. The first
  warehouse run settles it.

The ones to confirm cluster where clinical intent is not visible in claims:
tandem versus salvage transplant, bridging versus a new regimen, melphalan as
conditioning versus as therapy, a returning drug versus a re-challenge, a
biosimilar switch, and early refills.

---

## 10. Changing a rule

Every number above is a setting in `engine/config.csv`. A build that changes
one is a **different algorithm**: it runs only with `LOT_CONTRACT_OVERRIDE=TRUE`,
records the departure on its status row, and every reader refuses it as the
study's numbers, so a sensitivity analysis cannot be mistaken for the study
(`LOT_RULES.md` §1; the command is in `CONTENTS.md`, "Running it"). The
catalogue regenerates against the settings it is run with, so these examples
move with them.
