# What each check is given to find, and what it must not find.
#
# One entry per check that reads only LOT_LONG_FINAL. Each plants exactly the
# defect its `what` describes. The clean fixture must count 0 and the planted
# one must count more than 0 - a check that cannot tell them apart is a check
# that reports "pass" on a real defect.
#
# The rows are hand-made and small enough to reason about. LOT1 is a
# medication-started line ending on discontinuation; LOT2 ends on a new agent.

CLEAN_ROWS <- list(
  list(PATID = "P000001", LOT_NUM = 1L,
       LOT_START_DT = "2020-01-01", LOT_START_TYPE = "MED",
       LOT_BASE_MEDS = "BORT LEN DEX", LOT_MED_CNT = 3L,
       LOT_BASE_DISCON_DT = "2020-06-28", LOT_BASE_1ST_ADD_MED_DT = NULL,
       LOT_BASE_END_DT = "2020-06-28", LOT_BASE_END_REASON = "DISCONTINUATION",
       LOT_BASE_LENGTH = 180L,
       LOT_BASE_END_DT_CE_SENS = "2020-06-28",
       LOT_BASE_END_REASON_CE_SENS = "DISCONTINUATION",
       LOT_TX_AUTO_MAX_DT = NULL),
  list(PATID = "P000001", LOT_NUM = 2L,
       LOT_START_DT = "2020-07-01", LOT_START_TYPE = "SCT_AUTO",
       LOT_BASE_MEDS = "CARF DEX", LOT_MED_CNT = 2L,
       LOT_BASE_DISCON_DT = NULL, LOT_BASE_1ST_ADD_MED_DT = "2020-10-08",
       LOT_BASE_END_DT = "2020-10-08", LOT_BASE_END_REASON = "MED_ADD",
       LOT_BASE_LENGTH = 100L,
       LOT_BASE_END_DT_CE_SENS = "2020-10-08",
       LOT_BASE_END_REASON_CE_SENS = "MED_ADD",
       LOT_TX_AUTO_MAX_DT = "2020-07-01")
)

.plant <- function(base = 1L, ...) {
  r <- CLEAN_ROWS[[base]]
  r$PATID <- "P000009"
  utils::modifyList(r, list(...))
}

# `NULL` in modifyList REMOVES a field, so a plant that must null a column
# names it here instead.
.null_out <- function(r, cols) { for (c in cols) r[[c]] <- NA; r }

EXEC_CASES <- list(
  A1 = list(what = "a length that is not the span its own dates describe",
            planted = list(.plant(1L, LOT_BASE_LENGTH = 999L))),
  A2 = list(what = "a CE-sensitivity end AFTER the primary end",
            planted = list(.plant(1L, LOT_BASE_END_DT_CE_SENS = "2020-08-01"))),
  A3 = list(what = "DISENROLLMENT claimed where the cap did not move the date",
            planted = list(.plant(1L, LOT_BASE_END_REASON_CE_SENS = "DISENROLLMENT"))),
  A4 = list(what = "a line 1 that is not medication-started",
            planted = list(.plant(1L, LOT_START_TYPE = "SCT_AUTO"))),
  A5 = list(what = "a start type the build cannot write",
            planted = list(.plant(1L, LOT_START_TYPE = "SCT_CART"))),
  A6 = list(what = "a medication count that is not the size of its regimen string",
            planted = list(.plant(1L, LOT_MED_CNT = 7L))),
  A7 = list(what = "a medication-started line with no regimen",
            planted = list(.plant(1L, LOT_BASE_MEDS = "", LOT_MED_CNT = 0L))),
  B1 = list(what = "MED_ADD ending on a date that is not the added drug's",
            planted = list(.plant(2L, LOT_BASE_1ST_ADD_MED_DT = "2020-09-01"))),
  B2 = list(what = "DISCONTINUATION ending on a date that is not the run-out",
            planted = list(.plant(1L, LOT_BASE_DISCON_DT = "2020-05-01"))),
  B5 = list(what = "an end reason the build cannot write",
            planted = list(.plant(1L, LOT_BASE_END_REASON = "GAVE_UP"))),
  # These two read the DATE against the line's own start, not the end reason.
  # The first plants here got that wrong and both checks stayed silent - which
  # is the whole reason for running them rather than reading them.
  B6 = list(what = "an added-medication date BEFORE the line started",
            planted = list(.plant(2L, LOT_BASE_1ST_ADD_MED_DT = "2020-06-01"))),
  B7 = list(what = "a run-out date BEFORE the line started",
            planted = list(.plant(1L, LOT_BASE_DISCON_DT = "2019-12-01"))),
  B5b = list(what = "SCT_AUTO_CONT ending on a date that is not the transplant's",
             planted = list(.plant(2L, LOT_BASE_END_REASON = "SCT_AUTO_CONT",
                                   LOT_TX_AUTO_MAX_DT = "2020-08-15")))
)
