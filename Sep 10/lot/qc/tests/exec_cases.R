# What each check is given to find, and what it must not find.
#
# One entry per check. Each plants exactly the defect its `what` describes.
# The clean fixture must count 0 for every check and the planted one must count
# more than 0 for its own - a check that cannot tell them apart is a check that
# reports "pass" on a real defect.
#
# The clean fixture is one patient with two lines, and it has to satisfy all
# thirty-seven checks at once: the funnel has to reconcile with the published
# table, every regimen drug needs an episode inside its line, every episode
# inside a line has to be in that line's regimen, and every transplant has to
# belong to a line. That is most of what makes it a fixture worth having.
#
# No steroid episode and no death, so the `warn` and `info` checks read zero on
# it too - otherwise "counts nothing on clean data" would only be true of the
# failures.

.D <- function(x) x   # dates as ISO strings; DuckDB casts them

FINAL_1 <- list(PATID = "P000001", LOT_NUM = 1L,
  LOT_START_DT = "2020-01-01", LOT_START_TYPE = "MED",
  LOT_BASE_MEDS = "BORT LEN", LOT_MED_CNT = 2L,
  LOT_BASE_DISCON_DT = "2020-06-28", LOT_BASE_1ST_ADD_MED = NA,
  LOT_BASE_1ST_ADD_MED_DT = NA, LOT_BASE_END_DT = "2020-06-28",
  LOT_BASE_END_REASON = "DISCONTINUATION", LOT_BASE_LENGTH = 180L,
  LOT_BASE_END_DT_CE_SENS = "2020-06-28",
  LOT_BASE_END_REASON_CE_SENS = "DISCONTINUATION", LOT_TX_AUTO_MAX_DT = NA)

FINAL_2 <- list(PATID = "P000001", LOT_NUM = 2L,
  LOT_START_DT = "2020-07-01", LOT_START_TYPE = "SCT_AUTO",
  LOT_BASE_MEDS = "CARF POM", LOT_MED_CNT = 2L,
  LOT_BASE_DISCON_DT = NA, LOT_BASE_1ST_ADD_MED = "DARA",
  LOT_BASE_1ST_ADD_MED_DT = "2020-10-08", LOT_BASE_END_DT = "2020-10-08",
  LOT_BASE_END_REASON = "MED_ADD", LOT_BASE_LENGTH = 100L,
  LOT_BASE_END_DT_CE_SENS = "2020-10-08",
  LOT_BASE_END_REASON_CE_SENS = "MED_ADD", LOT_TX_AUTO_MAX_DT = "2020-07-01")

.long <- function(f) list(PATID = f$PATID, LOT_NUM = f$LOT_NUM,
  LOT_START_DT = f$LOT_START_DT, LOT_START_TYPE = f$LOT_START_TYPE,
  LOT_BASE_END_DT = f$LOT_BASE_END_DT, LOT_TX_AUTO_DT_1 = NA,
  LOT_TX_AUTO_DT_2 = NA, LOT_TX_AUTO_TAND_FLG = 0L)

.ep <- function(med, start, end, class = "NOVEL") list(
  PATID = "P000001", MAP_MED_ABBR = med, MAP_MED_TYPE = med,
  MAP_MED_CLASS = class, MAP_START_DT = start, MAP_END_DT = end,
  MAP_DISCON_FLG = 0L, MAP_MED_RUNOUT_DT = end, MAP_RX_RUNOUT_DT = NA,
  ELIGIBLE_END = end)

.prog <- function(n, pats, lines) list(
  RUN_ID = "run-abc", STEP_NUM = 10L + n, KIND = "progression",
  STEP = paste0("reached LOT", n), N_PATIENTS = pats, N_LINES = lines,
  PCT_OF_START = 100, PCT_OF_PREV = 100)

