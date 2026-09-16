# Returning-drug trace - prefix `example_`

Run `fixture`. What the rules adopted on 30 Aug 2026 (LOT_RULES.md 4.3 and 4.8) did with drugs that came back, on the patients they touched: raw MAP episodes beside the final lines, the returns marked.

**This is a rendered example on the eight FIXTURE patients in tests/returns_fixture.R, not a run. R000001-R000008 are invented ids, and every date, drug and episode below is made up - nothing here is a patient.** Each patient is one shape the trace tells apart: a fold into 2L, an own return inside 1L, an own return inside 2L, a return across a transplant-opened 2L that opened 3L, a return from two lines back that opened 4L, a short melphalan course that opened a line (4.7), a drug that arrived while such a course still covered, and a drug carried over inside a window (counted, not traced). A real run lists every return in the warehouse's finished LOT run, samples the patients to trace, and does carry real identifiers - which is what the line below is about.

Patient ids are NOT masked. This file carries patient identifiers and stays inside the study environment; it exists so each patient can be looked up in the warehouse.

Three kinds of return are traced, and a fourth is counted:

- **fold (4.8)** - a drug of the previous line, back after exactly one new agent opened the next line: it JOINED that line's regimen instead of starting one. Signature: in line n's regimen, in line n-1's, no episode inside line n's induction window, an episode inside line n after it.
- **own return (4.3)** - a drug the line already held, back after a confirmed break of its own (90 days or more with no supply of that drug): the line ran on over the break. Before the rule the break released the drug and the return opened a new line - a 1L drug back after a holiday made a 2L that no longer exists. Signature: an episode inside the line, after its window, whose preceding episode carries MAP_DISCON_FLG = 1 and was itself inside the line. That preceding dose is the window's for an ordinary regimen drug and the folded course for one 4.8 folded in, which the engine carries in the line's regimen - so a folded drug's LATER return is this kind, not a second fold.
- **opened a line** - a drug given earlier that came back and opened a line, which neither rule prevents. `OPEN_VIA` says which shape: `new_agent`, a drug two or more lines back, so 4.8's fold set - the immediately previous line's regimen - never held it, and where that previous line was itself opened by a transplant or CAR-T, 4.8 refused the fold as well; `melp_course`, a short melphalan course of the previous line's regimen that 4.7 confirmed, which is the one previous-line drug 4.3 exempts; and `melp_confirmed`, a drug two or more lines back that arrived while a short melphalan course was still covering, where the line opened on the melphalan's date rather than on its own. That last one says where the drug landed, not which rule put it there: a short course opening a line reads the same here whether 4.7 suppressed it and this arrival confirmed it, or melphalan simply started the line. The counter-example, so a reader sees where the rules stop.
- **carried over** (counted only) - a drug of the IMMEDIATELY previous line dosed inside the next line's induction window: an ordinary regimen drug of both lines. Not a return, and not a fold - the window is why. A drug from further back re-dosed inside a window is an ordinary regimen join (4.2) that no rule here decided, and is not counted.

RETURN_LINE is the line a return belongs to for the 2L question: the line a fold or an own return sits in, and the line BEFORE the one a returning drug opened. So "drugs that came back in 2L" is RETURN_LINE = 2: folds into LOT 2, own returns inside LOT 2, and returns after LOT 2 that opened LOT 3; own returns inside LOT 1 are the ones that would have made a 2L before the rule. It is a filing convention, not a column of the run: a reader who wants the returns whose episode LIES in 2L reads LOT_NUM = 2 in the candidates CSV.

Windows as the run recorded them: LOT1 60 days, later lines 30, CAR-T 45. A permissible substitute and the drug it replaces are one agent in the fold and line-opening tests (4.4); an own return is read under the drug's own name, because a substitute's restart was never released under the older reading either and so is not a return this rule changed. Each paragraph also says what the reading before 30 Aug 2026 would have made of the return - a local reading of these tables, stated for the FIRST return the rules decided in a patient; a later one says that it cannot be read locally. A build of the same cohort with APPLY_MAP_FOLDIN=FALSE and APPLY_OWN_RETURN_FOLD=FALSE, differenced against this one, is what settles an alternative history.

