# LOT1 start dates, the anchor every NDMM window is measured from.
#

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

# MMA codelist as a NDMM-side VALUES fragment. Same CSV (cl_mma_codelist.csv)
# and same column normalisation as parent S01 / pipeline_steps.R step 03,
# but materialised inside this script so the prior-MM-Tx scan does not
# depend on the parent having left mma_codelist alive in the session.
# Steroid MED_ABBR rows are dropped here, once, so every downstream query
# inherits the steroid exclusion without having to repeat it.
