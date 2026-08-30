# Edge-case vignettes for LOT assignment.
#
# A catalogue of the patients the algorithm is hardest on, each with the
# assignment its rules give. It is a SPECIFICATION, not a set of observed
# outputs: nothing here has been run against a warehouse, so a vignette says
# what the rules say and marks how far that is from having been seen.
#
# The days that make a case hard are the configured parameters - 180 for a
# tandem, 45 for CAR-T consolidation. A document quoting "day 181" is wrong the
# moment one of them moves, and nothing says so.
#
# So every offset is DERIVED from the parameter that decides it, and the cases
# come in pairs straddling it. check_vignettes() holds the catalogue to that:
# the parameter has to exist, the pair has to straddle the value, and the two
# sides have to disagree.
#
# Two confidence levels:
#
#   derived     follows from the rule quoted at `where`; reading the code is
#               enough to know it.
#   to_confirm  the rules interact and this is our reading. The first real run
#               settles it. A claim about us, not about the algorithm.

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
VIGNETTES <- list(

  # ---- tandem transplant, the idea's first named case ---------------------
  list(id = "tandem_within", title = "Second AUTO inside the tandem window",
       param = "sct_tandem_days", pair = "within", confidence = "to_confirm",
       where = "lot/engine/R/steps/05_sct.R - 14-day window grouping + 60-day gap + 180-day tandem",
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
       where = "lot/engine/R/steps/05_sct.R - single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1",
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
       where = "lot/engine/R/steps/05_sct.R:323 - datediff(x, cur_start) <= sct_auto_window_days",
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
       where = "lot/engine/R/steps/05_sct.R:323",
       events = function(p) rbind(
         ev(0,  "MED",  "1L regimen starts"),
         ev(40, "AUTO", "transplant code"),
         ev(40 + p$sct_auto_window_days + 1L, "AUTO", "second code, one day outside")),
       expected = function(p) "Two separate AUTO events, subject to the gap and tandem rules.",
       why = "The boundary between one billing episode and two transplants."),

  # ---- CAR-T bridging, the idea's named 45-day case -----------------------
  # The addition sits on induction_window_days, not earlier: a LOT1 MED_ADD is
  # an agent absent from the regimen, and the regimen is exactly the agents whose
  # episode started inside that window - so an agent added inside it is in the
  # regimen and is not an addition at all. Both cases carried an addition on d20,
  # which the engine cannot produce.
  list(id = "cart_bridge_within", title = "CAR-T inside the consolidation window",
       param = "cart_consolidation_days", pair = "within", confidence = "derived",
       where = "lot/engine/R/steps/06_lot1_end.R:176 - datediff BETWEEN 0 AND cart_consolidation_days",
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
       where = "lot/engine/R/steps/06_lot1_end.R:176",
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
       where = "lot/engine/R/steps/03_mma_map.R:396 - datediff(next_start, map_end) >= map_discon_gap_days",
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
       where = "lot/engine/R/steps/03_mma_map.R:396",
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
       where = "lot/engine/R/steps/10_lot2_5_base.R:362 - MAP_START <= date_add(LOT_START, window - 1)",
       events = function(p) rbind(
         ev(0, "MED", "1L regimen starts"),
         ev(p$induction_window_days - 1L, "MED_ADD", "agent added on the last day inside the window")),
       expected = function(p) paste0(
         "The agent joins LOT1's regimen. The window is day 0 through day ",
         p$induction_window_days - 1L, " - ", p$induction_window_days, " days inclusive."),
       why = "The -1 is the difference between a regimen of four drugs and one of three."),

  list(id = "induction_lot1_beyond", title = "Agent added the day after LOT1 induction closes",
       param = "induction_window_days", pair = "beyond", confidence = "derived",
       where = "lot/engine/R/steps/10_lot2_5_base.R:362",
       events = function(p) rbind(
         ev(0, "MED", "1L regimen starts"),
         ev(p$induction_window_days, "MED_ADD", "agent added one day outside")),
       expected = function(p) "Not part of LOT1's regimen. It is an addition, not an induction agent.",
       why = "Same claim, one day later, changes what LOT1 is called."),

  list(id = "induction_lotn_within", title = "Agent added on the last day of a later line's induction",
       param = "lot_n_induction_window_days", pair = "within", confidence = "derived",
       where = "lot/engine/R/steps/10_lot2_5_base.R:362 - LOT2+ uses the shorter window",
       events = function(p) rbind(
         ev(0, "MED", "LOT2 starts"),
         ev(p$lot_n_induction_window_days - 1L, "MED_ADD", "agent added on the last day inside")),
       expected = function(p) paste0(
         "Joins LOT2's regimen. Later lines use ", p$lot_n_induction_window_days,
         " days, not LOT1's ", p$induction_window_days, "."),
       why = "Two different windows in one algorithm is a standing source of error."),

  list(id = "induction_lotn_beyond", title = "Agent added the day after a later line's induction closes",
       param = "lot_n_induction_window_days", pair = "beyond", confidence = "derived",
       where = "lot/engine/R/steps/10_lot2_5_base.R:362",
       events = function(p) rbind(
         ev(0, "MED", "LOT2 starts"),
         ev(p$lot_n_induction_window_days, "MED_ADD", "agent added one day outside")),
       expected = function(p) "Not part of LOT2's regimen.",
       why = "The later-line window closes sooner than a reader expects."),

  # ---- cases with no boundary, but a rule worth stating -------------------
  list(id = "allo_single_day", title = "Allogeneic transplant line spans one day",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/steps/10_lot2_5_base.R:681 - allo_lot_span single_day",
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
       where = "lot/engine/R/steps/05_sct.R - ALLO immediately ends LOT1",
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
       where = "lot/engine/R/steps/01_codelists.R:66 - permissible_subs",
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
       where = "lot/engine/R/melp_rule.R:469 - melp_suppress, SHORT = 1 AND CONFIRMED = 0",
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
       where = "lot/engine/R/melp_rule.R:454 - datediff(COURSE_END_DT, EXPO_DT) + 1 <= cap",
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
       where = "lot/engine/R/melp_rule.R:485 - melp_inject, CONFIRMED = 1, at EXPO_DT",
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

  list(id = "returning_drug_one_advance", title = "A drug returns after one advance",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/foldin_rule.R - foldin_episodes, N_ADVANCES = 1",
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
       where = "lot/engine/R/foldin_rule.R - foldin_episodes, N_ADVANCES = 1",
       events = function(p) rbind(
         ev(0,   "MED", "1L starts on drug A and drug B"),
         ev(200, "MED", "drug C advances the line to 2L"),
         ev(300, "MED", "drug D advances it again, to 3L"),
         ev(450, "MED", "drug B comes back, during 3L")),
       expected = function(p) paste0(
         "A new line at day 450. Treatment moved on twice while B was away, so ",
         "B is not returning to the line it left and its return opens one."),
       why = paste0("The count is what separates a drug rejoining its own line ",
                    "from one re-introduced after the regimen has changed ",
                    "twice over.")),

  list(id = "returning_drug_two_agents_one_line",
       title = "Two drugs start one line while a drug is away",
       param = NA_character_, confidence = "to_confirm",
       where = "lot/engine/R/foldin_rule.R - foldin_openers, one row per line",
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

  list(id = "maintenance_to_relapse", title = "Maintenance running into relapse",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/steps/05_sct.R:13 - maintenance is a descriptive flag only",
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
       where = "lot/engine/R/steps/10_lot2_5_base.R:367 - MAP_MED_CLASS <> 'STEROID'",
       events = function(p) rbind(
         ev(0,   "MED",     "1L regimen starts"),
         ev(150, "STEROID", "dexamethasone alone for several weeks"),
         ev(220, "MED",     "next regimen begins")),
       expected = function(p) "The steroid stretch neither starts nor continues a line.",
       why = "Steroids accompany almost every MM regimen; counted, they would start lines everywhere."),

  list(id = "belantamab_any_line", title = "Belantamab anywhere in the patient's lines",
       param = NA_character_, confidence = "derived",
       where = "lot/engine/R/line_criteria.R:39 - no_belantamab, on_fail = truncate",
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
       where = "lot/engine/R/steps/05_sct.R:11 - excess AUTO ends LOT1",
       events = function(p) rbind(
         ev(0,   "MED",  "1L regimen starts"),
         ev(30,  "AUTO", "first transplant"),
         ev(30 + p$sct_tandem_days - 1L, "AUTO", "tandem partner"),
         ev(400, "AUTO", "third transplant")),
       expected = function(p) "The first two are a tandem inside LOT1; the third is excess and ends LOT1.",
       why = "Three transplants is rare enough that the rule is rarely exercised."),

  list(id = "overlapping_oral_refills", title = "Overlapping oral refills",
       param = "medical_day_supply", confidence = "to_confirm",
       where = "lot/engine/R/steps/03_mma_map.R - run-out from day supply",
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
       where = "lot/engine/R/build_lot.R - lines outside 1..max_lot are refused by check_lot_long",
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

  for (x in v) {
    at <- paste0("'", x$id, "'")
    if (!x$confidence %in% c("derived", "to_confirm"))
      bad <- c(bad, paste0(at, ": confidence '", x$confidence, "' is not one of derived/to_confirm"))
    # A renamed parameter must break this, not silently describe a rule that
    # no longer exists.
    if (!is.na(x$param)) {
      if (!x$param %in% names(VIGNETTE_PARAMS))
        bad <- c(bad, paste0(at, ": names parameter '", x$param, "', which is not one this catalogue knows"))
      else if (is.null(p[[x$param]]) || is.na(p[[x$param]]))
        bad <- c(bad, paste0(at, ": parameter '", x$param, "' is not set in this run's config"))
    }
    e <- tryCatch(x$events(p), error = function(err) NULL)
    if (is.null(e) || !nrow(e))
      bad <- c(bad, paste0(at, ": events() produced nothing"))
    else if (is.unsorted(e$day))
      bad <- c(bad, paste0(at, ": events are not in time order"))
  }

  # Each pair straddles its parameter, and the two sides disagree. This is what
  # makes the catalogue move when a setting does.
  paired <- Filter(function(x) !is.null(x$pair), v)
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
    # tests that the rule exists, not where its edge is - and every off-by-one
    # this catalogue has carried sat in that slack. The two sides must be
    # ADJACENT, so 'within' is the last day inside and 'beyond' the first day
    # outside. If that is wrong, one of them is on the wrong side of the edge.
    if (db > dw && db - dw != 1L)
      bad <- c(bad, paste0("parameter '", nm, "': the two sides are ", db - dw,
                           " days apart (d", dw, " and d", db, "), so neither is ",
                           "pinned to the boundary. They must be consecutive days"))
    if (identical(w$expected(p), b$expected(p)))
      bad <- c(bad, paste0("parameter '", nm, "': both sides expect the same thing, ",
                           "so the boundary is not being tested"))
  }
  if (length(bad))
    stop("The vignette catalogue does not hold:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}
