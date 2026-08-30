# The checks, as data.
#
# One list, one entry per check, each carrying the SQL that finds violations.
# Kept apart from the runner so the catalogue can be read - and tested - without
# a connection.
#
# Every check answers the same shape: N_BAD, and DETAIL naming one example.
# N_BAD = 0 is a pass. That uniformity is what lets the runner treat them all
# alike and lets the tests check them all alike.
#
# severity:
#   fail   the algorithm's own definition says this cannot happen. A non-zero
#          count is a defect in the build, not a property of the data.
#   warn   worth a human's eye. Real data can produce it.
#   info   counted and reported, never scored. These are the numbers that say
#          how much a documented ambiguity actually costs on this cohort.
#
# Patient ids are masked everywhere they appear. A QC report gets circulated.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Last six characters, lower case - enough to find the row again in the
# warehouse, not enough to be an identifier on its own. Same masking the
# dashboard uses.
MASK_PATID <- "concat('...', lower(substr(cast(%s as string), greatest(length(cast(%s as string)) - 5, 1))))"
mask <- function(col) sprintf(MASK_PATID, col, col)

# A one-row answer from a query that may match nothing. Wrapping the body in a
# subquery and aggregating outside it means an empty match gives 0 and NULL
# rather than no row at all, which the runner would have to special-case.
counted <- function(body, detail = "NULL") {
  paste0("SELECT count(*) AS N_BAD, max(", detail, ") AS DETAIL FROM (\n",
         body, "\n) q")
}