CLEAN_FIXTURE <- list(
  final = list(FINAL_1, FINAL_2),
  long  = list(.long(FINAL_1), .long(FINAL_2)),
  # One episode per regimen drug, inside its own line's window. C1 wants every
  # regimen drug to have one; C4 wants every episode in the window to be in the
  # regimen, so there are no others.
  map = list(.ep("BORT", "2020-01-01", "2020-02-01"),
             .ep("LEN",  "2020-01-05", "2020-02-05"),
             .ep("CARF", "2020-07-01", "2020-08-01"),
             .ep("POM",  "2020-07-05", "2020-08-05")),
  sct  = list(list(PATID = "P000001", LOT1_START_DT = "2020-01-01",
                   LOT1_TX_ENDDATE = "2020-06-28",
                   LOT1_SCT_AUTO_SING_FLG = 1L, LOT1_SCT_AUTO_TAND_FLG = 0L)),
  # The transplant that opened LOT2, so it belongs to a line.
  auto = list(list(PATID = "P000001", TX_DT = "2020-07-01")),
  allo = list(),
  attrition = list(
    list(RUN_ID = "run-abc", STEP_NUM = 1L, KIND = "input",
         STEP = "cohort", N_PATIENTS = 1L, N_LINES = 2L,
         PCT_OF_START = 100, PCT_OF_PREV = 100),
    list(RUN_ID = "run-abc", STEP_NUM = 99L, KIND = "final",
         STEP = "study population", N_PATIENTS = 1L, N_LINES = 2L,
         PCT_OF_START = 100, PCT_OF_PREV = 100),
    .prog(1L, 1L, 1L), .prog(2L, 1L, 1L),
    .prog(3L, 0L, 0L), .prog(4L, 0L, 0L), .prog(5L, 0L, 0L)),
  meta = list(list(RUN_ID = "run-abc", RUN_TIMESTAMP = "2026-09-09 10:00:00",
                   LOT_LONG_BY_LINE = "1:1|2:1", N_LOT_FINAL_ROWS = 2L,
                   N_LOT_FINAL_PATIENTS = 1L, CODE_MD5 = "x",
                   CONTRACT_SETTINGS = "", STUDY_START = "2016-01-01",
                   STUDY_END = "2026-03-31", LINE_CRITERIA_APPLIED = "")),
  cohort = list(list(PATID = "P000001", INDEX_DATE = "2020-01-01",
                     ENDDATE = "2021-12-31", ENDDATE_CE = "2021-12-31",
                     DEATH_DT = NA)),
  subs = list()
)

# A planted row is the clean one with the defect in it, under a patient id of
# its own so it cannot disturb the clean patient's reconciliation.
.f <- function(base, ...) utils::modifyList(
  utils::modifyList(base, list(PATID = "P000009")), list(...))
.l <- function(base, ...) utils::modifyList(.long(.f(base)), list(...))
.c <- function(...) utils::modifyList(
  list(PATID = "P000009", INDEX_DATE = "2020-01-01", ENDDATE = "2021-12-31",
       ENDDATE_CE = "2021-12-31", DEATH_DT = NA), list(...))