Traced: kinds fold, own_return, opens_line, every return line. 7 patient(s) carry a return in scope. 7 traced (a round-robin sample over kind, line and drug).

## Summary (over every return in the run, not the sample)

| kind | level | key | n_patients | n_lines | n_returns |
|---|---|---|---|---|---|
| LOT_LONG_FINAL | all lines |  | 8 | 20 |  |
| fold | all |  | 1 | 1 | 1 |
| fold | by return line | LOT2 | 1 | 1 | 1 |
| fold | by drug | LEN | 1 | 1 | 1 |
| own_return | all |  | 2 | 2 | 2 |
| own_return | by return line | LOT1 | 1 | 1 | 1 |
| own_return | by return line | LOT2 | 1 | 1 | 1 |
| own_return | by drug | LEN | 1 | 1 | 1 |
| own_return | by drug | POM | 1 | 1 | 1 |
| opens_line | all |  | 4 | 4 | 4 |
| opens_line | by return line | LOT1 | 1 | 1 | 1 |
| opens_line | by return line | LOT2 | 1 | 1 | 1 |
| opens_line | by return line | LOT3 | 2 | 2 | 2 |
| opens_line | by drug | LEN | 3 | 3 | 3 |
| opens_line | by drug | MELP | 1 | 1 | 1 |
| opens_line | by open path | melp_confirmed | 1 | 1 | 1 |
| opens_line | by open path | melp_course | 1 | 1 | 1 |
| opens_line | by open path | new_agent | 2 | 2 | 2 |
| carried_over | all |  | 1 | 1 | 1 |
| carried_over | by return line | LOT2 | 1 | 1 | 1 |
| carried_over | by drug | LEN | 1 | 1 | 1 |

## Patient R000001

**Folded into the line it returned in (4.8) - LEN, LOT 2.** LEN was in LOT 1's regimen (BORT LEN). LOT 2 opened on 2020-07-01 with CARF. LEN returned on 2020-08-15, 45 days after LOT 2 opened and outside its 30-day induction window (window ended 2020-07-30); under 4.8 it joined LOT 2's regimen (CARF LEN). Without the rule this return would have been an added medication: LOT 2's own regimen (CARF) was still covered on 2020-08-15 (cover ran to 2020-12-31), so LOT 2 would have ended MED_ADD on 2020-08-14, the day before the return, and a new line would have opened on 2020-08-15 with LEN.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | BORT LEN | 2 | 2020-06-30 | MED_ADD | 182 | CARF | 2020-07-01 |  |  |
| 2 | 2020-07-01 | MED | CARF LEN | 2 | 2021-01-31 | STUDY_END | 215 |  |  |  |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-07-31 | 2020-07-31 | BORT | NOVEL | 7 | 1 | 1 | opens LOT 1 |
| 2020-01-01 | 2020-06-30 | 2020-06-30 | DEX | STEROID | 6 | 0 | 1 |  |
| 2020-01-05 | 2020-04-30 | 2020-04-30 | LEN | NOVEL | 4 | 1 | 1 | induction |
| 2020-07-01 | 2020-12-31 | 2020-12-31 | CARF | NOVEL | 6 | 0 | 2 | opens LOT 2 |
| 2020-07-01 | 2021-01-31 | 2021-01-31 | DEX | STEROID | 7 | 0 | 2 |  |
| 2020-08-15 | 2021-01-31 | 2021-01-31 | LEN | NOVEL | 6 | 0 | 2 | FOLDED into LOT 2 (4.8) |

## Patient R000002

