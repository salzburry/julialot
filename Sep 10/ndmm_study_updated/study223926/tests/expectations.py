"""The golden numbers. Every one is derived by hand in fixtures/EXPECTED.md.

Each entry is (name, query, expected rows). The queries are deliberately
narrow: a check that reads one number and says what it is survives a fixture
change that a whole-table snapshot would not, and names the rule it broke.
"""

PY_BASELINE = round(365 / 365.25, 6)

EXPECTATIONS = [
    # --- enrolment spans: the protocol's <= 30 day bridge -----------------
    ("P3's two enrolment rows 9 days apart bridge into one span",
     "SELECT COV_START::VARCHAR, COV_END::VARCHAR FROM wk.S_ENROLL_SPANS "
     "WHERE PATID='P3' ORDER BY COV_START",
     [("2018-01-01", "2021-12-31")]),
    ("P6's two rows 60 days apart stay separate",
     "SELECT COV_START::VARCHAR, COV_END::VARCHAR FROM wk.S_ENROLL_SPANS "
     "WHERE PATID='P6' ORDER BY COV_START",
     [("2018-01-01", "2019-12-31"), ("2020-03-01", "2026-12-31")]),

    # --- the spine: lead() must see past MAX_LOT --------------------------
    ("P5's line 4 sees line 5 even though MAX_LOT drops line 5",
     "SELECT NEXT_LOT_START_DT::VARCHAR FROM wk.S_SPINE "
     "WHERE PATID='P5' AND LOT_NUM=4",
     [("2023-01-15",)]),
    ("and MAX_LOT still drops line 5 from the spine",
     "SELECT max(LOT_NUM) FROM wk.S_SPINE", [(4,)]),
    ("the protocol's discontinuation is the union of the end reasons",
     "SELECT IS_PROTOCOL_DISCON FROM wk.S_SPINE "
     "WHERE PATID='P1' AND LOT_NUM=3",   # MED_ADD, not DISCONTINUATION
     [(1,)]),

    # --- cohort membership ------------------------------------------------
    ("the 1L cohort is the seven patients indexed on or after 2019-01-01",
     "SELECT count(*) FROM wk.S_COHORT WHERE COHORT='1L' AND IN_COHORT=1",
     [(7,)]),
    ("P4 indexes before the 2019 floor and is not in it",
     "SELECT count(*) FROM wk.S_COHORT WHERE COHORT='1L' AND PATID='P4'",
     [(0,)]),
    ("2L is a subset of 1L, and P6 qualifies on its own index's enrolment",
     "SELECT PATID FROM wk.S_COHORT WHERE COHORT='2L' AND IN_COHORT=1 "
     "ORDER BY PATID",
     [("P1",), ("P3",), ("P5",), ("P6",)]),
    ("the attrition funnel never gains patients as it descends",
     "SELECT count(*) FROM (SELECT N_REMAINING, lag(N_REMAINING) OVER "
     "(PARTITION BY COHORT ORDER BY STEP) AS prev FROM wk.S_ATTRITION) t "
     "WHERE prev IS NOT NULL AND N_REMAINING > prev",
     [(0,)]),

    # --- follow-up: per-cohort, never negative ---------------------------
    ("P6's 2L follow-up ends at the study end, not at its 1L enrolment end",
     "SELECT FU_END::VARCHAR FROM wk.S_PERIODS WHERE PATID='P6' AND COHORT='2L'",
     [("2026-03-31",)]),
    ("P6's 1L follow-up still ends when its 1L enrolment span does",
     "SELECT FU_END::VARCHAR FROM wk.S_PERIODS WHERE PATID='P6' AND COHORT='1L'",
     [("2019-12-31",)]),
    ("no patient in any cohort has negative follow-up",
     "SELECT count(*) FROM wk.S_PERIODS WHERE FU_DAYS < 0", [(0,)]),
    ("P2's follow-up ends at disenrolment, before its death",
     "SELECT FU_END::VARCHAR, FU_DAYS FROM wk.S_PERIODS "
     "WHERE PATID='P2' AND COHORT='1L'",
     [("2020-06-30", 396)]),
    ("baseline person-years are 365/365.25, the window's own length",
     "SELECT DISTINCT round(BASELINE_PY, 6) FROM wk.S_PERIODS",
     [(PY_BASELINE,)]),
    ("a treatment period stops the day before the next line starts",
     "SELECT PERIOD_END::VARCHAR FROM wk.S_LOT_PERIODS "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=1",
     [("2020-02-14",)]),   # discon 2020-01-15 + 30 < next line - 1

    # --- Charlson, MM-adjusted -------------------------------------------
    ("P1's only cancer code is its myeloma, so its CCI is 0",
     "SELECT CCI FROM wk.S_COMORBIDITY WHERE PATID='P1' AND COHORT='1L'",
     [(0.0,)]),
    ("P3 has myeloma AND breast cancer, so any_malignancy still scores",
     "SELECT CCI FROM wk.S_COMORBIDITY WHERE PATID='P3' AND COHORT='1L'",
     [(2.0,)]),
    ("P2's congestive heart failure scores Quan's 2",
     "SELECT CCI FROM wk.S_COMORBIDITY WHERE PATID='P2' AND COHORT='1L'",
     [(2.0,)]),
    ("mild and severe liver disease score Quan's 4, not their sum of 6",
     "SELECT CCI FROM wk.S_COMORBIDITY WHERE PATID='P5' AND COHORT='1L'",
     [(4.0,)]),
    ("every 1L patient has a comorbidity row, including the zeroes",
     "SELECT count(*) FROM wk.S_COMORBIDITY WHERE COHORT='1L'", [(7,)]),

    # --- SOC: the regimen decides, not the winning agent's row -----------
    ("three agents with an anti-CD38 backbone is the anti-CD38 triplet",
     "SELECT SOC_CATEGORY FROM wk.S_SOC "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=1",
     [("Triplet with anti-CD38 backbone",)]),
    ("two agents is a doublet even when an agent maps to a triplet category",
     "SELECT SOC_CATEGORY FROM wk.S_SOC "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=2",
     [("Doublet/monotherapy",)]),
    ("four agents with that backbone is the quadruplet",
     "SELECT SOC_CATEGORY FROM wk.S_SOC "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=3",
     [("Quadruplet with anti-CD38 backbone",)]),
    ("the 3L cohort's regimens start at its own index line",
     "SELECT DISTINCT LOT_NUM FROM wk.S_SOC WHERE COHORT='3L' ORDER BY LOT_NUM",
     [(3,), (4,)]),

    # --- demographics -----------------------------------------------------
    ("age is the index year minus the birth year",
     "SELECT AGE_YEARS, AGE_BAND FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P1' AND COHORT='1L'",
     [(69, "65-74")]),
    # YRDOB is 0 on 614 rows of the deployed enrolment table. Unguarded,
    # year(index) - 0 is an age of about 2026, which lands every one of them in
    # the 75+ band - the band the protocol uses as its transplant-eligibility
    # proxy.
    ("a birth year of 0 is an unknown age, not an age of 2020",
     "SELECT AGE_YEARS, AGE_BAND FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P8' AND COHORT='1L'",
     [(None, "Unknown")]),
    ("and a birth year at the 89-year cap is still a real age",
     "SELECT AGE_YEARS, AGE_BAND FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P7' AND COHORT='1L'",
     [(83, "75+")]),
    ("the 75+ band is the transplant-eligibility proxy and is not empty",
     "SELECT PATID FROM wk.S_DEMOGRAPHICS "
     "WHERE COHORT='1L' AND AGE_BAND='75+' ORDER BY PATID",
     [("P5",), ("P7",)]),
    ("the CDM's own BUS codes map to the protocol's insurance types",
     "SELECT DISTINCT INSURANCE_TYPE FROM wk.S_DEMOGRAPHICS "
     "WHERE COHORT='1L' ORDER BY 1",
     [("Commercial Health Plan",), ("Medicare",)]),
    ("state maps to census region",
     "SELECT REGION FROM wk.S_DEMOGRAPHICS WHERE PATID='P5' AND COHORT='1L'",
     [("Midwest",)]),

    # --- safety counting: s7.8.1 -----------------------------------------
    ("two claims on one day are one event",
     "SELECT count(*) FROM wk.S_SAFETY_EVENTS WHERE PATID='P1' "
     "AND COHORT='1L' AND CONDITION='acute_hepatitis_b' "
     "AND EVENT_DT='2019-04-01'",
     [(1,)]),
    ("an acute event 9 days after a counted one does not count; 61 days does",
     "SELECT EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P1' "
     "AND COHORT='1L' AND PERIOD='TREATMENT' "
     "AND CONDITION='acute_hepatitis_b' ORDER BY EVENT_DT",
     [("2019-04-01",), ("2019-06-01",)]),
    ("a chronic condition counts once however many times it is coded",
     "SELECT count(*) FROM wk.S_SAFETY_COUNTED WHERE PATID='P5' "
     "AND COHORT='1L' AND PERIOD='TREATMENT' "
     "AND CONDITION='toxic_liver_disease'",
     [(1,)]),
    ("two acute events exactly 30 days apart are two events, not one",
     "SELECT EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P3' "
     "AND COHORT='1L' AND PERIOD='TREATMENT' "
     "AND CONDITION='acute_hepatitis_b' ORDER BY EVENT_DT",
     [("2020-03-01",), ("2020-03-31",)]),
    ("a chronic code ON the period start is not prior history",
     "SELECT count(*) FROM wk.S_SAFETY_COUNTED WHERE PATID='P2' "
     "AND COHORT='1L' AND PERIOD='TREATMENT' "
     "AND CONDITION='toxic_liver_disease'",
     [(1,)]),
    ("a chronic condition with prior history counts for nobody on treatment",
     "SELECT count(*) FROM wk.S_SAFETY_COUNTED WHERE PATID='P1' "
     "AND COHORT='1L' AND PERIOD='TREATMENT' "
     "AND CONDITION='toxic_liver_disease'",
     [(0,)]),
    # The baseline period counts the SAME way - washout for acute, once for
    # chronic - and differs in exactly one thing, which is the protocol's:
    # s7.8.1 takes the baseline denominator "irrespective of prior event
    # history", so nobody is dropped from it and a chronic first occurrence
    # counts for everyone.
    ("but it does count at baseline, where prior history is irrelevant",
     "SELECT EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P1' "
     "AND COHORT='1L' AND PERIOD='BASELINE' "
     "AND CONDITION='toxic_liver_disease'",
     [("2018-07-01",)]),
    ("and nobody leaves the baseline denominator",
     "SELECT N_AT_RISK, round(PERSON_YEARS,4) FROM wk.S_SAFETY_RATES "
     "WHERE COHORT='1L' AND PERIOD='BASELINE' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND CONDITION='toxic_liver_disease'",
     [(7, 6.9952)]),
    ("while on treatment the not-at-risk leave it",
     "SELECT N_AT_RISK FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND CONDITION='toxic_liver_disease'",
     [(6,)]),
    ("every condition gets a baseline row too, events or not",
     "SELECT count(*) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='BASELINE' AND SOC_CATEGORY='(all categories)'",
     [(23,)]),
    # Chronic person-time ends at the first occurrence, so a patient who has
    # the event contributes only up to it. Derived by hand in EXPECTED.md:
    # P1 0 (prior history) + P2 1/365.25 + P3 0.416153 + P5 77/365.25
    # + P6 0.588638 + P7 0.670773 + P8 0.670773 = 2.5599.
    # Suppression tests the stratum, not the event-positive count. A condition
    # with one patient among a 7-patient at-risk stratum is below 25 either
    # way, so the fixture cannot separate the two by size - but the released
    # row must be suppressed on N_AT_RISK and must carry N_PATIENTS among the
    # values it nulls, which is what testing the wrong column got wrong.
    ("release suppresses on the stratum and nulls the event count with it",
     "SELECT SUPPRESSED, N_AT_RISK, N_PATIENTS FROM wk.S_SAFETY_RATES_RELEASE "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND CONDITION='toxic_liver_disease'",
     [(1, None, None)]),
    # P6's 1L follow-up ends 2019-12-31; its 2L starts 2022-06-01, two and a
    # half years later. The LOT engine builds that line because it continues
    # through enrolment gaps, but this cohort stopped observing P6 long before
    # it, so it belongs in neither the treatment patterns nor the terminal
    # state. Unbounded, S_SOC carried ('P6', 2) while TTNT censored P6.
    ("a line starting after the cohort's follow-up is not a cohort line",
     "SELECT count(*) FROM wk.S_SOC WHERE COHORT='1L' AND PATID='P6'",
     [(1,)]),
    # The funnel has to end where the cohort begins. When the exclusions became
    # effective here, the funnel still accumulated only enrolment and
    # follow-up, so its last N_REMAINING could exceed the cohort it described.
    ("the funnel's last step equals the cohort it describes",
     "SELECT f.N_REMAINING - (SELECT count(*) FROM wk.S_COHORT "
     "  WHERE COHORT='1L' AND IN_COHORT=1) "
     "FROM wk.S_ATTRITION f WHERE f.COHORT='1L' "
     "AND f.STEP = (SELECT max(STEP) FROM wk.S_ATTRITION WHERE COHORT='1L')",
     [(0,)]),
    ("and so does the secondary cohort's",
     "SELECT f.N_REMAINING - (SELECT count(*) FROM wk.S_COHORT "
     "  WHERE COHORT='SEC2L' AND IN_COHORT=1) "
     "FROM wk.S_ATTRITION f WHERE f.COHORT='SEC2L' "
     "AND f.STEP = (SELECT max(STEP) FROM wk.S_ATTRITION WHERE COHORT='SEC2L')",
     [(0,)]),
    # And the periods table, which is built from IN_COHORT = 1, agrees too.
    ("and the periods built from it carry the same patients",
     "SELECT count(DISTINCT PATID) - (SELECT count(*) FROM wk.S_COHORT "
     "  WHERE COHORT='1L' AND IN_COHORT=1) "
     "FROM wk.S_PERIODS WHERE COHORT='1L'",
     [(0,)]),
    # S_MALIGNANCY_DATES is a per-cohort partition, not a table replaced on
    # every invocation. CREATE OR REPLACE inside a module that runs once per
    # cohort left only the last cohort's rows in a registered output.
    ("malignancy date evidence survives every cohort, not just the last",
     "SELECT count(DISTINCT COHORT) FROM wk.S_MALIGNANCY_DATES",
     [(4,)]),
    # NOT a `>= 99` filter on an eight-patient fixture - that expects no rows
    # and passes whatever the code does, which is why it missed this.
    #
    # P1, P3 and P5 start a 2L inside their 1L follow-up; P6 starts one
    # 2022-06-01, two and a half years after its 1L follow-up ended. So
    # `received_next_lot` on line 1 is 3, and line 2 carries those same 3
    # patients. Both are 4 if the follow-up bound is removed.
    ("and it is censoring, not receipt of a next line",
     "SELECT N_PATIENTS FROM wk.S_TX_ATTRITION WHERE COHORT='1L' "
     "AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND OUTCOME='received_next_lot'",
     [(3,)]),
    ("and the unobserved line adds nobody to the next line's attrition",
     "SELECT sum(N_PATIENTS) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' "
     "AND LOT_NUM=2 AND SOC_CATEGORY='(all categories)'",
     [(3,)]),
    ("and that patient leaves the chronic denominator too",
     "SELECT round(PERSON_YEARS,4) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' "
     "AND CONDITION='toxic_liver_disease'",
     [(2.5599,)]),
    # The same denominator with P5's first event moved 31 days earlier must
    # fall by exactly 31/365.25. Guarding the rule, not just the number:
    # summing PERIOD_PY regardless made this difference zero.
    ("and moving a first chronic event earlier shortens that denominator",
     "SELECT round(("
     "  SELECT PERSON_YEARS FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "  AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "  AND SOC_CATEGORY='(all categories)' AND CONDITION='toxic_liver_disease') "
     " - (SELECT sum(CASE WHEN PATID='P5' THEN 31.0/365.25 ELSE 0 END) "
     "    FROM wk.S_LOT_PERIODS WHERE COHORT='1L' AND LOT_NUM=1), 4)",
     [(2.4750,)]),
    ("while an acute condition keeps every patient's person-time",
     "SELECT round(PERSON_YEARS,4) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)'"
     "AND CONDITION='acute_hepatitis_b'",
     [(4.8569,)]),
    # --- the regimen-category stratification ------------------------------
    #
    # Every rate and count table is written twice: once for the line as a
    # whole, labelled (all categories), and once per SOC category. The claim
    # the whole thing rests on is that the categories are a PARTITION of the
    # line - same patients, same person-time, cut a different way - so each of
    # these adds the categories up and expects the line's own row back. A
    # GROUP BY that lost or duplicated a patient-line shows up here and
    # nowhere else, because every stratum in this fixture is far below the
    # floor and every released number is NULL.
    ("the line's own row is there, and so are the categories",
     "SELECT CASE WHEN count(*) > 0 THEN 1 ELSE 0 END "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND CONDITION='toxic_liver_disease' "
     "AND SOC_CATEGORY <> '(all categories)'",
     [(1,)]),
    ("no line falls outside the categories",
     "SELECT count(*) FROM wk.S_SAFETY_RATES "
     "WHERE SOC_CATEGORY='(uncategorised)'",
     [(0,)]),
    ("the categories' at-risk counts sum to the line's",
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 "
     "            ELSE N_AT_RISK END) "
     "     - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_AT_RISK END) "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND CONDITION='toxic_liver_disease'",
     [(0,)]),
    ("...and their person-time does too",
     "SELECT round(sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 "
     "                  ELSE PERSON_YEARS END) "
     "     - max(CASE WHEN SOC_CATEGORY='(all categories)' "
     "                THEN PERSON_YEARS END), 6) "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND CONDITION='toxic_liver_disease'",
     [(0.0,)]),
    ("...and the patients who had the event",
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 "
     "            ELSE N_PATIENTS END) "
     "     - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_PATIENTS END) "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND CONDITION='acute_hepatitis_b'",
     [(0,)]),
    ("the same holds for healthcare resource use",
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 "
     "            ELSE N_EVENTS END) "
     "     - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_EVENTS END) "
     "FROM wk.S_HCRU_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND MEASURE='ALL_CAUSE_HOSPITALISATION'",
     [(0,)]),
    ("and for what happened at the end of each line",
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 "
     "            ELSE N_PATIENTS END) "
     "     - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_PATIENTS END) "
     "FROM wk.S_TX_ATTRITION WHERE COHORT='1L' AND LOT_NUM=1 "
     "AND OUTCOME='received_next_lot'",
     [(0,)]),
    ("a category's percentage is out of that category, not the line",
     "SELECT count(*) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' AND LOT_NUM=1 "
     "AND SOC_CATEGORY <> '(all categories)' AND N_DENOM > "
     "(SELECT max(N_DENOM) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' "
     " AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)')",
     [(0,)]),
    ("and a category below the floor is suppressed like any other stratum",
     "SELECT count(*) FROM wk.S_SAFETY_RATES_RELEASE "
     "WHERE SOC_CATEGORY <> '(all categories)' AND SUPPRESSED = 0",
     [(0,)]),

    ("every condition gets an incidence row, events or not",
     "SELECT count(DISTINCT CONDITION) FROM wk.S_SAFETY_RATES "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)'",
     [(23,)]),

    # --- HCRU -------------------------------------------------------------
    ("MM-related means myeloma in the first or second diagnosis position",
     "SELECT count(*) FROM wk.S_HCRU_EVENTS WHERE COHORT='1L' "
     "AND EVENT_TYPE='INPATIENT' AND MM_RELATED=1",
     [(2,)]),   # P1's C1 and P2's C3; P1's C2 has myeloma in position 3
    ("LOS counts the admit day and not the discharge day",
     "SELECT LOS_DAYS FROM wk.S_HCRU_EVENTS WHERE PATID='P1' "
     "AND COHORT='1L' AND EVENT_DT='2019-05-01'",
     [(5,)]),
    ("a stay with no discharge date is an event with no LOS",
     "SELECT LOS_DAYS, HAS_DISCHARGE FROM wk.S_HCRU_EVENTS "
     "WHERE PATID='P2' AND COHORT='1L' AND EVENT_TYPE='INPATIENT'",
     [(None, 0)]),
    ("and is excluded from the LOS summary while still counting as an event",
     "SELECT N_EVENTS, MEAN_LOS, N_LOS_EXCLUDED FROM wk.S_HCRU_RATES "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND MEASURE='MM_RELATED_HOSPITALISATION'",
     [(2, 5.0, 1)]),
    ("two ED claim lines on one day are one visit",
     "SELECT count(*) FROM wk.S_HCRU_EVENTS WHERE PATID='P1' "
     "AND COHORT='1L' AND EVENT_TYPE='ED' AND EVENT_DT='2019-05-20'",
     [(1,)]),
    ("N_PATIENTS counts patients and N_EVENTS counts events",
     "SELECT N_PATIENTS, N_EVENTS FROM wk.S_HCRU_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND MEASURE='ALL_CAUSE_HOSPITALISATION'",
     [(2, 3)]),
    ("a line with person-time and no events still gets a row per measure",
     "SELECT count(*) FROM wk.S_HCRU_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND N_EVENTS=0 AND SOC_CATEGORY='(all categories)'",
     [(9,)]),
    ("person-time is per line, not the whole cohort's repeated",
     "SELECT count(DISTINCT PERSON_YEARS) FROM wk.S_HCRU_RATES "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND SOC_CATEGORY='(all categories)'",
     [(4,)]),

    # --- secondary malignancy --------------------------------------------
    ("two codes on separate dates confirm a malignancy; one date does not",
     "SELECT category, N_DATES FROM wk.S_MALIGNANCY WHERE COHORT='1L' "
     "ORDER BY category",
     [("Hematological", 2)]),
    ("and it is dated at the first code, not the confirming one",
     "SELECT FIRST_DT::VARCHAR, CONFIRM_DT::VARCHAR FROM wk.S_MALIGNANCY "
     "WHERE COHORT='1L' AND PATID='P1'",
     [("2019-07-01", "2019-08-01")]),

    # --- small-cell suppression, applied ---------------------------------
    ("a released row below the threshold carries no numbers at all",
     "SELECT N_PATIENTS, N_EVENTS, RATE, SUPPRESSED, SUPPRESSION_REASON "
     "FROM wk.S_SAFETY_RATES_RELEASE WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND CONDITION='acute_hepatitis_b'",
     [(None, None, None, 1, "n < 25")]),
    ("while the raw table keeps them, so QC can still read the counts",
     "SELECT N_PATIENTS, N_EVENTS FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)'"
     "AND CONDITION='acute_hepatitis_b'",
     [(2, 4)]),
    ("and nothing below the threshold escapes unsuppressed",
     "SELECT count(*) FROM wk.S_SAFETY_RATES_RELEASE WHERE SUPPRESSED=0",
     [(0,)]),
    ("every rate table gets a release table",
     "SELECT count(*) FROM wk.S_HCRU_RATES_RELEASE WHERE SUPPRESSED=1 "
     "AND (N_PATIENTS IS NOT NULL OR RATE IS NOT NULL)",
     [(0,)]),

    # --- time to event ----------------------------------------------------
    ("TTNT counts the index day and stops the day the next line starts",
     "SELECT TTNT_DAYS, TTNT_EVENT FROM wk.S_TTE "
     "WHERE PATID='P1' AND COHORT='1L'",
     [(366, 1)]),
    ("a death after follow-up ends is censored, not an event",
     "SELECT OS_EVENT, OS_DAYS FROM wk.S_TTE WHERE PATID='P2' AND COHORT='1L'",
     [(0, 395)]),   # died 2020-07-15, follow-up ended 2020-06-30
    ("no time-to-event duration is negative",
     "SELECT count(*) FROM wk.S_TTE WHERE TTNT_DAYS < 0 OR TTD_DAYS < 0 "
     "OR OS_DAYS < 0",
     [(0,)]),
]

# Checked after the whole script is executed a second time. A module that does
# not clear its scope before writing doubles every count in every table, with no
# error at all, so it has to be checked on a re-run rather than on one pass.
RERUN_STABLE_TABLES = [
    "wk.S_SPINE", "wk.S_COHORT", "wk.S_ATTRITION", "wk.S_PERIODS",
    "wk.S_LOT_PERIODS", "wk.S_DEMOGRAPHICS", "wk.S_COMORBIDITY", "wk.S_SOC",
    "wk.S_SAFETY_EVENTS", "wk.S_SAFETY_COUNTED", "wk.S_SAFETY_RATES",
    "wk.S_HCRU_EVENTS", "wk.S_HCRU_RATES", "wk.S_MALIGNANCY",
    "wk.S_MALIGNANCY_RATES", "wk.S_TTE", "wk.S_PATTERNS", "wk.S_SWITCH",
    "wk.S_TX_ATTRITION", "wk.S_SAFETY_RATES_RELEASE", "wk.S_HCRU_RATES_RELEASE",
    "wk.S_MALIGNANCY_RATES_RELEASE", "wk.S_PATTERNS_RELEASE",
    "wk.S_SWITCH_RELEASE", "wk.S_TX_ATTRITION_RELEASE",
]
