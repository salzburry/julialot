"""Build draft LOT2-5 spec workbook in chunks.

Run with optional CHUNK env var: cover, qc, base, base_end, sct, scenarios, finalize, all
"""
import os
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.utils import get_column_letter

OUT = "/home/user/julialot/Apr 18 2026/Program Spec and Scenarios/lot2to5_spec_DRAFT_apr30.xlsx"

HEADER_FILL = PatternFill("solid", fgColor="1F4E78")
SECTION_FILL = PatternFill("solid", fgColor="D9E1F2")
NOTE_FILL = PatternFill("solid", fgColor="FFF2CC")
HEADER_FONT = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
BOLD = Font(name="Calibri", size=11, bold=True)
NORMAL = Font(name="Calibri", size=10)
WRAP = Alignment(wrap_text=True, vertical="top")
THIN = Side(style="thin", color="999999")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def get_wb():
    if os.path.exists(OUT):
        return load_workbook(OUT)
    wb = Workbook()
    wb.remove(wb.active)
    return wb


def save(wb):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    wb.save(OUT)
    print(f"Saved: {OUT}")


def style_header(ws, row, ncols):
    for c in range(1, ncols + 1):
        cell = ws.cell(row=row, column=c)
        cell.fill = HEADER_FILL
        cell.font = HEADER_FONT
        cell.alignment = WRAP
        cell.border = BORDER


def write_rows(ws, start_row, rows, col_widths=None):
    for i, row in enumerate(rows):
        for j, val in enumerate(row):
            cell = ws.cell(row=start_row + i, column=j + 1, value=val)
            cell.alignment = WRAP
            cell.font = NORMAL
            cell.border = BORDER
    if col_widths:
        for idx, w in enumerate(col_widths, 1):
            ws.column_dimensions[get_column_letter(idx)].width = w


def build_cover(wb):
    if "1.Cover" in wb.sheetnames:
        del wb["1.Cover"]
    ws = wb.create_sheet("1.Cover", 0)
    ws.column_dimensions["A"].width = 28
    ws.column_dimensions["B"].width = 90

    ws["A1"] = "LOT 2-5 Programming Specification (DRAFT)"
    ws["A1"].font = Font(name="Calibri", size=16, bold=True, color="1F4E78")
    ws.merge_cells("A1:B1")

    meta = [
        ("Study", "Blenrep Epi - MM LOT Refresh 2026"),
        ("Document", "LOT 2-5 Base & Base End Programming Spec"),
        ("Status", "DRAFT - first stab; for QC by Julia"),
        ("Author", "Onkar (Claude-assisted draft)"),
        ("Draft Date", "30-Apr-2026"),
        ("Source Protocol", "Lot protocol Apr 13.pdf (v6 of LOT rules)"),
        ("Parent Spec", "lot1baseapr18.pdf / lot1baseendupdatedapr19.pdf"),
        ("Key reference", "Meeting Minutes Apr 22 (induction=30d; SCT/CAR-T can start LOT2-5)"),
        ("", ""),
        ("Tabs", ""),
        ("1.Cover", "This page"),
        ("2.QC Review", "QC sign-off log"),
        ("3.LOT2_5_BASE", "LOT 2-5 base period definition (start, induction, regimen)"),
        ("4.LOT2_5_BASE_END", "LOT 2-5 base end date and end reason derivation"),
        ("5.SCT_CART_LOT_START", "Rules for SCT/ALLO/CAR-T as LOT 2-5 starting events"),
        ("6.Scenarios", "Worked scenarios LOT2-LOT5"),
        ("7.Open_Questions", "Items needing Julia's review"),
        ("", ""),
        ("Key differences vs LOT1", ""),
        ("Induction window", "30 days (vs 60 days for LOT1)"),
        ("LOT start trigger", "First MM oncology agent OR ALLO SCT OR CAR-T event (vs LOT1 = first MM agent only)"),
        ("Numbering", "LOT_NUM increments 2..5; same algorithmic rules otherwise"),
        ("Maintenance", "Inherits LOT1 approach: contains_mtx_reg flag, no standalone maintenance LOT"),
        ("Permissible subs", "Same as LOT1 - do not advance LOT"),
        ("Steroids", "Excluded from regimen identification (per LOT1 protocol Section 5.1.1)"),
    ]
    for i, (k, v) in enumerate(meta, start=3):
        a = ws.cell(row=i, column=1, value=k)
        b = ws.cell(row=i, column=2, value=v)
        a.font = BOLD if k else NORMAL
        b.font = NORMAL
        a.alignment = WRAP
        b.alignment = WRAP
        if k in ("Tabs", "Key differences vs LOT1"):
            a.fill = SECTION_FILL
            b.fill = SECTION_FILL


