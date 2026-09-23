# Edge-case vignettes for LOT assignment.
#
# A catalogue of the patients the algorithm is hardest on, each with the
# assignment its rules give. It is a specification, not a set of observed
# outputs: a vignette says what the rules say and marks how far that is from
# having been seen.
#
# The days that make a case hard are configured parameters - 180 for a tandem,
# 45 for CAR-T consolidation - so every offset is derived from the parameter
# that decides it and the cases come in pairs straddling it. check_vignettes()
# requires the parameter to exist, the pair to straddle the value, and the two
# sides to disagree.
#
# Two confidence levels:
#
#   derived     follows from the rule quoted at `where`; reading the code is
#               enough to know it.
#   to_confirm  the rules interact and this is our reading. The first real run
#               settles it. A claim about us, not about the algorithm.
#
# `where` is "path | anchor": the file, and a literal that has to appear in it.
# A line number would not survive editing; an anchor moves with the code it
# names, and test_vignettes.R greps for it, so a citation whose rule has gone
# fails rather than misleading a reader.

# The parameters a vignette may hinge on. Named rather than inlined, so a
# renamed setting breaks the catalogue.
VIGNETTE_PARAMS <- c(
  induction_window_days       = "days a med may join LOT1's regimen, inclusive of day 0",
  lot_n_induction_window_days = "the same for LOT2 and later",
  map_discon_gap_days         = "gap after a MAP ends that counts as discontinuation",
  medical_day_supply          = "days a medical-claim administration is assumed to cover",
  sct_auto_window_days        = "days within which AUTO codes group into one transplant",
  sct_auto_gap_days           = "gap below which a later AUTO is not a separate event",
  sct_tandem_days             = "days within which a second AUTO is the tandem of the first",
  cart_consolidation_days     = "days after a med addition within which CAR-T closes the line",
  melp_simple_course_days     = "days of melphalan cover at or under which a course is short",
  max_lot                     = "highest line built")

# One event. `day` is an offset from the 1L start, so a vignette reads as a
# timeline rather than as dates nobody can check.
ev <- function(day, event, detail = "") {
  data.frame(day = as.integer(day), event = event, detail = detail,
             stringsAsFactors = FALSE)
}

