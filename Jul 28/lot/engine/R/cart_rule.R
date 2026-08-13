# The CAR-T induction rule.
#
# A CAR-T inside LOT1's induction window is part of LOT1. It does not end the
# line, and it does not start one.
#
# Without it, a CAR-T three weeks into first-line induction comes out as two
# lines: CART_INIT closes LOT1 the day before the infusion, and LOT2 opens as a
# CAR-T-started line. A CAR-T that soon after 1L started is not a second line -
# it is the same treatment episode, or an index date in the wrong place.
#
# LOT1 only, and 60 days only, because that is what was asked for and confirmed:
# "if the first CAR-T falls within the 60 day induction window they are
# considered to be in LOT 1 and not a LOT2 start". LOT2+ keep their own windows
# and a CAR-T there behaves as it always has.
#
# ---- Filter the rows, not the aggregate --------------------------------------
#
# The first version of this gated FIRST_CART_DT, which lot1_sct had already
# reduced to min(TX_DT) over every CAR-T in LOT1's observation window. Two
# defects followed, and both are the same mistake:
#
#   A patient with a CAR-T on day 20 and another on day 90 had the min taken
#   first - day 20 - and that single date nulled. The day-90 infusion, which is
#   outside induction and should end LOT1, was never looked at again. It ended
#   nothing and started nothing, and the patient lost a line.
#
#   The same day-20 CAR-T still censored later AUTOs out of LOT1, because
#   earliest_non_auto is built on the assumption that any ALLO or CAR-T ends the
#   line. Declared part of LOT1 by one rule and treated as its boundary by
#   another, it removed a transplant that belongs in the line.
#
# So the induction test is applied per row, before anything is aggregated, and
# lot1_sct carries two columns: FIRST_CART_DT, the earliest CAR-T of any kind,
# which is descriptive and is what LOT1_1ST_SCT_DT is built from; and
# ENDING_CART_DT, the earliest one eligible to end the line. Every boundary
# reads the second. A CAR-T can only be in one of those roles, and which one is
# a property of the row, not of the group.
#
# ---- Where it reaches ---------------------------------------------------------
#
#   1. first_cart          ENDING_CART_DT, so a later CAR-T is still a boundary.
#   2. earliest_non_auto   an in-induction CAR-T stops censoring AUTOs.
#   3. lot1_base_end       CART_INIT and the end date read ENDING_CART_DT.
#   4. lot2 d_CART         the suppressed infusion cannot open LOT2 either.
#
# What it deliberately does NOT do: extend LOT1 to swallow a CAR-T that arrived
# after LOT1 had already ended for some other reason. If a runout or an added
# medication closed the line on day 30 and the CAR-T is on day 40, the line
# ended on day 30 - the rule stops that CAR-T starting a line, it does not
# reopen a closed one. Those patients are counted by q3_cart_screen() in
# lot/questions/jul20_studyteam_qs.R, and the reading is open for sign-off.

# Whether a CAR-T date sits inside LOT1's induction window.
#
# Values rather than cfg, because steps/10_lot2_5_base.R takes every setting as
# a parameter and reads no global - and the window here is always LOT1's 60,
# never that file's own 30.
cart_in_induction_sql <- function(cart_col, lot1_start_col, window_days) {
  paste0(cart_col, " IS NOT NULL AND ", lot1_start_col, " IS NOT NULL",
         " AND ", cart_col, " BETWEEN ", lot1_start_col,
         " AND date_add(", lot1_start_col, ", ",
         as.integer(window_days) - 1L, ")")
}

# A CAR-T date only when it is eligible to end a line, for use INSIDE an
# aggregate - min() over this is the earliest boundary-eligible infusion rather
# than the earliest infusion, nulled.
#
# When the rule is off this is the column itself, so min() over it is what it
# always was and the generated SQL is unchanged.
cart_eligible_dt <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return(cart_col)
  paste0("CASE WHEN NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days),
         ") THEN ", cart_col, " END")
}

# Stops an in-induction CAR-T censoring the AUTOs that follow it. ANDed into the
# WHERE that collects the ALLO/CAR-T events treated as LOT1 boundaries; empty
# when the rule is off.
cart_censor_predicate <- function(on, type_col, cart_col, lot1_start_col,
                                  window_days) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (", type_col, " = 'CART' AND ",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days), ")")
}

# Keeps the same infusion out of LOT2's start candidates. Empty when off, so the
# clause it sits in is unchanged.
cart_exclude_predicate <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days), ")")
}