def build_qc(wb):
    if "2.QC Review" in wb.sheetnames:
        del wb["2.QC Review"]
    ws = wb.create_sheet("2.QC Review")
    headers = ["Date", "Reviewer", "Initials", "Section / Variable", "Comment", "Status"]
    for j, h in enumerate(headers, 1):
        ws.cell(row=1, column=j, value=h)
    style_header(ws, 1, len(headers))
    seed = [
        ("30-Apr-2026", "Onkar", "OK", "Whole sheet", "First-pass draft created from LOT1 spec + Apr22 meeting notes", "Draft"),
        ("", "Julia Moore", "JM", "Pending review", "", "Open"),
    ]
    write_rows(ws, 2, seed, col_widths=[14, 18, 10, 30, 70, 12])


def build_lot2_5_base(wb):
    name = "3.LOT2_5_BASE"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)
    headers = [
        "Time Period", "Variable", "Label", "Values", "Definition",
        "Code lists / Group", "Programming Notes", "QC Reviewed (Initials - Date)",
    ]
    for j, h in enumerate(headers, 1):
        ws.cell(row=1, column=j, value=h)
    style_header(ws, 1, len(headers))

    rows = [
        # Indexing variables
        ("FU_PD", "LOT_NUM", "Line of therapy number", "2, 3, 4, 5",
         "Sequential index of the line of therapy after LOT1. LOT2 starts after LOT1 ends; LOT3 after LOT2; etc., up to LOT5.",
         "n/a",
         "Derived sequentially. LOT_(N+1)_START_DT must be > LOT_N_BASE_END_DT.",
         ""),
        ("FU_PD", "LOTN_START_DT", "LOT N start date (N in 2..5)",
         "Date",
         "Earliest of: (a) first MM oncology agent (non-steroid) administered/dispensed AFTER LOT_(N-1)_BASE_END_DT; "
         "(b) first ALLO SCT date AFTER LOT_(N-1)_BASE_END_DT (ALLO always starts a new LOT); "
         "(c) first CAR-T infusion date AFTER LOT_(N-1)_BASE_END_DT (CAR-T classified as its own LOT). "
         "If LOT_(N-1) ended due to SCT_ALLO/SCT_CART/CART_INIT/SCT_AUTO unplanned, LOTN_START_DT = the SCT/CAR-T event date itself.",
         "CL_MMA_CODELIST (Tab 41), CL_SCT_CODELIST (Tab 44), CL_MMA_ROLLUP (Tab 40)",
         "Source: T_MEDICAL (PROC_CD, BILL_PROC_CD, NOC), T_RX (NOC), T_MEDICAL procedure codes for SCT/CAR-T. "
         "Steroids excluded from medication-trigger candidates (MAP_MED_CLASS != 'STEROID'). "
         "Permissible biosimilar subs do NOT trigger a new LOT.",
         ""),
        ("FU_PD", "LOTN_START_TYPE", "Type of LOT N start event",
         "MED / SCT_AUTO / SCT_ALLO / CART",
         "Indicates which trigger started LOT N: a new MM medication, an autologous SCT (unplanned), an allogeneic SCT, or a CAR-T infusion.",
         "n/a",
         "Determined from the event class on LOTN_START_DT. If multiple events on same day, priority: SCT_ALLO > CART > SCT_AUTO > MED.",
         ""),
        # Induction window
        ("FU_PD", "INDUCTION_WINDOW_DAYS", "Induction regimen identification window",
         "30 (LOT2-5)",
         "Per protocol: 'For LOT2-LOT5, the LOT regimen includes all MM therapies received within 30 days on and following the LOT start date.' "
         "(Contrast: LOT1 uses 60 days.)",
         "n/a",
         "Applied to MAP_START_DT from T_MEDICAL/T_RX claims. Medications with MAP_START_DT within "
         "[LOTN_START_DT, LOTN_START_DT + 29] inclusive are induction.",
         ""),
        ("FU_PD", "LOTN_BASE_MEDS", "LOT N induction medications",
         "Comma-separated MED_ABBR list",
         "All MM oncology therapies received on and within 30 days of LOTN_START_DT, with the first therapy considered induction. "
         "Excludes corticosteroids (non-oncology supportive agents). Switches between a biologic reference product and its biosimilar(s), "
         "or between biosimilars of the same reference product, are permitted and do not constitute a change in regimen.",
         "CL_MMA_CODELIST (Tab 41), CL_MMA_ROLLUP (Tab 40)",
         "Filter MAP_MED_CLASS != 'STEROID'. Source: T_MEDICAL/T_RX matched to CL_MMA_CODELIST; abbreviation from CL_MMA_ROLLUP. "
         "Window: MAP_START_DT in [LOTN_START_DT, LOTN_START_DT + 29].",
         ""),
        ("FU_PD", "LOTN_MED_CNT", "Count of distinct induction agents",
         "Integer",
         "Number of unique non-steroid MM medication abbreviations in LOTN_BASE_MEDS.",
         "n/a", "Count distinct MED_ABBR within induction window.", ""),
        # SCT-as-start-of-LOT inheritance flags
        ("FU_PD", "LOTN_TX_AUTO_FLG", "Flag: any valid AUTO SCT during LOT N",
         "0/1",
         "Binary flag indicating the patient received any valid autologous SCT during LOT N (single or tandem).",
         "CL_SCT_CODELIST (SCT_TYPE='AUTO')",
         "Same logic as LOT1: 14-day windowing of T_MEDICAL procedure code dates; 60-day gap validation between distinct events.",
         ""),
        ("FU_PD", "LOTN_TX_AUTO_SING_FL", "Flag: single valid AUTO SCT during LOT N",
         "0/1",
         "Single AUTO not part of a valid tandem pair within LOT N.",
         "CL_SCT_CODELIST", "Inherits LOT1 SCT logic.", ""),
        ("FU_PD", "LOTN_TX_AUTO_TAND_FL", "Flag: planned tandem AUTO SCT during LOT N",
         "0/1",
         "Two AUTO SCTs within LOT N that are >=60 and <=180 days apart (planned tandem).",
         "CL_SCT_CODELIST", "Use datediff(AUTO_DT_2, AUTO_DT_1) without +1 (per Apr 22 protocol resolution).", ""),
        ("FU_PD", "LOTN_TX_AUTO_DT_1 / LOTN_TX_AUTO_DT_2", "Dates of first/second valid AUTO during LOT N",
         "Date / Date",
         "AUTO_DT_1 is the first valid AUTO SCT during LOT N; AUTO_DT_2 is the second when a planned tandem exists.",
         "CL_SCT_CODELIST", "14-day windowing groups same-event claims; 60-day gap validates distinct events.", ""),
        ("FU_PD", "LOTN_TX_AUTO_MAX_DT", "Latest valid AUTO SCT date during LOT N",
         "Date",
         "Date of AUTO_DT_2 if a valid tandem; else AUTO_DT_1 if a single AUTO occurred; else NULL.",
         "CL_SCT_CODELIST", "", ""),
        # Maintenance flag inheritance
        ("FU_PD", "contains_mtx_reg_LOTN", "Flag: LOT N regimen contains valid maintenance subset",
         "0 / 1",
         "Set 1 when LOT N induction regimen contains BOTH (a) at least one valid mono-maintenance agent OR a valid dual-maintenance combination, "
         "AND (b) at least one additional non-maintenance anchor agent. Same definition as LOT1. "
         "Valid mono: lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide. "
         "Valid dual: bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide.",
         "CL_MMA_ROLLUP MONOMAINTENANCE / DUALMAINTENANCEWITH",
         "Descriptive flag only; does NOT derive a separate maintenance LOT or maintenance end date.",
         ""),
        # Special: ALLO and CART singleton LOTs
        ("FU_PD", "LOTN_ALLO_LOT_FLG", "Flag: LOT N is an allogeneic SCT line",
         "0/1",
         "Set 1 when LOTN_START_TYPE='SCT_ALLO'. Per protocol: an allogeneic SCT is classified as its own LOT, with no other MM therapies "
         "included in that LOT. LOT span is the ALLO date itself (start = end = ALLO date) unless followed by a regimen that initiates LOT_(N+1).",
         "CL_SCT_CODELIST (SCT_TYPE='ALLO')",
         "Open question: should LOTN_BASE_END_DT be the ALLO date (one-day LOT) or extend to the day before LOT_(N+1) start? "
         "See Open_Questions tab Q2.",
         ""),
        ("FU_PD", "LOTN_CART_LOT_FLG", "Flag: LOT N is a CAR-T line",
         "0/1",
         "Set 1 when LOTN_START_TYPE='CART'. Per protocol: CAR-T is its own LOT; oncology agents (incl. supportive, e.g., corticosteroids) "
         "given within 45 days of CAR-T are CONSOLIDATED into the CAR-T LOT and not treated as new induction.",
         "CL_SCT_CODELIST (SCT_TYPE='CART')",
         "Within 45-day consolidation window, do NOT advance to LOT_(N+1). Use FIRST_CART_DT as LOTN_START_DT.",
         ""),
    ]
    write_rows(ws, 2, rows, col_widths=[10, 30, 32, 22, 70, 30, 60, 18])
    ws.row_dimensions[1].height = 36


