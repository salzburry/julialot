# LOT1_START_DT per patient (the '1L cohort index date'), with the
# NDMM_LOT1_FROM cutoff enforced. Patients whose LOT1 starts before the
# cutoff are dropped from this view, which then propagates to every
# downstream NDMM step (lookback / belantamab / MM-Tx / other-cancer all join
# from here). Built in 00b_lot1_index.R.
