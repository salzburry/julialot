"""Executable scenarios for the QC checks the patient population cannot reach.

The patient run answers a check by building patients and asking whether the
check stays quiet. That works while the check reads tables the chain produces.
Four checks read tables it does not - the attrition funnel and the metadata
row are written by build_lot.R in R, outside the emitted SQL - so F2, F3 and F4
were reported as skipped and their only cover was a handful of string
assertions on their SQL. A string assertion cannot tell you whether the
predicate FIRES.

So these are fixtures, with expected answers, and that is the right shape here.
Nothing below is a patient: each one is a tiny attrition table built to be
wrong in one specific way, and the assertion is that the shipped check notices.
The thing under test is the check, not the algorithm - which is exactly the
case the no-expected-answers rule in run_synthetic.py is not about.

E1 is here for a different reason. It reads the raw per-line SCT tables, which
the emitted chain does write, but a double flag cannot be produced by a correct
build - so the patient run can only ever show it silent.
"""

# Each scenario: a name, the tables it needs, and how many rows the check must
# return. `rows` of 0 means the check must stay quiet on a correct fixture.
#
# Columns are the ones the writers declare: LOT_ATTRITION_COLS in build_lot.R,
# and the LOT<n>_SCT_AUTO_*_FLG pair in 10_lot2_5_base.R.

ATTRITION_DDL = """
CREATE OR REPLACE TABLE qc_attrition (
  RUN_ID VARCHAR, STEP_NUM INT, KIND VARCHAR, STEP VARCHAR,
  N_PATIENTS BIGINT, N_LINES BIGINT, PCT_OF_START DOUBLE,
  PCT_OF_PREV DOUBLE, RECORDED_AT TIMESTAMP)"""

FINAL_DDL = """
CREATE OR REPLACE TABLE qc_final (PATID VARCHAR, LOT_NUM INT)"""


def _funnel(rows):
    """(step_num, kind, step, n_patients, n_lines) -> INSERTs."""
    lit = lambda v: "NULL" if v is None else str(v)
    return [f"INSERT INTO qc_attrition VALUES ('synthetic', {n}, '{k}', '{st}', "
            f"{lit(p)}, {lit(l)}, NULL, NULL, NULL)" for (n, k, st, p, l) in rows]


def _lines(pats):
    """{patid: n_lines} -> one qc_final row per line."""
    return [f"INSERT INTO qc_final VALUES ('{pid}', {k})"
            for pid, n in pats.items() for k in range(1, n + 1)]


# Three patients, five lines between them: P1 reaches LOT3, P2 LOT1, P3 LOT1.
#
# N_LINES ON A PROGRESSION ROW IS count(*) FOR THAT LOT, not the cohort total.
# P1/P2/P3 each hold a LOT1, so LOT1 has three lines; only P1 holds a LOT2 and a
# LOT3, so those have one each. This set read 3/5, 1/3, 1/1 - the cohort's total
# line count pasted into LOT1, and a 3 in LOT2 from nothing at all - and was
# labelled a correct progression set. It passed because F3 compared only
# N_PATIENTS and never read N_LINES, so the fixture written to demonstrate a
# GOOD funnel was itself an instance of the defect. An external review found it.
GOOD_LINES = {"P1": 3, "P2": 1, "P3": 1}
GOOD_PROGRESSION = [(10, "progression", "Reached LOT1", 3, 3),
                    (11, "progression", "Reached LOT2", 1, 1),
                    (12, "progression", "Reached LOT3", 1, 1),
                    (13, "progression", "Reached LOT4", 0, 0),
                    (14, "progression", "Reached LOT5", 0, 0)]
GOOD_FUNNEL = [(1, "input", "Cohort patients handed to LOT", 3, None),
               (2, "reconciliation", "With LOT1 built", 3, 5),
               (3, "final", "Study population (LOT_LONG_FINAL)", 3, 5)]


