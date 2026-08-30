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
| `melp_confirmed_beats_the_fold` | A confirmed melphalan course that is also a returning drug | - | A new line on day 300 - the melphalan date - carrying the melphalan and the day-305 agent. 2L keeps its own end and does NOT name melphalan: the course starts a line, so it is not a drug folding back into the line before it. | to_confirm |
| `returning_drug_one_advance` | A drug returns after one advance | - | No new line. One agent advanced the line between B's two doses, so B joins 2L - the line's span carries it, and it joins 2L's regimen string too. | to_confirm |
| `returning_drug_two_advances` | A drug returns after two advances | - | A new line at day 450. Treatment moved on twice while B was away, so B is not returning to the line it left and its return opens one. | to_confirm |
| `returning_drug_two_agents_one_line` | Two drugs start one line while a drug is away | - | No new line. Two agents started 2L, but they advanced the line ONCE between them, so B sees one advance and joins 2L. | to_confirm |
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
- why it is hard: The count is what separates a drug rejoining its own line from one re-introduced after the regimen has changed twice over.
- rule: lot/engine/R/foldin_rule.R | N_ADVANCES

**returning_drug_two_agents_one_line** - Two drugs start one line while a drug is away

- timeline: d+0 MED (1L starts on drug A and drug B); d+200 MED (drugs C and D start together and advance the line to 2L); d+450 MED (drug B comes back, during 2L)
- why it is hard: The request counts agents advancing the line twice or more. Counting each drug that opened a line made a doublet two advances and refused a fold it should take.
- rule: lot/engine/R/foldin_rule.R | foldin_openers

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