# The catalogue. `events` and `expected` are functions of the resolved config,
# so a case is pinned to the rule rather than to a number. `pair` marks the two
# sides of a boundary: "within" is inside the value, "beyond" is the first day
# outside it.
#
# `measure` is the quantity the parameter bounds, read off the events - the
# gap between two transplants, the days from an addition to the CAR-T - and
# `bound` says whether "within" means <= the value ("le") or < it ("lt").
# check_vignettes() holds each pair to the value with these; adjacency and
# ordering alone would pass a pair shifted ten days late, with both sides
# outside.
VIGNETTES <- list(

  # ---- tandem transplant, the idea's first named case ---------------------
  list(id = "tandem_within", title = "Second AUTO inside the tandem window",
       param = "sct_tandem_days", pair = "within", confidence = "to_confirm",
       measure = function(e) diff(e$day[e$event == "AUTO"]), bound = "le",
       where = "lot/engine/R/steps/05_sct.R | {cfg$sct_tandem_days}",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(30,  "AUTO", "first autologous transplant"),
         ev(30 + p$sct_tandem_days, "AUTO",
            "second AUTO, exactly on the tandem window's last inside day")),
       expected = function(p) paste0(
         "The two AUTOs are one tandem pair. A tandem is allowed, so LOT1 is not ",
         "ended by the second one."),
       why = paste0("Planned tandem and unplanned second transplant look identical in ",
                    "claims. The only thing separating them is the ",
                    "gap, and a patient sitting on it goes either way.")),

  list(id = "tandem_beyond", title = "Second AUTO past the tandem window",
       param = "sct_tandem_days", pair = "beyond", confidence = "to_confirm",
       measure = function(e) diff(e$day[e$event == "AUTO"]), bound = "le",
       where = "lot/engine/R/steps/05_sct.R | Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(30,  "AUTO", "first autologous transplant"),
         ev(30 + p$sct_tandem_days + 1L, "AUTO", "second AUTO, one day past the tandem window")),
       expected = function(p) paste0(
         "Not a tandem. The second AUTO is excess, and excess AUTO ends LOT1."),
       why = "The same two claims, one day apart, land in different lines."),

  # ---- AUTO windowing ------------------------------------------------------
  list(id = "auto_window_within", title = "Two AUTO codes inside the grouping window",
       param = "sct_auto_window_days", pair = "within", confidence = "derived",
       measure = function(e) diff(e$day[e$event == "AUTO"]), bound = "le",
       where = "lot/engine/R/steps/05_sct.R | datediff(x, s.cur_start) <= {cfg$sct_auto_window_days}",
       events = function(p) rbind(
         ev(0,  "MED",  "1L regimen starts"),
         ev(40, "AUTO", "transplant code"),
         ev(40 + p$sct_auto_window_days, "AUTO", "second code, still inside the window")),
       expected = function(p) paste0(
         "One transplant, not two. The predicate is <=, so the window is ",
         p$sct_auto_window_days + 1L, " calendar days inclusive of the first."),
       why = paste0("A single admission often bills more than one code. The ",
                    "inclusive <= is the part that is easy to get wrong by one day.")),

  list(id = "auto_window_beyond", title = "Two AUTO codes past the grouping window",
       param = "sct_auto_window_days", pair = "beyond", confidence = "derived",
       measure = function(e) diff(e$day[e$event == "AUTO"]), bound = "le",
       where = "lot/engine/R/steps/05_sct.R | datediff(x, s.cur_start) <= {cfg$sct_auto_window_days}",
       events = function(p) rbind(
         ev(0,  "MED",  "1L regimen starts"),
         ev(40, "AUTO", "transplant code"),
         ev(40 + p$sct_auto_window_days + 1L, "AUTO", "second code, one day outside")),
       expected = function(p) "Two separate AUTO events, subject to the gap and tandem rules.",
       why = "The boundary between one billing episode and two transplants."),

  # ---- CAR-T bridging, the idea's named 45-day case -----------------------
  # The addition sits on induction_window_days, not earlier: a LOT1 MED_ADD is
  # an agent absent from the regimen, and the regimen is exactly the agents
  # whose episode started inside that window, so an agent added inside it is in
  # the regimen and is not an addition at all.
  list(id = "cart_bridge_within", title = "CAR-T inside the consolidation window",
       param = "cart_consolidation_days", pair = "within", confidence = "derived",
       measure = function(e) e$day[e$event == "CART"] - e$day[e$event == "MED_ADD"], bound = "le",
       where = "lot/engine/R/steps/06_lot1_end.R | BETWEEN 0 AND {cfg$cart_consolidation_days}",
       events = function(p) rbind(
         ev(0,  "MED",     "1L regimen starts"),
         ev(p$induction_window_days, "MED_ADD",
            "bridging agent added, the first day it can be an addition"),
         ev(p$induction_window_days + p$cart_consolidation_days, "CART",
            "CAR-T exactly on the window's last inside day, counted from the addition")),
       expected = function(p) paste0(
         "LOT1 ends with reason CART_INIT. The bridging agent stays part of LOT1 ",
         "rather than starting a line of its own."),
       why = paste0("Bridging therapy is given to hold a patient until CAR-T. ",
                    "Counted as its own line it inflates every downstream line number.")),

  list(id = "cart_bridge_beyond", title = "CAR-T past the consolidation window",
       param = "cart_consolidation_days", pair = "beyond", confidence = "to_confirm",
       measure = function(e) e$day[e$event == "CART"] - e$day[e$event == "MED_ADD"], bound = "le",
       where = "lot/engine/R/steps/06_lot1_end.R | BETWEEN 0 AND {cfg$cart_consolidation_days}",
       events = function(p) rbind(
         ev(0,  "MED",     "1L regimen starts"),
         ev(p$induction_window_days, "MED_ADD", "agent added"),
         ev(p$induction_window_days + p$cart_consolidation_days + 1L, "CART",
            "CAR-T on the first day outside the window")),
       expected = function(p) paste0(
         "Not CART_INIT. The addition is an ordinary regimen change and the CAR-T ",
         "is handled by the ordinary rules for a CAR-T event."),
       why = "Whether the added agent reads as bridging or as a new regimen."),

  # ---- administrative gaps, the idea's named case -------------------------
  list(id = "map_gap_within", title = "Treatment gap below the discontinuation threshold",
       param = "map_discon_gap_days", pair = "within", confidence = "derived",
       measure = function(e) e$day[nrow(e)] - e$day[e$event == "MAP_END"], bound = "lt",
       where = "lot/engine/R/steps/03_mma_map.R | datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}",
       events = function(p) rbind(
         ev(0,   "MED", "1L regimen starts"),
         ev(59,  "MAP_END", "last day the agent is covered - the gap starts d60"),
         ev(59 + p$map_discon_gap_days - 1L, "MED",
            "same agent resumes, one day inside the threshold measured from MAP_END_DT")),
       expected = function(p) "No discontinuation. The agent's exposure continues across the gap.",
       why = paste0("Prior-authorisation holds and hospitalisations both produce ",
                    "silence in claims. Neither is a clinical decision to stop.")),

  list(id = "map_gap_beyond", title = "Treatment gap at the discontinuation threshold",
       param = "map_discon_gap_days", pair = "beyond", confidence = "derived",
       measure = function(e) e$day[nrow(e)] - e$day[e$event == "MAP_END"], bound = "lt",
       where = "lot/engine/R/steps/03_mma_map.R | datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}",
       events = function(p) rbind(
         ev(0,  "MED", "1L regimen starts"),
         ev(59, "MAP_END", "last day the agent is covered"),
         ev(59 + p$map_discon_gap_days, "MED",
            "same agent resumes, exactly at the threshold measured from MAP_END_DT")),
       expected = function(p) paste0(
         "Discontinuation. The predicate is >=, so the threshold day itself counts ",
         "as a gap."),
       why = "The inclusive >= puts the boundary day on the discontinuation side."),

  # ---- induction windows ---------------------------------------------------
  list(id = "induction_lot1_within", title = "Agent added on the last day of LOT1 induction",
       param = "induction_window_days", pair = "within", confidence = "derived",
       measure = function(e) e$day[e$event == "MED_ADD"] - e$day[1], bound = "lt",
       where = "lot/engine/R/steps/10_lot2_5_base.R | ELSE {induction_window_days - 1} END)",
       events = function(p) rbind(
         ev(0, "MED", "1L regimen starts"),
         ev(p$induction_window_days - 1L, "MED_ADD", "agent added on the last day inside the window")),
       expected = function(p) paste0(
         "The agent joins LOT1's regimen. The window is day 0 through day ",
         p$induction_window_days - 1L, " - ", p$induction_window_days, " days inclusive."),
       why = "The -1 is the difference between a regimen of four drugs and one of three."),

  list(id = "induction_lot1_beyond", title = "Agent added the day after LOT1 induction closes",
       param = "induction_window_days", pair = "beyond", confidence = "derived",
       measure = function(e) e$day[e$event == "MED_ADD"] - e$day[1], bound = "lt",
       where = "lot/engine/R/steps/10_lot2_5_base.R | ELSE {induction_window_days - 1} END)",
       events = function(p) rbind(
         ev(0, "MED", "1L regimen starts"),
         ev(p$induction_window_days, "MED_ADD", "agent added one day outside")),
       expected = function(p) "Not part of LOT1's regimen. It is an addition, not an induction agent.",
       why = "Same claim, one day later, changes what LOT1 is called."),

  list(id = "induction_lotn_within", title = "Agent added on the last day of a later line's induction",
       param = "lot_n_induction_window_days", pair = "within", confidence = "derived",
       measure = function(e) e$day[e$event == "MED_ADD"] - e$day[1], bound = "lt",
       where = "lot/engine/R/steps/10_lot2_5_base.R | prev_med_window <- if (lot_num == 2L) lot1_induction_window_days",
       events = function(p) rbind(
         ev(0, "MED", "LOT2 starts"),
         ev(p$lot_n_induction_window_days - 1L, "MED_ADD", "agent added on the last day inside")),
       expected = function(p) paste0(
         "Joins LOT2's regimen. Later lines use ", p$lot_n_induction_window_days,
         " days, not LOT1's ", p$induction_window_days, "."),
       why = "Two different windows in one algorithm is a standing source of error."),

  list(id = "induction_lotn_beyond", title = "Agent added the day after a later line's induction closes",
       param = "lot_n_induction_window_days", pair = "beyond", confidence = "derived",
       measure = function(e) e$day[e$event == "MED_ADD"] - e$day[1], bound = "lt",
       where = "lot/engine/R/steps/10_lot2_5_base.R | ELSE {induction_window_days - 1} END)",
       events = function(p) rbind(
         ev(0, "MED", "LOT2 starts"),
         ev(p$lot_n_induction_window_days, "MED_ADD", "agent added one day outside")),
       expected = function(p) "Not part of LOT2's regimen.",
       why = "The later-line window closes sooner than a reader expects."),

  # ---- cases with no boundary, but a rule worth stating -------------------
  list(id = "allo_single_day", title = "Allogeneic transplant line spans one day",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/steps/10_lot2_5_base.R | A single_day ALLO LOT ends on the ALLO date itself",
       events = function(p) rbind(
         ev(0,   "MED",      "LOT1 starts"),
         ev(200, "ALLO",     "allogeneic transplant"),
         ev(201, "MED",      "medication the following day")),
       expected = function(p) paste0(
         "The ALLO line starts and ends on the transplant date. The next day's ",
         "medication starts the line after it. The ALLO line carries NO regimen ",
         "string - induction rows are suppressed for it - which is why anything ",
         "reading LOT_BASE_MEDS to decide a line exists will miss it."),
       why = paste0("A one-day line with no regimen is the shape that broke the ",
                    "transition Sankeys: they read a blank regimen as no line.")),

  list(id = "allo_after_failed_auto", title = "Allogeneic transplant after a failed autologous",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/steps/05_sct.R | ALLO",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(40,  "AUTO", "autologous transplant"),
         ev(240, "ALLO", "allogeneic transplant after relapse")),
       expected = function(p) paste0(
         "The AUTO sits inside LOT1. The ALLO ends the line it falls in and opens ",
         "a one-day SCT_ALLO line."),
       why = "Salvage allo after a failed auto is a different clinical event from a planned tandem."),

  list(id = "biosimilar_switch", title = "Biosimilar substituted mid-line",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/steps/01_codelists.R | materialize(con, \"S02_permissible_subs\"",
       events = function(p) rbind(
         ev(0,  "MED", "1L regimen starts with the reference product"),
         ev(70, "MED", "biosimilar of the same agent dispensed instead")),
       expected = function(p) paste0(
         "No new line. A permissible substitute is the same agent for line ",
         "purposes, and the pair is declared in permissible_subs.csv - so whether ",
         "this holds depends on that file, not on this rule."),
       why = paste0("A substitution the code list does not know about looks like ",
                    "a regimen change, which starts a line that did not happen.")),

  list(id = "melp_short_course", title = "Brief melphalan course outside induction",
       param = "melp_simple_course_days", pair = "within", confidence = "to_confirm",
       measure = function(e) e$day[e$event == "MAP_END"] - e$day[e$event == "MED"][2] + 1L, bound = "le",
       where = "lot/engine/R/melp_rule.R | WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 0",
       events = function(p) rbind(
         ev(0,   "MED", "1L regimen starts"),
         ev(100, "MED", "one melphalan administration, no other agent with it"),
         ev(100 + p$melp_simple_course_days - 1L, "MAP_END",
            "last day that course covers - exactly the cap, so the course is short")),
       expected = function(p) paste0(
         "No new line. The course neither ends line 1 nor starts line 2, and ",
         "line 1 is carried to day ",
         100 + p$melp_simple_course_days - 1L, " - the last day the course ",
         "covers - rather than ending at the melphalan date."),
       why = paste0("A brief melphalan course outside induction is usually ",
                    "transplant conditioning. Counted as an added medication it ",
                    "opens a line of therapy nobody gave.")),

  list(id = "melp_long_course", title = "Melphalan course past the short cap",
       param = "melp_simple_course_days", pair = "beyond", confidence = "to_confirm",
       measure = function(e) e$day[e$event == "MAP_END"] - e$day[e$event == "MED"][2] + 1L, bound = "le",
       where = "lot/engine/R/melp_rule.R | datediff(mc.COURSE_END_DT, mc.EXPO_DT) + 1",
       events = function(p) rbind(
         ev(0,   "MED", "1L regimen starts"),
         ev(100, "MED", "melphalan starts"),
         ev(100 + p$melp_simple_course_days, "MAP_END",
            "last day covered - one day past the cap, so the course is not short")),
       expected = function(p) paste0(
         "A new line at day 100. Past the cap the rule stands aside and ",
         "melphalan is an added medication like any other agent."),
       why = paste0("The cap is what separates conditioning from melphalan ",
                    "given as treatment. Ongoing melphalan is a regimen.")),

  list(id = "melp_short_course_confirmed", title = "A new agent inside a brief melphalan course",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/melp_rule.R | WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 1",
       events = function(p) rbind(
         ev(0,   "MED", "1L regimen starts"),
         ev(100, "MED", "melphalan starts; its cover runs to day 127"),
         ev(105, "MED", "a different line-defining agent starts, inside that cover")),
       expected = function(p) paste0(
         "A new line, and it starts on day 100 - the melphalan date - not on ",
         "day 105. The agent inside the course is what tells us treatment ",
         "changed; the melphalan is where it changed."),
       why = paste0("Dating the line at the later agent would put the boundary ",
                    "after treatment had already moved on, and split the ",
                    "melphalan away from the line it belongs to.")),

  list(id = "melp_confirmed_course_is_one_course",
       title = "A confirmed melphalan course given as more than one dose",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/melp_rule.R | melp_inject_rest AS (",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(90,  "MED",  "melphalan, outside 1L's induction window"),
         ev(95,  "MED",  "a new agent starts inside the course's cover"),
         ev(100, "ALLO", "an allograft"),
         ev(110, "MED",  paste0("a second melphalan dose - the same course, ",
                                "inside melp_exposure_days of the first"))),
       expected = function(p) paste0(
         "The course is confirmed, so it opens a line on day 90 - the ",
         "melphalan date. Its day-110 dose opens nothing: only the first day ",
         "of a course is a boundary. The allograft's line is carried to day ",
         "110 and owns it."),
       why = paste0("Suppression came off the candidate list at every dose ",
                    "of a course from the start; confirmation stored only ",
                    "the first. A course given as one episode never showed ",
                    "it, because its later doses sat inside the line the ",
                    "boundary opened - until a transplant ended that line ",
                    "first, and a later dose opened one of its own.")),

  list(id = "melp_course_split_by_a_transplant",
       title = "A transplant lands inside a brief melphalan course",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/melp_rule.R | Outside ANY induction window, in the ask",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(90,  "MED",  "melphalan, outside 1L's induction window"),
         ev(100, "ALLO", "an allograft, between the two doses"),
         ev(110, "MED",  paste0("a second melphalan dose - same course, it is ",
                                "inside melp_exposure_days of the first"))),
       expected = function(p) paste0(
         "No line starts on either dose. The course covers 21 days, which is ",
         "under the cap, and it began outside any induction window - so it ",
         "does not advance the line, wherever the transplant sits. The day-90 ",
         "dose stays in 1L; the allograft's own line is carried to day 110 and ",
         "owns the second."),
       why = paste0("The transplant splits one course in two. Judged only ",
                    "against a line it starts inside, the course was dropped ",
                    "by the allograft's line altogether, and the day-110 dose ",
                    "reached the engine as an ordinary added medication and ",
                    "opened a line of its own - which the rule forbids. ",
                    "Refusing it that line without giving it to one leaves ",
                    "the dose in no line at all, so both halves move ",
                    "together.")),

  list(id = "melp_confirmed_beats_the_fold",
       title = "A confirmed melphalan course that is also a returning drug",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/foldin_rule.R | OR EXISTS (SELECT 1 FROM melp_inject mi",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and melphalan"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(300, "MED", "melphalan returns for 28 days, outside 2L's window"),
         ev(305, "MED", "a different line-defining agent starts, inside that cover")),
       expected = function(p) paste0(
         "A new line on day 300 - the melphalan date - carrying the melphalan ",
         "and the day-305 agent. 2L keeps its own end and does NOT name ",
         "melphalan: the course starts a line, so it is not a drug folding ",
         "back into the line before it."),
       why = paste0("Two adopted rules reach for the same course. 4.7 says a ",
                    "confirmed short course opens the next line on its own ",
                    "first day; 4.8 says a previous line's drug coming back ",
                    "joins the line it returns in. Both cannot hold, and the ",
                    "study team's words settle it - the new line starts when ",
                    "the melphalan appears. 4.8 stands back. Without that, 2L ",
                    "named a drug whose only episode began after 2L had ",
                    "ended, and its end date and reason moved with it.")),

  list(id = "returning_drug_one_advance", title = "A drug returns after one advance",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/foldin_rule.R | N_ADVANCES",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(450, "MED", "drug B comes back, while 2L is still running")),
       expected = function(p) paste0(
         "No new line. One agent advanced the line between B's two doses, so B ",
         "joins 2L - the line's span carries it, and it joins 2L's regimen ",
         "string too."),
       why = paste0("A drug the patient has had before is not new treatment. ",
                    "Counted as an addition it opens a line that is really the ",
                    "same one continuing.")),

  list(id = "returning_drug_two_advances", title = "A drug returns after two advances",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/foldin_rule.R | N_ADVANCES",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C advances the line to 2L"),
         ev(300, "MED", "drug D advances it again, to 3L"),
         ev(450, "MED", "drug B comes back, during 3L")),
       expected = function(p) paste0(
         "A new line at day 450. B is a 1L drug and the fold set is the ",
         "IMMEDIATELY previous line's regimen, so B is not in it at all - the ",
         "count is never asked, and B opens a line as any other agent would."),
       why = paste0("The outcome the study team's note describes for two ",
                    "advances, reached by the scope rather than by the count. ",
                    "Scoped to the previous line the count cannot reach two, ",
                    "so this pins the ANSWER the 'two or more' clause gives ",
                    "and not the clause itself - which is unreachable, and ",
                    "said to be so in the rules and the contract.")),

  list(id = "returning_drug_two_agents_one_line",
       title = "Two drugs start one line while a drug is away",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/foldin_rule.R | foldin_openers",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drugs C and D start together and advance the line to 2L"),
         ev(450, "MED", "drug B comes back, during 2L")),
       expected = function(p) paste0(
         "No new line. Two agents started 2L, but they advanced the line ONCE ",
         "between them, so B sees one advance and joins 2L."),
       why = paste0("The request counts agents advancing the line twice or ",
                    "more. Counting each drug that opened a line made a ",
                    "doublet two advances and refused a fold it should take.")),

  list(id = "returning_drug_second_return_across_transplant",
       title = "A folded drug returns again, in a line a transplant opened",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_base_meds_ctes",
       events = function(p) rbind(
         ev(0,   "MED",  "1L starts on drug A and drug B"),
         ev(200, "MED",  "drug C advances the line to 2L"),
         ev(300, "MED",  "drug B comes back and folds into 2L"),
         ev(500, "AUTO", "a transplant opens 3L"),
         ev(600, "MED",  "drug B comes back AGAIN, during 3L")),
       expected = function(p) paste0(
         "A new line on day 600. A transplant opened 3L, so 4.8 refuses the ",
         "second fold and B is line-defining again - 3L ends the day before ",
         "it, and B opens 4L on its own date. The fold into 2L does not make ",
         "B a drug 3L already had."),
       why = paste0("What a fold contributes to a line's working set belongs ",
                    "to the line the fold happened in. Read across the whole ",
                    "history instead, 2L's fold made B 'already here' for 3L ",
                    "too, so the second return could not end 3L, was too late ",
                    "to open 4L, and sat inside a line that named nothing. QC ",
                    "check C5 reads that outcome; it was found on a real ",
                    "patient, because a drawn population does not make this ",
                    "shape.")),

  list(id = "returning_drug_refused_dose_is_an_arrival",
       title = "A dose the fold refused is an arrival for the doses after it",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_tx_refused",
       events = function(p) rbind(
         ev(0,   "MED",  "1L starts on drug A and drug B"),
         ev(170, "MED",  "drug C advances the line to 2L; A and B are dosed in it"),
         ev(213, "AUTO", "a transplant opens 3L; nothing starts in its window"),
         ev(294, "MED",  "drugs A and B are dosed again, on the same day"),
         ev(322, "MED",  "drug B is dosed once more")),
       expected = function(p) paste0(
         "3L carries no regimen and ends the day before day 294, and 4L opens ",
         "there on A and B. The day-294 doses have the transplant between them ",
         "and the previous dose, so 4.8 refuses both folds; A's refused dose ",
         "is what ends 3L. B's day-322 dose has only day 294 before it, no ",
         "transplant between, and would fold into 3L - but a refused dose is ",
         "line-defining for what follows it, so day 322 belongs to 4L."),
       why = paste0("The ownership test skips fold-set drugs, because under ",
                    "4.8 they are the line's own. A refused dose of one is ",
                    "not: read for the set instead of for its verdict, it was ",
                    "invisible, and a later dose of the same course folded ",
                    "into the line it had already ended. On an AUTO-started ",
                    "line that named a drug first dosed after the line closed; ",
                    "on an ALLO- or CAR-T-started line it held the single day ",
                    "4.6 gives open to that dose's cover and swallowed 4L.")),

  # ---- 4.8's other branches, one case each --------------------------------
  # The rule has four questions - how many agents advanced the line, whether a
  # transplant did, whether the return is in THIS line, and whether the course
  # travels with it - and a reader needs to see each answered on a patient.

  list(id = "returning_drug_no_advance",
       title = "A drug returns with nothing in between",
       param = "map_discon_gap_days", confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | N_ADVANCES = 1",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(420, "MED", "drug C stops covering; nothing else is given"),
         ev(520, "MED", "drug C comes back, 100 days later")),
       expected = function(p) paste0(
         "2L continues. The 100-day gap is past the ", p$map_discon_gap_days,
         "-day discontinuation, so this is a return and not a refill - but ",
         "nothing advanced the line between C's two doses, so ",
         "4.8 has nothing to decide and 4.3 answers instead: a drug restarting ",
         "in the line it left stays in it, whatever the gap."),
       why = paste0("The count is the rule's whole test. At zero it is not ",
                    "that the drug folds - it is that this rule was never ",
                    "asked. Reading a zero as a fold would make 4.8 a ",
                    "restatement of 4.3 and hide which rule owns the answer.")),

  list(id = "returning_drug_whole_course",
       title = "A returning course folds as one, not episode by episode",
       param = "map_discon_gap_days", confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_course",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(450, "MED", "drug B comes back and folds into 2L"),
         ev(500, "MED", "drug B again, 50 days later - no discontinuation "),
         ev(560, "MED", "and again")),
       expected = function(p) paste0(
         "One line. All three of B's doses are one course - the gaps are ",
         "shorter than the ", p$map_discon_gap_days, "-day discontinuation - ",
         "and the course folds as a unit, so no line opens on the follow-ups ",
         "and 2L runs to the last day B covers."),
       why = paste0("Asked episode by episode the same course was split ",
                    "between two owners: the first dose folded and the second ",
                    "opened a line, so one continuous course of one drug ",
                    "produced a line boundary in the middle of itself. One ",
                    "course, one answer.")),

  list(id = "returning_drug_joins_the_regimen",
       title = "A folded drug is in the line's regimen, not only its dates",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_regimen_union",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(450, "MED", "drug B comes back, while 2L is still running")),
       expected = function(p) paste0(
         "2L reports TWO drugs, C and B, and its medication count is two. B ",
         "joins the line's run-out chain as well, so the line cannot end ",
         "before B stops covering - it ends on the LAST of the base set's ",
         "cover, which is B's only where B outlasts C. A drug the rule says ",
         "is part of the line has to be part of it in every reading of the ",
         "line, and the run-out is one of those readings."),
       why = paste0("A fold that moved only the dates left the line refusing ",
                    "B a line of its own while not naming B either - and the ",
                    "next line then refused it too, as a drug of the previous ",
                    "regimen. The treatment sat in a line that did not report ",
                    "it. Span and regimen are two halves of one statement.")),

  list(id = "returning_drug_same_day_new_agent",
       title = "A genuinely new drug on the same day takes preference",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | o.AT_DT <= k.MAP_START_DT",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(450, "MED", "drug B returns AND drug D, never seen before, starts")),
       expected = function(p) paste0(
         "3L opens on day 450 on D, and B belongs to it rather than to 2L. 2L ",
         "ends where its OWN cover ran out - wherever C's supply put that, ",
         "which on these events is before day 450 and is not day 449. It ends ",
         "exactly where it would have ended had B not come back at all, which ",
         "is the whole of the claim: the return moved nothing."),
       why = paste0("The scan is at-or-before the return, not strictly ",
                    "before. Strictly before, it could not see a same-day ",
                    "arrival: B folded into 2L, carrying 2L's end date out to ",
                    "B's cover, while the line D opened named B as well. One ",
                    "dose in two lines, and the previous line's end decided by ",
                    "treatment that belongs to the next one.")),

  list(id = "returning_drug_own_transplant_no_advance",
       title = "A transplant the line already owns advances nothing",
       param = "lot_n_induction_window_days", confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_tx_opened",
       events = function(p) rbind(
         ev(0,   "MED",  "1L starts on drug A and drug B"),
         ev(200, "MED",  "drug C starts and advances the line to 2L"),
         ev(215, "AUTO", "a transplant inside 2L's own window"),
         ev(450, "MED",  "drug B comes back")),
       expected = function(p) paste0(
         "B folds into 2L as it would with no transplant at all. The ",
         "transplant on day 215 is 15 days into 2L, inside its ",
         p$lot_n_induction_window_days, "-day window, so 6.5 gives ",
         "it to that line: it opened nothing, and a transplant that opened no ",
         "line is not a boundary for this rule."),
       why = paste0("The override is read off the LINE TABLE, not off the ",
                    "transplant dates, and that is what makes it exact. Read ",
                    "off the dates, every transplant would look like a ",
                    "boundary - including the ones the line it falls in ",
                    "already contains, and including a planned tandem ",
                    "partner (6.3).")),

  list(id = "returning_drug_two_lines_back",
       title = "A drug from further back than the previous line is simply new",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_meds",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C starts and advances the line to 2L"),
         ev(400, "MED", "drug D starts and advances the line to 3L"),
         ev(600, "MED", "drug B comes back, during 3L")),
       expected = function(p) paste0(
         "4L opens on day 600. B was 1L's drug and the line before this one ",
         "is 2L, so B is outside the fold set entirely and the engine's ",
         "ordinary rules keep it: an agent not in the current regimen is an ",
         "added medication."),
       why = paste0("The fold set is the IMMEDIATELY previous line's regimen ",
                    "and no further. Widening it is the one change that would ",
                    "make the rule's two-or-more clause reachable, and it is ",
                    "a change to the rule the study team settled, not a ",
                    "detail of how it is measured.")),

  list(id = "returning_drug_same_day_as_the_transplant",
       title = "A dose on the transplant's own date is not that line's",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/foldin_rule.R | foldin_allo_excluded",
       events = function(p) rbind(
         ev(0,   "MED",  "1L starts on drug A and drug B"),
         ev(200, "MED",  "drug C starts and advances the line to 2L"),
         ev(300, "MED",  "drug B returns and folds into 2L"),
         ev(350, "ALLO", "an allogeneic transplant opens 3L"),
         ev(350, "MED",  "drug B is dosed the same day"),
         ev(410, "MED",  "drug B again, 60 days later")),
       expected = function(p) paste0(
         "3L keeps the one day and the empty regimen 4.6 gives it, and 4L ",
         "opens on day 410 on B. The day-350 dose is not 3L's: an allogeneic ",
         "line takes no regimen, so nothing folds into one."),
       why = paste0("The override asks for a line opened STRICTLY between a ",
                    "drug's two doses and the arrival scan for a dose STRICTLY ",
                    "after this line's start, so the transplant's own date is ",
                    "outside both. The dose folded, then stood as the PREVIOUS ",
                    "dose for the one after it - which measured its interval ",
                    "from a day the transplant no longer sat inside, and ",
                    "folded too. 3L ran to that course's cover, named B, and ",
                    "swallowed the line B should have opened. The guard is on ",
                    "the regimen, the hold, the working base set and the ",
                    "added-medication test alike, under every span: ",
                    "allo_lot_span sets how long the line runs, not whether ",
                    "it names anything.")),

  list(id = "maintenance_to_relapse", title = "Maintenance running into relapse",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/steps/05_sct.R | Maintenance is a descriptive flag and nothing more",
       events = function(p) rbind(
         ev(0,   "MED", "1L regimen starts"),
         ev(120, "MED", "reduced to a single maintenance agent"),
         ev(400, "MED", "new agents added at relapse")),
       expected = function(p) paste0(
         "Maintenance is NOT a line of its own here - contains_mtx_reg is a flag ",
         "and there is no maintenance period. The relapse is handled by the ",
         "ordinary rules, so the line count does not include a maintenance line."),
       why = paste0("This is a deliberate divergence from algorithms that count ",
                    "maintenance separately, and it shifts every later line number ",
                    "by one against them.")),

  list(id = "steroid_only_interval", title = "Steroid-only stretch between regimens",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/steps/10_lot2_5_base.R | AND ms.MAP_MED_CLASS <> 'STEROID'",
       events = function(p) rbind(
         ev(0,   "MED",     "1L regimen starts"),
         ev(150, "STEROID", "dexamethasone alone for several weeks"),
         ev(220, "MED",     "next regimen begins")),
       expected = function(p) "The steroid stretch neither starts nor continues a line.",
       why = "Steroids accompany almost every MM regimen; counted, they would start lines everywhere."),

  list(id = "belantamab_any_line", title = "Belantamab anywhere in the patient's lines",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/line_criteria.R | on_fail = \"truncate\"",
       events = function(p) rbind(
         ev(0,   "MED", "1L regimen starts"),
         ev(300, "MED", "LOT2 starts"),
         ev(500, "BELA", "belantamab given at LOT3")),
       expected = function(p) paste0(
         "The criterion is patient-level, so the patient loses EVERY line, not ",
         "just LOT3 onward. They are absent from LOT_LONG_FINAL entirely and ",
         "present in LOT_LONG."),
       why = paste0("A criterion that removes a patient rather than a line is the ",
                    "one shape that makes two tables hold different PATIENTS.")),

  list(id = "excess_auto", title = "A third autologous transplant",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/steps/05_sct.R | Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(30,  "AUTO", "first transplant"),
         ev(30 + p$sct_tandem_days - 1L, "AUTO", "tandem partner"),
         ev(400, "AUTO", "third transplant")),
       expected = function(p) "The first two are a tandem inside LOT1; the third is excess and ends LOT1.",
       why = "Three transplants is rare enough that the rule is rarely exercised."),

  list(id = "overlapping_oral_refills", title = "Overlapping oral refills",
       param = "medical_day_supply", confidence = "to_confirm",
       where = "lot/engine/R/steps/03_mma_map.R | rx_runout",
       events = function(p) rbind(
         ev(0,  "RX", "oral agent dispensed, 30-day supply"),
         ev(20, "RX", "refilled early, before the first has run out"),
         ev(40, "RX", "refilled early again")),
       expected = function(p) paste0(
         "Exposure runs to the accumulated run-out, not to the last fill date plus ",
         "one supply. Early refills push the end of the MAP later, which moves the ",
         "gap that would otherwise end the line. A medical-claim administration is ",
         "assumed to cover ", p$medical_day_supply, " days."),
       why = "Stockpiling is common with oral agents and quietly extends a line."),

  list(id = "line_beyond_max", title = "A patient who would reach a line above MAX_LOT",
       param = "max_lot", confidence = "derived",
       where = "lot/engine/R/build_lot.R | check_lot_long",
       # One regimen change per line, so the timeline actually reaches the cap
       # rather than asserting it. Two events could only ever demonstrate LOT2.
       events = function(p) do.call(rbind, c(
         list(ev(0, "MED", "1L starts")),
         lapply(seq_len(p$max_lot), function(k)
           ev(200 * k, "MED", paste0("a new agent, opening LOT", k + 1L,
                                     if (k == p$max_lot) " - above the cap" else ""))))),
       expected = function(p) paste0(
         "No line above ", p$max_lot, " is built. The patient's later therapy is ",
         "not represented, so a count of lines is a count of lines BUILT, not of ",
         "lines received."),
       why = "The cap is invisible in the output: a capped patient looks like a completed one.")
)