def scenarios():
    def s(check, name, funnel, lines, rows):
        return dict(check=check, name=name, sql=(
            [ATTRITION_DDL, FINAL_DDL] + _funnel(funnel) + _lines(lines)),
            rows=rows)

    out = [
        # --- F2 -----------------------------------------------------------
        s("F2", "a correct funnel is quiet", GOOD_FUNNEL, GOOD_LINES, 0),
        # The row above the final one carries the same patient count, so
        # taking whichever row came last compared 3 with 3 and passed.
        s("F2", "the final row is missing", GOOD_FUNNEL[:2], GOOD_LINES, 1),
        s("F2", "the final row is written twice",
          GOOD_FUNNEL + [(4, "final", "Study population (LOT_LONG_FINAL)", 3, 5)],
          GOOD_LINES, 1),
        # Patients agree, lines do not - what a truncating criterion produces.
        s("F2", "the lines disagree while the patients match",
          GOOD_FUNNEL[:2] + [(3, "final", "Study population (LOT_LONG_FINAL)", 3, 4)],
          GOOD_LINES, 1),
        s("F2", "the patients disagree",
          GOOD_FUNNEL[:2] + [(3, "final", "Study population (LOT_LONG_FINAL)", 2, 5)],
          GOOD_LINES, 1),
        s("F2", "there is no funnel at all", [], GOOD_LINES, 1),

        # --- F3 -----------------------------------------------------------
        s("F3", "a correct progression set is quiet",
          GOOD_FUNNEL + GOOD_PROGRESSION, GOOD_LINES, 0),
        # LOT4 and LOT5 appear on neither side of a join between the funnel
        # and the table, so a join compared LOT1 to LOT3 and passed.
        s("F3", "the zero rows for lines nobody reached are missing",
          GOOD_FUNNEL + GOOD_PROGRESSION[:3], GOOD_LINES, 2),
        s("F3", "a line above the cap has a row",
          GOOD_FUNNEL + GOOD_PROGRESSION +
          [(15, "progression", "Reached LOT6", 0, 0)], GOOD_LINES, 1),
        s("F3", "one line is counted twice",
          GOOD_FUNNEL + GOOD_PROGRESSION +
          [(16, "progression", "Reached LOT2", 1, 3)], GOOD_LINES, 1),
        s("F3", "a count disagrees with the table",
          GOOD_FUNNEL + GOOD_PROGRESSION[:1] +
          [(11, "progression", "Reached LOT2", 2, 3)] + GOOD_PROGRESSION[2:],
          GOOD_LINES, 1),
        s("F3", "no progression rows at all", GOOD_FUNNEL, GOOD_LINES, 5),
    ]

    # --- E1 ---------------------------------------------------------------
    # The raw tables, where the two flags are independent CASE expressions.
    # LOT_LONG derives its single flag as the negation of its tandem flag, so
    # a row like this one is normalised away before anything published sees it.
    sct_ddl = [f"""CREATE OR REPLACE TABLE qc_sct{n} (
        PATID VARCHAR, LOT{n}_SCT_AUTO_TAND_FLG INT,
        LOT{n}_SCT_AUTO_SING_FLG INT)""" for n in (1, 2)]
    out += [
        dict(check="E1", name="one flag each is quiet", rows=0, sql=sct_ddl + [
            "INSERT INTO qc_sct1 VALUES ('P1', 1, 0)",
            "INSERT INTO qc_sct2 VALUES ('P1', 0, 1)"]),
        dict(check="E1", name="both flags set at LOT1", rows=1, sql=sct_ddl + [
            "INSERT INTO qc_sct1 VALUES ('P1', 1, 1)",
            "INSERT INTO qc_sct2 VALUES ('P1', 0, 1)"]),
        # The one the move to LOT_LONG could not see.
        dict(check="E1", name="both flags set at LOT2", rows=1, sql=sct_ddl + [
            "INSERT INTO qc_sct1 VALUES ('P1', 1, 0)",
            "INSERT INTO qc_sct2 VALUES ('P1', 1, 1)"]),
    ]
    return out
