# MMA code list as a VALUES fragment, from cl_mma_codelist.csv. Built inside
# this script so the prior-therapy scan depends on no other build.
# Steroid MED_ABBR rows are dropped here, once, so every downstream query
# inherits the steroid exclusion without having to repeat it.