# Resolve every vignette against the run's parameters.
render_vignettes <- function(p, v = VIGNETTES) {
  do.call(rbind, lapply(v, function(x) {
    e <- x$events(p)
    data.frame(
      id         = x$id,
      title      = x$title,
      parameter  = if (is.na(x$param)) "" else
                     paste0(x$param, " = ", p[[x$param]]),
      pair       = if (is.null(x$pair)) "" else x$pair,
      confidence = x$confidence,
      timeline   = paste(sprintf("d%+d %s%s", e$day, e$event,
                                 ifelse(nzchar(e$detail),
                                        paste0(" (", e$detail, ")"), "")),
                         collapse = "; "),
      expected   = x$expected(p),
      why_hard   = x$why,
      rule_at    = x$where,
      stringsAsFactors = FALSE)
  }))
}

# The catalogue held to its own claims. No warehouse: every one of these is a
# property of the registry and the configured parameters.
check_vignettes <- function(p, v = VIGNETTES) {
  bad <- character(0)
  ids <- vapply(v, function(x) x$id, character(1))
  if (anyDuplicated(ids))
    bad <- c(bad, paste0("duplicate id: ", paste(unique(ids[duplicated(ids)]), collapse = ", ")))

  # A vignette whose parameter is unusable is recorded and then left alone.
  # Its events() compute their offsets from that parameter, so an unset one
  # gives a day of NA and the pair comparison below raises "missing value where
  # TRUE/FALSE needed" instead of naming the rule that stopped holding.
  usable <- rep(TRUE, length(v))
  for (i in seq_along(v)) {
    x  <- v[[i]]
    at <- paste0("'", x$id, "'")
    if (!x$confidence %in% c("derived", "to_confirm"))
      bad <- c(bad, paste0(at, ": confidence '", x$confidence, "' is not one of derived/to_confirm"))
    # A renamed parameter must break this, not silently describe a rule that
    # no longer exists.
    if (!is.na(x$param)) {
      if (!x$param %in% names(VIGNETTE_PARAMS)) {
        bad <- c(bad, paste0(at, ": names parameter '", x$param, "', which is not one this catalogue knows"))
        usable[i] <- FALSE
      } else if (is.null(p[[x$param]]) || is.na(p[[x$param]])) {
        bad <- c(bad, paste0(at, ": parameter '", x$param, "' is not set in this run's config"))
        usable[i] <- FALSE
      }
    }
    # Redundant with the anyNA() branch below, which catches the same timeline.
    # It stays because events() is a function the catalogue supplies, and
    # running one against a parameter already known to be unusable invites
    # whatever error it happens to raise rather than this function's own.
    if (!usable[i]) next
    e <- tryCatch(x$events(p), error = function(err) NULL)
    if (is.null(e) || !nrow(e)) {
      bad <- c(bad, paste0(at, ": events() produced nothing"))
      usable[i] <- FALSE
    } else if (anyNA(e$day)) {
      # A vignette can hinge on a setting it does not name in `param` - the
      # excess-AUTO case reads the tandem window without being about it - so
      # an unset setting reaches the timeline through a case the parameter
      # check above has nothing to say about. Named for what it is.
      bad <- c(bad, paste0(at, ": events() produced a day that is not a number, ",
                           "so a setting its timeline reads is unset"))
      usable[i] <- FALSE
    } else if (is.unsorted(e$day)) {
      bad <- c(bad, paste0(at, ": events are not in time order"))
    }
  }

  # Each pair straddles its parameter, and the two sides disagree. This is what
  # makes the catalogue move when a setting does.
  # Only the vignettes that resolved. Pairing one whose timeline could not be
  # computed is what turned a reportable problem into a crash.
  paired <- Filter(function(x) !is.null(x$pair), v[usable])
  by_param <- split(paired, vapply(paired, function(x) x$param, character(1)))
  for (nm in names(by_param)) {
    grp   <- by_param[[nm]]
    sides <- vapply(grp, function(x) x$pair, character(1))
    if (!setequal(sides, c("within", "beyond"))) {
      bad <- c(bad, paste0("parameter '", nm, "' has sides ",
                           paste(sides, collapse = "/"), "; a boundary needs both"))
      next
    }
    w <- grp[[match("within", sides)]]; b <- grp[[match("beyond", sides)]]
    dw <- max(w$events(p)$day); db <- max(b$events(p)$day)
    if (!(db > dw))
      bad <- c(bad, paste0("parameter '", nm, "': the 'beyond' case (d", db,
                           ") is not later than the 'within' case (d", dw, ")"))
    # Later is not enough. A pair that straddles the value from two days out
    # tests that the rule exists, not where its edge is, so the two sides must
    # be adjacent: 'within' the last day inside, 'beyond' the first day
    # outside.
    if (db > dw && db - dw != 1L)
      bad <- c(bad, paste0("parameter '", nm, "': the two sides are ", db - dw,
                           " days apart (d", dw, " and d", db, "), so neither is ",
                           "pinned to the boundary. They must be consecutive days"))
    if (identical(w$expected(p), b$expected(p)))
      bad <- c(bad, paste0("parameter '", nm, "': both sides expect the same thing, ",
                           "so the boundary is not being tested"))
    # And against the value. Adjacent, ordered and disagreeing is the shape of
    # a boundary, not the boundary: the measured quantity has to fall inside
    # the setting on one side and outside it on the other.
    if (is.null(w$measure) || is.null(b$measure)) {
      bad <- c(bad, paste0("parameter '", nm, "': its pair declares no measure, so ",
                           "nothing holds it to the value"))
    } else {
      val <- p[[nm]]
      mw <- tryCatch(as.numeric(w$measure(w$events(p)))[1], error = function(e) NA_real_)
      mb <- tryCatch(as.numeric(b$measure(b$events(p)))[1], error = function(e) NA_real_)
      le <- !identical(w$bound %||% "le", "lt")
      if (!isTRUE(if (le) mw <= val else mw < val))
        bad <- c(bad, paste0("parameter '", nm, "': the 'within' case measures ", mw,
                             " against a value of ", val, ", so it is not inside"))
      if (!isTRUE(if (le) mb > val else mb >= val))
        bad <- c(bad, paste0("parameter '", nm, "': the 'beyond' case measures ", mb,
                             " against a value of ", val, ", so it is not outside"))
    }
  }
  if (length(bad))
    stop("The vignette catalogue does not hold:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