def build_lot2_5_base_end(wb):
    name = "4.LOT2_5_BASE_END"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)
    headers = [
        "Time Period", "Variable", "Label", "Values", "Definition",
        "Code lists / Group", "Programming Notes", "QC Reviewed (Initials - Date)",
    ]
    for j, h in enumerate(headers, 1):
        ws.cell(row=1, column=j, value=h)
    style_header(ws, 1, len(headers))

    rows = [
        ("FU_PD", "LOTN_END_DT_TEMP", "Temporary end date for LOT N base period",
         "Date",
         "LOT N continues until the earliest of: "
         "(1) Discontinuation of all agents in the regimen (with or without switch to a new agent) - end date is the run-out date "
         "(last MAP_END_DT among induction agents); "
         "(2) Addition of a qualifying new MM oncology agent not in the LOT N induction regimen and not a permissible biosimilar substitute "
         "- end date is the day before the new agent's MAP_START_DT; "
         "(3) SCT/CAR-T events: any ALLO SCT ends the LOT the day before the ALLO; an AUTO SCT >180 days after a previous AUTO ends LOT "
         "the day before; CAR-T infusion ends the LOT the day before FIRST_CART_DT; "
         "(4) Death; "
         "(5) Health plan disenrollment; "
         "(6) End of the study period.",
         "T_MEDICAL/T_RX (MAP_END_DT, MAP_START_DT), T_MEDICAL procedure codes (SCT/CAR-T), T_DOD (YMDOD), T_MEMBER_CONT_ENROLLMENT (ELIGEND), study_end config",
         "Same priority logic as LOT1; only the induction window differs.",
         ""),
        ("FU_PD", "LOTN_BASE_DISCON_DT", "LOT N discontinuation date",
         "Date",
         "Run-out date: max(MAP_END_DT) across LOT N induction medications. If regimen is discontinued and no new agent is initiated, "
         "LOT end date is this run-out date. If interrupted by a new agent on or before the run-out date, LOT end is day before the new agent.",
         "CL_MMA_CODELIST",
         "Source: T_MEDICAL (FST_DT + medical_day_supply - 1), T_RX (FILL_DT + DAYS_SUP - 1) for induction meds. "
         "Pharmacy claims with missing/anomalous DAY_SUPPLY use 28-day default (per protocol; see C2 of Apr 15 review).",
         ""),
        ("FU_PD", "LOTN_BASE_1ST_ADD_MED_DT / LOTN_BASE_1ST_ADD_MED",
         "Date and name of first non-induction medication added during LOT N",
         "Date / MED_ABBR",
         "First MM oncology agent (non-steroid) appearing AFTER the induction window with MAP_START_DT on or before LOTN_BASE_DISCON_DT, "
         "and not already part of LOTN_BASE_MEDS or its permissible biosimilar substitute.",
         "CL_MMA_CODELIST, CL_MMA_ROLLUP, permissible_subs",
         "Filter MAP_MED_CLASS != 'STEROID'. Validate against permissible_subs reference table before classifying as new add.",
         ""),
        ("FU_PD", "LOT_DISCON_GAP_DAYS", "Discontinuation gap threshold (days)",
         "90",
         "Inherits LOT1 protocol value: discontinuation = all MM agents in LOT have stopped (run-out reached) and no new agent within gap.",
         "n/a", "Same as LOT1; sensitivity analyses may vary 30/60/90.", ""),
        ("FU_PD", "MEDICAL_DAY_SUPPLY", "Assumed days supply for medical claims",
         "28",
         "Medical-claim days supply is missing; assume 28 days. Pharmacy claims with missing or anomalous days supply also default to 28.",
         "n/a", "Apply COALESCE/CASE; do NOT delete claims with missing DAY_SUPPLY.", ""),
        ("FU_PD", "ALLO_ALWAYS_ENDS_LOT", "Allogeneic SCT always ends current LOT",
         "TRUE",
         "Any ALLO SCT immediately ends the current LOT (day before the ALLO) and begins a new LOT (the ALLO LOT).",
         "CL_SCT_CODELIST (SCT_TYPE='ALLO')",
         "Same as LOT1.",
         ""),
        ("FU_PD", "AUTO_TANDEM_WINDOW", "Tandem AUTO classification window",
         "60-180 days",
         "Two AUTO SCTs >=60 and <=180 days apart are planned tandem (continuation of same LOT). >180 days apart triggers a new LOT.",
         "CL_SCT_CODELIST (SCT_TYPE='AUTO')",
         "Use datediff without +1 (per Apr 22 resolution).",
         ""),
        ("FU_PD", "CART_45D_CONSOLIDATION", "CAR-T 45-day consolidation rule",
         "TRUE",
         "Oncology therapies (including supportive agents like steroids) given within 45 days of FIRST_CART_DT are consolidated into the CAR-T LOT.",
         "CL_SCT_CODELIST (SCT_TYPE='CART')",
         "Reclassify within 45-day window; do NOT trigger LOT_(N+1).",
         ""),
        ("FU_PD", "LOTN_BASE_END_DT", "Final LOT N base period end date",
         "Date",
         "Earliest of all qualifying end events. For ALLO/CAR-T-started LOTs (LOTN_START_TYPE in ('SCT_ALLO','CART')), "
         "see special handling in Open_Questions tab Q2.",
         "All sources above",
         "Priority logic same as LOT1.",
         ""),
        ("FU_PD", "LOTN_BASE_END_REASON", "Final LOT N base end reason",
         "SCT_ALLO / SCT_CART / SCT_AUTO / CART_INIT / MED_ADD / DISCONTINUATION / DEATH / DISENROLLMENT / STUDY_END",
         "Final reason. Priority when ties on the same day: "
         "SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END.",
         "All sources above",
         "Same priority order as LOT1. CART_INIT applies when CAR-T occurs within 45 days of a first added agent during LOT N.",
         ""),
        ("FU_PD", "LOTN_BASE_LENGTH", "LOT N base period duration in days",
         "Integer",
         "If LOTN_BASE_END_REASON = 'DISCONTINUATION' then LOTN_BASE_DISCON_DT - LOTN_START_DT + 1; "
         "else LOTN_BASE_END_DT - LOTN_START_DT + 1.",
         "n/a",
         "Confirm censored-patient handling against LOT1 M1 finding (Apr 15 review).",
         ""),
        ("FU_PD", "PERMISSIBLE_SUBS_EFFECT", "Permissible biosimilar substitution rules",
         "Do not advance LOT",
         "Substitution of a biologic reference product with any of its biosimilars, or between biosimilars of the same reference product, "
         "does not advance the LOT. The LOT is named by the drug given for the longest duration.",
         "permissible_subs reference",
         "Same as LOT1.",
         ""),
    ]
    write_rows(ws, 2, rows, col_widths=[10, 30, 32, 30, 80, 30, 60, 18])
    ws.row_dimensions[1].height = 36


