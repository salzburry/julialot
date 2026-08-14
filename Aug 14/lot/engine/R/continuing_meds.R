# Treatment observed inside a line that is not part of its regimen.
#
# The returning-agent rule stops an agent whose cover merely lapsed from opening
# a line. Without somewhere to put it, that agent then appears nowhere: it is not
# in LOT_BASE_MEDS, which is fixed at induction; it is not a boundary, because
# the rule rejected it; and it does not reach the next line either. A month of
# dispensed therapy would simply be absent from the output.
#
# So it is recorded beside the regimen rather than inside it. LOT_BASE_MEDS stays
# what the protocol defines - agents received in the induction window - and
# LOT_CONTINUING_MEDS carries what else the patient was actually on while the
# line ran.
#
# Deliberately descriptive. discon_per_med joins base_meds, so the regimen set is
# also the run-out set, and adding an agent to LOT_BASE_MEDS would hand it
# control of the line's end date. Whether a continuing agent should hold a line
# open is a separate question and not settled; this column does not answer it.
#
# The membership test needs no reference to the discontinuation flag. An agent
# the rule accepted ends the line the day before its own start, so it falls
# outside the span this bounds on, and cannot appear here. The set is therefore
# the same whether the rule is on or off - empty when it is off, because then
# nothing is rejected.

# A LEFT JOIN producing one row per patient. `alias` is the base-end alias the
# caller already has in scope; the three columns are that alias's line start, end
# and regimen string, which differ by line number.
continuing_meds_join_sql <- function(base_view, alias, start_col, end_col,
                                     meds_col, map_tbl = "map_stacked") {
  paste0("
    LEFT JOIN (
      SELECT ms.PATID,
             concat_ws(' ', sort_array(collect_set(ms.MAP_MED_TYPE)))
                                                     AS LOT_CONTINUING_MEDS
      FROM ", map_tbl, " ms
      INNER JOIN ", base_view, " b ON ms.PATID = b.PATID
      WHERE ms.MAP_MED_CLASS <> 'STEROID'
        AND ms.MAP_START_DT >= b.", start_col, "
        AND ms.MAP_START_DT <= b.", end_col, "
        AND NOT array_contains(split(coalesce(b.", meds_col, ", ''), ' '),
                               ms.MAP_MED_TYPE)
      GROUP BY ms.PATID
    ) cm ON cm.PATID = ", alias, ".PATID")
}
