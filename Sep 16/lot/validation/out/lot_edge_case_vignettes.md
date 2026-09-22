# LOT edge-case vignettes

Resolved against: induction_window_days=60, lot_n_induction_window_days=30, map_discon_gap_days=90, medical_day_supply=28, sct_auto_window_days=13, sct_auto_gap_days=60, sct_tandem_days=180, cart_consolidation_days=45, melp_simple_course_days=28, max_lot=5

`derived` follows from the rule quoted beside it. `to_confirm` is our
reading of how the rules interact, and the first warehouse run settles it.

| id | case | parameter | expected under this algorithm | confidence |
|---|---|---|---|---|
| `tandem_within` | Second AUTO inside the tandem window | `sct_tandem_days = 180` | The two AUTOs are one tandem pair. A tandem is allowed, so LOT1 is not ended by the second one. | to_confirm |
| `tandem_beyond` | Second AUTO past the tandem window | `sct_tandem_days = 180` | Not a tandem. The second AUTO is excess, and excess AUTO ends LOT1. | to_confirm |
| `auto_window_within` | Two AUTO codes inside the grouping window | `sct_auto_window_days = 13` | One transplant, not two. The predicate is <=, so the window is 14 calendar days inclusive of the first. | derived |
| `auto_window_beyond` | Two AUTO codes past the grouping window | `sct_auto_window_days = 13` | Two separate AUTO events, subject to the gap and tandem rules. | derived |
| `cart_bridge_within` | CAR-T inside the consolidation window | `cart_consolidation_days = 45` | LOT1 ends with reason CART_INIT. The bridging agent stays part of LOT1 rather than starting a line of its own. | derived |
| `cart_bridge_beyond` | CAR-T past the consolidation window | `cart_consolidation_days = 45` | Not CART_INIT. The addition is an ordinary regimen change and the CAR-T is handled by the ordinary rules for a CAR-T event. | to_confirm |
| `map_gap_within` | Treatment gap below the discontinuation threshold | `map_discon_gap_days = 90` | No discontinuation. The agent's exposure continues across the gap. | derived |
| `map_gap_beyond` | Treatment gap at the discontinuation threshold | `map_discon_gap_days = 90` | Discontinuation. The predicate is >=, so the threshold day itself counts as a gap. | derived |
| `induction_lot1_within` | Agent added on the last day of LOT1 induction | `induction_window_days = 60` | The agent joins LOT1's regimen. The window is day 0 through day 59 - 60 days inclusive. | derived |
| `induction_lot1_beyond` | Agent added the day after LOT1 induction closes | `induction_window_days = 60` | Not part of LOT1's regimen. It is an addition, not an induction agent. | derived |
| `induction_lotn_within` | Agent added on the last day of a later line's induction | `lot_n_induction_window_days = 30` | Joins LOT2's regimen. Later lines use 30 days, not LOT1's 60. | derived |
| `induction_lotn_beyond` | Agent added the day after a later line's induction closes | `lot_n_induction_window_days = 30` | Not part of LOT2's regimen. | derived |
| `allo_single_day` | Allogeneic transplant line spans one day | - | The ALLO line starts and ends on the transplant date. The next day's medication starts the line after it. The ALLO line carries NO regimen string - induction rows are suppressed for it - which is why anything reading LOT_BASE_MEDS to decide a line exists will miss it. | derived |
| `allo_after_failed_auto` | Allogeneic transplant after a failed autologous | - | The AUTO sits inside LOT1. The ALLO ends the line it falls in and opens a one-day SCT_ALLO line. | to_confirm |
| `biosimilar_switch` | Biosimilar substituted mid-line | - | No new line. A permissible substitute is the same agent for line purposes, and the pair is declared in permissible_subs.csv - so whether this holds depends on that file, not on this rule. | to_confirm |
| `melp_short_course` | Brief melphalan course outside induction | `melp_simple_course_days = 28` | No new line. The course neither ends line 1 nor starts line 2, and line 1 is carried to day 127 - the last day the course covers - rather than ending at the melphalan date. | to_confirm |
| `melp_long_course` | Melphalan course past the short cap | `melp_simple_course_days = 28` | A new line at day 100. Past the cap the rule stands aside and melphalan is an added medication like any other agent. | to_confirm |
| `melp_short_course_confirmed` | A new agent inside a brief melphalan course | - | A new line, and it starts on day 100 - the melphalan date - not on day 105. The agent inside the course is what tells us treatment changed; the melphalan is where it changed. | to_confirm |
| `melp_confirmed_course_is_one_course` | A confirmed melphalan course given as more than one dose | - | The course is confirmed, so it opens a line on day 90 - the melphalan date. Its day-110 dose opens nothing: only the first day of a course is a boundary. The allograft's line is carried to day 110 and owns it. | to_confirm |
| `melp_course_split_by_a_transplant` | A transplant lands inside a brief melphalan course | - | No line starts on either dose. The course covers 21 days, which is under the cap, and it began outside any induction window - so it does not advance the line, wherever the transplant sits. The day-90 dose stays in 1L; the allograft's own line is carried to day 110 and owns the second. | to_confirm |
| `melp_confirmed_beats_the_fold` | A confirmed melphalan course that is also a returning drug | - | A new line on day 300 - the melphalan date - carrying the melphalan and the day-305 agent. 2L keeps its own end and does NOT name melphalan: the course starts a line, so it is not a drug folding back into the line before it. | to_confirm |
| `returning_drug_one_advance` | A drug returns after one advance | - | No new line. One agent advanced the line between B's two doses, so B joins 2L - the line's span carries it, and it joins 2L's regimen string too. | to_confirm |
| `returning_drug_two_advances` | A drug returns after two advances | - | A new line at day 450. B is a 1L drug and the fold set is the IMMEDIATELY previous line's regimen, so B is not in it at all - the count is never asked, and B opens a line as any other agent would. | to_confirm |
| `returning_drug_two_agents_one_line` | Two drugs start one line while a drug is away | - | No new line. Two agents started 2L, but they advanced the line ONCE between them, so B sees one advance and joins 2L. | to_confirm |
| `returning_drug_second_return_across_transplant` | A folded drug returns again, in a line a transplant opened | - | A new line on day 600. A transplant opened 3L, so 4.8 refuses the second fold and B is line-defining again - 3L ends the day before it, and B opens 4L on its own date. The fold into 2L does not make B a drug 3L already had. | derived |
| `returning_drug_refused_dose_is_an_arrival` | A dose the fold refused is an arrival for the doses after it | - | 3L carries no regimen and ends the day before day 294, and 4L opens there on A and B. The day-294 doses have the transplant between them and the previous dose, so 4.8 refuses both folds; A's refused dose is what ends 3L. B's day-322 dose has only day 294 before it, no transplant between, and would fold into 3L - but a refused dose is line-defining for what follows it, so day 322 belongs to 4L. | derived |
| `returning_drug_no_advance` | A drug returns with nothing in between | `map_discon_gap_days = 90` | 2L continues. The 100-day gap is past the 90-day discontinuation, so this is a return and not a refill - but nothing advanced the line between C's two doses, so 4.8 has nothing to decide and 4.3 answers instead: a drug restarting in the line it left stays in it, whatever the gap. | derived |
| `returning_drug_whole_course` | A returning course folds as one, not episode by episode | `map_discon_gap_days = 90` | One line. All three of B's doses are one course - the gaps are shorter than the 90-day discontinuation - and the course folds as a unit, so no line opens on the follow-ups and 2L runs to the last day B covers. | derived |
| `returning_drug_joins_the_regimen` | A folded drug is in the line's regimen, not only its dates | - | 2L reports TWO drugs, C and B, and its medication count is two. The line also runs to the last day B's supply reaches, because a drug the rule says is part of the line has to be part of it in every reading of the line. | derived |
| `returning_drug_same_day_new_agent` | A genuinely new drug on the same day takes preference | - | 3L opens on day 450 on D, and B belongs to it rather than to 2L. 2L ends the day before, on its own run-out, exactly where it would have ended had B not come back at all. | derived |
| `returning_drug_own_transplant_no_advance` | A transplant the line already owns advances nothing | `lot_n_induction_window_days = 30` | B folds into 2L as it would with no transplant at all. The transplant on day 215 is 15 days into 2L, inside its 30-day window, so 6.5 gives it to that line: it opened nothing, and a transplant that opened no line is not a boundary for this rule. | derived |
| `returning_drug_two_lines_back` | A drug from further back than the previous line is simply new | - | 4L opens on day 600. B was 1L's drug and the line before this one is 2L, so B is outside the fold set entirely and the engine's ordinary rules keep it: an agent not in the current regimen is an added medication. | derived |
| `returning_drug_same_day_as_the_transplant` | A dose on the transplant's own date is not that line's | - | 3L keeps the one day and the empty regimen 4.6 gives it, and 4L opens on day 410 on B. The day-350 dose is not 3L's: an allogeneic line takes no regimen, so nothing folds into one. | derived |
| `maintenance_to_relapse` | Maintenance running into relapse | - | Maintenance is NOT a line of its own here - contains_mtx_reg is a flag and there is no maintenance period. The relapse is handled by the ordinary rules, so the line count does not include a maintenance line. | derived |
| `steroid_only_interval` | Steroid-only stretch between regimens | - | The steroid stretch neither starts nor continues a line. | derived |
| `belantamab_any_line` | Belantamab anywhere in the patient's lines | - | The criterion is patient-level, so the patient loses EVERY line, not just LOT3 onward. They are absent from LOT_LONG_FINAL entirely and present in LOT_LONG. | derived |
| `excess_auto` | A third autologous transplant | - | The first two are a tandem inside LOT1; the third is excess and ends LOT1. | to_confirm |
| `overlapping_oral_refills` | Overlapping oral refills | `medical_day_supply = 28` | Exposure runs to the accumulated run-out, not to the last fill date plus one supply. Early refills push the end of the MAP later, which moves the gap that would otherwise end the line. A medical-claim administration is assumed to cover 28 days. | to_confirm |
| `line_beyond_max` | A patient who would reach a line above MAX_LOT | `max_lot = 5` | No line above 5 is built. The patient's later therapy is not represented, so a count of lines is a count of lines BUILT, not of lines received. | derived |

