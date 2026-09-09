# The rule's decision, executed rather than read.
#
# melp_decision_ctes() emits a self-contained chain: it reads the claims, a
# table naming the line being judged, and that line's base set and restart
# flags. All four can be real tables, so the chain runs on its own here - no
# engine, no build - and each patient below pins one branch of it.
#
# Why in this package. The rule's behaviour on whole patients is proved by the
# repository's planted-patient harnesses, which build every statement the
# engine issues. What they cannot do cheaply is a boundary: a course whose
# confirming agent lands exactly on its last covered day, a hold that has to
# be capped at the line's span end. Each of those is one row here.
#
# Thirteen patients, one line each. The line is 2020-01-01 with a 60-day
# induction window unless the case says otherwise, and every course is 28 days
# - the contract cap - unless it is the case testing the cap.
RULE_SCHEMA <- list(
  map = list(table = "map_stacked", columns = c(
    PATID = "VARCHAR", MAP_MED_TYPE = "VARCHAR", MAP_MED_CLASS = "VARCHAR",
    MAP_START_DT = "DATE", MAP_END_DT = "DATE", MAP_DISCON_FLG = "INTEGER")),

  # The line under judgement, with the induction end already worked out - the
  # steps hand that expression in, so it is data here.
  line = list(table = "mline", columns = c(
    PATID = "VARCHAR", LOT_START_DT = "DATE", IND_END_DT = "DATE",
    OBS_END_DT = "DATE", START_TYPE = "VARCHAR")),

  base = list(table = "mbase", columns = c(
    PATID = "VARCHAR", MED_ABBR = "VARCHAR", SUBSTITUTE_ONLY = "INTEGER")),

  restart = list(table = "mrestart", columns = c(
    PATID = "VARCHAR", MAP_MED_TYPE = "VARCHAR", MAP_START_DT = "DATE",
    PREV_DISCON = "INTEGER")),

  auto = list(table = "tx_auto_dates", columns = c(
    PATID = "VARCHAR", TX_DT = "DATE")),

  allo = list(table = "tx_allo_cart_dates", columns = c(
    PATID = "VARCHAR", TX_DT = "DATE", SCT_TYPE = "VARCHAR")),

  # The lines already built, for the courses an earlier line held inside its
  # own window. Empty for every patient whose case is about one line.
  lot_long = list(table = "lot_long", columns = c(
    PATID = "VARCHAR", LOT_NUM = "INTEGER", LOT_START_DT = "DATE",
    LOT_START_TYPE = "VARCHAR")))

.rl <- function(pat, start = "2020-01-01", ind = "2020-02-29",
                obs = "2021-12-31", type = "MED")
  list(PATID = pat, LOT_START_DT = start, IND_END_DT = ind, OBS_END_DT = obs,
       START_TYPE = type)

.rm <- function(pat, med, cls, start, end, discon = 0L)
  list(PATID = pat, MAP_MED_TYPE = med, MAP_MED_CLASS = cls,
       MAP_START_DT = start, MAP_END_DT = end, MAP_DISCON_FLG = discon)

.rb <- function(pat, med, sub = 0L)
  list(PATID = pat, MED_ABBR = med, SUBSTITUTE_ONLY = sub)

.rr <- function(pat, med, start, prev = 0L)
  list(PATID = pat, MAP_MED_TYPE = med, MAP_START_DT = start, PREV_DISCON = prev)