**Came back to its own line after a break (4.3) - LEN, LOT 1.** LEN is in LOT 1's own regimen (LEN): it was dosed inside the line's 60-day induction window. Its episode of 2020-01-01 to 2020-04-30 was followed by a break of 214 days (MAP_DISCON_FLG = 1: at least 90 days with no supply of LEN itself), and LEN came back on 2020-11-30, 334 days after LOT 1 opened and outside the window (window ended 2020-02-29). Under 4.3 a drug of the line's own regimen never starts a line, so the return stayed in LOT 1, which runs on over the break: LOT 1 is 2020-01-01 to 2021-03-31 (DISCONTINUATION). Before 30 Aug 2026 the break released the drug, and this return would have opened a new line on 2020-11-30. LOT 1's regimen (LEN) had run out on 2020-04-30, before the return, so the return would have confirmed that run-out (5.3): LOT 1 would have ended DISCONTINUATION on 2020-04-30 and the next line would have started on 2020-11-30 with LEN.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | LEN | 1 | 2021-03-31 | DISCONTINUATION | 456 |  |  | 2021-03-31 |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-04-30 | 2020-04-30 | DEX | STEROID | 4 | 1 | 1 |  |
| 2020-01-01 | 2020-04-30 | 2020-04-30 | LEN | NOVEL | 4 | 1 | 1 | break follows: 214 days to the return |
| 2020-11-30 | 2021-03-31 | 2021-03-31 | DEX | STEROID | 4 | 1 | 1 |  |
| 2020-11-30 | 2021-03-31 | 2021-03-31 | LEN | NOVEL | 4 | 1 | 1 | RETURNED to LOT 1 after a 214-day break (4.3) |

## Patient R000003

**Came back to its own line after a break (4.3) - POM, LOT 2.** POM is in LOT 2's own regimen (POM): it was dosed inside the line's 30-day induction window. Its episode of 2020-09-01 to 2020-12-15 was followed by a break of 137 days (MAP_DISCON_FLG = 1: at least 90 days with no supply of POM itself), and POM came back on 2021-05-01, 242 days after LOT 2 opened and outside the window (window ended 2020-09-30). Under 4.3 a drug of the line's own regimen never starts a line, so the return stayed in LOT 2, which runs on over the break: LOT 2 is 2020-09-01 to 2021-08-31 (STUDY_END). Before 30 Aug 2026 the break released the drug, and this return would have opened a new line on 2021-05-01. LOT 2's regimen (POM) had run out on 2020-12-15, before the return, so the return would have confirmed that run-out (5.3): LOT 2 would have ended DISCONTINUATION on 2020-12-15 and the next line would have started on 2021-05-01 with POM.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | BORT | 1 | 2020-08-31 | MED_ADD | 244 | POM | 2020-09-01 |  |  |
| 2 | 2020-09-01 | MED | POM | 1 | 2021-08-31 | STUDY_END | 365 |  |  |  |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-09-30 | 2020-09-30 | BORT | NOVEL | 9 | 1 | 1 | opens LOT 1 |
| 2020-01-01 | 2020-06-15 | 2020-06-15 | DEX | STEROID | 6 | 0 | 1 |  |
| 2020-09-01 | 2020-12-15 | 2020-12-15 | DEX | STEROID | 4 | 0 | 2 |  |
| 2020-09-01 | 2020-12-15 | 2020-12-15 | POM | NOVEL | 4 | 1 | 2 | break follows: 137 days to the return |
| 2021-05-01 | 2021-08-31 | 2021-08-31 | DEX | STEROID | 4 | 0 | 2 |  |
| 2021-05-01 | 2021-08-31 | 2021-08-31 | POM | NOVEL | 4 | 0 | 2 | RETURNED to LOT 2 after a 137-day break (4.3) |

## Patient R000007