def build_sct_cart_start(wb):
    name = "5.SCT_CART_LOT_START"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)
    headers = ["Trigger", "When it starts a new LOT (N>=2)", "LOT N start date", "LOT N regimen scope", "End-of-LOT-(N-1) reason", "Notes"]
    for j, h in enumerate(headers, 1):
        ws.cell(row=1, column=j, value=h)
    style_header(ws, 1, len(headers))

    rows = [
        ("Allogeneic SCT (ALLO)",
         "Always - any ALLO ends the current LOT and starts a new ALLO LOT.",
         "ALLO_DT",
         "ALLO LOT contains NO MM therapies (per protocol). Subsequent MM therapy starts LOT_(N+1).",
         "SCT_ALLO",
         "Open question Q2: should this LOT be a single-day record (start=end=ALLO_DT) or extend until the next agent?"),
        ("CAR-T infusion",
         "Always - CAR-T is its own LOT.",
         "FIRST_CART_DT",
         "Includes all oncology therapies (and supportive agents like steroids) within 45 days post-CAR-T (consolidation).",
         "SCT_CART (or CART_INIT if CAR-T within 45d of a first-add agent in LOT_(N-1))",
         "Use 45-day consolidation window for the CAR-T LOT regimen."),
        ("Autologous SCT (AUTO) - unplanned",
         "AUTO occurs >180 days after a previous AUTO in the same line.",
         "AUTO_DT (the latter, unplanned AUTO)",
         "Inducton window 30 days from AUTO_DT.",
         "SCT_AUTO",
         "If within 60-180 days of prior AUTO, it is planned tandem and stays in the same LOT - does not start LOT_(N+1)."),
        ("New MM oncology agent",
         "After LOT_(N-1) ends by DISCONTINUATION/MED_ADD with no SCT/CAR-T trigger.",
         "MAP_START_DT of the first such agent post LOT_(N-1)_BASE_END_DT",
         "30-day induction window from LOTN_START_DT.",
         "n/a (this is the start of LOT N, not the end of LOT_(N-1))",
         "Steroids alone do not start a LOT. Permissible biosimilar substitutes do not start a LOT."),
        ("Death / disenrollment / study end",
         "Never - these end follow-up; no LOT_(N+1).",
         "n/a", "n/a",
         "DEATH / DISENROLLMENT / STUDY_END",
         "LOT_(N-1) ends; no new LOT begins."),
    ]
    write_rows(ws, 2, rows, col_widths=[26, 50, 28, 50, 36, 60])
    ws.row_dimensions[1].height = 30


