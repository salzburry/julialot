# The CAR-T induction rule.
#
# A CAR-T inside LOT1's 60-day induction window is part of LOT1. It neither ends
# the line nor starts one. LOT1 only; LOT2+ keep their own windows.
#
# The window test runs per row, before any aggregate. So lot1_sct carries two
# dates: FIRST_CART_DT, the earliest infusion of any kind, and ENDING_CART_DT,
# the earliest one allowed to end the line. Every boundary reads the second.
# Gate the aggregate instead and a later CAR-T that should have ended the line
# is lost.
#
# It does not reopen a line that had already ended for another reason.

# Is this CAR-T date inside LOT1's induction window? Takes values rather than
# cfg: 10_lot2_5_base.R reads no globals, and the window here is always LOT1's
# 60, not that file's own 30.
cart_in_induction_sql <- function(cart_col, lot1_start_col, window_days) {
  paste0(cart_col, " IS NOT NULL AND ", lot1_start_col, " IS NOT NULL",
         " AND ", cart_col, " BETWEEN ", lot1_start_col,
         " AND date_add(", lot1_start_col, ", ",
         as.integer(window_days) - 1L, ")")
}

# A CAR-T date, but only where it may end a line. For use inside an aggregate:
# min() over this gives the earliest infusion that can be a boundary. With the
# rule off it is the column itself and the SQL is unchanged.
cart_eligible_dt <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return(cart_col)
  paste0("CASE WHEN NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days),
         ") THEN ", cart_col, " END")
}

# Stops an in-induction CAR-T censoring the AUTOs after it. ANDed into the WHERE
# that collects LOT1's boundary events. Empty when the rule is off.
cart_censor_predicate <- function(on, type_col, cart_col, lot1_start_col,
                                  window_days) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (", type_col, " = 'CART' AND ",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days), ")")
}

# Keeps the same infusion out of LOT2's start candidates. Empty when off.
#
# `active_through` is the last day LOT1 was still running - its end date. The
# exemption depends on it, because "part of LOT1" means nothing for an infusion
# arriving after LOT1 has ended. Without it the window outlives the line. A LOT1
# that discontinued inside its own 60 days left a CAR-T that this predicate
# refused as a LOT2 start and no other rule could place. The infusion belonged
# to no line at all.
#
# cart_cand already requires TX_DT > PREV_END_DT, so the condition makes the
# predicate inert there. That is the point: every CAR-T reaching it is one LOT1
# has already ended before. Written as a condition rather than deleted, so the
# rule reads as the rule, and so a caller with a different frame cannot reopen
# the gap by accident.
cart_exclude_predicate <- function(on, cart_col, lot1_start_col, window_days,
                                   active_through) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days),
         "\n                 AND ", cart_col, " <= ", active_through, ")")
}
