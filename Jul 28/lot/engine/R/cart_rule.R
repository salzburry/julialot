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
# Three places a CAR-T acts on a line, and the rule has to reach all three or it
# only moves the problem:
#
#   1. lot1_sct        FIRST_CART_DT feeds LOT1_TX_ENDDATE, which ends LOT1 as
#                      SCT_CART.
#   2. lot1_base_end   CART_INIT_FLG reads FIRST_CART_DT directly, and ends
#                      LOT1 at FIRST_CART_DT - 1.
#   3. lot2 d_CART     the same CAR-T opens LOT2. Suppressing only 1 and 2
#                      moves the infusion from ending LOT1 to starting LOT2,
#                      which is the same two lines with different dates.
#
# What it deliberately does NOT do: extend LOT1 to swallow a CAR-T that arrived
# after LOT1 had already ended for some other reason. If a runout or an added
# medication closed the line on day 30 and the CAR-T is on day 40, the line
# ended on day 30 - the rule stops that CAR-T starting a line, it does not
# reopen a closed one. Those patients are counted by q3_cart_screen() in
# lot/questions/jul20_studyteam_qs.R.

# Whether a CAR-T date sits inside LOT1's induction window. Written as SQL
# rather than computed once, because the three call sites see it in three
# different relations and none of them shares a row grain with the others.
# Values rather than cfg, because steps/10_lot2_5_base.R takes every setting as
# a parameter and reads no global - and the window here is always LOT1's 60,
# never that file's own 30.
cart_in_induction_sql <- function(cart_col, lot1_start_col, window_days) {
  paste0(cart_col, " IS NOT NULL AND ", lot1_start_col, " IS NOT NULL",
         " AND ", cart_col, " BETWEEN ", lot1_start_col,
         " AND date_add(", lot1_start_col, ", ",
         as.integer(window_days) - 1L, ")")
}

# The CAR-T date for line-boundary purposes: the column itself, or NULL when the
# rule is on and the infusion is inside induction.
#
# When the rule is off this returns the column unchanged, so the generated SQL
# is byte-identical to what it was - which is what keeps the off path provably
# the old algorithm rather than a re-derivation of it.
cart_line_dt <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return(cart_col)
  paste0("CASE WHEN ", cart_in_induction_sql(cart_col, lot1_start_col, window_days),
         " THEN NULL ELSE ", cart_col, " END")
}

# The same, as a predicate to AND into a WHERE clause. Empty when the rule is
# off, so the clause it sits in is unchanged.
cart_exclude_predicate <- function(on, cart_col, lot1_start_col, window_days) {
  if (!isTRUE(on)) return("")
  paste0("\n        AND NOT (",
         cart_in_induction_sql(cart_col, lot1_start_col, window_days), ")")
}
