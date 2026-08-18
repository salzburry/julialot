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
                     "no new start behind. This is open question 1 in ",
                     "KNOWN_ISSUES.md."),
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
       sql = "
      WITH lot1 AS (SELECT PATID, LOT_START_DT FROM {t$long} WHERE LOT_NUM = 1)
      SELECT 1 AS LOT_NUM, count(DISTINCT s.PATID) AS N_PATIENTS
      FROM {t$sct} s
      INNER JOIN lot1 l ON l.PATID = s.PATID
      WHERE s.FIRST_CART_DT IS NOT NULL
        AND s.FIRST_CART_DT BETWEEN l.LOT_START_DT
                                AND date_add(l.LOT_START_DT, {lot1_window} - 1)"),

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
                     "carries d100. This is open question 2 in KNOWN_ISSUES.md."),
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
       sql = "
      SELECT count(DISTINCT m.PATID) AS N_PATIENTS, 0 AS LOT_NUM
      FROM {t$map} m
      WHERE m.MAP_MED_CLASS = 'STEROID'
        AND NOT EXISTS (SELECT 1 FROM {t$long} l
                        WHERE l.PATID = m.PATID
                          AND m.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)")
)