## Timelines

**tandem_within** - Second AUTO inside the tandem window

- timeline: d+0 MED (1L regimen starts); d+30 AUTO (first autologous transplant); d+210 AUTO (second AUTO, exactly on the tandem window's last inside day)
- why it is hard: Planned tandem and unplanned second transplant look identical in claims. The only thing separating them is the gap, and a patient sitting on it goes either way.
- rule: lot/engine/R/steps/05_sct.R | {cfg$sct_tandem_days}

**tandem_beyond** - Second AUTO past the tandem window

- timeline: d+0 MED (1L regimen starts); d+30 AUTO (first autologous transplant); d+211 AUTO (second AUTO, one day past the tandem window)
- why it is hard: The same two claims, one day apart, land in different lines.
- rule: lot/engine/R/steps/05_sct.R | Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1

**auto_window_within** - Two AUTO codes inside the grouping window

- timeline: d+0 MED (1L regimen starts); d+40 AUTO (transplant code); d+53 AUTO (second code, still inside the window)
- why it is hard: A single admission often bills more than one code. The inclusive <= is the part that is easy to get wrong by one day.
- rule: lot/engine/R/steps/05_sct.R | datediff(x, s.cur_start) <= {cfg$sct_auto_window_days}

**auto_window_beyond** - Two AUTO codes past the grouping window

- timeline: d+0 MED (1L regimen starts); d+40 AUTO (transplant code); d+54 AUTO (second code, one day outside)
- why it is hard: The boundary between one billing episode and two transplants.
- rule: lot/engine/R/steps/05_sct.R | datediff(x, s.cur_start) <= {cfg$sct_auto_window_days}

**cart_bridge_within** - CAR-T inside the consolidation window

- timeline: d+0 MED (1L regimen starts); d+60 MED_ADD (bridging agent added, the first day it can be an addition); d+105 CART (CAR-T exactly on the window's last inside day, counted from the addition)
- why it is hard: Bridging therapy is given to hold a patient until CAR-T. Counted as its own line it inflates every downstream line number.
- rule: lot/engine/R/steps/06_lot1_end.R | BETWEEN 0 AND {cfg$cart_consolidation_days}

**cart_bridge_beyond** - CAR-T past the consolidation window

- timeline: d+0 MED (1L regimen starts); d+60 MED_ADD (agent added); d+106 CART (CAR-T on the first day outside the window)
- why it is hard: Whether the added agent reads as bridging or as a new regimen.
- rule: lot/engine/R/steps/06_lot1_end.R | BETWEEN 0 AND {cfg$cart_consolidation_days}

**map_gap_within** - Treatment gap below the discontinuation threshold

- timeline: d+0 MED (1L regimen starts); d+59 MAP_END (last day the agent is covered - the gap starts d60); d+148 MED (same agent resumes, one day inside the threshold measured from MAP_END_DT)
- why it is hard: Prior-authorisation holds and hospitalisations both produce silence in claims. Neither is a clinical decision to stop.
- rule: lot/engine/R/steps/03_mma_map.R | datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}

**map_gap_beyond** - Treatment gap at the discontinuation threshold

- timeline: d+0 MED (1L regimen starts); d+59 MAP_END (last day the agent is covered); d+149 MED (same agent resumes, exactly at the threshold measured from MAP_END_DT)
- why it is hard: The inclusive >= puts the boundary day on the discontinuation side.
- rule: lot/engine/R/steps/03_mma_map.R | datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}