# The days a line may take a regimen drug from, as the induction step bounds
# them - the induction window AND the transplant cutoff, whichever is earlier.
#
# One definition because C1 and C4 ask opposite directions of the same set, and
# two copies of a window is how the two stop describing the same rule. C1 asked
# the window alone, which is the weaker half: a regimen drug whose episode
# started after the transplant that ended the line is still inside the nominal
# 30, 45 or 60 days, so C1 passed on exactly the shape REGIMEN_CUTOFF_DT was
# added to prevent.
#
# The cutoff is read the way 04_lot1_base.R and 10_lot2_5_base.R build it. LOT1
# takes an allograft from its start date, and takes a CAR-T only where the
# induction exemption is off - with the rule on, an in-window CAR-T is part of
# LOT1 and cuts nothing. Later lines take both, and only strictly after their
# own start, so the transplant that STARTED the line is not a cutoff on it.
# Floored at the line start, so a transplant on day one leaves a one-day window
# rather than one that closes before it opens.
#
# per_line = TRUE gives one row per line (`lines`); FALSE gives one row per
# line and regimen drug (`reg`).
qc_window_sql <- function(t, p, per_line = FALSE) {
  cutoff <- paste0("
    cut AS (
      SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM,
             min(greatest(l.LOT_START_DT, date_sub(x.TX_DT, 1))) AS CUTOFF_DT
      FROM ", t$final, " l
      INNER JOIN ", t$allo, " x ON cast(x.PATID as string) = cast(l.PATID as string)
      WHERE (l.LOT_NUM = 1  AND x.TX_DT >= l.LOT_START_DT
             AND (x.SCT_TYPE = 'ALLO'
                  OR ", if (isTRUE(p$cart_exempt)) "1 = 0" else "x.SCT_TYPE = 'CART'", "))
         OR (l.LOT_NUM  > 1 AND x.TX_DT >  l.LOT_START_DT)
      GROUP BY cast(l.PATID as string), l.LOT_NUM
    ),")
  win <- paste0("
             least(
               date_add(l.LOT_START_DT,
                 CASE WHEN l.LOT_NUM = 1             THEN ", p$ind1 - 1, "
                      WHEN l.LOT_START_TYPE = 'CART' THEN ", p$cart - 1, "
                      ELSE                                ", p$indn - 1, " END),
               coalesce(c.CUTOFF_DT, cast('9999-12-31' as date))) AS ELIGIBLE_END")
  if (per_line)
    paste0(cutoff, "
    lines AS (
      SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM, l.LOT_START_DT,
             l.LOT_START_TYPE, l.LOT_BASE_MEDS,", win, "
      FROM ", t$final, " l
      LEFT JOIN cut c ON c.PATID = cast(l.PATID as string) AND c.LOT_NUM = l.LOT_NUM
    )")
  else
    paste0(cutoff, "
    reg AS (
      SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM, l.LOT_START_DT,
             l.LOT_BASE_END_DT, l.LOT_START_TYPE, m AS MED_ABBR,", win, "
      FROM ", t$final, " l
      LEFT JOIN cut c ON c.PATID = cast(l.PATID as string) AND c.LOT_NUM = l.LOT_NUM
      LATERAL VIEW explode(split(coalesce(l.LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    )")
}

# The returning-drug exemption. C2's `why` states the rule and why the lag has
# to be the immediately-preceding episode; this is the one copy of the SQL.
#
# One definition for the same reason qc_window_sql() has one: C2 and C3 both
# lean on this exemption, and two copies of a rule is how the two stop
# describing the same rule. They were still byte-identical when this was
# extracted, which is the moment to do it rather than after they have drifted.
#
# No leading newline or indent, so each call site keeps its own layout and the
# emitted SQL is byte-identical to the two copies this replaced.
qc_restart_sql <- function(t) paste0("restart AS (
      SELECT cast(PATID as string) AS PATID, MAP_MED_TYPE, MAP_START_DT,
             coalesce(lag(MAP_DISCON_FLG) OVER (PARTITION BY PATID, MAP_MED_TYPE
                                    ORDER BY MAP_START_DT), 0) AS PREV_DISCON
      FROM ", t$map, "
    )")

LOT_QC_CHECKS <- list(

  # ---- A. Line structure ---------------------------------------------------
  # check_lot_long already refuses null dates, ends before starts, duplicate
  # (PATID, LOT_NUM), lines outside 1..max_lot, non-contiguous line numbers,
  # a line starting on or before the previous one's end, and a line ending
  # after observation. None of that is repeated here. These are the ones it
  # does not make.

  list(id = "A1", group = "Structure", severity = "fail",
       what = "LOT_BASE_LENGTH is the span its own dates describe",
       why = paste0("The build computes reason, end date and length as three ",
                    "separate CASE cascades over the same branches, because SQL ",
                    "cannot reference a sibling alias. Three copies that must ",
                    "agree is exactly where one gets edited and the others do ",
                    "not, and nothing in the build compares them."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM, LOT_BASE_LENGTH,
           datediff(LOT_BASE_END_DT, LOT_START_DT) + 1 AS want
    FROM ", t$final, "
    WHERE LOT_BASE_LENGTH <> datediff(LOT_BASE_END_DT, LOT_START_DT) + 1"),
    "concat(pid, ' LOT', LOT_NUM, ': length ', LOT_BASE_LENGTH, ', dates say ', want)")),

  list(id = "A2", group = "Structure", severity = "fail",
       what = "the CE sensitivity end never falls after the primary end",
       why = paste0("LOT_BASE_END_DT_CE_SENS caps the primary end at ENDDATE_CE. ",
                    "A cap can only pull a date earlier, so later means the ",
                    "column was built from something other than the line it ",
                    "sits on."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_END_DT_CE_SENS > LOT_BASE_END_DT"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "A3", group = "Structure", severity = "fail",
       what = "DISENROLLMENT appears only where the CE cap actually moved the date",
       why = paste0("DISENROLLMENT is not reachable in the primary cascade - ",
                    "disenrollment is not a censoring criterion - so it exists ",
                    "only in the CE column, and only when the cap bit. Anywhere ",
                    "else it is a reason nothing produced."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON_CE_SENS = 'DISENROLLMENT'
      AND NOT (LOT_BASE_END_DT_CE_SENS < LOT_BASE_END_DT)"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "A4", group = "Structure", severity = "fail",
       what = "line 1 is medication-started",
       why = paste0("LOT1 starts at the first non-steroid agent, so its start ",
                    "type is written as MED and never derived. The post-runout ",
                    "guard in the LOT1 end step relies on that: it applies the ",
                    "window the next line's AUTO rule would apply to a ",
                    "MED-started predecessor, which for LOT1 is LOT1's OWN 60 ",
                    "days. It read 30 once - the later-line window - and that ",
                    "left the guard short of the range LOT1 actually owns a ",
                    "transplant over."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$final, "
    WHERE LOT_NUM = 1 AND LOT_START_TYPE <> 'MED'"), "pid")),

  list(id = "A5", group = "Structure", severity = "fail",
       what = "LOT_START_TYPE is one of the four the build can write",
       why = "A fifth value means a branch nothing downstream knows how to read.",
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT DISTINCT LOT_START_TYPE AS v
    FROM ", t$final, "
    WHERE LOT_START_TYPE IS NULL
       OR LOT_START_TYPE NOT IN ('MED', 'SCT_ALLO', 'SCT_AUTO', 'CART')"),
    "coalesce(v, '(null)')")),

  list(id = "A6", group = "Structure", severity = "fail",
       what = "LOT_MED_CNT is the size of the regimen string",
       why = paste0("Both come off the same induction rows - a count and a ",
                    "sorted concat of the same set. They can only disagree if ",
                    "one was built over a different set."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM, LOT_MED_CNT,
           CASE WHEN trim(coalesce(LOT_BASE_MEDS, '')) = '' THEN 0
                ELSE size(split(trim(LOT_BASE_MEDS), ' ')) END AS want
    FROM ", t$final, "
    WHERE coalesce(LOT_MED_CNT, -1) <>
          CASE WHEN trim(coalesce(LOT_BASE_MEDS, '')) = '' THEN 0
               ELSE size(split(trim(LOT_BASE_MEDS), ' ')) END"),
    "concat(pid, ' LOT', LOT_NUM, ': count ', LOT_MED_CNT, ', string has ', want)")),

  list(id = "A7", group = "Structure", severity = "fail",
       what = "a medication-started line has a regimen",
       why = paste0("The real invariant is narrow: a line started by a DRUG ",
                    "must carry that drug. Its regimen window opens on the ",
                    "line's own start date, and that is the date the starting ",
                    "drug's episode begins, so an empty regimen there is a ",
                    "line whose own starting drug did not reach it. ",
                    "Every OTHER start type may legitimately be empty, and the ",
                    "check asks only about 'MED' rather than listing them. An ",
                    "ALLO line is empty by construction - the induction step ",
                    "suppresses its rows. A CAR-T line is empty when no ",
                    "consolidation drug arrives in its window. And an ",
                    "AUTO-started line is empty when no drug starts in its ",
                    "30 days, which is a shape the build really produces. ",
                    "Naming the allowed start types instead would fail on it: ",
                    "leave SCT_AUTO off the list and a transplant that opened ",
                    "a later line with no drug behind it reads as a defect. ",
                    "So this asks about 'MED' rather than listing the rest. ",
                    "A5 pins LOT_START_TYPE to its four ",
                    "values, so a new one cannot arrive here unannounced."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM, LOT_START_TYPE
    FROM ", t$final, "
    WHERE trim(coalesce(LOT_BASE_MEDS, '')) = ''
      AND LOT_START_TYPE = 'MED'"),
    "concat(pid, ' LOT', LOT_NUM, ' started by ', LOT_START_TYPE)")),

  # ---- B. End reason against end date --------------------------------------
  # The reason and the date are two cascades over the same branches. Each check
  # below takes one branch and asserts the pair a reader would infer from it.

  list(id = "B1", group = "End reason", severity = "fail",
       what = "MED_ADD ends on the added medication's date",
       why = "Any other date means the two cascades took different branches.",
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON = 'MED_ADD'
      AND (LOT_BASE_1ST_ADD_MED_DT IS NULL
           OR LOT_BASE_END_DT <> LOT_BASE_1ST_ADD_MED_DT)"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B2", group = "End reason", severity = "fail",
       what = "DISCONTINUATION ends on the run-out date",
       why = "Same reasoning as B1, on the discontinuation branch.",
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON = 'DISCONTINUATION'
      AND (LOT_BASE_DISCON_DT IS NULL
           OR LOT_BASE_END_DT <> LOT_BASE_DISCON_DT)"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B3", group = "End reason", severity = "fail",
       what = "DEATH ends on the death date, inside observation",
       why = paste0("DEATH is the one branch that can outrank an earlier ",
                    "discontinuation, so it is the branch most worth pinning to ",
                    "its own date."),
       needs = c("final", "cohort"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("l.PATID"), " AS pid, l.LOT_NUM
    FROM ", t$final, " l
    INNER JOIN ", t$cohort, " c ON cast(l.PATID as string) = cast(c.PATID as string)
    WHERE l.LOT_BASE_END_REASON = 'DEATH'
      AND (c.DEATH_DT IS NULL
           OR l.LOT_BASE_END_DT <> cast(c.DEATH_DT as date)
           OR cast(c.DEATH_DT as date) > ", p$obs_end, ")"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B4", group = "End reason", severity = "fail",
       what = "STUDY_END ends at the observation end",
       why = paste0("STUDY_END is the fall-through: nothing ended the line, so ",
                    "it runs to the end of what can be seen. A different date ",
                    "means something did end it and was not recorded."),
       needs = c("final", "cohort"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("l.PATID"), " AS pid, l.LOT_NUM
    FROM ", t$final, " l
    INNER JOIN ", t$cohort, " c ON cast(l.PATID as string) = cast(c.PATID as string)
    WHERE l.LOT_BASE_END_REASON = 'STUDY_END'
      AND l.LOT_BASE_END_DT <> ", p$obs_end),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B5", group = "End reason", severity = "fail",
       what = "the end reason is one the build can write",
       why = paste0("The enum here is what the build writes - nothing ",
                    "produces SUBSTITUTION or MAINTENANCE_END, and CART_INIT ",
                    "is produced. ",
                    "This check is what makes that concrete rather than a ",
                    "reading of the code."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT DISTINCT LOT_BASE_END_REASON AS v
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON IS NULL
       OR LOT_BASE_END_REASON NOT IN
          ('SCT_AUTO', 'SCT_AUTO_CONT', 'SCT_ALLO', 'SCT_CART', 'SCT',
           'CART_INIT', 'MED_ADD', 'DEATH', 'DISCONTINUATION', 'STUDY_END')"),
    "coalesce(v, '(null)')")),

  list(id = "B5b", group = "End reason", severity = "fail",
       what = "SCT_AUTO_CONT ends on the transplant date itself",
       why = paste0("The other two AUTO-shaped reasons end the line the day ",
                    "BEFORE their transplant, because there the transplant ",
                    "starts the next line. SCT_AUTO_CONT is the opposite case - ",
                    "the transplant belongs to this line and closes it - so an ",
                    "off-by-one here is the difference between the two rules, ",
                    "not a rounding error."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON = 'SCT_AUTO_CONT'
      AND (LOT_TX_AUTO_MAX_DT IS NULL
           OR LOT_BASE_END_DT <> LOT_TX_AUTO_MAX_DT)"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B5c", group = "End reason", severity = "fail",
       what = "a line covers every transplant inside its own window",
       why = paste0("This is the shape SCT_AUTO_CONT exists to prevent: a line ",
                    "that ends before a transplant inside its own window leaves ",
                    "that transplant in no line, because the next line's start ",
                    "gate refuses it for being in-window. Read from ",
                    "TX_AUTO_DATES - every processed autologous event, before ",
                    "any line claims one. The per-line SCT tables cannot answer ",
                    "this: an AUTO outside a line's window is stored as ",
                    "ENDING_AUTO_DT and never as TX_AUTO_DT_1, so a check over ",
                    "those columns cannot see it and would report clean. Read ",
                    "against LOT_LONG, not the published table, so a line ",
                    "dropped by the line criteria does not read as a missing ",
                    "one. ",
                    "One transplant is not the line's to cover: the build stops ",
                    "reading a line's AUTOs at the first allogeneic or CAR-T ",
                    "event, so an AUTO after one of those is not an orphan but ",
                    "a transplant the line was never asked to hold open. The ",
                    "same censor is applied here - and from the same day the ",
                    "build applies it. LOT1 censors from its start date; LOT2 ",
                    "and later censor from the day AFTER, so the transplant ",
                    "that STARTED the line is not read as a censor on it. ",
                    "Taking the LOT1 rule everywhere switched this check off ",
                    "for every CAR-T-started and allograft-started line: the ",
                    "start event sits on the start date, so it censored every ",
                    "later AUTO and the check could not fire. That is the one ",
                    "shape where an orphan is most likely, because a CAR-T ",
                    "line with no consolidation ends on its own start date and ",
                    "its whole window sits after the end."),
       needs = c("long", "auto", "allo"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("a.PATID"), " AS pid, l.LOT_NUM, a.TX_DT AS tx
    FROM ", t$auto, " a
    INNER JOIN ", t$long, " l ON a.PATID = l.PATID
    WHERE a.TX_DT BETWEEN l.LOT_START_DT
                      AND date_add(l.LOT_START_DT,
                            CASE l.LOT_START_TYPE
                              WHEN 'SCT_ALLO' THEN 0
                              WHEN 'CART'     THEN ", p$cart, " - 1
                              ELSE CASE WHEN l.LOT_NUM = 1 THEN ", p$ind1, " - 1
                                        ELSE ", p$indn, " - 1 END
                            END)
      AND a.TX_DT > l.LOT_BASE_END_DT
      AND NOT EXISTS (
        SELECT 1 FROM ", t$allo, " x
        WHERE x.PATID = a.PATID
          AND x.SCT_TYPE IN ('ALLO', 'CART')
          AND ((l.LOT_NUM = 1  AND x.TX_DT >= l.LOT_START_DT)
            OR (l.LOT_NUM  > 1 AND x.TX_DT >  l.LOT_START_DT))
          AND x.TX_DT <= a.TX_DT",
      # An in-induction CAR-T is part of LOT1 and does not censor - the build
      # keeps reading LOT1's AUTOs past it, so this check must too. It is the
      # only exemption, and it is LOT1's alone.
      if (isTRUE(p$cart_exempt)) paste0("
          AND NOT (x.SCT_TYPE = 'CART' AND l.LOT_NUM = 1
                   AND x.TX_DT <= date_add(l.LOT_START_DT, ", p$ind1 - 1L, "))") else "", ")"),
    "concat(pid, ' LOT', LOT_NUM, ' @ ', tx)")),

  list(id = "B6", group = "End reason", severity = "fail",
       what = "the added-medication date is not before the line started",
       why = paste0("It is the day before the added drug's first MAP, and that ",
                    "MAP is taken from the line's own span - so the subtraction ",
                    "can only land before the start if the candidate window let ",
                    "in something on the start date itself. The transplant ",
                    "branch has an explicit floor for this case; this branch has ",
                    "none."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_1ST_ADD_MED_DT IS NOT NULL
      AND LOT_BASE_1ST_ADD_MED_DT < LOT_START_DT"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B7", group = "End reason", severity = "fail",
       what = "the run-out date is not before the line started",
       why = "Same shape as B6, on the discontinuation date.",
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$final, "
    WHERE LOT_BASE_DISCON_DT IS NOT NULL
      AND LOT_BASE_DISCON_DT < LOT_START_DT"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "B8", group = "End reason", severity = "fail",
       what = "unconfirmed discontinuations, which should be none",
       why = paste0("A run-out counts as a discontinuation only once it is ",
                    "confirmed: either LOT_DISCON_CONFIRM_DAYS of observation ",
                    "follow it, or the patient came back and opened the next ",
                    "line. Anything else is censored at observation end, ",
                    "because in a real-world claims study a patient we stop ",
                    "seeing fills for has not necessarily stopped treatment. ",
                    "So a DISCONTINUATION inside the window is fine when a ",
                    "later line exists, and a defect when none does - the ",
                    "buffer should have censored that one. Lines at the ",
                    "max_lot cap are exempt: the build stops there, so the ",
                    "confirming line would not have been built either way."),
       needs = c("final", "cohort"),
       sql = function(t, p) counted(paste0("
    SELECT pid, LOT_NUM, days_left
    FROM (
      SELECT ", mask("l.PATID"), " AS pid,
             l.LOT_NUM,
             l.LOT_BASE_END_REASON AS reason,
             datediff(", p$obs_end, ", l.LOT_BASE_END_DT) AS days_left,
             max(l.LOT_NUM) OVER (PARTITION BY l.PATID) AS LAST_LOT_NUM
      FROM ", t$final, " l
      INNER JOIN ", t$cohort, " c ON cast(l.PATID as string) = cast(c.PATID as string)
    ) x
    WHERE reason = 'DISCONTINUATION'
      AND days_left < ", p$confirm, "
      AND LOT_NUM = LAST_LOT_NUM
      AND LOT_NUM < ", p$max_lot),
    "concat(pid, ' LOT', LOT_NUM, ': ', days_left, ' days of follow-up after run-out, and no later line')")),

  list(id = "B9", group = "End reason", severity = "info",
       what = "deaths outranking an earlier run-out",
       why = paste0("The spec ends a line at the earliest of its ending events, ",
                    "with the priority order only breaking same-day ties - and ",
                    "in that tie-break death ranks below discontinuation. The ",
                    "build instead lets a death outrank an earlier run-out when ",
                    "nothing between the two would have started the next line. ",
                    "These are the lines where the two readings give different ",
                    "answers: under the spec's letter they end DISCONTINUATION ",
                    "at the run-out date, here they end DEATH."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM,
           datediff(LOT_BASE_END_DT, LOT_BASE_DISCON_DT) AS days_apart
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON = 'DEATH'
      AND LOT_BASE_DISCON_DT IS NOT NULL
      AND LOT_BASE_DISCON_DT < LOT_BASE_END_DT"),
    "concat(pid, ' LOT', LOT_NUM, ': death ', days_apart, ' days after run-out')")),

  # ---- C. Regimen against the claims ---------------------------------------

  list(id = "C1", group = "Regimen", severity = "fail",
       what = "every drug in a regimen has a treatment episode inside its line",
       why = paste0("This is the regimen rule itself, asked backwards. The ",
                    "window is the line's own: 60 days at LOT1, 45 for a CAR-T ",
                    "started line, 30 otherwise. A drug with no episode in it ",
                    "reached the regimen some other way. ",
                    "With the fold-in on one route is legitimate: a previous ",
                    "line's drug returning after the window joins this line's ",
                    "regimen (LOT_RULES.md 4.8), and its episode is inside the ",
                    "LINE rather than the window. The accepted range ends at ",
                    "the line's end there - but only for a drug the PREVIOUS ",
                    "line carried, which is what a fold requires. A drug that ",
                    "is neither in the window nor a previous-line agent got ",
                    "into the regimen some other way and is still caught. ",
                    "A permissible substitute and the drug it replaces are ",
                    "ONE agent, in both directions (4.4), so the previous ",
                    "line carrying either counts as carrying the other. ",
                    "Matching the reported name alone failed a folded ",
                    "biosimilar whose previous line named the reference ",
                    "product - a fail on valid output."),
       needs = c("final", "map", "allo", "subs"),
       sql = function(t, p) counted(paste0("
    WITH ", qc_window_sql(t, p), ",
    -- Every name this drug could wear in the previous line's regimen: itself,
    -- the drug it stands in for, and the substitutes that stand in for it.
    -- Both directions, because 4.4 makes the pair one agent whichever half a
    -- line happens to report.
    w_alias AS (
      SELECT PATID, LOT_NUM, MED_ABBR, MED_ABBR AS ALIAS FROM reg
      UNION ALL
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, s.original_med
      FROM reg w INNER JOIN ", t$subs, " s ON s.substitute_med = w.MED_ABBR
      UNION ALL
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, s.substitute_med
      FROM reg w INNER JOIN ", t$subs, " s ON s.original_med = w.MED_ABBR
    ),
    prev_carried AS (
      SELECT DISTINCT a.PATID, a.LOT_NUM, a.MED_ABBR
      FROM w_alias a
      INNER JOIN ", t$final, " pl
        ON cast(pl.PATID as string) = a.PATID AND pl.LOT_NUM = a.LOT_NUM - 1
      WHERE array_contains(split(coalesce(pl.LOT_BASE_MEDS, ''), ' '), a.ALIAS)
    )
    SELECT ", mask("w.PATID"), " AS pid, w.LOT_NUM, w.MED_ABBR
    FROM reg w
    LEFT JOIN ", t$map, " ms
      ON cast(ms.PATID as string) = w.PATID
     AND ms.MAP_MED_TYPE = w.MED_ABBR
     AND ms.MAP_START_DT >= w.LOT_START_DT
     AND ms.MAP_START_DT <= ",
       if (isTRUE(p$foldin)) "greatest(w.ELIGIBLE_END, w.LOT_BASE_END_DT)"
       else "w.ELIGIBLE_END", "
    WHERE ms.PATID IS NULL",
    # ...and the wider range is allowed only where a fold could have put the
    # drug there: it has to be an agent of the line BEFORE this one. Widening
    # for every regimen drug would have let unrelated post-induction pollution
    # through, since anything inside the line would pass.
    if (!isTRUE(p$foldin)) "" else paste0("
       OR NOT EXISTS (
            SELECT 1 FROM prev_carried pc
            WHERE pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM
              AND pc.MED_ABBR = w.MED_ABBR)
          AND NOT EXISTS (
            SELECT 1 FROM ", t$map, " ms2
            WHERE cast(ms2.PATID as string) = w.PATID
              AND ms2.MAP_MED_TYPE = w.MED_ABBR
              AND ms2.MAP_START_DT >= w.LOT_START_DT
              AND ms2.MAP_START_DT <= w.ELIGIBLE_END)")),
    "concat(pid, ' LOT', LOT_NUM, ': ', MED_ABBR, ' has no episode in the line')")),

  list(id = "C4", group = "Regimen", severity = "fail",
       what = "an eligible episode in the window reached the regimen",
       why = paste0("C1 asked one direction only: every drug IN the regimen has ",
                    "an episode that could have put it there. It says nothing ",
                    "about a drug the window should have admitted and did not. ",
                    "Both halves pass on a regimen that is missing the drug ",
                    "which STARTED the line - C1 because the drugs listed are ",
                    "all eligible, A7 because the string is not empty. This is ",
                    "the other direction. ",
                    "Eligible means what the induction step means by it: a ",
                    "non-steroid episode starting on or after the line start and ",
                    "on or before the earlier of the induction window and the ",
                    "transplant cutoff. Every such episode's drug has to appear ",
                    "in LOT_BASE_MEDS. ",
                    "ALLO lines are out of scope, and by construction rather ",
                    "than by exception - the induction step suppresses their ",
                    "regimen rows, so the eligible set is empty for them too."),
       needs = c("final", "map", "allo"),
       sql = function(t, p) counted(paste0("
    WITH ", qc_window_sql(t, p, per_line = TRUE), "
    SELECT ", mask("l.PATID"), " AS pid, l.LOT_NUM, ms.MAP_MED_TYPE AS med
    FROM lines l
    INNER JOIN ", t$map, " ms
      ON cast(ms.PATID as string) = l.PATID
     AND ms.MAP_START_DT >= l.LOT_START_DT
     AND ms.MAP_START_DT <= l.ELIGIBLE_END
    WHERE l.LOT_START_TYPE <> 'SCT_ALLO'
      AND ms.MAP_MED_CLASS <> 'STEROID'
      AND NOT array_contains(split(coalesce(l.LOT_BASE_MEDS, ''), ' '),
                             ms.MAP_MED_TYPE)"),
    "concat(pid, ' LOT', LOT_NUM, ': ', med, ' was eligible and is not in the regimen')")),

  list(id = "C2", group = "Regimen", severity = "fail",
       what = "the added medication is not already in the regimen, unless it returned",
       why = paste0("An added medication is normally one the regimen does not ",
                    "contain. Where it does, the candidate query and the ",
                    "regimen disagree about what the regimen is. ",
                    "The exception is a rule, not a tolerance. A regimen drug ",
                    "whose own episode carried a confirmed discontinuation and ",
                    "which then restarts ends the line like any other drug ",
                    "would (LOT_RULES.md 11.1, prior_regimen.R). That drug IS ",
                    "in the regimen and IS the added medication, both correctly. ",
                    "This check predates that rule and was not moved with it, so ",
                    "it failed every returning-drug line - eleven of them on a ",
                    "400-patient synthetic run, all eleven a restart after a ",
                    "confirmed gap and none of them a defect. ",
                    "The exemption is read the way the engine reads it: the lag ",
                    "of MAP_DISCON_FLG over that drug's own episodes, so it is ",
                    "the episode IMMEDIATELY before the restart that has to ",
                    "carry the flag. Any-earlier-episode would excuse a drug ",
                    "that discontinued once and has been running since."),
       needs = c("final", "map"),
       sql = function(t, p) counted(paste0("
    WITH ", qc_restart_sql(t), "
    SELECT ", mask("f.PATID"), " AS pid, f.LOT_NUM,
           f.LOT_BASE_1ST_ADD_MED AS med
    FROM ", t$final, " f
    LEFT JOIN restart r
      ON r.PATID = cast(f.PATID as string)
     AND r.MAP_MED_TYPE = f.LOT_BASE_1ST_ADD_MED
     AND r.MAP_START_DT = date_add(f.LOT_BASE_1ST_ADD_MED_DT, 1)
    WHERE f.LOT_BASE_1ST_ADD_MED IS NOT NULL
      AND array_contains(split(coalesce(f.LOT_BASE_MEDS, ''), ' '),
                         f.LOT_BASE_1ST_ADD_MED)
      AND coalesce(r.PREV_DISCON, 0) = 0"),
    "concat(pid, ' LOT', LOT_NUM, ': ', med)")),

  list(id = "C3", group = "Regimen", severity = "info",
       what = "lines where more than one drug could have been the added medication",
       why = paste0("When several non-regimen drugs share the earliest added ",
                    "date the build breaks the tie with rand(42) inside a window ",
                    "ORDER BY. Spark seeds that per partition, so the date is ",
                    "stable across re-runs but the drug is only stable while the ",
                    "physical plan is. This counts how many lines are exposed. ",
                    "Zero means the question never arises on this cohort. ",
                    "Counted over the drugs the engine would ACTUALLY have ",
                    "considered, which is not the same as every drug sharing the ",
                    "date. A steroid can never be a candidate. And a regimen ",
                    "drug normally cannot, but one restarting after a confirmed ",
                    "discontinuation can - so a discontinued LEN returning on the ",
                    "same day a new DARA starts is a genuine two-way tie, and ",
                    "reading LOT_BASE_MEDS alone dropped LEN and reported no tie ",
                    "at all. Both errors ran in the same direction as each other ",
                    "being invisible: one hid a tie, the other invented one. ",
                    "One eligibility rule is still missing, and saying so is ",
                    "cheaper than half-implementing it: a permissible substitute ",
                    "of a regimen drug is excluded by the engine and is counted ",
                    "here, because permissible_subs is not one of the tables this ",
                    "package binds. Info severity, so the number informs and ",
                    "never gates."),
       needs = c("final", "map"),
       sql = function(t, p) counted(paste0("
    WITH add_lines AS (
      SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_BASE_MEDS,
             date_add(LOT_BASE_1ST_ADD_MED_DT, 1) AS ADD_START_DT
      FROM ", t$final, "
      WHERE LOT_BASE_1ST_ADD_MED_DT IS NOT NULL
    ),
    ", qc_restart_sql(t), "
    SELECT ", mask("a.PATID"), " AS pid, a.LOT_NUM,
           count(DISTINCT ms.MAP_MED_TYPE) AS n_tied
    FROM add_lines a
    INNER JOIN ", t$map, " ms
      ON cast(ms.PATID as string) = a.PATID
     AND ms.MAP_START_DT = a.ADD_START_DT
    LEFT JOIN restart r
      ON r.PATID = a.PATID AND r.MAP_MED_TYPE = ms.MAP_MED_TYPE
     AND r.MAP_START_DT = ms.MAP_START_DT
    WHERE ms.MAP_MED_CLASS <> 'STEROID'
      AND (NOT array_contains(split(coalesce(a.LOT_BASE_MEDS, ''), ' '),
                              ms.MAP_MED_TYPE)
           OR coalesce(r.PREV_DISCON, 0) = 1)
    GROUP BY ", mask("a.PATID"), ", a.LOT_NUM
    HAVING count(DISTINCT ms.MAP_MED_TYPE) > 1"),
    "concat(pid, ' LOT', LOT_NUM, ': ', n_tied, ' drugs share the date')")),

  # ---- D. The treatment-episode layer --------------------------------------

  list(id = "D1", group = "Episodes", severity = "fail",
       what = "no episode ends before it starts",
       why = "Re-asked here because the in-build version only reports.",
       needs = "map",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$map, "
    WHERE MAP_END_DT < MAP_START_DT"), "pid")),

  list(id = "D2", group = "Episodes", severity = "fail",
       what = "an episode ends at the later of its two run-out dates",
       why = paste0("MAP_END_DT is defined as that maximum. A mismatch means ",
                    "the state machine closed an episode on something else."),
       needs = "map",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$map, "
    WHERE MAP_END_DT IS NOT NULL
      AND MAP_END_DT <> greatest(
            coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
            coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date)))"), "pid")),

  list(id = "D3", group = "Episodes", severity = "warn",
       what = "episodes carrying a steroid",
       why = paste0("Two spec-consistent states, and this says which one the ",
                    "run is in. The spec keeps steroid claims in the episode ",
                    "data - its own worked example is DEXA - and excludes them ",
                    "from every line decision by class, which the engine does at ",
                    "each decision point. The rollup itself should not carry ",
                    "them either. Zero means the list is clean; a count means the ",
                    "steroid rows are still in the production rollup, and the ",
                    "class filters are what the exclusion is resting on - correct ",
                    "in every current step, but resting on sixteen predicates ",
                    "rather than on the input."),
       needs = "map",
       sql = function(t, p) counted(paste0("
    SELECT DISTINCT MAP_MED_TYPE AS v
    FROM ", t$map, "
    WHERE upper(trim(coalesce(MAP_MED_CLASS, ''))) = 'STEROID'"), "v")),

  list(id = "D4", group = "Episodes", severity = "fail",
       what = "episodes stay inside the patient's observation",
       why = paste0("Claims are filtered to index..observation end before the ",
                    "episodes are built, so an episode starting outside it is a ",
                    "filter that did not hold."),
       needs = c("map", "cohort"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("ms.PATID"), " AS pid
    FROM ", t$map, " ms
    INNER JOIN ", t$cohort, " c ON cast(ms.PATID as string) = cast(c.PATID as string)
    WHERE ms.MAP_START_DT < cast(c.INDEX_DATE as date)
       OR ms.MAP_START_DT > ", p$obs_end), "pid")),

  # ---- E. Transplants ------------------------------------------------------

  # E2 and E3 read LOT_LONG, which carries the per-line transplant columns for
  # EVERY line. They read LOT1_SCT once, which answered them for LOT1 alone -
  # and LOT2-5 has its own SCT implementation in 10_lot2_5_base.R, so proving
  # LOT1 proved nothing about the code that actually builds the later lines. A
  # LOT2 tandem pair 230 days apart with the flag set passed both.
  #
  # E1 cannot follow them, and the reason is worth stating rather than
  # discovering twice. LOT_LONG does not carry the two flags, it DERIVES them:
  # SING is written as "an in-LOT DT_1 that is not a TAND". Both being 1 is
  # unsatisfiable there, so E1 over LOT_LONG is a tautology - it was moved
  # there and stopped being able to fail, at LOT1 as well as later. It reads
  # the raw tables instead.
  list(id = "E1", group = "Transplant", severity = "fail",
       what = "tandem and single autologous flags are mutually exclusive",
       why = paste0("A line is one or the other, and the raw step builds them ",
                    "as two independent CASE expressions rather than as a ",
                    "negation - which is what makes this a question and not an ",
                    "identity. Asked of LOT1_SCT and of each LOT<n>_SCT the run ",
                    "wrote. ",
                    "Asked of the RAW tables on purpose. The published columns ",
                    "in LOT_LONG are derived: the single flag there IS the ",
                    "negation of the tandem flag, so a raw table carrying both ",
                    "at 1 is normalised to TAND=1, SING=0 on the way out and ",
                    "the published row looks clean. ",
                    "The later-line tables are named through the run's own ",
                    "record of which lines it built, because the loop stops at ",
                    "the first line with no patients to roll forward - a run ",
                    "that reached LOT3 wrote no LOT4_SCT, and naming it would ",
                    "skip this check rather than answer it."),
       needs = "sct",
       sql = function(t, p) {
         arms <- c(list(list(tbl = t$sct, n = 1L)),
                   lapply(seq_along(p$sct_extra), function(i)
                     list(tbl = p$sct_extra[[i]], n = as.integer(names(p$sct_extra)[i]))))
         counted(paste(vapply(arms, function(a) paste0("
    SELECT ", mask("PATID"), " AS pid, ", a$n, " AS LOT_NUM
    FROM ", a$tbl, "
    WHERE LOT", a$n, "_SCT_AUTO_TAND_FLG = 1
      AND LOT", a$n, "_SCT_AUTO_SING_FLG = 1"), character(1)),
           collapse = "\n    UNION ALL"),
         "concat(pid, ' LOT', LOT_NUM)")
       }),

  list(id = "E2", group = "Transplant", severity = "fail",
       what = "a tandem pair sits between 60 and 180 days apart",
       why = paste0("The lower bound is enforced upstream, by merging ",
                    "autologous events closer than 60 days into one. The upper ",
                    "bound is the tandem test itself. A pair outside either is a ",
                    "pair one of those two steps should not have produced. ",
                    "Every line, for the reason above E1."),
       needs = "long",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM,
           datediff(LOT_TX_AUTO_DT_2, LOT_TX_AUTO_DT_1) AS gap
    FROM ", t$long, "
    WHERE LOT_TX_AUTO_TAND_FLG = 1
      AND (LOT_TX_AUTO_DT_2 IS NULL
           OR datediff(LOT_TX_AUTO_DT_2, LOT_TX_AUTO_DT_1) < ", p$auto_gap, "
           OR datediff(LOT_TX_AUTO_DT_2, LOT_TX_AUTO_DT_1) > ", p$tandem, ")"),
    "concat(pid, ' LOT', LOT_NUM, ': ', gap, ' days apart')")),

  list(id = "E3", group = "Transplant", severity = "info",
       what = "tandem pairs sitting exactly on the boundary",
       why = paste0("The spec says both. Its prose and its LOT2-6 settings table ",
                    "give the window as 60 to 180 days inclusive, no +1 - which ",
                    "is what the build tests - while its SCT tab still carries ",
                    "the older (date2 - date1 + 1) <= 180 formula, one day ",
                    "tighter, and the autologous windowing step still aims at ",
                    "that tighter reading. A pair at exactly 180 days is tandem ",
                    "under one and not the other, and a tandem pair does not end ",
                    "the line. This is how many patients the disagreement is ",
                    "worth. Every line, for the reason above E1."),
       needs = "long",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM
    FROM ", t$long, "
    WHERE LOT_TX_AUTO_TAND_FLG = 1
      AND datediff(LOT_TX_AUTO_DT_2, LOT_TX_AUTO_DT_1) = ", p$tandem),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "E4", group = "Transplant", severity = "fail",
       what = "the transplant end date is not before the line started",
       why = paste0("It is a transplant date minus one, floored at the line ",
                    "start precisely so a transplant coded on day one gives a ",
                    "one-day line. An unfloored value would be a line ending ",
                    "before it began. ",
                    "LOT1 only, and unlike E1-E3 that is not a gap. LOT1 is the ",
                    "only line that admits a transplant ON its own start date, ",
                    "which is why it needs the floor at all. 10_lot2_5_base.R ",
                    "gates every end-candidate transplant on being strictly ",
                    "AFTER the line start, so date_sub(x, 1) cannot land before ",
                    "it and the failure this looks for is unreachable there. ",
                    "The pre-floor column is not published for later lines ",
                    "either, so asking would need four more tables to answer a ",
                    "question the structure already answers."),
       needs = "sct",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$sct, "
    WHERE LOT1_TX_ENDDATE IS NOT NULL
      AND LOT1_TX_ENDDATE < LOT1_START_DT"), "pid")),

  list(id = "E5", group = "Transplant", severity = "fail",
       what = "every processed autologous transplant belongs to some line",
       why = paste0("The one failure mode the other transplant checks cannot ",
                    "see. Every check beside this one starts from a line and ",
                    "asks whether its dates agree, so a transplant that ended ",
                    "up in NO line has no row to be wrong on. This starts from ",
                    "TX_AUTO_DATES instead - every processed autologous event, ",
                    "whatever any line made of it - and requires each to sit ",
                    "inside some line's span. ",
                    "Autologous only, and the title says so. An allogeneic ",
                    "transplant or a CAR-T ends a line on the day before it and ",
                    "starts the next one, so its own date sits in no line's span ",
                    "by design; asking the same question of those events needs a ",
                    "different one, and answering it here would report every ",
                    "correctly handled ALLO as an orphan. ",
                    "There is ONE excuse and it has two conditions, both ",
                    "required: the build has run out of lines to give the event ",
                    "(max_lot reached) AND the event trails the last line. With ",
                    "fewer than max_lot lines a line was still available, so an ",
                    "unassigned event is the missing next line. Inside the span ",
                    "of the lines that exist, it is an event that fell in a gap ",
                    "between two of them. ",
                    "A failure, not a warning. This was a warn on the reasoning ",
                    "that an event past the end of observation is data rather ",
                    "than a defect - but 05_sct.R bounds every claim source to ",
                    "the patient's INDEX_DATE and OBS_END_DT, so TX_AUTO_DATES ",
                    "cannot hold one. ",
                    "Scoped to the span where the build had a line to give. A ",
                    "transplant BEFORE the patient's first line is not an ",
                    "ownership defect: the SCT step keeps claims from ",
                    "INDEX_DATE, LOT1 opens on the first non-steroid episode, ",
                    "and nothing makes those the same day - so a transplant in ",
                    "between belongs to no line and no rule could have given it ",
                    "one. Whether the patient later starts a line is beside the ",
                    "point, and gating on it made the same mismatch a blocking ",
                    "defect for one patient and a reported number for another. ",
                    "E5b carries both of those cases."),
       needs = c("long", "auto"),
       sql = function(t, p) counted(paste0("
    SELECT a.pid, a.dt, a.n_lines
    FROM (
      SELECT ", mask("x.PATID"), " AS pid, x.PATID AS k, x.TX_DT AS dt,
             (SELECT count(*) FROM ", t$long, " c WHERE c.PATID = x.PATID) AS n_lines,
             (SELECT min(c.LOT_START_DT) FROM ", t$long, " c
               WHERE c.PATID = x.PATID) AS first_start
      FROM ", t$auto, " x
    ) a
    LEFT JOIN ", t$long, " l ON a.k = l.PATID
    WHERE a.n_lines > 0
      AND a.dt >= a.first_start
    GROUP BY a.pid, a.k, a.dt, a.n_lines
    HAVING sum(CASE WHEN a.dt BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
                    THEN 1 ELSE 0 END) = 0
       AND (a.n_lines < ", p$max_lot, "
            OR a.dt <= max(l.LOT_BASE_END_DT))"),
    "concat(pid, ' @ ', dt, ' with ', n_lines, ' lines')")),

  list(id = "E5b", group = "Transplant", severity = "warn",
       what = "transplants the build never had a line to put them in",
       why = paste0("The cases E5 is scoped away from, kept as their own ",
                    "number rather than dropped. Both are the same thing: a ",
                    "transplant that arrives before this package has a line to ",
                    "give it. ",
                    "A line starts on a non-steroid medication episode. A ",
                    "patient whose claims produced a transplant but no such ",
                    "episode gets no line at all. A patient whose first episode ",
                    "comes after the transplant gets a first line that starts ",
                    "later than it. The SCT step keeps claims from INDEX_DATE, ",
                    "and nothing ties INDEX_DATE to the first episode, so both ",
                    "are shapes the build produces. ",
                    "Neither is a defect in how lines are built - there was no ",
                    "line to build the transplant into - and both are the same ",
                    "disagreement between the cohort's own indexing and this ",
                    "package's episode derivation that the attrition funnel ",
                    "reports as a RECONCILIATION step. ",
                    "Kept out of E5 so that check can fail. Folded in, a run ",
                    "would go red on a known cohort question rather than on an ",
                    "ownership defect, and the report could not tell the two ",
                    "apart. Split the other way - by whether the patient has ",
                    "any line at all - and one patient's pre-index transplant ",
                    "blocks the run while another's is a number, on a ",
                    "difference that has nothing to do with the transplant."),
       needs = c("long", "auto"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("x.PATID"), " AS pid, x.TX_DT AS dt
    FROM ", t$auto, " x
    WHERE x.TX_DT < coalesce((SELECT min(c.LOT_START_DT) FROM ", t$long, " c
                               WHERE c.PATID = x.PATID),
                             cast('9999-12-31' as date))"),
    "concat(pid, ' @ ', dt)")),

  # ---- F. The tables against each other ------------------------------------

  list(id = "F1", group = "Reconciliation", severity = "fail",
       what = "every published line exists in the unfiltered table",
       why = paste0("The criteria layer removes lines; it never invents one. A ",
                    "line in the final table with no counterpart is a line that ",
                    "came from somewhere else."),
       needs = c("final", "long"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("f.PATID"), " AS pid, f.LOT_NUM
    FROM ", t$final, " f
    LEFT JOIN ", t$long, " l
      ON cast(f.PATID as string) = cast(l.PATID as string)
     AND f.LOT_NUM = l.LOT_NUM
    WHERE l.PATID IS NULL"),
    "concat(pid, ' LOT', LOT_NUM)")),

  list(id = "F2", group = "Reconciliation", severity = "fail",
       what = "the funnel's final row is the published table, on both counts",
       why = paste0("The final row IS the study population, so it has to exist, ",
                    "exist once, and equal the table it names. ",
                    "By KIND, not by position. This took the last ",
                    "non-progression row by STEP_NUM, which is the final row ",
                    "only when one was written - a run whose funnel stopped at ",
                    "'With LOT1 built' handed that row over instead, compared ",
                    "its count with the table, found them equal and passed. The ",
                    "missing final row is the thing it is for. ",
                    "Patients AND lines. The funnel records both because a ",
                    "truncating criterion drops a patient's later lines without ",
                    "dropping the patient, so a patient count alone agrees while ",
                    "the line counts differ - 100 patients and 260 lines against ",
                    "100 and 240 passed. ",
                    "Duplicates fail too: two final rows under one run id means ",
                    "an earlier attempt survived, and which one a reader takes ",
                    "is then whichever the engine returns first."),
       needs = c("final", "attrition"),
       sql = function(t, p) counted(paste0("
    SELECT n_final, funnel_p, funnel_l, published_p, published_l
    FROM (
      SELECT (SELECT count(*) FROM ", t$attrition, "
               WHERE RUN_ID = '", p$run_id, "' AND KIND = 'final') AS n_final,
             (SELECT max(N_PATIENTS) FROM ", t$attrition, "
               WHERE RUN_ID = '", p$run_id, "' AND KIND = 'final') AS funnel_p,
             (SELECT max(N_LINES) FROM ", t$attrition, "
               WHERE RUN_ID = '", p$run_id, "' AND KIND = 'final') AS funnel_l,
             (SELECT count(DISTINCT PATID) FROM ", t$final, ") AS published_p,
             (SELECT count(*) FROM ", t$final, ")               AS published_l
    ) x
    WHERE n_final <> 1
       OR funnel_p IS NULL OR funnel_p <> published_p
       OR funnel_l IS NULL OR funnel_l <> published_l"),
    paste0("concat('final rows ', n_final, '; funnel ',",
           " coalesce(cast(funnel_p as string), 'null'), ' patients / ',",
           " coalesce(cast(funnel_l as string), 'null'), ' lines; table ',",
           " published_p, ' / ', published_l)"))),

  list(id = "F3", group = "Reconciliation", severity = "fail",
       what = "there is one progression row per line, and each is the reach the table shows",
       why = paste0("Those rows are what the dashboard draws and what gets ",
                    "quoted. Recomputing them from the lines is the only way to ",
                    "know they describe this run. ",
                    "The expected rows are GENERATED, 1 through max_lot, not ",
                    "discovered from the two sides. The writer promises a row ",
                    "for every line to the cap, including the ones nobody ",
                    "reached - and a missing LOT4 and LOT5 appear on neither ",
                    "side of a join between the funnel and the table, so a join ",
                    "compared LOT1 to LOT3, found them right and passed. A ",
                    "stray LOT6 row passed the same way, its zero agreeing with ",
                    "an absent published count. ",
                    "So: exactly one row per expected line, nothing outside ",
                    "1..max_lot, and each count equal to the table's. A ",
                    "progression row of zero for a line nobody reached is ",
                    "correct and is what the writer emits."),
       needs = c("final", "attrition"),
       sql = function(t, p) counted(paste0("
    WITH want AS (
      ", paste0("SELECT ", seq_len(p$max_lot), " AS LOT_NUM",
                collapse = " UNION ALL\n      "), "
    ),
    reach AS (
      -- BOTH FIGURES THE WRITER RECORDS. The attrition writer stores
      -- N_PATIENTS and N_LINES per progression row, and this compared only the
      -- first - so a row claiming the right patient count and the wrong line
      -- count reconciled. The 'correct' synthetic fixture demonstrated it:
      -- three patients over five lines were written as LOT1 3/5, LOT2 1/3,
      -- LOT3 1/1 and labelled a good progression set, when the lines say
      -- 3/3, 1/1, 1/1. An external review found both the gap and the fixture.
      SELECT LOT_NUM, count(DISTINCT PATID) AS n, count(*) AS n_lines
      FROM ", t$final, " GROUP BY LOT_NUM
    ),
    said AS (
      SELECT cast(regexp_extract(STEP, 'LOT([0-9]+)', 1) as int) AS LOT_NUM,
             max(N_PATIENTS) AS N_PATIENTS, max(N_LINES) AS N_LINES,
             count(*) AS n_rows
      FROM ", t$attrition, "
      WHERE RUN_ID = '", p$run_id, "' AND KIND = 'progression'
      GROUP BY cast(regexp_extract(STEP, 'LOT([0-9]+)', 1) as int)
    )
    SELECT coalesce(w.LOT_NUM, s.LOT_NUM) AS LOT_NUM,
           coalesce(s.n_rows, 0) AS rows_written,
           s.N_PATIENTS AS said, coalesce(r.n, 0) AS actual,
           s.N_LINES AS said_lines, coalesce(r.n_lines, 0) AS actual_lines
    FROM want w
    FULL OUTER JOIN said s ON s.LOT_NUM = w.LOT_NUM
    LEFT JOIN reach r ON r.LOT_NUM = coalesce(w.LOT_NUM, s.LOT_NUM)
    WHERE w.LOT_NUM IS NULL
       OR coalesce(s.n_rows, 0) <> 1
       OR s.N_PATIENTS <> coalesce(r.n, 0)
       OR coalesce(s.N_LINES, -1) <> coalesce(r.n_lines, 0)"),
    paste0("concat('LOT', LOT_NUM, ': ', rows_written, ' row(s), funnel says ',",
           " coalesce(cast(said as string), 'nothing'), '/',",
           " coalesce(cast(said_lines as string), 'nothing'),",
           " ' (patients/lines), lines say ', actual, '/', actual_lines)"))),

  list(id = "F4", group = "Reconciliation", severity = "fail",
       what = "the run has exactly one metadata row",
       why = paste0("Two rows means an earlier attempt's numbers survived under ",
                    "this run's id, and nothing on them says they are stale."),
       needs = "meta",
       sql = function(t, p) counted(paste0("
    SELECT count(*) AS n
    FROM ", t$meta, "
    WHERE RUN_ID = '", p$run_id, "'
    HAVING count(*) <> 1"), "concat(n, ' metadata rows')")),

  list(id = "F5", group = "Reconciliation", severity = "warn",
       what = "no patient in the published table is outside the cohort",
       why = paste0("Lines are built from the cohort table, so this can only ",
                    "fail if the cohort was rebuilt under the prefix after the ",
                    "lines were. A warning rather than a failure because the ",
                    "cohort table is an input this package is pointed at, not ",
                    "one it can prove is the right one."),
       needs = c("final", "cohort"),
       sql = function(t, p) counted(paste0("
    SELECT ", mask("f.PATID"), " AS pid
    FROM (SELECT DISTINCT PATID FROM ", t$final, ") f
    LEFT JOIN ", t$cohort, " c ON cast(f.PATID as string) = cast(c.PATID as string)
    WHERE c.PATID IS NULL"), "pid"))
)

# ---- Reading the run's own settings ----------------------------------------
# Here rather than in the runner so they can be tested without a connection,
# which is the only way anything in this package gets tested at all.

# One value out of the run's recorded settings. Not defaulted: the point of
# reading them is to describe the run being checked, and a default would
# quietly describe a different one.
qc_setting <- function(settings, key) {
  m <- regmatches(settings, regexpr(paste0("(^|[|])", key, "=[^|]*"), settings))
  if (!length(m))
    stop("The run's CONTRACT_SETTINGS does not carry '", key, "', so this ",
         "package cannot tell what the run used. It was built by a version ",
         "that recorded a different set.", call. = FALSE)
  sub(paste0("^[|]?", key, "="), "", m)
}

qc_int <- function(settings, key) {
  raw <- qc_setting(settings, key)
  v <- suppressWarnings(as.integer(raw))
  if (is.na(v))
    stop("The run recorded ", key, "='", raw, "', which is not a whole number.",
         call. = FALSE)
  v
}

# The windows every check judges by, read from the run rather than from
# config.csv, so an edited config cannot judge lines built under the old value.
qc_params <- function(settings, run_id) {
  censor <- toupper(trimws(qc_setting(settings, "censor_at_disenrollment")))
  # Whether the run treated a CAR-T inside LOT1's window as part of LOT1. B5c
  # needs it: with the rule on, such an infusion does not stop the build reading
  # LOT1's later AUTOs, and a check that censored there would miss the orphan.
  cart_ex <- toupper(trimws(qc_setting(settings, "apply_cart_induction_rule")))
  # Which melphalan rule the run applied. No check judges by it, but a report
  # that cannot say it is a report where the study's build and one without the
  # rule look the same on their face - and they are different algorithms, with
  # different line counts and different line shapes.
  melp <- trimws(qc_setting(settings, "apply_melp_rule"))
  # Whether the run folded a returning previous-line drug into the line it
  # returned in. C1 needs it: a folded drug joins that line's regimen and its
  # episode sits inside the LINE but after the induction window, which the
  # strict window test would report as a drug that reached the regimen some
  # other way. Read off the run's own recorded settings, not config.csv.
  foldin <- toupper(trimws(qc_setting(settings, "apply_map_foldin")))
  list(run_id   = run_id,
       censor   = identical(censor, "TRUE"),
       cart_exempt = identical(cart_ex, "TRUE"),
       foldin   = identical(foldin, "TRUE"),
       melp_rule = if (nzchar(melp)) melp else "off",
       ind1     = qc_int(settings, "induction_window_days"),
       indn     = qc_int(settings, "lot_n_induction_window_days"),
       cart     = qc_int(settings, "cart_consolidation_days"),
       tandem   = qc_int(settings, "sct_tandem_days"),
       auto_gap = qc_int(settings, "sct_auto_gap_days"),
       # B8's confirmation window, and the line cap that tells it where the
       # build stops looking for a next line.
       confirm  = qc_int(settings, "lot_discon_confirm_days"),
       max_lot  = qc_int(settings, "max_lot"),
       # The build derives this once, in a session view that is gone by the
       # time this package runs, so it is rebuilt the same way rather than
       # assumed to be ENDDATE.
       obs_end  = if (identical(censor, "TRUE"))
                    "coalesce(cast(c.ENDDATE_CE as date), cast(c.ENDDATE as date))"
                  else "cast(c.ENDDATE as date)")
}

# What a count means for a check of this severity. Its own function because
# "zero is a pass" is the one rule the whole report rests on.
qc_outcome <- function(n, severity) {
  if (is.na(n)) return("error")
  if (n == 0) return("pass")
  switch(severity, fail = "FAIL", warn = "warn", info = "info")
}

QC_SEVERITIES <- c("fail", "warn", "info")

# Catalogue hygiene, checked at load rather than trusted. A duplicate id makes
# two rows in the report indistinguishable; an unknown severity would be
# scored as neither a pass nor a failure.
check_qc_catalogue <- function(checks = LOT_QC_CHECKS) {
  ids <- vapply(checks, function(c_i) c_i$id %||% "", character(1))
  if (any(!nzchar(ids))) stop("A check has no id.", call. = FALSE)
  if (anyDuplicated(ids))
    stop("Duplicate check id(s): ",
         paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)
  for (c_i in checks) {
    for (f in c("group", "what", "why", "needs", "sql"))
      if (is.null(c_i[[f]]))
        stop("Check ", c_i$id, " has no ", f, ".", call. = FALSE)
    if (!c_i$severity %in% QC_SEVERITIES)
      stop("Check ", c_i$id, " has severity '", c_i$severity, "'; want one of ",
           paste(QC_SEVERITIES, collapse = ", "), ".", call. = FALSE)
    if (!is.function(c_i$sql))
      stop("Check ", c_i$id, "'s sql is not a function.", call. = FALSE)
  }
  invisible(TRUE)
}

# The report a reviewer reads. Here rather than in the runner so a test can
# check what it says without a warehouse behind it.
qc_markdown <- function(res, run_id, pfx, p, devs) {
  ln <- c(paste0("# LOT QC - ", pfx),
          "",
          paste0("Run `", run_id, "`. ", nrow(res), " checks: ",
                 sum(res$result == "pass"), " passed, ",
                 sum(res$result == "FAIL"), " failed, ",
                 sum(res$result == "error"), " errored, ",
                 sum(res$result == "skip"), " skipped."),
          "")
  if (nzchar(devs))
    ln <- c(ln, paste0("**Not a contract build.** `", devs,
                       "` - these numbers are that algorithm's, not the study's."), "")
  ln <- c(ln,
          paste0("Windows as the run recorded them: LOT1 ", p$ind1,
                 " days, later lines ", p$indn, ", CAR-T ", p$cart,
                 "; tandem ", p$tandem, ", autologous gap ", p$auto_gap, "."),
          # In the report, not only on the console: a study build and one
          # without the melphalan rule are different algorithms with different
          # line counts, and the file is what gets read later.
          paste0("Melphalan rule: ", p$melp_rule, "."),
          "", "| | check | result | n | detail |", "|---|---|---|---|---|")
  for (i in seq_len(nrow(res)))
    ln <- c(ln, paste0("| ", res$id[i], " | ", res$what[i], " | ",
                       res$result[i], " | ",
                       if (is.na(res$n_bad[i])) "" else format(res$n_bad[i], big.mark = ","),
                       " | ", gsub("|", "/", res$detail[i], fixed = TRUE), " |"))
  ln
}
