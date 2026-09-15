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
    # P9 is on the input cohort and has a 1L line in LOT_LONG_ALLFLAGS, but
    # the engine's any-LOT belantamab rule truncated it, so P9 never reaches
    # LOT_LONG_FINAL. Before these two steps the funnel started below P9 with
    # nothing to say so, and every step in it was already net of that removal.
    # 8, not 9: P4's 1L starts 2018-06-01, before LOT1_INDEX_FROM, so it is
    # outside the funnel's own first step. The other eight are P1, P2, P3, P5,
    # P6, P7, P8 and P9.
    ("the funnel starts from the lines the engine built, P9 included",
     "SELECT N_REMAINING FROM wk.S_ATTRITION "
     "WHERE COHORT='1L' AND CRITERION='indexed_at_line'",
     [(8,)]),
    # P9 alone: its 1L line is in LOT_LONG_ALLFLAGS with
    # NO_BELANTAMAB_ANY_LOT = 0, and the rule truncates, so it never reaches
    # LOT_LONG_FINAL. Before this step the funnel began at 7 with nothing to
    # say where the eighth went.
    ("...and its next step is what the engine's own line criteria removed",
     "SELECT N_REMAINING, N_LOST FROM wk.S_ATTRITION "
     "WHERE COHORT='1L' AND CRITERION='lot_line_criteria'",
     [(7, 1)]),
    ("a nested cohort starts from the cohort it is drawn from",
     "SELECT N_REMAINING FROM wk.S_ATTRITION "
     "WHERE COHORT='2L' AND CRITERION='in_1L_cohort'",
     [(7,)]),
    # P2, P7 and P8: in the 1L cohort, never a second line. That loss is what
    # N1_received_line names, and until this step it had nothing above it to
    # be a difference from, so it reported none.
    ("...so N1_received_line's loss is those who did not go on to that line",
     "SELECT N_LOST FROM wk.S_ATTRITION "
     "WHERE COHORT='2L' AND CRITERION='N1_received_line'",
     [(3,)]),
    ("...and those three are exactly the 1L members with no 2L line",
     "SELECT PATID FROM wk.S_COHORT WHERE COHORT='1L' AND IN_COHORT=1 "
     "AND PATID NOT IN (SELECT PATID FROM wk.S_COHORT WHERE COHORT='2L') "
     "ORDER BY PATID",
     [("P2",), ("P7",), ("P8",)]),
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

    # --- the diagnosis date, and the durations anchored on it -------------
    # By default the diagnosis date is the cohort build's qualifying
    # diagnosis, MM_DX_DT, the date age and the 1L index are already measured
    # against. Table 4's own definition is the other reading, executed with
    # its own goldens in expectations_alt.py.
    ("the diagnosis date is the cohort's qualifying diagnosis, and the row says so",
     "SELECT MM_DX_DT::VARCHAR, DX_DT::VARCHAR, DX_DT_SOURCE, DX_YEAR "
     "FROM wk.S_PERIODS WHERE PATID='P1' AND COHORT='1L'",
     [("2019-01-05", "2019-01-05", "cohort_mm_dx", 2019)]),
    ("time from diagnosis to index counts the diagnosis day and not the index day",
     "SELECT DX_TO_INDEX_DAYS, DX_TO_INDEX_MONTHS FROM wk.S_PERIODS "
     "WHERE PATID='P1' AND COHORT='1L'",
     [(55, 1.81)]),    # 2019-01-05 -> 2019-03-01, bare datediff
    ("follow-up from diagnosis counts both ends",
     "SELECT FU_FROM_DX_DAYS FROM wk.S_PERIODS WHERE PATID='P2' AND COHORT='1L'",
     [(457,)]),        # 2019-04-01 -> 2020-06-30 inclusive
    ("a 2L row's diagnosis is the same patient-level date, measured to the 2L index",
     "SELECT DX_DT::VARCHAR, DX_TO_INDEX_DAYS FROM wk.S_PERIODS "
     "WHERE PATID='P1' AND COHORT='2L'",
     [("2019-01-05", 421)]),
    ("time to the next line counts the start day and not the next start",
     "SELECT NEXT_LOT_DAYS, NEXT_LOT_MONTHS FROM wk.S_LOT_PERIODS "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=1",
     [(366, 12.02)]),
    # P6's 2L starts 2022-06-01, after its 1L follow-up ended 2019-12-31: the
    # 1L cohort never saw it initiated, so there is no interval to report.
    ("a next line after follow-up ended is not an interval the cohort observed",
     "SELECT NEXT_LOT_START_DT::VARCHAR, NEXT_LOT_DAYS FROM wk.S_LOT_PERIODS "
     "WHERE PATID='P6' AND COHORT='1L' AND LOT_NUM=1",
     [("2022-06-01", None)]),
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
    # s7.2.2's size categories are claims about the regimen, and hold whether
    # or not Annex 2 names the agents. P7's carfilzomib triplet is on no row
    # of the list: three agents and no anti-CD38 backbone is the non-anti-CD38
    # triplet, with MATCHED 0 so the QC still says the list is short.
    ("a triplet of unlisted agents is still the non-anti-CD38 triplet, and still unmatched",
     "SELECT SOC_CATEGORY, MATCHED, N_AGENTS FROM wk.S_SOC "
     "WHERE PATID='P7' AND COHORT='1L' AND LOT_NUM=1",
     [("Other triplet (non-anti-CD38)", 0, 3)]),
    ("a line's start year is on its SOC row - Table 4, by year",
     "SELECT LOT_START_YEAR FROM wk.S_SOC "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=3",
     [(2021,)]),
    # Table 6: patients with an SCT by year according to SOC type. P5's 1L
    # carries the engine's in-line autologous transplant on 2019-03-15.
    ("a line's transplant is on its SOC row with the transplant's year - Table 6",
     "SELECT AUTO_SCT, AUTO_SCT_YEAR, ALLO_SCT, CART FROM wk.S_SOC "
     "WHERE PATID='P5' AND COHORT='1L' AND LOT_NUM=1",
     [(1, 2019, 0, 0)]),
    ("...and a line without one says so",
     "SELECT AUTO_SCT, AUTO_SCT_YEAR FROM wk.S_SOC "
     "WHERE PATID='P1' AND COHORT='1L' AND LOT_NUM=1",
     [(0, None)]),

    # --- demographics -----------------------------------------------------
    ("age is the index year minus the birth year",
     "SELECT AGE_YEARS, AGE_BAND FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P1' AND COHORT='1L'",
     [(69, "65-74")]),
    # Two different questions on one table. AGE_BAND is Table 1's descriptive
    # distribution, four bands wide; AGE_GROUP is the protocol's
    # stratification, which is two groups and is what the rate tables carry -
    # a rate is not the sum of its strata's rates, so an age group split over
    # three bands could report no rate at all.
    ("...and the protocol's two age groups sit beside the four bands",
     "SELECT AGE_GROUP FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P1' AND COHORT='1L'",
     [("<75",)]),
    ("every band maps into the group its cut-point puts it in",
     "SELECT count(*) FROM wk.S_DEMOGRAPHICS "
     "WHERE (AGE_BAND = '75+') <> (AGE_GROUP = '75+')",
     [(0,)]),
    # YRDOB is 0 on 614 rows of the deployed enrolment table. Unguarded,
    # year(index) - 0 is an age of about 2026, which lands every one of them in
    # the 75+ band - the band the protocol uses as its transplant-eligibility
    # proxy.
    ("a birth year of 0 is an unknown age, not an age of 2020",
     "SELECT AGE_YEARS, AGE_GROUP FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P8' AND COHORT='1L'",
     [(None, "Unknown")]),
    ("and a birth year at the 89-year cap is still a real age",
     "SELECT AGE_YEARS, AGE_GROUP FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P7' AND COHORT='1L'",
     [(83, "75+")]),
    ("the 75+ band is the transplant-eligibility proxy and is not empty",
     "SELECT PATID FROM wk.S_DEMOGRAPHICS "
     "WHERE COHORT='1L' AND AGE_GROUP='75+' ORDER BY PATID",
     [("P5",), ("P7",)]),
    ("the CDM's own BUS codes map to the protocol's insurance types",
     "SELECT DISTINCT INSURANCE_TYPE FROM wk.S_DEMOGRAPHICS "
     "WHERE COHORT='1L' ORDER BY 1",
     [("Commercial Health Plan",), ("Medicare",)]),
    ("state maps to census region",
     "SELECT REGION FROM wk.S_DEMOGRAPHICS WHERE PATID='P5' AND COHORT='1L'",
     [("Midwest",)]),
    # s7.8.1: at the index where possible, else the baseline row nearest it.
    # P7's enrolment ends 2020-05-31 and resumes 2020-06-05, around its
    # 2020-06-01 index: no row covers the index day, and the row ending
    # nearest it (NV, Medicare) supplies the attributes rather than the later
    # one (NY, commercial) or nothing.
    ("a patient whose index day no enrolment row covers takes the baseline row nearest it",
     "SELECT RACE, REGION, INSURANCE_TYPE, ENROL_ROW_FOUND, ATTR_SOURCE "
     "FROM wk.S_DEMOGRAPHICS WHERE PATID='P7' AND COHORT='1L'",
     [("Asian", "West", "Medicare", 1, "baseline_nearest")]),
    ("...while a patient with a covering row still reads that row",
     "SELECT ATTR_SOURCE FROM wk.S_DEMOGRAPHICS WHERE PATID='P1' AND COHORT='1L'",
     [("index_span",)]),
    # Sex is on the enrolment row like race and insurance, and is read off
    # the same row. P8's cohort row says U; the enrolment row covering its
    # index says M.
    ("sex is read off the enrolment row that supplies the other attributes",
     "SELECT SEX FROM wk.S_DEMOGRAPHICS WHERE PATID='P8' AND COHORT='1L'",
     [("Male",)]),
    ("the index year is on the periods row beside the diagnosis year - Table 4",
     "SELECT INDEX_YEAR, DX_YEAR FROM wk.S_PERIODS WHERE PATID='P3' AND COHORT='1L'",
     [(2020, 2019)]),
    # I2 is age at diagnosis by calendar year; the shells tabulate it beside
    # age at index. P5 was diagnosed 2018-12-01 and indexed 2019-01-15, born
    # 1940: 78 at diagnosis, 79 at index.
    ("age at diagnosis is the diagnosis year minus the birth year, beside age at index",
     "SELECT AGE_AT_DX_YEARS, AGE_AT_DX_BAND, AGE_YEARS FROM wk.S_DEMOGRAPHICS "
     "WHERE PATID='P5' AND COHORT='1L'",
     [(78, "75+", 79)]),

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
    # The washout runs once over the whole timeline, then the periods take
    # the distinct events dated inside them. P5's hepatitis B is coded on
    # 2019-01-10 (baseline) and 2019-01-20 (treatment, index 2019-01-15):
    # ten days apart, one event, and it is baseline's. Counted period by
    # period it was two - a baseline event AND a new incident event.
    ("an acute event 10 days after a counted baseline event is not a new event on treatment",
     "SELECT PERIOD, EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P5' "
     "AND COHORT='1L' AND CONDITION='acute_hepatitis_b' AND PERIOD <> 'TIMELINE' "
     "ORDER BY PERIOD",
     [("BASELINE", "2019-01-10")]),
    ("...the chain's own answer is kept on the table under TIMELINE",
     "SELECT EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P5' "
     "AND COHORT='1L' AND CONDITION='acute_hepatitis_b' AND PERIOD='TIMELINE'",
     [("2019-01-10",)]),
    # The 2L cohort's timeline starts at ITS baseline (2019-01-15), which
    # holds only the second code, so there it is a baseline event: s7.8.1
    # takes the baseline irrespective of prior event history.
    ("...and a cohort's chain starts at its own baseline, not before it",
     "SELECT PERIOD, EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P5' "
     "AND COHORT='2L' AND CONDITION='acute_hepatitis_b' AND PERIOD <> 'TIMELINE'",
     [("BASELINE", "2019-01-20")]),
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
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND CONDITION='toxic_liver_disease'",
     [(7, 6.9952)]),
    ("while on treatment the not-at-risk leave it",
     "SELECT N_AT_RISK FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND CONDITION='toxic_liver_disease'",
     [(6,)]),
    # 23 conditions on the list, plus a hospitalisation series for each of
    # the 12 chronic ones read from every claim - Figure 3's note - plus one
    # aggregate row for each of the 7 domains - s7.8.1's "and aggregated".
    ("every condition gets a baseline row too, events or not",
     "SELECT count(*) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='BASELINE' AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'",
     [(42,)]),
    ("...twelve of them the hospitalisation series of the chronic conditions",
     "SELECT count(DISTINCT CONDITION) FROM wk.S_SAFETY_RATES "
     "WHERE CONDITION LIKE '% (hospitalisation)'",
     [(12,)]),
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
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND CONDITION='toxic_liver_disease'",
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
     "AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND OUTCOME='received_next_lot'",
     [(3,)]),
    ("and the unobserved line adds nobody to the next line's attrition",
     "SELECT sum(N_PATIENTS) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' "
     "AND LOT_NUM=2 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'",
     [(3,)]),
    ("and that patient leaves the chronic denominator too",
     "SELECT round(PERSON_YEARS,4) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='toxic_liver_disease'",
     [(2.5599,)]),
    # The same denominator with P5's first event moved 31 days earlier must
    # fall by exactly 31/365.25. Guarding the rule, not just the number:
    # summing PERIOD_PY regardless made this difference zero.
    ("and moving a first chronic event earlier shortens that denominator",
     "SELECT round(("
     "  SELECT PERSON_YEARS FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "  AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "  AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND CONDITION='toxic_liver_disease') "
     " - (SELECT sum(CASE WHEN PATID='P5' THEN 31.0/365.25 ELSE 0 END) "
     "    FROM wk.S_LOT_PERIODS WHERE COHORT='1L' AND LOT_NUM=1), 4)",
     [(2.4750,)]),
    ("while an acute condition keeps every patient's person-time",
     "SELECT round(PERSON_YEARS,4) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'"
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
    ("both stratifications are written, beside the line's own row",
     "SELECT CASE WHEN count(*) = 2 THEN 1 ELSE 0 END FROM ("
     " SELECT DISTINCT CASE WHEN SOC_CATEGORY <> '(all categories)' "
     "        THEN 'soc' ELSE 'age' END AS which "
     " FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     " AND LOT_NUM=1 AND CONDITION='toxic_liver_disease' "
     " AND NOT (SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'))",
     [(1,)]),
    ("nothing falls outside either stratification",
     "SELECT count(*) FROM wk.S_SAFETY_RATES "
     "WHERE SOC_CATEGORY='(uncategorised)' "
     "OR AGE_GROUP='(no demographics row)'",
     [(0,)]),
    ("they are margins, not a cross: no row names a real value in both",
     "SELECT count(*) FROM wk.S_SAFETY_RATES "
     "WHERE SOC_CATEGORY <> '(all categories)' AND AGE_GROUP <> '(all ages)'",
     [(0,)]),
    ("the categories' at-risk counts sum to the line's",
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 ELSE N_AT_RISK END) - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_AT_RISK END) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND CONDITION='toxic_liver_disease' AND AGE_GROUP='(all ages)'",
     [(0,)]),
    ('...and their person-time does too',
     "SELECT round(sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 ELSE PERSON_YEARS END) - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN PERSON_YEARS END), 6) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND CONDITION='toxic_liver_disease' AND AGE_GROUP='(all ages)'",
     [(0.0,)]),
    ('...and the patients who had the event',
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 ELSE N_PATIENTS END) - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_PATIENTS END) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND CONDITION='acute_hepatitis_b' AND AGE_GROUP='(all ages)'",
     [(0,)]),
    ('the age bands sum to the line just as the categories do',
     "SELECT sum(CASE WHEN AGE_GROUP='(all ages)' THEN 0 ELSE N_AT_RISK END) - max(CASE WHEN AGE_GROUP='(all ages)' THEN N_AT_RISK END) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND CONDITION='toxic_liver_disease' AND SOC_CATEGORY='(all categories)'",
     [(0,)]),
    ('...and their person-time as well',
     "SELECT round(sum(CASE WHEN AGE_GROUP='(all ages)' THEN 0 ELSE PERSON_YEARS END) - max(CASE WHEN AGE_GROUP='(all ages)' THEN PERSON_YEARS END), 6) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND CONDITION='toxic_liver_disease' AND SOC_CATEGORY='(all categories)'",
     [(0.0,)]),
    ('the same holds for healthcare resource use',
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 ELSE N_EVENTS END) - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_EVENTS END) FROM wk.S_HCRU_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND MEASURE='ALL_CAUSE_HOSPITALISATION' AND AGE_GROUP='(all ages)'",
     [(0,)]),
    ('...by age too',
     "SELECT sum(CASE WHEN AGE_GROUP='(all ages)' THEN 0 ELSE N_EVENTS END) - max(CASE WHEN AGE_GROUP='(all ages)' THEN N_EVENTS END) FROM wk.S_HCRU_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND MEASURE='ALL_CAUSE_HOSPITALISATION' AND SOC_CATEGORY='(all categories)'",
     [(0,)]),
    ('and for what happened at the end of each line',
     "SELECT sum(CASE WHEN SOC_CATEGORY='(all categories)' THEN 0 ELSE N_PATIENTS END) - max(CASE WHEN SOC_CATEGORY='(all categories)' THEN N_PATIENTS END) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' AND LOT_NUM=1 AND OUTCOME='received_next_lot' AND AGE_GROUP='(all ages)'",
     [(0,)]),
    ('...by age there as well',
     "SELECT sum(CASE WHEN AGE_GROUP='(all ages)' THEN 0 ELSE N_PATIENTS END) - max(CASE WHEN AGE_GROUP='(all ages)' THEN N_PATIENTS END) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' AND LOT_NUM=1 AND OUTCOME='received_next_lot' AND SOC_CATEGORY='(all categories)'",
     [(0,)]),
    ("a stratum's percentage is out of that stratum, not the line",
     "SELECT count(*) FROM wk.S_TX_ATTRITION WHERE COHORT='1L' AND LOT_NUM=1 "
     "AND NOT (SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)') "
     "AND N_DENOM > (SELECT max(N_DENOM) FROM wk.S_TX_ATTRITION "
     " WHERE COHORT='1L' AND LOT_NUM=1 "
     " AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)')",
     [(0,)]),
    ("and a stratum below the floor is suppressed like any other",
     "SELECT count(*) FROM wk.S_SAFETY_RATES_RELEASE "
     "WHERE NOT (SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)') "
     "AND SUPPRESSED = 0",
     [(0,)]),

    ("every condition gets an incidence row, events or not",
     "SELECT count(DISTINCT CONDITION) FROM wk.S_SAFETY_RATES "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'",
     [(36,)]),   # 35 conditions and series, and the one aggregate name

    # Zero events is a rate of zero WITH an interval: the exact Poisson limits
    # for a count of 0 are 0 and 3.688879 / PY, scaled like the rate
    # (3.688879 / 4.8569 x 100,000 = 75950.57).
    ("a condition with no events has a rate of zero and an exact upper limit, not no interval",
     "SELECT N_EVENTS, round(RATE,4), round(RATE_LO,4), round(RATE_HI,4) "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND CONDITION='seizures'",
     [(0, 0.0, 0.0, 75950.5668)]),

    # --- the domain aggregates: s7.8.1 "and aggregated" ------------------
    # Hepatologic on 1L line 1 treatment: acute hepatitis B counted 4 times
    # (P1 twice, P3 twice) and toxic liver disease twice (P2, P5), so 6 events
    # among 4 patients. P1's prior toxic liver disease keeps it out of THAT
    # condition's denominator, but it is still at risk of the domain's four
    # other conditions, so the aggregate keeps everyone's whole period.
    ("a domain's aggregate adds its conditions' events and counts each patient once",
     "SELECT N_PATIENTS, N_EVENTS, N_AT_RISK, round(PERSON_YEARS,4), ACUTE_CHRONIC "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='(any in domain)' AND DOMAIN='hepatologic'",
     [(4, 6, 7, 4.8569, "aggregate")]),
    # At baseline: P1's toxic liver disease and P5's hepatitis B (2019-01-10,
    # five days before its index), two patients, two events.
    ("...and at baseline it is the domain's events over the window everyone contributes",
     "SELECT N_PATIENTS, N_EVENTS, N_AT_RISK, round(PERSON_YEARS,4) "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='BASELINE' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='(any in domain)' AND DOMAIN='hepatologic'",
     [(2, 2, 7, 6.9952)]),
    # The hospitalisation series is not in the aggregate: P1's toxic liver
    # admission would otherwise be counted beside the condition it is an
    # admission for. Infectious carries only the one inpatient severe
    # infection.
    ("...and the derived hospitalisation series is not double counted into it",
     "SELECT N_EVENTS FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='(any in domain)' AND DOMAIN='infectious'",
     [(1,)]),
    ("every domain gets an aggregate row in every period",
     "SELECT count(*) FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='(any in domain)'",
     [(14,)]),

    # --- inpatient claims: business rule 14, and Figure 3's note ---------
    # P1's Z119 (severe infection resulting in hospitalisation, setting
    # inpatient) is coded on an outpatient claim on 2019-06-10 and on a claim
    # carrying confinement C2 on 2019-07-02. Only the second is an event, and
    # it is dated at C2's admission, 2019-07-01.
    ("an inpatient-defined condition is its admissions, dated at the admit date",
     "SELECT EVENT_DT::VARCHAR, INPATIENT, ADMIT_DT::VARCHAR FROM wk.S_SAFETY_EVENTS "
     "WHERE PATID='P1' AND COHORT='1L' "
     "AND CONDITION='severe_infection_resulting_in_hospitalisation'",
     [("2019-07-01", 1, "2019-07-01")]),
    # P1 has toxic_liver_disease (chronic) before its treatment period, so the
    # condition itself counts for nobody on treatment - the golden above - but
    # its Z100 on a claim inside stay C1 (admitted 2019-05-01) is a
    # hospitalisation due to the chronic condition, and that is an acute
    # event in its own series.
    ("a hospitalisation due to a chronic condition counts as an acute event, prior history or not",
     "SELECT EVENT_DT::VARCHAR FROM wk.S_SAFETY_COUNTED WHERE PATID='P1' "
     "AND COHORT='1L' AND PERIOD='TREATMENT' "
     "AND CONDITION='toxic_liver_disease (hospitalisation)'",
     [("2019-05-01",)]),
    ("...typed acute, so nobody leaves its denominator and the whole period counts",
     "SELECT ACUTE_CHRONIC, DOMAIN, N_PATIENTS, N_EVENTS, N_AT_RISK, round(PERSON_YEARS,4) "
     "FROM wk.S_SAFETY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='toxic_liver_disease (hospitalisation)'",
     [("acute", "hepatologic", 1, 1, 7, 4.8569)]),
    # The same Z100 claim is also a code for the condition itself, and it
    # changes nothing there: P1's prior history still keeps it out.
    ("...while the condition's own series is unchanged by the inpatient claim",
     "SELECT N_PATIENTS, N_AT_RISK, round(PERSON_YEARS,4) FROM wk.S_SAFETY_RATES "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CONDITION='toxic_liver_disease'",
     [(2, 6, 2.5599)]),
    ("an inpatient event knows the claim it came from",
     "SELECT count(*) FROM wk.S_SAFETY_EVENTS WHERE INPATIENT=1 AND ADMIT_DT IS NULL",
     [(0,)]),

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
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND MEASURE='MM_RELATED_HOSPITALISATION'",
     [(2, 5.0, 1)]),
    ("two ED claim lines on one day are one visit",
     "SELECT count(*) FROM wk.S_HCRU_EVENTS WHERE PATID='P1' "
     "AND COHORT='1L' AND EVENT_TYPE='ED' AND EVENT_DT='2019-05-20'",
     [(1,)]),
    ("N_PATIENTS counts patients and N_EVENTS counts events",
     "SELECT N_PATIENTS, N_EVENTS FROM wk.S_HCRU_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND MEASURE='ALL_CAUSE_HOSPITALISATION'",
     [(2, 3)]),
    ("a line with person-time and no events still gets a row per measure",
     "SELECT count(*) FROM wk.S_HCRU_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND N_EVENTS=0 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'",
     [(9,)]),
    ("person-time is per line, not the whole cohort's repeated",
     "SELECT count(DISTINCT PERSON_YEARS) FROM wk.S_HCRU_RATES "
     "WHERE COHORT='1L' AND PERIOD='TREATMENT' AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'",
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
    # P1's malignancy falls after its 1L index (2019-03-01) and before its 2L
    # one (2020-03-01). Table 4 measures time from the index only where the
    # malignancy came after it, so the 2L-indexed rows carry the flag off and
    # no duration, not a negative one.
    ("a malignancy after the index is flagged, with its months from the index",
     "SELECT AFTER_INDEX, MONTHS_FROM_INDEX FROM wk.S_MALIGNANCY "
     "WHERE COHORT='1L' AND PATID='P1'",
     [(1, 4.04)]),
    ("...and one before it is not, and has no duration from an index it precedes",
     "SELECT AFTER_INDEX, MONTHS_FROM_INDEX FROM wk.S_MALIGNANCY "
     "WHERE COHORT='SEC2L' AND PATID='P1'",
     [(0, None)]),
    # s7.4.1.2 / s7.8.4: the secondary cohort's background prevalence is "all
    # malignancies occurring after diagnosis but prior to 2L". Its four
    # patients' diagnosis-to-index intervals, both ends excluded, are 420,
    # 304, 409 and 1246 days: 2379 / 365.25 = 6.5133 person-years - not the
    # four baseline years (3.9973) the other window would give.
    ("the secondary cohort's malignancy prevalence runs from diagnosis to its index",
     "SELECT N_PATIENTS, N_AT_RISK, round(PERSON_YEARS,4) FROM wk.S_MALIGNANCY_RATES "
     "WHERE COHORT='SEC2L' AND PERIOD='BASELINE' AND LOT_NUM=2 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CATEGORY='Hematological'",
     [(1, 4, 6.5133)]),
    # s7.8.1 names "malignancies" as one chronic condition, so beside the
    # categories there is the aggregate: a first malignancy of any kind. P1's
    # is the only one in 1L, inside its line-1 window, and at-risk time ends
    # there for P1 (4.2327 person-years across the seven, not 4.8569). Each
    # rate row carries its interval, and a row with no event carries the
    # exact zero-count limits.
    ("the aggregate row is a first malignancy of any kind, counted once, at-risk time ending at it",
     "SELECT N_PATIENTS, N_AT_RISK, round(PERSON_YEARS,4), round(RATE_LO,4), round(RATE_HI,4) "
     "FROM wk.S_MALIGNANCY_RATES WHERE COHORT='1L' AND PERIOD='TREATMENT' AND LOT_NUM=1 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CATEGORY='(any malignancy)'",
     [(1, 7, 4.2327, 3327.9683, 167719.008)]),
    ("...and it is written for the secondary cohort's prevalence too",
     "SELECT N_PATIENTS, N_AT_RISK, round(PERSON_YEARS,4) FROM wk.S_MALIGNANCY_RATES "
     "WHERE COHORT='SEC2L' AND PERIOD='BASELINE' AND LOT_NUM=2 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CATEGORY='(any malignancy)'",
     [(1, 4, 6.5133)]),
    ("a malignancy row with no event carries the exact zero-count limits",
     "SELECT N_PATIENTS, N_AT_RISK, round(PERSON_YEARS,4), round(RATE,4), round(RATE_LO,4), round(RATE_HI,4) "
     "FROM wk.S_MALIGNANCY_RATES WHERE COHORT='SEC2L' AND PERIOD='TREATMENT' AND LOT_NUM=2 "
     "AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' "
     "AND CATEGORY='Hematological'",
     [(0, 3, 2.1328, 0.0, 0.0, 172960.5975)]),
    ("every category and the aggregate get a row per line and period",
     "SELECT count(DISTINCT CATEGORY) FROM wk.S_MALIGNANCY_RATES",
     [(11,)]),
    # Table 4: the treatment sequences of those with a malignancy after
    # treatment, in regimen categories. P1 is the one such patient in 1L; its
    # malignancy (2019-07-01) fell in its 1L line, and its three lines inside
    # follow-up are 1L triplet, 2L doublet, 3L quadruplet. Three readings of
    # "sequence", each its own row: the lines up to the malignancy, the lines
    # after it, and every observed line. The sensitivity scope keeps only
    # malignancies after 2L, and P1's came before its 2L.
    ("the treatment sequences of patients with a malignancy after the index, in three readings, ranked",
     "SELECT LINES, SEQUENCE, N_PATIENTS, N_DENOM, PCT, RANK FROM wk.S_MALIGNANCY_SEQUENCES "
     "WHERE COHORT='1L' AND SCOPE='after_index' ORDER BY LINES",
     [("after_malignancy", "Doublet/monotherapy -> Quadruplet with anti-CD38 backbone",
       1, 1, 100.0, 1),
      ("all_observed", "Triplet with anti-CD38 backbone -> Doublet/monotherapy -> "
       "Quadruplet with anti-CD38 backbone", 1, 1, 100.0, 1),
      ("to_malignancy", "Triplet with anti-CD38 backbone", 1, 1, 100.0, 1)]),
    ("...and the sensitivity scope keeps only malignancies after 2L",
     "SELECT count(*) FROM wk.S_MALIGNANCY_SEQUENCES "
     "WHERE COHORT='1L' AND SCOPE='after_2l'",
     [(0,)]),
    ("...and a malignancy before the secondary cohort's index is in neither scope",
     "SELECT count(*) FROM wk.S_MALIGNANCY_SEQUENCES WHERE COHORT='SEC2L'",
     [(0,)]),

    # --- small-cell suppression, applied ---------------------------------
    ("a released row below the threshold carries no numbers at all",
     "SELECT N_PATIENTS, N_EVENTS, RATE, SUPPRESSED, SUPPRESSION_REASON "
     "FROM wk.S_SAFETY_RATES_RELEASE WHERE COHORT='1L' AND PERIOD='TREATMENT' "
     "AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)' AND CONDITION='acute_hepatitis_b'",
     [(None, None, None, 1, "n < 25")]),
    ("while the raw table keeps them, so QC can still read the counts",
     "SELECT N_PATIENTS, N_EVENTS FROM wk.S_SAFETY_RATES WHERE COHORT='1L' "
     "AND PERIOD='TREATMENT' AND LOT_NUM=1 AND SOC_CATEGORY='(all categories)' AND AGE_GROUP='(all ages)'"
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
    # Table 4's footnote dates a discontinuation by what happened: a line that
    # ran out ends ON the confirmed run-out (P1's 1L, 2020-01-15), and a line
    # ended by an agent being added ends the day BEFORE the agent, so the
    # discontinuation is the day after that end (P1's 3L: engine end
    # 2022-01-15, agent introduced 2022-01-16).
    ("TTD dates a run-out on the run-out day, index included and that day excluded",
     "SELECT TTD_DT::VARCHAR, TTD_DAYS, TTD_EVENT FROM wk.S_TTE WHERE PATID='P1' AND COHORT='1L'",
     [("2020-01-15", 320, 1)]),
    ("...and an added agent on the day it was introduced, not the line's last day",
     "SELECT TTD_DT::VARCHAR, TTD_DAYS, TTD_EVENT FROM wk.S_TTE WHERE PATID='P1' AND COHORT='3L'",
     [("2022-01-16", 321, 1)]),
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
    "wk.S_MALIGNANCY_SEQUENCES", "wk.S_MALIGNANCY_SEQUENCES_RELEASE",
    "wk.S_SWITCH_RELEASE", "wk.S_TX_ATTRITION_RELEASE",
]