**induction_lot1_within** - Agent added on the last day of LOT1 induction

- timeline: d+0 MED (1L regimen starts); d+59 MED_ADD (agent added on the last day inside the window)
- why it is hard: The -1 is the difference between a regimen of four drugs and one of three.
- rule: lot/engine/R/steps/10_lot2_5_base.R | ELSE {induction_window_days - 1} END)

**induction_lot1_beyond** - Agent added the day after LOT1 induction closes

- timeline: d+0 MED (1L regimen starts); d+60 MED_ADD (agent added one day outside)
- why it is hard: Same claim, one day later, changes what LOT1 is called.
- rule: lot/engine/R/steps/10_lot2_5_base.R | ELSE {induction_window_days - 1} END)

**induction_lotn_within** - Agent added on the last day of a later line's induction

- timeline: d+0 MED (LOT2 starts); d+29 MED_ADD (agent added on the last day inside)
- why it is hard: Two different windows in one algorithm is a standing source of error.
- rule: lot/engine/R/steps/10_lot2_5_base.R | prev_med_window <- if (lot_num == 2L) lot1_induction_window_days

**induction_lotn_beyond** - Agent added the day after a later line's induction closes

- timeline: d+0 MED (LOT2 starts); d+30 MED_ADD (agent added one day outside)
- why it is hard: The later-line window closes sooner than a reader expects.
- rule: lot/engine/R/steps/10_lot2_5_base.R | ELSE {induction_window_days - 1} END)