**Came back and opened a line (outside 4.8) - MELP, LOT 2.** MELP was in LOT 1's regimen (LEN MELP) and came back on 2020-12-01 as a short course confirmed by DARA. 4.7 makes such a course a line of its own from its first day, and melphalan is the one agent 4.3 exempts from 'a drug of the previous regimen never starts a line'. It was an added medication: LOT 1 ended MED_ADD on 2020-11-30, and MELP opened LOT 2 (DARA MELP). The 30 Aug 2026 rules changed nothing here: this is 4.7's reading, and it held before them too.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | LEN MELP | 2 | 2020-11-30 | MED_ADD | 335 | MELP | 2020-12-01 |  |  |
| 2 | 2020-12-01 | MED | DARA MELP | 2 | 2021-06-30 | STUDY_END | 212 |  |  |  |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-12-31 | 2020-12-31 | LEN | NOVEL | 12 | 1 | 1 | opens LOT 1 |
| 2020-02-01 | 2020-02-28 | 2020-02-28 | MELP | NOVEL | 1 | 1 | 1 | induction |
| 2020-12-01 | 2020-12-28 | 2020-12-28 | MELP | NOVEL | 1 | 0 | 2 | opens LOT 2 - a short melphalan course 4.7 confirmed |
| 2020-12-10 | 2021-06-30 | 2021-06-30 | DARA | NOVEL | 7 | 0 | 2 | induction |

## Patient R000004

**Came back and opened a line (outside 4.8) - LEN, LOT 3.** LEN was last in LOT 1's regimen (BORT LEN). Its previous episode ran 2020-01-01 to 2020-06-30, 154 days before. LOT 2 was opened by a transplant or CAR-T (SCT_AUTO) and carried no drug. 4.8 refuses a fold across a procedure that opened a line, so LEN was no returning regimen drug when it came back on 2020-12-01. It was an added medication: LOT 2 ended MED_ADD on 2020-11-30, and LEN opened LOT 3 (LEN). The 30 Aug 2026 rules changed nothing here: this return opened a line under the earlier reading too.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | BORT LEN | 2 | 2020-06-30 | DISCONTINUATION | 182 |  |  | 2020-06-30 |  |
| 2 | 2020-09-01 | SCT_AUTO |  | 0 | 2020-11-30 | MED_ADD | 91 | LEN | 2020-12-01 |  |  |
| 3 | 2020-12-01 | MED | LEN | 1 | 2021-06-30 | STUDY_END | 212 |  |  |  |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-05-31 | 2020-05-31 | BORT | NOVEL | 5 | 1 | 1 | opens LOT 1 |
| 2020-01-01 | 2020-06-30 | 2020-06-30 | DEX | STEROID | 6 | 0 | 1 |  |
| 2020-01-01 | 2020-06-30 | 2020-06-30 | LEN | NOVEL | 6 | 1 | 1 | opens LOT 1 |
| 2020-09-01 |  |  | SCT_AUTO | TRANSPLANT |  |  | 2 | opens LOT 2 |
| 2020-12-01 | 2021-06-30 | 2021-06-30 | LEN | NOVEL | 7 | 0 | 3 | opens LOT 3 - LOT 2 was opened by SCT_AUTO, so no fold across it |

## Patient R000005

**Came back and opened a line (outside 4.8) - LEN, LOT 4.** LEN was last in LOT 1's regimen (BORT LEN). Its previous episode ran 2020-01-01 to 2020-04-30, 489 days before. LOT 3 (POM) did not carry it. 4.8's fold set is the immediately previous line's regimen only, so a drug from further back is out of its scope, and 4.3 does not hold it either: when LEN came back on 2021-09-01 it was a new agent like any other. It was an added medication: LOT 3 ended MED_ADD on 2021-08-31, and LEN opened LOT 4 (LEN). The 30 Aug 2026 rules changed nothing here: this return opened a line under the earlier reading too.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | BORT LEN | 2 | 2020-06-30 | MED_ADD | 182 | CARF | 2020-07-01 |  |  |
| 2 | 2020-07-01 | MED | CARF | 1 | 2021-01-31 | MED_ADD | 215 | POM | 2021-02-01 |  |  |
| 3 | 2021-02-01 | MED | POM | 1 | 2021-08-31 | MED_ADD | 212 | LEN | 2021-09-01 |  |  |
| 4 | 2021-09-01 | MED | LEN | 1 | 2022-03-31 | STUDY_END | 212 |  |  |  |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-07-31 | 2020-07-31 | BORT | NOVEL | 7 | 1 | 1 | opens LOT 1 |
| 2020-01-01 | 2020-04-30 | 2020-04-30 | LEN | NOVEL | 4 | 1 | 1 | opens LOT 1 |
| 2020-07-01 | 2021-02-28 | 2021-02-28 | CARF | NOVEL | 8 | 1 | 2 | opens LOT 2 |
| 2020-07-01 | 2021-01-31 | 2021-01-31 | DEX | STEROID | 7 | 0 | 2 |  |
| 2021-02-01 | 2021-09-30 | 2021-09-30 | POM | NOVEL | 8 | 1 | 3 | opens LOT 3 |
| 2021-09-01 | 2022-03-31 | 2022-03-31 | LEN | NOVEL | 7 | 0 | 4 | opens LOT 4 - back from LOT 1, out of 4.8's scope |

