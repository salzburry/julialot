"""Golden numbers for three readings the default run never emits.

Run with DX_DATE_SOURCE=baseline_first_claim, ENROL_ATTR_AT=latest_span and
MALIG_PREVALENCE_WINDOW=baseline, over the same fixtures. Every number is
derived by hand in fixtures/EXPECTED.md, under "The diagnosis date",
"Demographics" and "Secondary malignancy".
"""

EXPECTATIONS = [
    # Table 4: "first medical claim for MM within the baseline period on or
    # prior to 1L". P1's qualifying diagnosis on the cohort table is
    # 2019-01-05; its first MM claim inside [2018-03-01, 2019-03-01] is
    # 2018-06-01, and under this reading that is the date the rows hang on.
    ("the diagnosis date is the first MM claim in the 1L baseline, index day included",
     "SELECT MM_DX_DT::VARCHAR, DX_DT::VARCHAR, DX_DT_SOURCE, DX_YEAR "
     "FROM wk.S_PERIODS WHERE PATID='P1' AND COHORT='1L'",
     [("2019-01-05", "2018-06-01", "baseline_claim", 2018)]),
    # P6 has no diagnosis row in the fixture at all, so the window is empty
    # and the cohort's own date stands in - and the row says so.
    ("a patient with no MM claim in that window takes the cohort's date, and the row says so",
     "SELECT DX_DT::VARCHAR, DX_DT_SOURCE FROM wk.S_PERIODS "
     "WHERE PATID='P6' AND COHORT='1L'",
     [("2019-01-01", "cohort_mm_dx")]),
    ("time from diagnosis to index counts the diagnosis day and not the index day",
     "SELECT DX_TO_INDEX_DAYS, DX_TO_INDEX_MONTHS FROM wk.S_PERIODS "
     "WHERE PATID='P1' AND COHORT='1L'",
     [(273, 8.97)]),   # 2018-06-01 -> 2019-03-01, bare datediff
    ("follow-up from diagnosis counts both ends",
     "SELECT FU_FROM_DX_DAYS FROM wk.S_PERIODS WHERE PATID='P2' AND COHORT='1L'",
     [(700,)]),        # 2018-08-01 -> 2020-06-30 inclusive
    ("a 2L row's diagnosis is anchored on the patient's 1L, not on the 2L baseline",
     "SELECT DX_DT::VARCHAR, DX_TO_INDEX_DAYS FROM wk.S_PERIODS "
     "WHERE PATID='P1' AND COHORT='2L'",
     [("2018-06-01", 639)]),

    # ENROL_ATTR_AT=latest_span: the most recent enrolment row, wherever it
    # falls. P7's later row is NY and commercial.
    ("the latest enrolment row supplies the attributes under the other reading",
     "SELECT REGION, INSURANCE_TYPE, ATTR_SOURCE FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P7' AND COHORT='1L'",
     [("Northeast", "Commercial Health Plan", "latest_span")]),

    # MALIG_PREVALENCE_WINDOW=baseline: the 12-month window Objective 1 uses,
    # so four baseline years. P1's malignancy on 2019-07-01 is inside its 2L
    # baseline (2019-03-02 -> 2020-02-29) as well.
    ("under the baseline reading the prevalence window is the four baseline years",
     "SELECT N_PATIENTS, N_AT_RISK, round(PERSON_YEARS,4) FROM wk.S_MALIGNANCY_RATES "
     "WHERE COHORT='SEC2L' AND PERIOD='BASELINE' AND LOT_NUM=2 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CATEGORY='Hematological'",
     [(1, 4, 3.9973)]),
]