def build_scenarios(wb):
    name = "6.Scenarios"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)
    headers = ["Scenario", "Description", "Expected LOT2-5 behaviour"]
    for j, h in enumerate(headers, 1):
        ws.cell(row=1, column=j, value=h)
    style_header(ws, 1, len(headers))

    rows = [
        ("S1. LOT1 ends by MED_ADD, LOT2 starts on new agent",
         "Patient on VRd in LOT1; on day 200, daratumumab is added. LOT1 ends day 199 (MED_ADD); LOT2 starts day 200 with DARA.",
         "LOT2_START_DT = day 200; LOT2_START_TYPE = MED. LOT2 induction window = day 200 to day 229 captures any agents started within 30 days. "
         "If only DARA appears in induction window -> LOT2_BASE_MEDS = DARA."),
        ("S2. LOT1 ends by SCT_AUTO unplanned, LOT2 starts at AUTO date",
         "Single AUTO SCT during LOT1 followed by another AUTO 220 days later. The second AUTO is unplanned (>180d gap).",
         "LOT1 ends day before the second AUTO; LOT2_START_DT = second AUTO date; LOT2_START_TYPE = SCT_AUTO. "
         "LOT2 30-day induction captures any post-AUTO agents."),
        ("S3. LOT1 ends by SCT_ALLO, LOT2 = ALLO LOT",
         "Patient receives ALLO during/after LOT1.",
         "LOT1 ends day before ALLO; LOT2_START_DT = ALLO_DT; LOT2_START_TYPE = SCT_ALLO; LOT2_ALLO_LOT_FLG = 1. "
         "LOT2 contains no MM therapies. Next MM agent starts LOT3."),
        ("S4. LOT1 ends by CART, LOT2 = CAR-T LOT",
         "Patient receives CAR-T infusion.",
         "LOT1 ends day before FIRST_CART_DT; LOT2_START_DT = FIRST_CART_DT; LOT2_START_TYPE = CART. "
         "Agents (incl. steroids) within 45 days post-CAR-T are part of LOT2. Next non-consolidated agent starts LOT3."),
        ("S5. LOT2 -> LOT3 by discontinuation then new agent",
         "VRd in LOT2 ends by run-out (no new agent within 90d). Patient restarts therapy 200 days later with KRd.",
         "LOT2 ends on run-out (DISCONTINUATION). LOT3_START_DT = first KRd agent date; LOT3_START_TYPE = MED. "
         "30-day induction captures K, R, d (steroid excluded from regimen)."),
        ("S6. LOT3 ends by DEATH",
         "Patient dies during LOT3.",
         "LOT3_BASE_END_DT = YMDOD; LOT3_BASE_END_REASON = DEATH. No LOT4."),
        ("S7. Tandem AUTO during LOT2",
         "Two AUTO SCTs 90 days apart during LOT2.",
         "Both are planned tandem; LOT2 continues. LOT2_TX_AUTO_TAND_FL = 1; LOT2_TX_AUTO_DT_1/DT_2 populated. "
         "LOT2 does not end on the second AUTO."),
        ("S8. Permissible biosimilar swap mid-LOT2",
         "Patient on DARA in LOT2 switches to a DARA biosimilar.",
         "Substitution does NOT advance the LOT. LOT2 continues; regimen named by drug with longest duration."),
        ("S9. LOT2 base length = 1 day (ALLO LOT, open question)",
         "ALLO is its own LOT; if no further therapy, what is LOT span?",
         "Open question Q2. Draft assumption: LOT2_BASE_END_DT = ALLO_DT (1-day LOT); subsequent agents -> LOT3."),
        ("S10. CART_INIT carries through LOT boundary",
         "First add medication appears in LOT1, CAR-T occurs within 45 days of that add.",
         "Per LOT1 spec: LOT1_BASE_END_REASON = CART_INIT and LOT1_BASE_END_DT = FIRST_CART_DT - 1. "
         "LOT2_START_TYPE = CART; FIRST_CART_DT = LOT2_START_DT."),
    ]
    write_rows(ws, 2, rows, col_widths=[40, 70, 80])
    ws.row_dimensions[1].height = 30


