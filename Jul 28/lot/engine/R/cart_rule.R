# The CAR-T induction rule.
#
# A CAR-T inside LOT1's 60-day induction window is part of LOT1: it neither ends
# the line nor starts one. LOT1 only; LOT2+ keep their own windows.
#
# The window test is applied per row, before any aggregation, so lot1_sct
# carries two dates: FIRST_CART_DT, the earliest infusion of any kind, and
# ENDING_CART_DT, the earliest one eligible to end the line. Every boundary
# reads the second. Gating the aggregate instead loses a later CAR-T that
# should have ended the line.
#
# It does not reopen a line that had already ended for another reason.

# Whether a CAR-T date sits inside LOT1's induction window. Takes values rather
# than cfg: 10_lot2_5_base.R reads no globals, and the window is always LOT1's
# 60 rather than that file's own 30.
cart_in_induction_sql <- function(cart_col, lot1_start_col, window_days) {
  paste0(cart_col, " IS NOT NULL AND ", lot1_start_col, " IS NOT NULL",
         " AND ", cart_col, " BETWEEN ", lot1_start_col,
         " AND date_add(", lot1_start_col, ", ",
         as.integer(window_days) - 1L, ")")
}

# A CAR-T date only where it may end a line, for use inside an aggregate: min()
# over this gives the earliest boundary-eligible infusion. Off, it is the column
# itself and the SQL is unchanged.
cart_eligible_dt <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return(cart_col)
  paste0("CASE WHEN NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days),
         ") THEN ", cart_col, " END")
}

# Stops an in-induction CAR-T censoring the AUTOs after it. ANDed into the WHERE
# that collects LOT1 boundary events; empty when off.
cart_censor_predicate <- function(on, type_col, cart_col, lot1_start_col,
                                  window_days) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (", type_col, " = 'CART' AND ",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days), ")")
}

# Keeps the same infusion out of LOT2's start candidates. Empty when off.
cart_exclude_predicate <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days), ")")
}