## Patient R000008

**Came back and opened a line (outside 4.8) - LEN, LOT 4.** LEN was last in LOT 1's regimen (BORT LEN). Its previous episode ran 2020-01-01 to 2020-04-30, 489 days before. It came back on 2021-09-01, while a melphalan course that started on 2021-08-25 was still covering - a course of 28 days or fewer, which is 4.7's short one. 4.7 reads a new agent arriving inside such a course as what advances the line, and advances it on the MELPHALAN's date rather than the agent's, so LEN is in LOT 4's regimen (LEN MELP) without a line ever opening on its own date. LOT 3 ended MED_ADD on 2021-08-24, and the melphalan opened LOT 4. What these tables cannot show is whether 4.7 was the rule that acted: a course this short opening a line looks the same here whether the rule suppressed it and this arrival advanced it, or melphalan simply started the line as a new agent. Read this as where the drug landed, not as the rule's verdict.

Lines (LOT_LONG_FINAL):

| LOT_NUM | LOT_START_DT | LOT_START_TYPE | LOT_BASE_MEDS | LOT_MED_CNT | LOT_BASE_END_DT | LOT_BASE_END_REASON | LOT_BASE_LENGTH | LOT_BASE_1ST_ADD_MED | LOT_BASE_1ST_ADD_MED_DT | LOT_BASE_DISCON_DT | LOT_TX_AUTO_MAX_DT |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2020-01-01 | MED | BORT LEN | 2 | 2020-06-30 | MED_ADD | 182 | CARF | 2020-07-01 |  |  |
| 2 | 2020-07-01 | MED | CARF | 1 | 2021-01-31 | MED_ADD | 215 | POM | 2021-02-01 |  |  |
| 3 | 2021-02-01 | MED | POM | 1 | 2021-08-24 | MED_ADD | 205 | MELP | 2021-08-25 |  |  |
| 4 | 2021-08-25 | MED | LEN MELP | 2 | 2022-03-31 | STUDY_END | 219 |  |  |  |  |

Episodes (MAP_STACKED) and transplant events, in date order:

| MAP_START_DT | MAP_END_DT | MAP_MED_RUNOUT_DT | MAP_MED_TYPE | MAP_MED_CLASS | MAP_CNT | MAP_DISCON_FLG | line | note |
|---|---|---|---|---|---|---|---|---|
| 2020-01-01 | 2020-07-31 | 2020-07-31 | BORT | NOVEL | 7 | 1 | 1 | opens LOT 1 |
| 2020-01-01 | 2020-04-30 | 2020-04-30 | LEN | NOVEL | 4 | 1 | 1 | opens LOT 1 |
| 2020-07-01 | 2021-02-28 | 2021-02-28 | CARF | NOVEL | 8 | 1 | 2 | opens LOT 2 |
| 2021-02-01 | 2021-08-31 | 2021-08-31 | POM | NOVEL | 7 | 1 | 3 | opens LOT 3 |
| 2021-08-25 | 2021-09-21 | 2021-09-21 | MELP | NOVEL | 1 | 0 | 4 | opens LOT 4 |
| 2021-09-01 | 2022-03-31 | 2022-03-31 | LEN | NOVEL | 7 | 0 | 4 | confirms the melphalan course that opened LOT 4 (4.7) |