def build_open_questions(wb):
    name = "7.Open_Questions"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)
    headers = ["#", "Question / Assumption", "Draft answer", "Owner", "Status"]
    for j, h in enumerate(headers, 1):
        ws.cell(row=1, column=j, value=h)
    style_header(ws, 1, len(headers))

    rows = [
        ("Q1", "Should LOT2-5 use the same 90-day discontinuation gap as LOT1?",
         "Yes - inherit unless protocol amendment says otherwise.",
         "Julia / Peter", "Open"),
        ("Q2", "Span of an ALLO-only LOT: single day (start=end=ALLO_DT) or extending until next agent?",
         "Draft: single day (consistent with 'ALLO contains no MM therapies'). Aligns with Apr 22 discussion of one-day SCT events.",
         "Julia / Peter", "Open"),
        ("Q3", "Span of a CAR-T LOT when no consolidation agents within 45 days?",
         "Draft: LOT spans FIRST_CART_DT to FIRST_CART_DT (1 day) or to last consolidation MAP_END_DT if any agents within 45d.",
         "Julia / Peter", "Open"),
        ("Q4", "If patient receives CAR-T during LOT1 induction window (CART_INIT), where does the next AUTO go?",
         "Per LOT1 spec, LOT1 ends day before CAR-T; CAR-T is LOT2. A subsequent AUTO would start LOT3 with SCT_AUTO trigger.",
         "Julia", "Open"),
        ("Q5", "Should LOTN_BASE_END_REASON include MAINTENANCE_END (Rule 8) for LOT2-5?",
         "Draft: NO - matches LOT1 decision (no standalone maintenance LOT). Use contains_mtx_reg_LOTN flag only.",
         "Julia", "Open"),
        ("Q6", "Maximum LOT cap = 5 even if patient continues to switch therapies?",
         "Draft: yes, cap at LOT5 per study scope. Anything after LOT5 collapses into a 'LOT5+' indicator (TBD).",
         "Julia", "Open"),
        ("Q7", "Should LOTN_TX_AUTO_FLG include AUTOs that occurred during LOT_(N-1) but were attributed to LOT_(N-1)?",
         "Draft: NO - AUTO flags are LOT-specific; only AUTOs with FST_DT within [LOTN_START_DT, LOTN_BASE_END_DT].",
         "Onkar", "Open"),
        ("Q8", "Steroids leak (LOT1 finding H1) - confirm fix is applied to LOT2-5 induction & first-add candidates.",
         "Yes - all induction filters and first_add_candidates CTEs must include MAP_MED_CLASS != 'STEROID'.",
         "Onkar", "Open"),
        ("Q9", "Off-by-one tandem (LOT1 finding H2) - same fix for LOT2-5.",
         "Yes - drop +1 in datediff for tandem window check; window is >=60 AND <=180 days.",
         "Onkar", "Open"),
        ("Q10", "Output table: should we emit one row per LOT (long format) with LOT_NUM column, or one wide row per patient?",
         "Draft: long format (patient_id, LOT_NUM, start, end, reason, regimen) + a wide pivot for analytic convenience.",
         "Julia / Dominique", "Open"),
    ]
    write_rows(ws, 2, rows, col_widths=[6, 60, 70, 22, 12])
    ws.row_dimensions[1].height = 30


if __name__ == "__main__":
    chunk = os.environ.get("CHUNK", "cover")
    wb = get_wb()
    if chunk in ("cover", "all"):
        build_cover(wb)
    if chunk in ("qc", "all"):
        build_qc(wb)
    if chunk in ("base", "all"):
        build_lot2_5_base(wb)
    if chunk in ("base_end", "all"):
        build_lot2_5_base_end(wb)
    if chunk in ("sct_cart", "all"):
        build_sct_cart_start(wb)
    if chunk in ("scenarios", "all"):
        build_scenarios(wb)
    if chunk in ("open_q", "all"):
        build_open_questions(wb)
    save(wb)
