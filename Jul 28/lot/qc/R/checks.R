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
                    "guard in the LOT1 end step relies on that: it hardcodes the ",
                    "30-day window that the next line's AUTO rule would apply to ",
                    "a MED-started predecessor."),
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
       what = "an empty regimen belongs only to a procedure-started line",
       why = paste0("The induction step suppresses regimen rows for an ALLO ",
                    "line, which is why that line carries no drugs. A ",
                    "medication-started line with no regimen is a line whose ",
                    "own starting drug did not reach its regimen."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM, LOT_START_TYPE
    FROM ", t$final, "
    WHERE trim(coalesce(LOT_BASE_MEDS, '')) = ''
      AND LOT_START_TYPE NOT IN ('SCT_ALLO', 'CART')"),
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
       why = paste0("The enum here is the build's, not the program spec's - the ",
                    "spec lists SUBSTITUTION and MAINTENANCE_END, which nothing ",
                    "produces, and does not list CART_INIT, which is produced. ",
                    "This check is what makes that concrete rather than a ",
                    "reading of the code."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT DISTINCT LOT_BASE_END_REASON AS v
    FROM ", t$final, "
    WHERE LOT_BASE_END_REASON IS NULL
       OR LOT_BASE_END_REASON NOT IN
          ('SCT_AUTO', 'SCT_ALLO', 'SCT_CART', 'SCT', 'CART_INIT',
           'MED_ADD', 'DEATH', 'DISCONTINUATION', 'STUDY_END')"),
    "coalesce(v, '(null)')")),

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
       what = "every drug in a regimen has a treatment episode in that line's window",
       why = paste0("This is the regimen rule itself, asked backwards. The ",
                    "window is the line's own: 60 days at LOT1, 45 for a CAR-T ",
                    "started line, 30 otherwise. A drug with no episode in it ",
                    "reached the regimen some other way."),
       needs = c("final", "map"),
       sql = function(t, p) counted(paste0("
    WITH reg AS (
      SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM, l.LOT_START_DT,
             l.LOT_START_TYPE, m AS MED_ABBR
      FROM ", t$final, " l
      LATERAL VIEW explode(split(coalesce(l.LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    win AS (
      SELECT r.*,
             date_add(r.LOT_START_DT,
               CASE WHEN r.LOT_NUM = 1              THEN ", p$ind1 - 1, "
                    WHEN r.LOT_START_TYPE = 'CART'  THEN ", p$cart - 1, "
                    ELSE                                 ", p$indn - 1, " END) AS WIN_END
      FROM reg r
    )
    SELECT ", mask("w.PATID"), " AS pid, w.LOT_NUM, w.MED_ABBR
    FROM win w
    LEFT JOIN ", t$map, " ms
      ON cast(ms.PATID as string) = w.PATID
     AND ms.MAP_MED_TYPE = w.MED_ABBR
     AND ms.MAP_START_DT >= w.LOT_START_DT
     AND ms.MAP_START_DT <= w.WIN_END
    WHERE ms.PATID IS NULL"),
    "concat(pid, ' LOT', LOT_NUM, ': ', MED_ABBR, ' has no episode in the window')")),

  list(id = "C2", group = "Regimen", severity = "fail",
       what = "the added medication is not already in the regimen",
       why = paste0("An added medication is by definition one the regimen does ",
                    "not contain. If it does, the candidate query and the ",
                    "regimen disagree about what the regimen is."),
       needs = "final",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid, LOT_NUM, LOT_BASE_1ST_ADD_MED AS med
    FROM ", t$final, "
    WHERE LOT_BASE_1ST_ADD_MED IS NOT NULL
      AND array_contains(split(coalesce(LOT_BASE_MEDS, ''), ' '),
                         LOT_BASE_1ST_ADD_MED)"),
    "concat(pid, ' LOT', LOT_NUM, ': ', med)")),

  list(id = "C3", group = "Regimen", severity = "info",
       what = "lines where more than one drug could have been the added medication",
       why = paste0("When several non-regimen drugs share the earliest added ",
                    "date the build breaks the tie with rand(42) inside a window ",
                    "ORDER BY. Spark seeds that per partition, so the date is ",
                    "stable across re-runs but the drug is only stable while the ",
                    "physical plan is. This counts how many lines are exposed. ",
                    "Zero means the question never arises on this cohort."),
       needs = c("final", "map"),
       sql = function(t, p) counted(paste0("
    WITH add_lines AS (
      SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_BASE_MEDS,
             date_add(LOT_BASE_1ST_ADD_MED_DT, 1) AS ADD_START_DT
      FROM ", t$final, "
      WHERE LOT_BASE_1ST_ADD_MED_DT IS NOT NULL
    )
    SELECT ", mask("a.PATID"), " AS pid, a.LOT_NUM,
           count(DISTINCT ms.MAP_MED_TYPE) AS n_tied
    FROM add_lines a
    INNER JOIN ", t$map, " ms
      ON cast(ms.PATID as string) = a.PATID
     AND ms.MAP_START_DT = a.ADD_START_DT
    WHERE NOT array_contains(split(coalesce(a.LOT_BASE_MEDS, ''), ' '),
                             ms.MAP_MED_TYPE)
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
                    "each decision point. The engine README goes further: the code ",
                    "list itself should not carry them, and lot/tools ships the ",
                    "script that removes them. Zero means the list is clean; a count means ",
                    "the tool has not run against the production list, and the ",
                    "class filters are what the exclusion is resting on."),
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

  list(id = "E1", group = "Transplant", severity = "fail",
       what = "tandem and single autologous flags are mutually exclusive",
       why = "A patient is one or the other; the flags are built as a negation.",
       needs = "sct",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$sct, "
    WHERE LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1"), "pid")),

  list(id = "E2", group = "Transplant", severity = "fail",
       what = "a tandem pair sits between 60 and 180 days apart",
       why = paste0("The lower bound is enforced upstream, by merging ",
                    "autologous events closer than 60 days into one. The upper ",
                    "bound is the tandem test itself. A pair outside either is a ",
                    "pair one of those two steps should not have produced."),
       needs = "sct",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid,
           datediff(LOT1_TX_AUTO_DT_2, LOT1_TX_AUTO_DT_1) AS gap
    FROM ", t$sct, "
    WHERE LOT1_SCT_AUTO_TAND_FLG = 1
      AND (LOT1_TX_AUTO_DT_2 IS NULL
           OR datediff(LOT1_TX_AUTO_DT_2, LOT1_TX_AUTO_DT_1) < ", p$auto_gap, "
           OR datediff(LOT1_TX_AUTO_DT_2, LOT1_TX_AUTO_DT_1) > ", p$tandem, ")"),
    "concat(pid, ': ', gap, ' days apart')")),

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
                    "worth."),
       needs = "sct",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$sct, "
    WHERE LOT1_SCT_AUTO_TAND_FLG = 1
      AND datediff(LOT1_TX_AUTO_DT_2, LOT1_TX_AUTO_DT_1) = ", p$tandem), "pid")),

  list(id = "E4", group = "Transplant", severity = "fail",
       what = "the transplant end date is not before the line started",
       why = paste0("It is a transplant date minus one, floored at the line ",
                    "start precisely so a transplant coded on day one gives a ",
                    "one-day line. An unfloored value would be a line ending ",
                    "before it began."),
       needs = "sct",
       sql = function(t, p) counted(paste0("
    SELECT ", mask("PATID"), " AS pid
    FROM ", t$sct, "
    WHERE LOT1_TX_ENDDATE IS NOT NULL
      AND LOT1_TX_ENDDATE < LOT1_START_DT"), "pid")),

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
       what = "the attrition funnel ends where the published table does",
       why = paste0("The last funnel row is the study population. If it does ",
                    "not equal the table it names, one of the two was written ",
                    "by a different attempt."),
       needs = c("final", "attrition"),
       sql = function(t, p) counted(paste0("
    WITH last_step AS (
      SELECT N_PATIENTS
      FROM ", t$attrition, "
      WHERE RUN_ID = '", p$run_id, "' AND KIND <> 'progression'
      ORDER BY STEP_NUM DESC LIMIT 1
    )
    SELECT ls.N_PATIENTS AS funnel,
           (SELECT count(DISTINCT PATID) FROM ", t$final, ") AS published
    FROM last_step ls
    WHERE ls.N_PATIENTS <> (SELECT count(DISTINCT PATID) FROM ", t$final, ")"),
    "concat('funnel says ', funnel, ', table has ', published)")),

  list(id = "F3", group = "Reconciliation", severity = "fail",
       what = "the progression rows are the reach the published table shows",
       why = paste0("Those rows are what the dashboard draws and what gets ",
                    "quoted. Recomputing them from the lines is the only way to ",
                    "know they describe this run."),
       needs = c("final", "attrition"),
       sql = function(t, p) counted(paste0("
    WITH reach AS (
      SELECT LOT_NUM, count(DISTINCT PATID) AS n
      FROM ", t$final, " GROUP BY LOT_NUM
    ),
    said AS (
      SELECT cast(regexp_extract(STEP, 'LOT([0-9]+)', 1) as int) AS LOT_NUM,
             N_PATIENTS
      FROM ", t$attrition, "
      WHERE RUN_ID = '", p$run_id, "' AND KIND = 'progression'
    )
    SELECT s.LOT_NUM, s.N_PATIENTS AS said, coalesce(r.n, 0) AS actual
    FROM said s LEFT JOIN reach r ON s.LOT_NUM = r.LOT_NUM
    WHERE s.N_PATIENTS <> coalesce(r.n, 0)"),
    "concat('LOT', LOT_NUM, ': funnel says ', said, ', lines say ', actual)")),

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

# Which tables a check needs, across the whole catalogue. The runner uses this
# to skip a check whose table is absent rather than failing it: a missing table
# is a run built by a different version, not a defect in this one.
qc_needs <- function(checks = LOT_QC_CHECKS)
  sort(unique(unlist(lapply(checks, function(c_i) c_i$needs))))

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
  list(run_id   = run_id,
       censor   = identical(censor, "TRUE"),
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
          "", "| | check | result | n | detail |", "|---|---|---|---|---|")
  for (i in seq_len(nrow(res)))
    ln <- c(ln, paste0("| ", res$id[i], " | ", res$what[i], " | ",
                       res$result[i], " | ",
                       if (is.na(res$n_bad[i])) "" else format(res$n_bad[i], big.mark = ","),
                       " | ", gsub("|", "/", res$detail[i], fixed = TRUE), " |"))
  ln
}