EXEC_CASES <- list(
  A1 = list(what = "a length that is not the span its own dates describe",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_LENGTH = 999L)))),
  A2 = list(what = "a CE-sensitivity end AFTER the primary end",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_END_DT_CE_SENS = "2020-08-01")))),
  A3 = list(what = "DISENROLLMENT claimed where the cap did not move the date",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_END_REASON_CE_SENS = "DISENROLLMENT")))),
  A4 = list(what = "a line 1 that is not medication-started",
            planted = list(final = list(.f(FINAL_1, LOT_START_TYPE = "SCT_AUTO")))),
  A5 = list(what = "a start type the build cannot write",
            planted = list(final = list(.f(FINAL_1, LOT_START_TYPE = "SCT_CART")))),
  A6 = list(what = "a medication count that is not the size of its regimen string",
            planted = list(final = list(.f(FINAL_1, LOT_MED_CNT = 7L)))),
  A7 = list(what = "a medication-started line with no regimen",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_MEDS = "", LOT_MED_CNT = 0L)))),
  B1 = list(what = "MED_ADD ending on a date that is not the added drug's",
            planted = list(final = list(.f(FINAL_2, LOT_BASE_1ST_ADD_MED_DT = "2020-09-01")))),
  B2 = list(what = "DISCONTINUATION ending on a date that is not the run-out",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_DISCON_DT = "2020-05-01")))),
  B5 = list(what = "an end reason the build cannot write",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_END_REASON = "GAVE_UP")))),
  # These two read the DATE against the line's own start, not the end reason.
  # The first plants here got that wrong and both checks stayed silent - which
  # is the whole reason for running them rather than reading them.
  B6 = list(what = "an added-medication date BEFORE the line started",
            planted = list(final = list(.f(FINAL_2, LOT_BASE_1ST_ADD_MED_DT = "2020-06-01")))),
  B7 = list(what = "a run-out date BEFORE the line started",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_DISCON_DT = "2019-12-01")))),
  B5b = list(what = "SCT_AUTO_CONT ending on a date that is not the transplant's",
             planted = list(final = list(.f(FINAL_2, LOT_BASE_END_REASON = "SCT_AUTO_CONT",
                                            LOT_TX_AUTO_MAX_DT = "2020-08-15")))),

  # --- the checks that read more than the published table --------------------

  # Three disjuncts, so three planted rows and an exact expected count. With
  # one row the check still counted something after a disjunct was deleted,
  # and "more than zero" could not tell that a third of it had gone.
  B3 = list(what = "DEATH ending anywhere but on a death date inside observation",
            n = 3L,
            planted = list(
              final  = list(
                .f(FINAL_1, LOT_BASE_END_REASON = "DEATH"),
                utils::modifyList(.f(FINAL_1, LOT_BASE_END_REASON = "DEATH"),
                                  list(PATID = "P000010")),
                utils::modifyList(.f(FINAL_1, LOT_BASE_END_REASON = "DEATH",
                                     LOT_BASE_END_DT = "2022-06-01"),
                                  list(PATID = "P000011"))),
              cohort = list(
                .c(DEATH_DT = "2020-09-09"),
                utils::modifyList(.c(), list(PATID = "P000010", DEATH_DT = NA)),
                utils::modifyList(.c(), list(PATID = "P000011",
                                             DEATH_DT = "2022-06-01"))))),
  B4 = list(what = "STUDY_END ending somewhere other than the observation end",
            planted = list(
              final  = list(.f(FINAL_1, LOT_BASE_END_REASON = "STUDY_END")),
              cohort = list(.c()))),
  B8 = list(what = "a discontinuation on the last line with no confirmation window",
            planted = list(
              final  = list(.f(FINAL_1, LOT_BASE_END_DT = "2021-12-01",
                               LOT_BASE_DISCON_DT = "2021-12-01",
                               LOT_BASE_LENGTH = 701L,
                               LOT_BASE_END_DT_CE_SENS = "2021-12-01")),
              cohort = list(.c()))),
  B9 = list(what = "a death outranking an earlier run-out",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_END_REASON = "DEATH",
                                           LOT_BASE_DISCON_DT = "2020-05-01")))),
  B5c = list(what = "a transplant inside a line's window but after the line ended",
             planted = list(
               long = list(.l(FINAL_1, LOT_BASE_END_DT = "2020-01-10")),
               auto = list(list(PATID = "P000009", TX_DT = "2020-01-20")))),

  C1 = list(what = "a regimen drug with no treatment episode inside its line",
            planted = list(final = list(.f(FINAL_1, LOT_BASE_MEDS = "BORT GHOST",
                                           LOT_MED_CNT = 2L)))),
  C4 = list(what = "an eligible episode in the window that never reached the regimen",
            planted = list(
              final = list(.f(FINAL_1)),
              map = list(.ep("BORT", "2020-01-01", "2020-02-01"),
                         .ep("LEN", "2020-01-05", "2020-02-05"),
                         utils::modifyList(.ep("STRAY", "2020-01-10", "2020-02-10"),
                                           list(PATID = "P000009"))))),
  C2 = list(what = "an added medication that is already in the regimen",
            planted = list(final = list(.f(FINAL_2, LOT_BASE_1ST_ADD_MED = "CARF")))),
  # The tie is looked for on the day AFTER the added-medication date -
  # date_add(LOT_BASE_1ST_ADD_MED_DT, 1) - so episodes on the date itself find
  # nothing. The first plant used the date and the check stayed silent.
  C3 = list(what = "a line where more than one drug could have been the added one",
            planted = list(
              final = list(.f(FINAL_2)),
              map = list(utils::modifyList(.ep("NEWA", "2020-10-09", "2020-11-09"),
                                           list(PATID = "P000009")),
                         utils::modifyList(.ep("NEWB", "2020-10-09", "2020-11-09"),
                                           list(PATID = "P000009"))))),

  D1 = list(what = "an episode that ends before it starts",
            planted = list(map = list(utils::modifyList(
              .ep("BORT", "2020-03-01", "2020-02-01"), list(PATID = "P000009"))))),
  D2 = list(what = "an episode not ending at the later of its two run-out dates",
            planted = list(map = list(utils::modifyList(
              .ep("BORT", "2020-03-01", "2020-04-01"),
              list(PATID = "P000009", MAP_MED_RUNOUT_DT = "2020-05-01"))))),
  D3 = list(what = "an episode carrying a steroid",
            planted = list(map = list(utils::modifyList(
              .ep("DEX", "2020-03-01", "2020-04-01", class = "STEROID"),
              list(PATID = "P000009"))))),
  D4 = list(what = "an episode outside the patient's observation",
            planted = list(
              map = list(utils::modifyList(.ep("BORT", "2019-01-01", "2019-02-01"),
                                           list(PATID = "P000009"))),
              cohort = list(.c()))),

  E1 = list(what = "a transplant flagged both tandem and single",
            planted = list(sct = list(list(PATID = "P000009",
              LOT1_START_DT = "2020-01-01", LOT1_TX_ENDDATE = "2020-06-28",
              LOT1_SCT_AUTO_SING_FLG = 1L, LOT1_SCT_AUTO_TAND_FLG = 1L)))),
  E2 = list(what = "a tandem pair outside the 60-to-180-day window",
            planted = list(long = list(.l(FINAL_1, LOT_TX_AUTO_TAND_FLG = 1L,
              LOT_TX_AUTO_DT_1 = "2020-01-01", LOT_TX_AUTO_DT_2 = "2020-11-01")))),
  E3 = list(what = "a tandem pair sitting exactly on the boundary",
            planted = list(long = list(.l(FINAL_1, LOT_TX_AUTO_TAND_FLG = 1L,
              LOT_TX_AUTO_DT_1 = "2020-01-01", LOT_TX_AUTO_DT_2 = "2020-06-29")))),
  E4 = list(what = "a transplant end date before the line started",
            planted = list(sct = list(list(PATID = "P000009",
              LOT1_START_DT = "2020-01-01", LOT1_TX_ENDDATE = "2019-12-01",
              LOT1_SCT_AUTO_SING_FLG = 0L, LOT1_SCT_AUTO_TAND_FLG = 0L)))),
  # AFTER the only line ends, not inside it. The first plant put the transplant
  # within the line, where it belongs to one, and the check was right to say
  # nothing.
  E5 = list(what = "a processed transplant belonging to no line",
            planted = list(
              long = list(.l(FINAL_1)),
              auto = list(list(PATID = "P000009", TX_DT = "2020-08-01")))),
  E5b = list(what = "a transplant before the build had any line to put it in",
             planted = list(
               long = list(.l(FINAL_1)),
               auto = list(list(PATID = "P000009", TX_DT = "2019-06-01")))),

  F1 = list(what = "a published line that is not in the unfiltered table",
            planted = list(final = list(.f(FINAL_1)))),
  F5 = list(what = "a published patient who is not in the cohort",
            planted = list(final = list(.f(FINAL_1)),
                           long = list(.l(FINAL_1)))),
  F2 = list(what = "a funnel final row that disagrees with the published table",
            planted = list(final = list(.f(FINAL_1)), long = list(.l(FINAL_1)),
                           cohort = list(.c()))),
  F3 = list(what = "a progression row that disagrees with the lines",
            planted = list(final = list(.f(FINAL_1)), long = list(.l(FINAL_1)),
                           cohort = list(.c()))),
  F4 = list(what = "a second metadata row for the same run",
            planted = list(meta = list(list(RUN_ID = "run-abc",
              RUN_TIMESTAMP = "2026-09-09 11:00:00", LOT_LONG_BY_LINE = "1:1",
              N_LOT_FINAL_ROWS = 2L, N_LOT_FINAL_PATIENTS = 1L, CODE_MD5 = "y",
              CONTRACT_SETTINGS = "", STUDY_START = "2016-01-01",
              STUDY_END = "2026-03-31", LINE_CRITERIA_APPLIED = ""))))
)
