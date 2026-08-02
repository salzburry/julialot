# LOT1 start dates - the anchor every window is measured from.

build_lot1_starts_ndmm <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT1_STARTS} AS
    SELECT cast(PATID as string) AS PATID,
           LOT_START_DT AS LOT1_START_DT
    FROM {lot_long}
    WHERE LOT_NUM = 1
      AND LOT_START_DT IS NOT NULL
      AND LOT_START_DT >= date('{NDMM_LOT1_FROM}')
  "))
}

# MMA code list as a VALUES fragment, from cl_mma_codelist.csv. Built inside
# this script so the prior-therapy scan depends on no other build.
# Steroid MED_ABBR rows are dropped here, once, so every downstream query
# inherits the steroid exclusion without having to repeat it.
