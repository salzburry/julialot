# Treatment observed inside a line that is not part of its regimen: an episode
# starting within the line, non-steroid, absent from LOT_BASE_MEDS. Descriptive
# only - it never reaches discon_per_med, so it cannot move the line's end.

# A LEFT JOIN producing one row per patient. `alias` is the base-end alias the
# caller has in scope; the three columns are that alias's line start, end and
# regimen string, which differ by line number.
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
