# Worked treatment histories, the lines the engine builds from them, and the
# count that says how many real patients are in each shape.
#
# The question this answers: how does a line of therapy get created, and how
# many patients does each rule actually decide?
#
# Each entry carries four things.
#
#   timeline  the patient, as drug cover and transplant dates. Day 0 is the
#             first non-steroid MM agent, which is where LOT1 starts.
#   lines     what the engine builds. Not a prediction: every one of these was
#             produced by running the engine's own SQL over the patient. The
#             synthetic harness beside this delivery re-runs them all and fails
#             if any line moves, so this half cannot go stale quietly.
#   patient   the same history in one string, so the harness plants exactly
#             what the timeline describes rather than parsing prose.
#   rule      the section of lot/LOT_RULES.md that decides it.
#   sql       a count over a finished run: how many patients are in this shape,
#             by line number. Read-only.
#
# A scenario with no `sql` is one whose shape cannot be recovered from finished
# output - the reason is on the entry.

# Day numbers, so a reader can check a timeline against the rules without
# converting dates. `cover` is inclusive of both ends, the way MAP episodes are.
LOT_SCENARIOS <- list(

  list(id = "S01", group = "A drug that comes back",
       title = "A drug comes back two months after it stopped",
       story = paste0("A patient starts on daratumumab. Ten days before it runs out they ",
                      "also start lenalidomide. Two months after the daratumumab stops, ",
                      "they go back on it. "),
       outcome = paste0("Three lines. Lenalidomide counts as a new drug, so it closes the ",
                        "first line and opens the second. When the daratumumab comes back ",
                        "it closes the second line and opens a third. "),
       patient = list(meds = "DARA:MAB:0:100; LEN:IMID:90:200; DARA:MAB:160:250"),
       timeline = c("DARA  cover d0-d100",
                    "LEN   cover d90-d200",
                    "DARA  cover d160-d250   - 60 days after DARA's first cover ended"),
       lines = c("LOT1  d0-d89     MED  MED_ADD          regimen DARA",
                 "LOT2  d90-d159   MED  MED_ADD          regimen LEN",
                 "LOT3  d160-d250  MED  DISCONTINUATION  regimen DARA"),
       rule = "LOT_RULES.md 4.1, 4.3, 7.4",
       note = paste0("Three lines. LEN starts outside LOT1's 60-day window, so it is an ",
                     "added medication and ends LOT1. DARA's return then ends LOT2 the ",
                     "same way. The 60-day gap does NOT block DARA from starting a line: ",
                     "the prior-regimen exclusion looks one line back, and DARA was ",
                     "LOT1's drug, not LOT2's."),
       count_of = paste0("every patient where a drug from two lines back returns and ",
                           "starts a line - any drugs, any gap. Wider than the worked ",
                           "days."),
       sql = "
      WITH ex AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      back AS (
        SELECT DISTINCT e.PATID, n.LOT_NUM
        FROM ex e
        INNER JOIN {t$long} n
           ON n.PATID = e.PATID AND n.LOT_NUM = e.LOT_NUM + 2
        INNER JOIN ex mid
           ON mid.PATID = e.PATID AND mid.LOT_NUM = e.LOT_NUM + 1
        WHERE array_contains(split(n.LOT_BASE_MEDS, ' '), e.MED_ABBR)
          AND NOT EXISTS (SELECT 1 FROM ex m2
                          WHERE m2.PATID = e.PATID AND m2.LOT_NUM = e.LOT_NUM + 1
                            AND m2.MED_ABBR = e.MED_ABBR)
      )
      SELECT LOT_NUM, count(DISTINCT PATID) AS N_PATIENTS
      FROM back GROUP BY LOT_NUM ORDER BY LOT_NUM"),

  list(id = "S02", group = "A drug that comes back",
       title = "The same drug comes back three months after it stopped",
       story = paste0("The same patient, but the daratumumab comes back a month later - ",
                      "three months after it stopped. "),
       outcome = paste0("The same three lines. Only the date the third line starts is ",
                        "different. The 90-day rule for deciding whether a drug has been ",
                        "restarted does not apply here, because it only looks at the line ",
                        "immediately before. "),
       patient = list(meds = "DARA:MAB:0:100; LEN:IMID:90:200; DARA:MAB:190:250"),
       timeline = c("DARA  cover d0-d100",
                    "LEN   cover d90-d200",
                    "DARA  cover d190-d250   - 90 days after DARA's first cover ended"),
       lines = c("LOT1  d0-d89     MED  MED_ADD          regimen DARA",
                 "LOT2  d90-d189   MED  MED_ADD          regimen LEN",
                 "LOT3  d190-d250  MED  DISCONTINUATION  regimen DARA"),
       rule = "LOT_RULES.md 4.1, 4.3, 7.4",
       note = paste0("THE SAME THREE LINES as S01. Only the LOT3 start date moves. ",
                     "The 90-day discontinuation threshold decides nothing here, ",
                     "because the drug that returns belongs to the line before last. ",
                     "S05 and S06 are where the threshold does decide the answer."),
       sql = NULL,
       sql_note = "Same shape as S01 - one count covers both."),

  list(id = "S03", group = "Transplants",
       title = "One stem cell transplant, just outside the first 60 days",
       story = paste0("A patient is on daratumumab for about three months. They have a ",
                      "stem cell transplant two months in. "),
       outcome = paste0("One line. At the first line, the first transplant counts as part ",
                        "of the starting treatment, so it does not open a new line. It ",
                        "arrived just after the 60-day window, so it does not extend the ",
                        "line either. The line ends when the drug runs out. "),
       patient = list(meds = "DARA:MAB:0:100", auto = "60"),
       timeline = c("DARA  cover d0-d100",
                    "AUTO  d60"),
       lines = c("LOT1  d0-d100  MED  DISCONTINUATION  regimen DARA"),
       rule = "LOT_RULES.md 3.4, 6.5",
       note = paste0("One line. LOT1's first autologous transplant is part of ",
                     "induction and never ends the line. Day 60 is one day past ",
                     "the 60-day window (d0-d59), so it does not hold the line ",
                     "open either - the line still ends where its drug runs out. ",
                     "The transplant sits inside LOT1 because LOT1 covers d0-d100."),
       count_of = paste0("every transplant sitting inside a line but past that line's ",
                           "window, at any line. Wider than the worked history."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      INNER JOIN {t$auto} x
         ON x.PATID = l.PATID
        AND x.TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
      WHERE x.TX_DT > date_add(l.LOT_START_DT,
              CASE l.LOT_START_TYPE WHEN 'SCT_ALLO' THEN 0
                                    WHEN 'CART' THEN {cart_days} - 1
                                    ELSE CASE WHEN l.LOT_NUM = 1
                                              THEN {lot1_window} - 1
                                              ELSE {lotn_window} - 1 END END)
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S04", group = "Transplants",
       title = "A second transplant four months after the first",
       story = paste0("The same patient has a second transplant four months after the ",
                      "first. "),
       outcome = paste0("Two lines. Two transplants within six months would normally count ",
                        "as one planned pair. But the first arrived after the 60-day ",
                        "window, so the first line never took ownership of it. The second ",
                        "transplant opens a new line. "),
       patient = list(meds = "DARA:MAB:0:100", auto = "60,180"),
       timeline = c("DARA  cover d0-d100",
                    "AUTO  d60",
                    "AUTO  d180   - 120 days after the first"),
       lines = c("LOT1  d0-d100     MED       DISCONTINUATION  regimen DARA",
                 "LOT2  d180-d1200  SCT_AUTO  STUDY_END        regimen (none)"),
       rule = "LOT_RULES.md 6.3, 4.1",
       note = paste0("Two lines. The pair is inside 180 days, which would make it ",
                     "a planned tandem - but the FIRST transplant fell outside ",
                     "LOT1's window, so no line ever held the pair. The tandem ",
                     "exemption does not apply and the second transplant opens ",
                     "LOT2 on its own date."),
       count_of = paste0("every close transplant pair whose earlier transplant fell ",
                           "outside its line's window - the pairs no line held. Wider ",
                           "than the worked days."),
       sql = "
      WITH paired AS (
        SELECT PATID, TX_DT,
               lag(TX_DT) OVER (PARTITION BY PATID ORDER BY TX_DT) AS PREV_TX_DT
        FROM {t$auto}
      )
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM paired p
      INNER JOIN {t$long} l
         ON l.PATID = p.PATID
        AND p.PREV_TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
      WHERE p.PREV_TX_DT IS NOT NULL
        AND datediff(p.TX_DT, p.PREV_TX_DT) <= {tandem_days}
        AND p.PREV_TX_DT > date_add(l.LOT_START_DT,
              CASE l.LOT_START_TYPE WHEN 'SCT_ALLO' THEN 0
                                    WHEN 'CART' THEN {cart_days} - 1
                                    ELSE CASE WHEN l.LOT_NUM = 1
                                              THEN {lot1_window} - 1
                                              ELSE {lotn_window} - 1 END END)
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S05", group = "A drug that comes back",
       title = "The same drug restarted after a break of 89 days",
       story = paste0("A patient is on lenalidomide for about three months, stops, and ",
                      "goes back on it 89 days later. "),
       outcome = paste0("One line. A break of under 90 days does not count as stopping. The ",
                        "line carries on through the gap and ends when the second supply ",
                        "runs out. "),
       patient = list(meds = "LEN:IMID:0:100; LEN:IMID:189:400"),
       timeline = c("LEN  cover d0-d100",
                    "LEN  cover d189-d400   - 89 days after the first cover ended"),
       lines = c("LOT1  d0-d400  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 4.3, 5.2",
       note = paste0("ONE line. The gap is under map_discon_gap_days, so the drug ",
                     "was never discontinued. LOT1's run-out chains over the gap ",
                     "to d400, and the drug cannot start a line because it is ",
                     "still LOT1's own."),
       count_of = paste0("every return of a line's own drug after a break under 90 ",
                           "days - the held population, any drug."),
       sql = "
      WITH ep AS (
        SELECT m.PATID, m.MAP_MED_TYPE, m.MAP_END_DT,
               lead(m.MAP_START_DT) OVER (PARTITION BY m.PATID, m.MAP_MED_TYPE
                                          ORDER BY m.MAP_START_DT) AS RETURN_DT
        FROM {t$map} m
      )
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM ep
      INNER JOIN {t$long} l
         ON l.PATID = ep.PATID
        AND array_contains(split(l.LOT_BASE_MEDS, ' '), ep.MAP_MED_TYPE)
        AND ep.MAP_END_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
      WHERE ep.RETURN_DT IS NOT NULL
        AND datediff(ep.RETURN_DT, ep.MAP_END_DT) <  {discon_days}
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S06", group = "A drug that comes back",
       title = "The same drug restarted after a break of 90 days",
       story = paste0("The same patient goes back on it one day later - 90 days after ",
                      "stopping. "),
       outcome = paste0("Two lines, both on the same drug. A break of 90 days or more ",
                        "counts as stopping, so coming back counts as starting again. One ",
                        "day changes the answer. "),
       patient = list(meds = "LEN:IMID:0:100; LEN:IMID:190:400"),
       timeline = c("LEN  cover d0-d100",
                    "LEN  cover d190-d400   - 90 days after the first cover ended"),
       lines = c("LOT1  d0-d100    MED  DISCONTINUATION  regimen LEN",
                 "LOT2  d190-d400  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 4.3, 5.2",
       note = paste0("TWO lines, on the same drug. The gap reaches ",
                     "map_discon_gap_days, so the first episode is a confirmed ",
                     "discontinuation and the return is a restart. This is the ",
                     "one day that changes the answer - S05 and S06 differ by it."),
       count_of = paste0("every return at 90 days or more - the released population, ",
                           "any drug."),
       sql = "
      WITH ep AS (
        SELECT m.PATID, m.MAP_MED_TYPE, m.MAP_END_DT,
               lead(m.MAP_START_DT) OVER (PARTITION BY m.PATID, m.MAP_MED_TYPE
                                          ORDER BY m.MAP_START_DT) AS RETURN_DT
        FROM {t$map} m
      )
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM ep
      INNER JOIN {t$long} l
         ON l.PATID = ep.PATID
        AND array_contains(split(l.LOT_BASE_MEDS, ' '), ep.MAP_MED_TYPE)
        AND ep.MAP_END_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
      WHERE ep.RETURN_DT IS NOT NULL
        AND datediff(ep.RETURN_DT, ep.MAP_END_DT) >= {discon_days}
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S07", group = "Which drugs count as the line's",
       title = "A second drug added inside the first 60 days",
       story = paste0("A patient starts daratumumab, and adds lenalidomide a month later. "),
       outcome = paste0("One line, with both drugs on it. Anything started in the first 60 ",
                        "days counts as part of the starting treatment. "),
       patient = list(meds = "DARA:MAB:0:200; LEN:IMID:30:200"),
       timeline = c("DARA  cover d0-d200",
                    "LEN   cover d30-d200   - day 30, inside LOT1's 60-day window"),
       lines = c("LOT1  d0-d200  MED  DISCONTINUATION  regimen DARA LEN"),
       rule = "LOT_RULES.md 3.2, 7.4",
       note = paste0("ONE line with both drugs in its regimen. An agent starting ",
                     "inside the window joins the regimen, so it can never be an ",
                     "addition."),
       count_of = paste0("every line whose drug list holds more than one drug - any ",
                           "drugs, any timing inside the window. Much wider than the ",
                           "worked pair."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_MED_CNT > 1
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S08", group = "Which drugs count as the line's",
       title = "The same drug added one day later, on day 60",
       story = paste0("The same patient adds the lenalidomide on day 60 instead of day ",
                      "30. "),
       outcome = paste0("Two lines. One day past the window makes lenalidomide a new drug ",
                        "rather than part of the starting treatment, so it closes the first ",
                        "line and opens the second. "),
       patient = list(meds = "DARA:MAB:0:200; LEN:IMID:60:200"),
       timeline = c("DARA  cover d0-d200",
                    "LEN   cover d60-d200   - day 60, one day past the window"),
       lines = c("LOT1  d0-d59    MED  MED_ADD          regimen DARA",
                 "LOT2  d60-d200  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 3.2, 7.4, 4.1",
       note = paste0("TWO lines. One day moves the agent out of the regimen and ",
                     "makes it an added medication, which ends LOT1 the day ",
                     "before and starts LOT2 on it."),
       count_of = paste0("every line ended by an added drug, on any day outside the ",
                           "window - not only day-60 additions."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'MED_ADD'
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S09", group = "Which drugs count as the line's",
       title = "A drug the patient never stops taking",
       story = paste0("A patient takes lenalidomide without a break for over a year. ",
                      "Three months in they also start pomalidomide, and they keep ",
                      "refilling the lenalidomide. "),
       outcome = paste0("Two lines - and lenalidomide is NOT listed on the second line, ",
                        "even though the patient is on it the whole time. The algorithm ",
                        "looks for a drug that STARTS in the line's first 30 days. A refill ",
                        "of a supply that never lapsed is not a start. This is an open ",
                        "question for the study team. "),
       patient = list(meds = "LEN:IMID:0:400; POMA:IMID:100:300"),
       timeline = c("LEN   cover d0-d400    - one episode, never interrupted",
                    "POMA  cover d100-d300"),
       lines = c("LOT1  d0-d99     MED  MED_ADD          regimen LEN",
                 "LOT2  d100-d300  MED  DISCONTINUATION  regimen POMA"),
       rule = "LOT_RULES.md 2.3, 4.2",
       note = paste0("LEN is absent from LOT2's regimen even though the patient ",
                     "is on it throughout. A regimen is the agents whose EPISODE ",
                     "STARTS in the window, and LEN's episode started on d0. A ",
                     "refill inside LOT2's window extends that episode and leaves ",
                     "no new start behind. This is Q1 on the Open ",
                     "questions sheet."),
       count_of = paste0("every later line with a previous-line drug covered across ",
                           "its start and absent from its list - the exact rule ",
                           "population."),
       sql = "
      SELECT n.LOT_NUM, count(DISTINCT n.PATID) AS N_PATIENTS
      FROM {t$long} n
      INNER JOIN {t$long} p ON p.PATID = n.PATID AND p.LOT_NUM = n.LOT_NUM - 1
      INNER JOIN {t$map} m
         ON m.PATID = n.PATID
        AND array_contains(split(p.LOT_BASE_MEDS, ' '), m.MAP_MED_TYPE)
        AND m.MAP_START_DT <  n.LOT_START_DT
        AND m.MAP_END_DT   >= n.LOT_START_DT
      WHERE NOT array_contains(split(coalesce(n.LOT_BASE_MEDS, ''), ' '), m.MAP_MED_TYPE)
      GROUP BY n.LOT_NUM ORDER BY n.LOT_NUM"),

  list(id = "S10", group = "Transplants",
       title = "Two transplants six months apart, nothing in between",
       story = paste0("A patient's drug runs out after three weeks. They have a ",
                      "transplant on day 40, and a second one six months later, with no ",
                      "other treatment in between. "),
       outcome = paste0("One line. The first transplant is inside the 60-day window, so the ",
                        "line owns it. The second is within six months with nothing in ",
                        "between, so the two count as one planned course and the line is ",
                        "held open to the second. "),
       patient = list(meds = "LEN:IMID:0:19", auto = "40,219"),
       timeline = c("LEN   cover d0-d19",
                    "AUTO  d40    - inside LOT1's 60-day window",
                    "AUTO  d219   - 179 days after the first, nothing in between"),
       lines = c("LOT1  d0-d219  MED  SCT_AUTO_CONT  regimen LEN"),
       rule = "LOT_RULES.md 6.3, 6.5",
       note = paste0("ONE line. The first transplant is inside the window, so ",
                     "LOT1 holds it. The second is inside 180 days with nothing ",
                     "in between, so the pair is a planned tandem and LOT1 is ",
                     "carried to it. The line's drug ran out on d19; the ",
                     "transplant pair is what keeps it open to d219."),
       count_of = paste0("every line held open to a planned transplant pair (end ",
                           "reason SCT_AUTO_CONT). Includes single in-window transplants ",
                           "past the natural end, not only pairs."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'SCT_AUTO_CONT'
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S11", group = "Transplants",
       title = "The same two transplants, with a drug started in between",
       story = paste0("The same two transplants, but the patient starts pomalidomide in ",
                      "between. "),
       outcome = paste0("Three lines. A planned pair needs a clear gap. The pomalidomide ",
                        "breaks it, so the second transplant counts as unplanned and opens ",
                        "a line of its own. "),
       patient = list(meds = "LEN:IMID:0:19; POMA:IMID:100:300", auto = "40,219"),
       timeline = c("LEN   cover d0-d19",
                    "AUTO  d40",
                    "POMA  cover d100-d300  - between the two transplants",
                    "AUTO  d219"),
       lines = c("LOT1  d0-d40      MED       SCT_AUTO_CONT  regimen LEN",
                 "LOT2  d100-d218   MED       SCT_AUTO       regimen POMA",
                 "LOT3  d219-d1200  SCT_AUTO  STUDY_END      regimen (none)"),
       rule = "LOT_RULES.md 6.3",
       note = paste0("THREE lines. A tandem needs a clear gap, not just an ",
                     "interval. POMA between the two transplants breaks the pair, ",
                     "so the second transplant is unplanned and opens a line of ",
                     "its own."),
       count_of = paste0("every close transplant pair with treatment between the two - ",
                           "the broken pairs, whatever the treatment was."),
       sql = "
      WITH paired AS (
        SELECT PATID, TX_DT,
               lag(TX_DT) OVER (PARTITION BY PATID ORDER BY TX_DT) AS PREV_TX_DT
        FROM {t$auto}
      ),
      interrupts AS (
        SELECT PATID, MAP_START_DT AS dt FROM {t$map} WHERE MAP_MED_CLASS <> 'STEROID'
        UNION ALL
        SELECT PATID, TX_DT AS dt FROM {t$allo} WHERE SCT_TYPE IN ('ALLO', 'CART')
      )
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM paired p
      INNER JOIN {t$long} l
         ON l.PATID = p.PATID
        AND p.PREV_TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
      WHERE p.PREV_TX_DT IS NOT NULL
        AND datediff(p.TX_DT, p.PREV_TX_DT) <= {tandem_days}
        AND EXISTS (SELECT 1 FROM interrupts x
                    WHERE x.PATID = p.PATID
                      AND x.dt > p.PREV_TX_DT AND x.dt < p.TX_DT)
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S12", group = "CAR-T",
       title = "CAR-T therapy inside the first 60 days",
       story = paste0("A patient on lenalidomide has CAR-T therapy on day 40. "),
       outcome = paste0("One line. CAR-T in the first 60 days counts as part of the ",
                        "starting treatment. It does not appear anywhere in the published ",
                        "line table. "),
       patient = list(meds = "LEN:IMID:0:200", ac = "CART:40"),
       timeline = c("LEN   cover d0-d200",
                    "CART  d40   - inside LOT1's 60-day window"),
       lines = c("LOT1  d0-d200  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 6.4",
       note = paste0("ONE line. A CAR-T inside LOT1's window is part of LOT1 and ",
                     "ends nothing. LOT_LONG carries no CAR-T column for it, so ",
                     "the infusion is invisible in the published table."),
       count_of = paste0("every first CAR-T inside LOT1's window that was absorbed - ",
                           "LOT1 runs to or past the infusion. The exact rule ",
                           "population."),
       sql = "
      WITH lot1 AS (SELECT PATID, LOT_START_DT, LOT_BASE_END_DT
                    FROM {t$long} WHERE LOT_NUM = 1)
      SELECT 1 AS LOT_NUM, count(DISTINCT s.PATID) AS N_PATIENTS
      FROM {t$sct} s
      INNER JOIN lot1 l ON l.PATID = s.PATID
      WHERE s.FIRST_CART_DT IS NOT NULL
        AND s.FIRST_CART_DT BETWEEN l.LOT_START_DT
                                AND date_add(l.LOT_START_DT, {lot1_window} - 1)
        -- absorbed, not merely in the calendar window: the rule needs LOT1
        -- still open, and an absorbed infusion leaves the line running to or
        -- past it. A line that ended before the infusion is the other case -
        -- the CAR-T is free to start the next line.
        AND l.LOT_BASE_END_DT >= s.FIRST_CART_DT"),

  list(id = "S13", group = "CAR-T",
       title = "CAR-T therapy after the first 60 days",
       story = paste0("The same patient has the CAR-T on day 100 instead. "),
       outcome = paste0("Two lines. Outside the window the CAR-T closes the first line and ",
                        "opens a CAR-T line. With no drug started in the 45 days after it, ",
                        "that line lasts a single day. "),
       patient = list(meds = "LEN:IMID:0:200", ac = "CART:100"),
       timeline = c("LEN   cover d0-d200",
                    "CART  d100   - outside LOT1's 60-day window"),
       lines = c("LOT1  d0-d99    MED   SCT_CART  regimen LEN",
                 "LOT2  d100-d100 CART  SCT_CART  regimen (none)"),
       rule = "LOT_RULES.md 6.4, 4.1",
       note = paste0("TWO lines. Outside the window the CAR-T ends LOT1 the day ",
                     "before and starts a CAR-T line. With no consolidation drug ",
                     "in its 45-day window, that line is one day long."),
       count_of = paste0("every CAR-T-started line, however it arose - wider than the ",
                           "worked history."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_START_TYPE = 'CART'
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S14", group = "Transplants",
       title = "A donor transplant",
       story = paste0("A patient on lenalidomide has a donor transplant on day 150. "),
       outcome = paste0("Two lines. A donor transplant always closes the line before it and ",
                        "opens one of its own. That line is one day long and has no drugs ",
                        "on it. "),
       patient = list(meds = "LEN:IMID:0:200", ac = "ALLO:150"),
       timeline = c("LEN   cover d0-d200",
                    "ALLO  d150"),
       lines = c("LOT1  d0-d149     MED       SCT_ALLO  regimen LEN",
                 "LOT2  d150-d150   SCT_ALLO  SCT_ALLO  regimen (none)"),
       rule = "LOT_RULES.md 4.6, 7.1",
       note = paste0("TWO lines. An allogeneic transplant always ends the line ",
                     "before it and opens one of its own, and that line spans a ",
                     "single day and carries no regimen."),
       count_of = paste0("every donor-transplant line - the exact rule population."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_START_TYPE = 'SCT_ALLO'
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S15", group = "How a line ends",
       title = "Treatment stops, then the patient dies four months later",
       story = paste0("A patient's drug runs out after three months. They die four months ",
                      "later, with no treatment in between. "),
       outcome = paste0("One line, recorded as ending at the death - not at the point ",
                        "treatment stopped, even though there is enough follow-up to ",
                        "confirm the stop. The date treatment stopped is still on the row. ",
                        "This is an open question for the study team. "),
       patient = list(meds = "LEN:IMID:0:100", death = 220, obs = 220),
       timeline = c("LEN    cover d0-d100",
                    "death  d220",
                    "observation ends d220"),
       lines = c("LOT1  d0-d220  MED  DEATH  regimen LEN"),
       rule = "LOT_RULES.md 5.3, 7.5",
       note = paste0("ONE line, ending DEATH at d220 - not DISCONTINUATION at ",
                     "d100, even though the run-out has 120 days of observation ",
                     "behind it and is confirmed. LOT_BASE_DISCON_DT still ",
                     "carries d100. This is Q3 on the Open questions sheet."),
       count_of = paste0("every line ending DEATH that carries an earlier confirmed ",
                           "stop - the exact population of open question Q3."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'DEATH'
        AND l.LOT_BASE_DISCON_DT IS NOT NULL
        AND l.LOT_BASE_DISCON_DT < l.LOT_BASE_END_DT
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S16", group = "How a line ends",
       title = "Treatment stops just before the data ends",
       story = paste0("A patient's drug runs out after three months, and their data ends ",
                      "one month after that. "),
       outcome = paste0("One line, recorded as ending when the data ends. Stopping ",
                        "treatment is only recorded once 90 days of follow-up confirm it, ",
                        "or later treatment arrives. Neither happened here. "),
       patient = list(meds = "LEN:IMID:0:100", obs = 130),
       timeline = c("LEN  cover d0-d100",
                    "observation ends d130"),
       lines = c("LOT1  d0-d130  MED  STUDY_END  regimen LEN"),
       rule = "LOT_RULES.md 5.3",
       note = paste0("ONE line, ending STUDY_END at d130. The drug ran out on ",
                     "d100 but nothing confirmed it: lot_discon_confirm_days of ",
                     "observation did not follow, and no later treatment ",
                     "arrived. LOT_BASE_DISCON_DT is NULL and the line censors ",
                     "at the end of observation."),
       count_of = paste0("every line ending at the data's end with no confirmed stop - ",
                           "any reason the stop went unconfirmed, not only short ",
                           "follow-up."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'STUDY_END'
        AND l.LOT_BASE_DISCON_DT IS NULL
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S17", group = "How a line ends",
       title = "A steroid given after treatment stops",
       story = paste0("A patient's drug runs out. Three months later they are given ",
                      "dexamethasone, a steroid. "),
       outcome = paste0("One line. Steroids are ignored throughout: they never start a ",
                        "line, never join a line's drug list, and never close a line. "),
       patient = list(meds = "LEN:IMID:0:100; DEX:STEROID:200:400"),
       timeline = c("LEN  cover d0-d100",
                    "DEX  cover d200-d400   - a steroid"),
       lines = c("LOT1  d0-d100  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 2.1",
       note = paste0("ONE line. Steroids are excluded everywhere: they do not ",
                     "start a line, do not join a regimen, and do not end a line ",
                     "as an addition. The DEX cover is invisible to the ",
                     "algorithm."),
       count_of = paste0("every patient with steroid supply outside every line - any ",
                           "steroid, any timing."),
       sql = "
      SELECT count(DISTINCT m.PATID) AS N_PATIENTS, 0 AS LOT_NUM
      FROM {t$map} m
      WHERE m.MAP_MED_CLASS = 'STEROID'
        AND NOT EXISTS (SELECT 1 FROM {t$long} l
                        WHERE l.PATID = m.PATID
                          AND m.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)"),

  list(id = "S18", group = "Which drugs count as the line's",
       title = "A repeat prescription collected while the last one is still covering the patient",
       story = paste0("A patient is on lenalidomide. They collect the next prescription ",
                      "50 days in, while the current supply still has 50 days left on it. "),
       outcome = paste0("One line. The second collection does not count as starting the ",
                        "drug again - it just extends how long the patient is covered. So ",
                        "it is not a new drug being added, and it does not close the line. "),
       patient = list(meds = "LEN:IMID:0:201"),
       timeline = c("LEN  one supply episode, d0-d201",
                    "     (two collections: d0 and d50. The second landed while the",
                    "      first was still covering, so they become one episode that",
                    "      runs 50 days longer)"),
       lines = c("LOT1  d0-d201  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 2.3",
       note = paste0("A claim arriving while an agent's cover is live extends the open ",
                     "episode rather than opening a new one (03_mma_map.R CASE 3). It ",
                     "leaves no MAP_START_DT, so nothing downstream can see it. The ",
                     "pushout is by the second fill's days supply, which is why the ",
                     "episode runs to d201 rather than d150. "),
       sql = NULL,
       sql_note = "the folding happens when supply episodes are built, upstream of the line table, so a finished run cannot be asked how often it happened"),

  list(id = "S19", group = "Which drugs count as the line's",
       title = "Two drugs started on the same day",
       story = paste0("A patient starts daratumumab and lenalidomide on the same day. "),
       outcome = paste0("One line with both drugs on it. The line starts that day and both ",
                        "drugs are part of the starting treatment. "),
       patient = list(meds = "DARA:MAB:0:200; LEN:IMID:0:200"),
       timeline = c("DARA  cover d0-d200",
                    "LEN   cover d0-d200"),
       lines = c("LOT1  d0-d200  MED  DISCONTINUATION  regimen DARA LEN"),
       rule = "LOT_RULES.md 3.1, 3.2",
       note = paste0("The line starts at the earliest non-steroid agent, and both ",
                     "qualify on the same date. Neither can be an addition to the other: ",
                     "both are inside the induction window by construction. "),
       sql = NULL,
       sql_note = "same count as S07 - lines carrying more than one drug"),

  list(id = "S20", group = "Transplants",
       title = "A transplant and a new drug on the same day",
       story = paste0("A patient's first drug runs out. Fifty days later they have a stem ",
                      "cell transplant and start pomalidomide, both on the same day. "),
       outcome = paste0("Two lines. The second line is recorded as started by the ",
                        "transplant, not by the drug - a transplant wins when both land on ",
                        "the same day. The pomalidomide is still on that line's drug list. "),
       patient = list(meds = "LEN:IMID:0:50; POMA:IMID:100:300", auto = "100"),
       timeline = c("LEN   cover d0-d50",
                    "AUTO  d100",
                    "POMA  cover d100-d300"),
       lines = c("LOT1  d0-d50    MED       DISCONTINUATION  regimen LEN",
                 "LOT2  d100-d300  SCT_AUTO  DISCONTINUATION  regimen POMA"),
       rule = "LOT_RULES.md 4.5",
       note = paste0("The same-day tie-break is SCT_ALLO > CART > SCT_AUTO > MED. It ",
                     "decides the START TYPE only - the regimen is still collected over ",
                     "the window, so the drug appears on the line the transplant ",
                     "started. "),
       count_of = paste0("every transplant-started line that carries drugs on its list ",
                           "- any in-window drug, not only same-day starts."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_START_TYPE IN ('SCT_AUTO', 'SCT_ALLO', 'CART')
        AND coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S21", group = "How a line ends",
       title = "Six changes of treatment - more than the five lines counted",
       story = paste0("A patient goes through six different drugs, each starting well ",
                      "after the last one stopped. "),
       outcome = paste0("Five lines. Counting stops at five, so the sixth drug is not given ",
                        "a line and does not appear anywhere in the line table. "),
       patient = list(meds = "LEN:IMID:0:50; POMA:IMID:70:120; DARA:MAB:160:210; BORT:PI:250:300; CARF:PI:340:390; ELO:MAB:430:480"),
       timeline = c("LEN   cover d0-d50",
                    "POMA  cover d70-d120",
                    "DARA  cover d160-d210",
                    "BORT  cover d250-d300",
                    "CARF  cover d340-d390",
                    "ELO   cover d430-d480   - a sixth change of treatment"),
       lines = c("LOT1  d0-d50     MED  DISCONTINUATION  regimen LEN",
                 "LOT2  d70-d120   MED  DISCONTINUATION  regimen POMA",
                 "LOT3  d160-d210  MED  DISCONTINUATION  regimen DARA",
                 "LOT4  d250-d300  MED  DISCONTINUATION  regimen BORT",
                 "LOT5  d340-d390  MED  DISCONTINUATION  regimen CARF"),
       rule = "LOT_RULES.md 9",
       note = paste0("max_lot is 5. Treatment after the fifth line belongs to no line by ",
                     "construction, which is why every count of unowned treatment carves ",
                     "it out rather than reporting it as a defect. "),
       count_of = paste0("every patient at the 5-line cap with non-steroid treatment ",
                           "after the last line - the exact rule population."),
       sql = "
      WITH capped AS (
        SELECT PATID, max(LOT_NUM) AS N_LINES, max(LOT_BASE_END_DT) AS LAST_END
        FROM {t$long} GROUP BY PATID HAVING max(LOT_NUM) >= {max_lot}
      )
      SELECT {max_lot} AS LOT_NUM, count(DISTINCT c.PATID) AS N_PATIENTS
      FROM capped c
      INNER JOIN {t$map} m
         ON m.PATID = c.PATID AND m.MAP_START_DT > c.LAST_END
        AND m.MAP_MED_CLASS <> 'STEROID'"),

  list(id = "S22", group = "Which drugs count as the line's",
       title = "A drug added on the last day that still counts as starting treatment",
       story = paste0("A patient starts daratumumab, and adds lenalidomide on day 59. "),
       outcome = paste0("One line with both drugs. Day 59 is the last day of the 60-day ",
                        "window, so the lenalidomide is still part of the starting ",
                        "treatment. One day later it would have opened a second line. "),
       patient = list(meds = "DARA:MAB:0:200; LEN:IMID:59:200"),
       timeline = c("DARA  cover d0-d200",
                    "LEN   cover d59-d200   - the last day of the window"),
       lines = c("LOT1  d0-d200  MED  DISCONTINUATION  regimen DARA LEN"),
       rule = "LOT_RULES.md 3.2",
       note = paste0("The window runs from the line start through start + 59, inclusive ",
                     "of both ends. S08 is the same patient one day later, and gets two ",
                     "lines. "),
       sql = NULL,
       sql_note = "same count as S07 - lines carrying more than one drug"),

  list(id = "S23", group = "Which drugs count as the line's",
       title = "A drug added 45 days into the second line, where the window is only 30",
       story = paste0("A patient changes treatment, then adds a third drug 45 days into ",
                      "the new treatment. "),
       outcome = paste0("Three lines. The first 60 days only apply to the first line. From ",
                        "the second line on, the window is 30 days - so a drug added on day ",
                        "45 is a new drug rather than part of the treatment, and it opens ",
                        "another line. "),
       patient = list(meds = "DARA:MAB:0:50; LEN:IMID:100:300; POMA:IMID:145:300"),
       timeline = c("DARA  cover d0-d50",
                    "LEN   cover d100-d300   - opens line 2, window d100-d129",
                    "POMA  cover d145-d300   - 45 days into line 2, outside its window"),
       lines = c("LOT1  d0-d50     MED  DISCONTINUATION  regimen DARA",
                 "LOT2  d100-d144  MED  MED_ADD          regimen LEN",
                 "LOT3  d145-d300  MED  DISCONTINUATION  regimen POMA"),
       rule = "LOT_RULES.md 3.2, 4.2",
       note = paste0("60 days at line 1, 30 from line 2 on, 45 on a CAR-T-started line. ",
                     "The same interval is inside the window at line 1 and outside it at ",
                     "line 2. "),
       count_of = paste0("every later line ended by an added drug - any drug, any day ",
                           "past the 30 (or 45)."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'MED_ADD' AND l.LOT_NUM > 1
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S24", group = "How a line ends",
       title = "The patient dies before the stop can be confirmed",
       story = paste0("A patient's drug runs out after three months. They die 30 days ",
                      "later. "),
       outcome = paste0("One line, ending at the death. Stopping treatment needs 90 days of ",
                        "follow-up to confirm it, and the patient did not live that long - ",
                        "so there is no confirmed stop to compete with the death. This is ",
                        "NOT the disputed case: the death is the only ending available. "),
       patient = list(meds = "LEN:IMID:0:100", death = 130, obs = 130),
       timeline = c("LEN    cover d0-d100",
                    "death  d130   - 30 days after the drug ran out"),
       lines = c("LOT1  d0-d130  MED  DEATH  regimen LEN"),
       rule = "LOT_RULES.md 5.3, 7.5",
       note = paste0("Contrast with S25, where 120 days of follow-up DO confirm the stop ",
                     "and the death still takes the line's end. That one is Q3 on the ",
                     "Open questions sheet; this one is not in question. "),
       count_of = paste0("every line ending DEATH with no confirmed stop on the row - ",
                           "the death was the only ending available."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'DEATH' AND l.LOT_BASE_DISCON_DT IS NULL
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S25", group = "How a line ends",
       title = "The patient restarts treatment, then dies",
       story = paste0("A patient's drug runs out after three months. Three months after ",
                      "that they start a different drug, and they die later on. "),
       outcome = paste0("Two lines. The restart confirms that the first treatment had ",
                        "stopped, so the first line ends where it ran out. The death ends ",
                        "the second line. "),
       patient = list(meds = "LEN:IMID:0:100; POMA:IMID:200:300", death = 400, obs = 400),
       timeline = c("LEN    cover d0-d100",
                    "POMA   cover d200-d300",
                    "death  d400"),
       lines = c("LOT1  d0-d100    MED  DISCONTINUATION  regimen LEN",
                 "LOT2  d200-d400  MED  DEATH            regimen POMA"),
       rule = "LOT_RULES.md 5.3, 7.5",
       note = paste0("Later treatment is one of the two things that can confirm a ",
                     "run-out - the other is 90 days of observation. Here it arrives ",
                     "before the 90 days are up and confirms it early. "),
       count_of = paste0("every DEATH line directly after a confirmed-stop line - the ",
                           "exact shape."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      INNER JOIN {t$long} p ON p.PATID = l.PATID AND p.LOT_NUM = l.LOT_NUM - 1
      WHERE l.LOT_BASE_END_REASON = 'DEATH'
        AND p.LOT_BASE_END_REASON = 'DISCONTINUATION'
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S26", group = "Transplants",
       title = "Two transplants just over six months apart",
       story = paste0("A patient's drug runs out after three weeks. They have a ",
                      "transplant on day 40 and another one 181 days later. "),
       outcome = paste0("Two lines. Just over six months is too long to count as one ",
                        "planned pair, so the second transplant is treated as new treatment ",
                        "and opens a line of its own. "),
       patient = list(meds = "LEN:IMID:0:19", auto = "40,221"),
       timeline = c("LEN   cover d0-d19",
                    "AUTO  d40    - inside the 60-day window",
                    "AUTO  d221   - 181 days after the first"),
       lines = c("LOT1  d0-d40      MED       SCT_AUTO_CONT  regimen LEN",
                 "LOT2  d221-d1200  SCT_AUTO  STUDY_END      regimen (none)"),
       rule = "LOT_RULES.md 6.3",
       note = paste0("sct_tandem_days is 180 and the test is <= 180, so 181 falls ",
                     "outside. S10 is the same patient at 179 days and gets one line. "),
       count_of = paste0("every transplant opening a line more than 180 days after the ",
                           "one before it - the exact rule population."),
       sql = "
      WITH paired AS (
        SELECT PATID, TX_DT,
               lag(TX_DT) OVER (PARTITION BY PATID ORDER BY TX_DT) AS PREV_TX_DT
        FROM {t$auto}
      )
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM paired p
      INNER JOIN {t$long} l
         ON l.PATID = p.PATID AND l.LOT_START_DT = p.TX_DT
      WHERE p.PREV_TX_DT IS NOT NULL
        AND datediff(p.TX_DT, p.PREV_TX_DT) > {tandem_days}
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S27", group = "Transplants",
       title = "Three transplants: a planned pair, then a third much later",
       story = paste0("A patient has two transplants 100 days apart, and a third one more ",
                      "than a year after that. "),
       outcome = paste0("Two lines. The first two count as one planned pair and stay on the ",
                        "first line. The third is far too late to join them, so it opens a ",
                        "new line. "),
       patient = list(meds = "LEN:IMID:0:19", auto = "40,140,440"),
       timeline = c("LEN   cover d0-d19",
                    "AUTO  d40",
                    "AUTO  d140   - 100 days after the first",
                    "AUTO  d440   - 300 days after the second"),
       lines = c("LOT1  d0-d140     MED       SCT_AUTO_CONT  regimen LEN",
                 "LOT2  d440-d1200  SCT_AUTO  STUDY_END      regimen (none)"),
       rule = "LOT_RULES.md 6.3, 6.5",
       note = paste0("The pair is judged on consecutive transplants, so the third is ",
                     "measured against the second and not against the first. The line is ",
                     "held open to the second, which is where it ends. "),
       count_of = paste0("every patient with three or more transplants, by line - ",
                           "wider than the worked spacing."),
       sql = "
      WITH n AS (
        SELECT PATID, count(*) AS N_AUTO FROM {t$auto} GROUP BY PATID HAVING count(*) >= 3
      )
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM n INNER JOIN {t$long} l ON l.PATID = n.PATID
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  list(id = "S28", group = "Transplants",
       title = "A transplant before any treatment in the data",
       story = paste0("A patient has a stem cell transplant on day 20, and their first ",
                      "myeloma drug does not appear until day 100. "),
       outcome = paste0("One line, starting at the drug. The transplant is before the first ",
                        "line begins, so it belongs to no line. That is expected rather ",
                        "than a fault - the transplant came before the patient's first ",
                        "qualifying myeloma drug, so before any line exists. "),
       patient = list(meds = "LEN:IMID:100:300", auto = "20"),
       timeline = c("AUTO  d20    - before any drug in the data",
                    "LEN   cover d100-d300"),
       lines = c("LOT1  d100-d300  MED  DISCONTINUATION  regimen LEN"),
       rule = "LOT_RULES.md 3.1",
       note = paste0("The first line starts at the first non-steroid agent, so nothing ",
                     "before that date can be inside a line. Counts of unowned ",
                     "transplants exclude this shape for that reason. "),
       count_of = paste0("every patient with a transplant before their first line - ",
                           "the exact rule population."),
       sql = "
      WITH first_line AS (
        SELECT PATID, min(LOT_START_DT) AS FIRST_START FROM {t$long} GROUP BY PATID
      )
      SELECT 1 AS LOT_NUM, count(DISTINCT x.PATID) AS N_PATIENTS
      FROM {t$auto} x
      INNER JOIN first_line f ON f.PATID = x.PATID
      WHERE x.TX_DT < f.FIRST_START"),

  list(id = "S29", group = "A drug that comes back",
       title = "A biosimilar of the drug the line was built on",
       story = paste0("A patient is on daratumumab for three months. Three months after ",
                      "it stops they start a biosimilar version of the same drug. "),
       outcome = paste0("One line. A permitted biosimilar swap never counts as new ",
                        "treatment, so it does not open a line - even though the patient ",
                        "was off the drug for 90 days, which for the original drug would ",
                        "have been enough. The line runs on to the end of the biosimilar's ",
                        "supply. "),
       patient = list(meds = "DARA:MAB:0:100; DARAB:MAB:190:300", subs = "DARA:DARAB"),
       timeline = c("DARA   cover d0-d100",
                    "DARAB  cover d190-d300   - a permitted biosimilar of DARA, 90 days later"),
       lines = c("LOT1  d0-d300  MED  DISCONTINUATION  regimen DARA"),
       rule = "LOT_RULES.md 4.4",
       note = paste0("A substitute is never released by a gap, however long. ",
                     "discon_per_med sets PREV_DISCON to 0 for a substitute-only drug, ",
                     "and the prior-regimen exclusion holds it unconditionally. Compare ",
                     "S06, where the same 90-day gap on the original drug opens a second ",
                     "line. "),
       sql = NULL,
       sql_note = "permissible_subs is loaded from CSV into a session view and is never written to the warehouse, so a finished run cannot be asked which agents were substitutes"),

  list(id = "S30", group = "A drug that comes back",
       title = "A biosimilar of a drug from two lines back",
       story = paste0("A patient is on daratumumab, changes to lenalidomide, and later ",
                      "starts a biosimilar of the daratumumab. "),
       outcome = paste0("Three lines. The biosimilar opens the third line, because the rule ",
                        "that would have blocked it only looks at the line immediately ",
                        "before - and that line was lenalidomide. Same shape as S01 and ",
                        "S02. "),
       patient = list(meds = "DARA:MAB:0:100; LEN:IMID:90:200; DARAB:MAB:250:400", subs = "DARA:DARAB"),
       timeline = c("DARA   cover d0-d100",
                    "LEN    cover d90-d200",
                    "DARAB  cover d250-d400"),
       lines = c("LOT1  d0-d89     MED  MED_ADD          regimen DARA",
                 "LOT2  d90-d200   MED  DISCONTINUATION  regimen LEN",
                 "LOT3  d250-d400  MED  DISCONTINUATION  regimen DARAB"),
       rule = "LOT_RULES.md 4.4, 4.1",
       note = paste0("The substitute exclusion is built from the PREVIOUS line's ",
                     "regimen. A substitute for a drug two lines back is not in that ",
                     "set, so nothing stops it. S29 is the same swap one line earlier, ",
                     "and gets one line. "),
       sql = NULL,
       sql_note = "permissible_subs is never written to the warehouse - see S29"),

  list(id = "S31", group = "CAR-T",
       title = "A CAR-T line with a drug started after it",
       story = paste0("A patient has CAR-T therapy on day 100, and starts pomalidomide 20 ",
                      "days later. "),
       outcome = paste0("Two lines. The CAR-T closes the first line and opens a CAR-T line. ",
                        "The pomalidomide starts inside that line's 45-day window, so it ",
                        "joins its drug list and the line runs on until the drug stops. "),
       patient = list(meds = "LEN:IMID:0:200; POMA:IMID:120:400", ac = "CART:100"),
       timeline = c("LEN   cover d0-d200",
                    "CART  d100",
                    "POMA  cover d120-d400   - 20 days after the CAR-T, inside its 45-day window"),
       lines = c("LOT1  d0-d99     MED   SCT_CART         regimen LEN",
                 "LOT2  d100-d400  CART  DISCONTINUATION  regimen POMA"),
       rule = "LOT_RULES.md 4.2, 6.4",
       note = paste0("A CAR-T-started line collects its regimen over 45 days rather than ",
                     "30. S13 is the same CAR-T with nothing started after it, and that ",
                     "line lasts a single day. "),
       count_of = paste0("every CAR-T-started line with at least one drug on its list ",
                           "- the exact rule population."),
       sql = "
      SELECT l.LOT_NUM, count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_START_TYPE = 'CART' AND l.LOT_MED_CNT > 0
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM")
)