# One entry per patient: the line, the claims, the base set, and what the rule
# must make of the course. Expected values are worked out from the rule as
# LOT_RULES.md 4.7 states it, not from what the SQL happens to return.
RULE_CASES <- list(
  R01 = list(
    what = "a short course outside induction, on its own",
    line = .rl("R01"),
    map  = list(.rm("R01", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R01", "MELP", "ALKY", "2020-06-01", "2020-06-28")),
    base = list(.rb("R01", "LEN")),
    # 28 days of cover, nothing new starts in it: suppressed, and the line is
    # carried to its last covered day.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 1, INJECTED = 0, HOLD = "2020-06-28")),

  R02 = list(
    what = "one day past the cap, so the rule leaves it to the engine",
    line = .rl("R02"),
    map  = list(.rm("R02", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R02", "MELP", "ALKY", "2020-06-01", "2020-06-29")),
    base = list(.rb("R02", "LEN")),
    # 29 days inclusive. The cap is 28, so this is not a short course at all.
    expect = list(SHORT = 0, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 0, HOLD = NA)),

  R03 = list(
    what = "a new agent five days into the course confirms it",
    line = .rl("R03"),
    map  = list(.rm("R03", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R03", "MELP", "ALKY", "2020-06-01", "2020-06-28"),
                .rm("R03", "DARA", "MAB",  "2020-06-05", "2020-09-01")),
    base = list(.rb("R03", "LEN")),
    # Injected on the MELPHALAN date. A single-dose course has nothing after
    # its first day, so the line it opens needs no hold.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 1, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 1, HOLD = NA)),

  R04 = list(
    what = "an agent on the course's LAST covered day still confirms it",
    line = .rl("R04"),
    map  = list(.rm("R04", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R04", "MELP", "ALKY", "2020-06-01", "2020-06-28"),
                .rm("R04", "DARA", "MAB",  "2020-06-28", "2020-09-01")),
    base = list(.rb("R04", "LEN")),
    # "starts while the course still covers" includes the last day of cover.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 1, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 1, HOLD = NA)),

  R05 = list(
    what = "an agent on the melphalan date itself confirms nothing",
    line = .rl("R05"),
    map  = list(.rm("R05", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R05", "MELP", "ALKY", "2020-06-01", "2020-06-28"),
                .rm("R05", "DARA", "MAB",  "2020-06-01", "2020-09-01")),
    base = list(.rb("R05", "LEN")),
    # Two drugs starting the same day start one line together; neither began
    # "while the other still covered", so the agent confirms nothing.
    #
    # And the course is not this line's either. melp_taken owns a course only
    # up to and including the exposure date, so an agent landing exactly on it
    # is one that got there first - the line it opens is the course's line,
    # and that line's own statement judges the course from its start date.
    # This is why the strict > in melp_confirm cannot be observed from
    # outside: an agent close enough to be excluded by it is one that has
    # already taken the course, and it passes the same candidate gate in both
    # places.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 1,
                  SUPPRESSED = 0, INJECTED = 0, HOLD = NA)),

  R06 = list(
    what = "the hold is capped at the line's span end",
    line = .rl("R06", obs = "2020-06-15"),
    map  = list(.rm("R06", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R06", "MELP", "ALKY", "2020-06-01", "2020-06-28")),
    base = list(.rb("R06", "LEN")),
    # The course covers to 06-28, the line's span ends 06-15. A line cannot be
    # carried past its own span, so the hold is the earlier of the two.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 1, INJECTED = 0, HOLD = "2020-06-15")),

  R07 = list(
    what = "two doses closer than the exposure gap are one course",
    line = .rl("R07"),
    map  = list(.rm("R07", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R07", "MELP", "ALKY", "2020-06-01", "2020-06-14"),
                .rm("R07", "MELP", "ALKY", "2020-06-15", "2020-06-28"),
                .rm("R07", "DARA", "MAB",  "2020-06-05", "2020-09-01")),
    base = list(.rb("R07", "LEN")),
    # 14 days apart, under the 30-day exposure gap, so the course runs 06-01
    # to 06-28 and is short. The confirming agent is inside it.
    #
    # No hold on THIS line: the boundary is the course's first day, and
    # holding the line the boundary ends would carry it across its own
    # boundary. The 06-15 dose is refused a line of its own instead, which is
    # what REST records.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 1, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 1, HOLD = NA,
                  REST = "2020-06-15")),

  R08 = list(
    what = "an allograft line judges a course starting on its own date",
    line = .rl("R08", start = "2020-06-01", ind = "2020-06-01",
                type = "SCT_ALLO"),
    map  = list(.rm("R08", "MELP", "ALKY", "2020-06-01", "2020-06-14"),
                .rm("R08", "MELP", "ALKY", "2020-06-15", "2020-06-28"),
                .rm("R08", "DARA", "MAB",  "2020-06-05", "2020-09-01")),
    base = list(),
    allo = list(list(PATID = "R08", TX_DT = "2020-06-01", SCT_TYPE = "ALLO")),
    # An allograft line takes no drugs at all, so a course on its date is not
    # an induction drug of it however the window arithmetic reads - INSIDE is
    # 0 and the course is judged. Confirmed, so it is injected, and this line
    # IS the one that day opens, so the hold applies and reaches the later
    # dose.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 1, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 1, HOLD = "2020-06-28",
                  REST = "2020-06-15")),

  R09 = list(
    what = "a steroid confirms nothing",
    line = .rl("R09"),
    map  = list(.rm("R09", "LEN",  "IMID",    "2020-01-01", "2020-12-31"),
                .rm("R09", "MELP", "ALKY",    "2020-06-01", "2020-06-28"),
                .rm("R09", "DEX",  "STEROID", "2020-06-05", "2020-09-01")),
    base = list(.rb("R09", "LEN")),
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 1, INJECTED = 0, HOLD = "2020-06-28")),

  R10 = list(
    what = "a drug the line already holds confirms nothing",
    line = .rl("R10"),
    map  = list(.rm("R10", "LEN", "IMID", "2020-01-01", "2020-03-31"),
                .rm("R10", "MELP", "ALKY", "2020-06-01", "2020-06-28"),
                .rm("R10", "LEN", "IMID", "2020-06-05", "2020-09-01")),
    base = list(.rb("R10", "LEN")),
    restart = list(.rr("R10", "LEN", "2020-06-05", 0L)),
    # Nothing new happened: LEN is this line's own drug, refilling.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 1, INJECTED = 0, HOLD = "2020-06-28")),

  R11 = list(
    what = "...unless it comes back after a confirmed discontinuation",
    line = .rl("R11"),
    map  = list(.rm("R11", "LEN", "IMID", "2020-01-01", "2020-03-31", 1L),
                .rm("R11", "MELP", "ALKY", "2020-06-01", "2020-06-28"),
                .rm("R11", "LEN", "IMID", "2020-06-05", "2020-09-01")),
    base = list(.rb("R11", "LEN")),
    restart = list(.rr("R11", "LEN", "2020-06-05", 1L)),
    # A released restart is a candidate the engine would accept, so it is one
    # the rule accepts too - the same gate, read from the same tables.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 1, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 1, HOLD = NA)),

  R12 = list(
    what = "a course inside induction is left to the engine",
    line = .rl("R12"),
    map  = list(.rm("R12", "LEN",  "IMID", "2020-01-01", "2020-12-31"),
                .rm("R12", "MELP", "ALKY", "2020-02-01", "2020-02-28")),
    base = list(.rb("R12", "LEN")),
    # Inside the window it is an induction drug of the line, not a course the
    # rule judges.
    expect = list(SHORT = 1, INSIDE = 1, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 0, HOLD = NA)),

  R13 = list(
    what = "a course after another agent opened a line is not this line's",
    line = .rl("R13"),
    map  = list(.rm("R13", "LEN",  "IMID", "2020-01-01", "2020-02-28"),
                .rm("R13", "DARA", "MAB",  "2020-03-01", "2020-03-30"),
                .rm("R13", "MELP", "ALKY", "2020-06-01", "2020-06-28")),
    base = list(.rb("R13", "LEN")),
    # DARA is a candidate against this line and got there first, so the course
    # belongs to the line DARA opened - this one does not judge it.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 1,
                  SUPPRESSED = 0, INJECTED = 0, HOLD = NA)),

  R14 = list(
    what = "a course that started before the line and still covers into it",
    line = .rl("R14", start = "2020-06-10", ind = "2020-07-09"),
    map  = list(.rm("R14", "MELP", "ALKY", "2020-06-01", "2020-06-28"),
                .rm("R14", "LEN",  "IMID", "2020-06-10", "2020-12-31")),
    base = list(.rb("R14", "LEN")),
    # Neither inside this line's window nor after it - a course starting
    # BEFORE the line is a third thing, and the two are not each other's
    # negation. It is still judged, and still suppressed.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 1, INJECTED = 0, HOLD = "2020-06-28")),

  R15 = list(
    what = "a course an EARLIER line held inside its own window",
    line = .rl("R15", start = "2020-03-01", ind = "2020-03-30"),
    map  = list(.rm("R15", "LEN",  "IMID", "2020-01-01", "2020-02-29"),
                .rm("R15", "MELP", "ALKY", "2020-02-25", "2020-03-23"),
                .rm("R15", "DARA", "MAB",  "2020-03-01", "2020-12-31")),
    base = list(.rb("R15", "DARA")),
    lot_long = list(list(PATID = "R15", LOT_NUM = 1L,
                         LOT_START_DT = "2020-01-01", LOT_START_TYPE = "MED")),
    # The course starts inside LOT1's own 60-day window, so LOT1 owns it. It
    # covers into this line, which is why the cover bound alone does not keep
    # it out - and a line that judged and suppressed a course it does not own
    # would be carried to a date belonging to the line before it.
    expect = list(SHORT = 1, INSIDE = 0, CONFIRMED = 0, TAKEN = 0,
                  SUPPRESSED = 0, INJECTED = 0, HOLD = NA)))

rule_data <- function(cases = RULE_CASES) {
  g <- function(k) unlist(lapply(cases, function(c_i) c_i[[k]] %||% list()),
                          recursive = FALSE, use.names = FALSE)
  list(map = g("map"), line = lapply(cases, function(c_i) c_i$line),
       base = g("base"), restart = g("restart"),
       auto = g("auto"), allo = g("allo"), lot_long = g("lot_long"))
}

# One statement, reading every CTE the decision emits. The verdict columns come
# from melp_judged where it judged the course and from the chain itself where
# it did not, so a course this line refused to judge is still reported rather
# than vanishing.
rule_query <- function(cfg) {
  ctes <- melp_decision_ctes(cfg, "mline", "LOT_START_DT", "mline.OBS_END_DT",
                             "mline.IND_END_DT", base_tbl = "mbase",
                             restart_tbl = "mrestart",
                             prior_held_ctes = melp_prior_held_cte(2L, 30L, 45L, 60L),
                             no_regimen_line = "mline.START_TYPE = 'SCT_ALLO'")
  paste0("WITH", ctes, "
    answer AS (
      SELECT c.PATID,
             CASE WHEN datediff(c.COURSE_END_DT, c.EXPO_DT) + 1 <= ",
               cfg$melp_simple_course_days, " THEN 1 ELSE 0 END AS SHORT,
             CASE WHEN c.EXPO_DT >= mline.LOT_START_DT
                   AND c.EXPO_DT <= mline.IND_END_DT
                   AND NOT (mline.START_TYPE = 'SCT_ALLO')
                  THEN 1 ELSE 0 END                              AS INSIDE,
             CASE WHEN cf.PATID IS NOT NULL THEN 1 ELSE 0 END    AS CONFIRMED,
             CASE WHEN tk.PATID IS NOT NULL THEN 1 ELSE 0 END    AS TAKEN,
             CASE WHEN s.PATID  IS NOT NULL THEN 1 ELSE 0 END    AS SUPPRESSED,
             CASE WHEN i.PATID  IS NOT NULL THEN 1 ELSE 0 END    AS INJECTED,
             cast(h.MELP_HOLD_DT as string)                      AS HOLD,
             cast(max(r.DOSE_DT) as string)                      AS REST
      FROM melp_course c
      INNER JOIN mline           ON mline.PATID = c.PATID
      LEFT JOIN melp_confirm cf  ON cf.PATID = c.PATID AND cf.EXPO_DT = c.EXPO_DT
      LEFT JOIN melp_taken   tk  ON tk.PATID = c.PATID AND tk.EXPO_DT = c.EXPO_DT
      LEFT JOIN melp_suppress s  ON s.PATID  = c.PATID AND s.SUPPRESS_DT = c.EXPO_DT
      LEFT JOIN melp_inject   i  ON i.PATID  = c.PATID AND i.INJECT_DT = c.EXPO_DT
      LEFT JOIN melp_hold     h  ON h.PATID  = c.PATID
      LEFT JOIN melp_dose_expo de ON de.PATID = c.PATID AND de.EXPO_DT = c.EXPO_DT
      LEFT JOIN melp_inject_rest r ON r.PATID = c.PATID AND r.DOSE_DT = de.DOSE_DT
      GROUP BY c.PATID, c.EXPO_DT, c.COURSE_END_DT, mline.LOT_START_DT,
               mline.IND_END_DT, mline.START_TYPE, cf.PATID, tk.PATID,
               s.PATID, i.PATID, h.MELP_HOLD_DT
    )
    SELECT * FROM answer ORDER BY PATID")
}

# The doses the run-out chain must not break at, as the chain itself reads
# them: the verdict relation, then melp_no_break over it.
#
# This is a different question from the one above and asks a different
# induction test - AFTER_WINDOW rather than INSIDE - so it is executed
# separately rather than inferred from the verdicts.
NO_BREAK_EXPECT <- c(
  "R01 2020-06-01",   # suppressed outright
  "R05 2020-06-01",   # the same-day agent took the course; it still refuses
                      # a boundary, because it decided nothing here
  "R06 2020-06-01",
  "R07 2020-06-15",   # a CONFIRMED course breaks the chain on its first day
                      # and only there - the rest of it belongs to the line
                      # that day opened
  "R09 2020-06-01",
  "R10 2020-06-01",
  "R13 2020-06-01")
# R02 is past the cap and left to the engine; R03/R04/R11 are confirmed on
# their first day; R08 and R12 start inside their line's window; R14 starts
# before the line, which is not after its window; R15's course is LOT1's.

no_break_query <- function(cfg) {
  ctes <- melp_decision_ctes(cfg, "mline", "LOT_START_DT", "mline.OBS_END_DT",
                             "mline.IND_END_DT", base_tbl = "mbase",
                             restart_tbl = "mrestart",
                             prior_held_ctes = melp_prior_held_cte(2L, 30L, 45L, 60L),
                             no_regimen_line = "mline.START_TYPE = 'SCT_ALLO'")
  paste0("WITH", ctes,
         melp_verdict_cte(cfg, "mline", "LOT_START_DT", "mline.OBS_END_DT",
                          "mline.IND_END_DT"),
         melp_short_course_ctes(cfg, "melp_verdict"), "
    answer AS (
      SELECT PATID, cast(MAP_START_DT as string) AS DOSE_DT FROM melp_no_break
    )
    SELECT * FROM answer ORDER BY PATID, DOSE_DT")
}