**allo_single_day** - Allogeneic transplant line spans one day

- timeline: d+0 MED (LOT1 starts); d+200 ALLO (allogeneic transplant); d+201 MED (medication the following day)
- why it is hard: A one-day line with no regimen is the shape that broke the transition Sankeys: they read a blank regimen as no line.
- rule: lot/engine/R/steps/10_lot2_5_base.R | A single_day ALLO LOT ends on the ALLO date itself

**allo_after_failed_auto** - Allogeneic transplant after a failed autologous

- timeline: d+0 MED (1L regimen starts); d+40 AUTO (autologous transplant); d+240 ALLO (allogeneic transplant after relapse)
- why it is hard: Salvage allo after a failed auto is a different clinical event from a planned tandem.
- rule: lot/engine/R/steps/05_sct.R | ALLO

**biosimilar_switch** - Biosimilar substituted mid-line

- timeline: d+0 MED (1L regimen starts with the reference product); d+70 MED (biosimilar of the same agent dispensed instead)
- why it is hard: A substitution the code list does not know about looks like a regimen change, which starts a line that did not happen.
- rule: lot/engine/R/steps/01_codelists.R | materialize(con, "S02_permissible_subs"

**melp_short_course** - Brief melphalan course outside induction

- timeline: d+0 MED (1L regimen starts); d+100 MED (one melphalan administration, no other agent with it); d+127 MAP_END (last day that course covers - exactly the cap, so the course is short)
- why it is hard: A brief melphalan course outside induction is usually transplant conditioning. Counted as an added medication it opens a line of therapy nobody gave.
- rule: lot/engine/R/melp_rule.R | WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 0

**melp_long_course** - Melphalan course past the short cap

- timeline: d+0 MED (1L regimen starts); d+100 MED (melphalan starts); d+128 MAP_END (last day covered - one day past the cap, so the course is not short)
- why it is hard: The cap is what separates conditioning from melphalan given as treatment. Ongoing melphalan is a regimen.
- rule: lot/engine/R/melp_rule.R | datediff(mc.COURSE_END_DT, mc.EXPO_DT) + 1

**melp_short_course_confirmed** - A new agent inside a brief melphalan course

- timeline: d+0 MED (1L regimen starts); d+100 MED (melphalan starts; its cover runs to day 127); d+105 MED (a different line-defining agent starts, inside that cover)
- why it is hard: Dating the line at the later agent would put the boundary after treatment had already moved on, and split the melphalan away from the line it belongs to.
- rule: lot/engine/R/melp_rule.R | WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 1

**melp_confirmed_course_is_one_course** - A confirmed melphalan course given as more than one dose

- timeline: d+0 MED (1L regimen starts); d+90 MED (melphalan, outside 1L's induction window); d+95 MED (a new agent starts inside the course's cover); d+100 ALLO (an allograft); d+110 MED (a second melphalan dose - the same course, inside melp_exposure_days of the first)
- why it is hard: Suppression came off the candidate list at every dose of a course from the start; confirmation stored only the first. A course given as one episode never showed it, because its later doses sat inside the line the boundary opened - until a transplant ended that line first, and a later dose opened one of its own.
- rule: lot/engine/R/melp_rule.R | melp_inject_rest AS (

**melp_course_split_by_a_transplant** - A transplant lands inside a brief melphalan course

- timeline: d+0 MED (1L regimen starts); d+90 MED (melphalan, outside 1L's induction window); d+100 ALLO (an allograft, between the two doses); d+110 MED (a second melphalan dose - same course, it is inside melp_exposure_days of the first)
- why it is hard: The transplant splits one course in two. Judged only against a line it starts inside, the course was dropped by the allograft's line altogether, and the day-110 dose reached the engine as an ordinary added medication and opened a line of its own - which the rule forbids. Refusing it that line without giving it to one leaves the dose in no line at all, so both halves move together.
- rule: lot/engine/R/melp_rule.R | Outside ANY induction window, in the ask

**melp_confirmed_beats_the_fold** - A confirmed melphalan course that is also a returning drug

- timeline: d+0 MED (1L starts on drug A and melphalan); d+200 MED (drug C starts and advances the line to 2L); d+300 MED (melphalan returns for 28 days, outside 2L's window); d+305 MED (a different line-defining agent starts, inside that cover)
- why it is hard: Two adopted rules reach for the same course. 4.7 says a confirmed short course opens the next line on its own first day; 4.8 says a previous line's drug coming back joins the line it returns in. Both cannot hold, and the study team's words settle it - the new line starts when the melphalan appears. 4.8 stands back. Without that, 2L named a drug whose only episode began after 2L had ended, and its end date and reason moved with it.
- rule: lot/engine/R/foldin_rule.R | OR EXISTS (SELECT 1 FROM melp_inject mi

**returning_drug_one_advance** - A drug returns after one advance

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+450 MED (drug B comes back, while 2L is still running)
- why it is hard: A drug the patient has had before is not new treatment. Counted as an addition it opens a line that is really the same one continuing.
- rule: lot/engine/R/foldin_rule.R | N_ADVANCES

**returning_drug_two_advances** - A drug returns after two advances

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C advances the line to 2L); d+300 MED (drug D advances it again, to 3L); d+450 MED (drug B comes back, during 3L)
- why it is hard: The outcome the study team's note describes for two advances, reached by the scope rather than by the count. Scoped to the previous line the count cannot reach two, so this pins the ANSWER the 'two or more' clause gives and not the clause itself - which is unreachable, and said to be so in the rules and the contract.
- rule: lot/engine/R/foldin_rule.R | N_ADVANCES

**returning_drug_two_agents_one_line** - Two drugs start one line while a drug is away

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drugs C and D start together and advance the line to 2L); d+450 MED (drug B comes back, during 2L)
- why it is hard: The request counts agents advancing the line twice or more. Counting each drug that opened a line made a doublet two advances and refused a fold it should take.
- rule: lot/engine/R/foldin_rule.R | foldin_openers

**returning_drug_second_return_across_transplant** - A folded drug returns again, in a line a transplant opened

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C advances the line to 2L); d+300 MED (drug B comes back and folds into 2L); d+500 AUTO (a transplant opens 3L); d+600 MED (drug B comes back AGAIN, during 3L)
- why it is hard: What a fold contributes to a line's working set belongs to the line the fold happened in. Read across the whole history instead, 2L's fold made B 'already here' for 3L too, so the second return could not end 3L, was too late to open 4L, and sat inside a line that named nothing. QC check C5 reads that outcome; it was found on a real patient, because a drawn population does not make this shape.
- rule: lot/engine/R/foldin_rule.R | foldin_base_meds_ctes

**returning_drug_refused_dose_is_an_arrival** - A dose the fold refused is an arrival for the doses after it

- timeline: d+0 MED (1L starts on drug A and drug B); d+170 MED (drug C advances the line to 2L; A and B are dosed in it); d+213 AUTO (a transplant opens 3L; nothing starts in its window); d+294 MED (drugs A and B are dosed again, on the same day); d+322 MED (drug B is dosed once more)
- why it is hard: The ownership test skips fold-set drugs, because under 4.8 they are the line's own. A refused dose of one is not: read for the set instead of for its verdict, it was invisible, and a later dose of the same course folded into the line it had already ended. On an AUTO-started line that named a drug first dosed after the line closed; on an ALLO- or CAR-T-started line it held the single day 4.6 gives open to that dose's cover and swallowed 4L.
- rule: lot/engine/R/foldin_rule.R | foldin_tx_refused

**returning_drug_no_advance** - A drug returns with nothing in between

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+420 MED (drug C stops covering; nothing else is given); d+520 MED (drug C comes back, 100 days later)
- why it is hard: The count is the rule's whole test. At zero it is not that the drug folds - it is that this rule was never asked. Reading a zero as a fold would make 4.8 a restatement of 4.3 and hide which rule owns the answer.
- rule: lot/engine/R/foldin_rule.R | N_ADVANCES = 1

**returning_drug_whole_course** - A returning course folds as one, not episode by episode

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+450 MED (drug B comes back and folds into 2L); d+500 MED (drug B again, 50 days later - no discontinuation ); d+560 MED (and again)
- why it is hard: Asked episode by episode the same course was split between two owners: the first dose folded and the second opened a line, so one continuous course of one drug produced a line boundary in the middle of itself. One course, one answer.
- rule: lot/engine/R/foldin_rule.R | foldin_course

**returning_drug_joins_the_regimen** - A folded drug is in the line's regimen, not only its dates

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+450 MED (drug B comes back, while 2L is still running)
- why it is hard: A fold that moved only the dates left the line refusing B a line of its own while not naming B either - and the next line then refused it too, as a drug of the previous regimen. The treatment sat in a line that did not report it. Span and regimen are two halves of one statement.
- rule: lot/engine/R/foldin_rule.R | foldin_regimen_union

**returning_drug_same_day_new_agent** - A genuinely new drug on the same day takes preference

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+450 MED (drug B returns AND drug D, never seen before, starts)
- why it is hard: The scan is at-or-before the return, not strictly before. Strictly before, it could not see a same-day arrival: B folded into 2L, carrying 2L's end date out to B's cover, while the line D opened named B as well. One dose in two lines, and the previous line's end decided by treatment that belongs to the next one.
- rule: lot/engine/R/foldin_rule.R | o.AT_DT <= k.MAP_START_DT

**returning_drug_own_transplant_no_advance** - A transplant the line already owns advances nothing

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+215 AUTO (a transplant inside 2L's own window); d+450 MED (drug B comes back)
- why it is hard: The override is read off the LINE TABLE, not off the transplant dates, and that is what makes it exact. Read off the dates, every transplant would look like a boundary - including the ones the line it falls in already contains, and including a planned tandem partner (6.3).
- rule: lot/engine/R/foldin_rule.R | foldin_tx_opened

**returning_drug_two_lines_back** - A drug from further back than the previous line is simply new

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+400 MED (drug D starts and advances the line to 3L); d+600 MED (drug B comes back, during 3L)
- why it is hard: The fold set is the IMMEDIATELY previous line's regimen and no further. Widening it is the one change that would make the rule's two-or-more clause reachable, and it is a change to the rule the study team settled, not a detail of how it is measured.
- rule: lot/engine/R/foldin_rule.R | foldin_meds

**returning_drug_same_day_as_the_transplant** - A dose on the transplant's own date is not that line's

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drug C starts and advances the line to 2L); d+300 MED (drug B returns and folds into 2L); d+350 ALLO (an allogeneic transplant opens 3L); d+350 MED (drug B is dosed the same day); d+410 MED (drug B again, 60 days later)
- why it is hard: The override asks for a line opened STRICTLY between a drug's two doses and the arrival scan for a dose STRICTLY after this line's start, so the transplant's own date is outside both. The dose folded, then stood as the PREVIOUS dose for the one after it - which measured its interval from a day the transplant no longer sat inside, and folded too. 3L ran to that course's cover, named B, and swallowed the line B should have opened. The guard is on the regimen, the hold, the working base set and the added-medication test alike, under every span: allo_lot_span sets how long the line runs, not whether it names anything.
- rule: lot/engine/R/foldin_rule.R | foldin_allo_excluded

**maintenance_to_relapse** - Maintenance running into relapse

- timeline: d+0 MED (1L regimen starts); d+120 MED (reduced to a single maintenance agent); d+400 MED (new agents added at relapse)
- why it is hard: This is a deliberate divergence from algorithms that count maintenance separately, and it shifts every later line number by one against them.
- rule: lot/engine/R/steps/05_sct.R | Maintenance is a descriptive flag and nothing more

**steroid_only_interval** - Steroid-only stretch between regimens

- timeline: d+0 MED (1L regimen starts); d+150 STEROID (dexamethasone alone for several weeks); d+220 MED (next regimen begins)
- why it is hard: Steroids accompany almost every MM regimen; counted, they would start lines everywhere.
- rule: lot/engine/R/steps/10_lot2_5_base.R | AND ms.MAP_MED_CLASS <> 'STEROID'

**belantamab_any_line** - Belantamab anywhere in the patient's lines

- timeline: d+0 MED (1L regimen starts); d+300 MED (LOT2 starts); d+500 BELA (belantamab given at LOT3)
- why it is hard: A criterion that removes a patient rather than a line is the one shape that makes two tables hold different PATIENTS.
- rule: lot/engine/R/line_criteria.R | on_fail = "truncate"

**excess_auto** - A third autologous transplant

- timeline: d+0 MED (1L regimen starts); d+30 AUTO (first transplant); d+209 AUTO (tandem partner); d+400 AUTO (third transplant)
- why it is hard: Three transplants is rare enough that the rule is rarely exercised.
- rule: lot/engine/R/steps/05_sct.R | Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1

**overlapping_oral_refills** - Overlapping oral refills

- timeline: d+0 RX (oral agent dispensed, 30-day supply); d+20 RX (refilled early, before the first has run out); d+40 RX (refilled early again)
- why it is hard: Stockpiling is common with oral agents and quietly extends a line.
- rule: lot/engine/R/steps/03_mma_map.R | rx_runout

**line_beyond_max** - A patient who would reach a line above MAX_LOT

- timeline: d+0 MED (1L starts); d+200 MED (a new agent, opening LOT2); d+400 MED (a new agent, opening LOT3); d+600 MED (a new agent, opening LOT4); d+800 MED (a new agent, opening LOT5); d+1000 MED (a new agent, opening LOT6 - above the cap)
- why it is hard: The cap is invisible in the output: a capped patient looks like a completed one.
- rule: lot/engine/R/build_lot.R | check_lot_long

