"""Build draft LOT2-5 spec workbook in chunks.

Run with optional CHUNK env var: cover, qc, base, base_end, sct_cart, scenarios, open_q, all (default)
"""
import os
from pathlib import Path
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.utils import get_column_letter

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT = str(REPO_ROOT / "May 12 2026" / "Program Specs" / "lot2to5_spec_DRAFT_may13.xlsx")

HEADER_FILL = PatternFill("solid", fgColor="1F4E78")
SECTION_FILL = PatternFill("solid", fgColor="D9E1F2")
NOTE_FILL = PatternFill("solid", fgColor="FFF2CC")
EXAMPLE_FILL = PatternFill("solid", fgColor="E2EFDA")
EXAMPLE_HEADER_FILL = PatternFill("solid", fgColor="70AD47")

# Gantt color palette for timeline cells
LOT_COLORS = {
    "LOT1": "BDD7EE",       # light blue
    "LOT2": "F4B084",       # peach
    "LOT3": "C6E0B4",       # light green
    "LOT4": "FFD966",       # light gold
    "LOT5": "B4A7D6",       # lavender
    "GAP":  "F2F2F2",       # light grey - between LOTs
    "INDUCTION": "FFE699",  # induction window highlight
    "EVENT_SCT_AUTO": "FF9900",
    "EVENT_SCT_ALLO": "C00000",
    "EVENT_CART":     "7030A0",
    "EVENT_DEATH":    "404040",
    "EVENT_MED_ADD":  "0070C0",
}
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


def write_example_block(ws, start_row, title, narrative, var_table, ncols):
    """Append a 'Worked Example' block below an existing variable table."""
    # Title bar
    cell = ws.cell(row=start_row, column=1, value=title)
    cell.font = Font(name="Calibri", size=12, bold=True, color="FFFFFF")
    cell.fill = EXAMPLE_HEADER_FILL
    cell.alignment = WRAP
    ws.merge_cells(start_row=start_row, start_column=1, end_row=start_row, end_column=ncols)
    ws.row_dimensions[start_row].height = 22

    # Narrative
    nr = start_row + 1
    ncell = ws.cell(row=nr, column=1, value=narrative)
    ncell.font = NORMAL
    ncell.fill = EXAMPLE_FILL
    ncell.alignment = WRAP
    ncell.border = BORDER
    ws.merge_cells(start_row=nr, start_column=1, end_row=nr, end_column=ncols)
    ws.row_dimensions[nr].height = 60

    # Variable table header
    hr = nr + 1
    headers = ["Variable", "Value for this patient", "How it was derived"]
    # Spread the 3 columns across ncols (1 + 1 + remainder merged)
    ws.cell(row=hr, column=1, value=headers[0])
    ws.cell(row=hr, column=2, value=headers[1])
    ws.cell(row=hr, column=3, value=headers[2])
    if ncols > 3:
        ws.merge_cells(start_row=hr, start_column=3, end_row=hr, end_column=ncols)
    for c in range(1, ncols + 1):
        cell = ws.cell(row=hr, column=c)
        cell.font = BOLD
        cell.fill = SECTION_FILL
        cell.alignment = WRAP
        cell.border = BORDER

    # Variable rows
    for i, (var, val, deriv) in enumerate(var_table):
        r = hr + 1 + i
        ws.cell(row=r, column=1, value=var).font = BOLD
        ws.cell(row=r, column=2, value=val)
        ws.cell(row=r, column=3, value=deriv)
        if ncols > 3:
            ws.merge_cells(start_row=r, start_column=3, end_row=r, end_column=ncols)
        for c in range(1, ncols + 1):
            cell = ws.cell(row=r, column=c)
            cell.alignment = WRAP
            cell.fill = EXAMPLE_FILL
            cell.border = BORDER
            if c != 1:
                cell.font = NORMAL

    return hr + 1 + len(var_table)


def style_header(ws, row, ncols):
    for c in range(1, ncols + 1):
        cell = ws.cell(row=row, column=c)
        cell.fill = HEADER_FILL
        cell.font = HEADER_FONT
        cell.alignment = WRAP
        cell.border = BORDER


def _safe(val):
    """Guard against text values that Excel would interpret as a formula.

    A leading =, +, -, or @ at the start of a string cell makes Excel parse it
    as a formula. Reject these here so the bug surfaces at build time rather
    than as a corrupt cell in the workbook.
    """
    if isinstance(val, str) and val[:1] in ("=", "+", "-", "@"):
        raise ValueError(
            f"Cell value would be parsed as Excel formula: {val[:60]!r}. "
            "Reword to start with a letter (e.g. 'Flag is 1 when...')."
        )
    return val


def write_rows(ws, start_row, rows, col_widths=None):
    for i, row in enumerate(rows):
        for j, val in enumerate(row):
            cell = ws.cell(row=start_row + i, column=j + 1, value=_safe(val))
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
        ("Status", "DRAFT - revised per Julia 06-May QC comments"),
        ("Draft Date", "13-May-2026"),
        ("Source Protocol", "Lot protocol Apr 13.pdf (v6)"),
        ("Parent Spec", "lot1baseapr18.pdf / lot1baseendupdatedapr19.pdf"),
        ("Reference", "Apr 22 meeting minutes"),
        ("", ""),
        ("Tabs", ""),
        ("1.Cover", "This page"),
        ("2.QC Review", "QC sign-off log"),
        ("3.LOT2_5_BASE", "LOT 2-5 base period definition (start, induction, regimen)"),
        ("4.LOT2_5_BASE_END", "LOT 2-5 base end date and end reason derivation"),
        ("5.SCT_CART_LOT_START", "Rules for SCT/ALLO/CAR-T as LOT 2-5 starting events"),
        ("6.Scenarios", "Worked scenarios LOT2-LOT5"),
        ("7.Open_Questions", "Items needing Julia's review"),
        ("8.Timelines", "Gantt-style patient journey examples (visual)"),
        ("9.Decision_Flow", "Decision tree for when LOT(N+1) starts"),
        ("", ""),
        ("Key differences vs LOT1", ""),
        ("Induction window", "30d (LOT1 = 60d)"),
        ("LOT start trigger", "Earliest of: new MM agent / ALLO SCT / CAR-T / unplanned AUTO"),
        ("Numbering", "LOT_NUM = 2..5"),
        ("Maintenance", "contains_mtx_reg flag only; no standalone maintenance LOT (inherits LOT1 code). Q5."),
        ("Steroids", "Excluded from regimen."),
        ("Biosimilar subs", "Do not advance LOT."),
        ("CAR-T consolidation", "45 days; study-team decision."),
        ("Disenrollment", "PRIMARY: ignored. SENSITIVITY: ENDDATE_CE cap, reason = DISENROLLMENT (Q12 resolved)."),
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
         "LOT number after LOT1, up to LOT5. Each LOT starts after the previous one ends.",
         "n/a",
         "LOT_(N+1)_START_DT must be > LOT_N_BASE_END_DT.",
         ""),
        ("FU_PD", "LOTN_START_DT", "LOT N start date (N in 2..5)",
         "Date",
         "First of these after LOT_(N-1) ends: (a) a new non-steroid MM drug; (b) an ALLO SCT; "
         "(c) a CAR-T infusion; (d) an AUTO SCT - but an AUTO does NOT start a LOT if it is inside "
         "LOT_(N-1)'s window (30d MED/AUTO, 1d ALLO, 45d CART) or is a planned tandem "
         "(<=180d after the prior AUTO). Biosimilar swaps never trigger.",
         "CL_MMA_CODELIST, CL_SCT_CODELIST, CL_MMA_ROLLUP",
         "From T_MEDICAL / T_RX. Steroids excluded. LOT2-5 only; in LOT1 the first AUTO is induction.",
         ""),
        ("FU_PD", "LOTN_START_TYPE", "Trigger that started LOT N",
         "MED / SCT_AUTO / SCT_ALLO / CART",
         "Type of the trigger.",
         "n/a",
         "Same-day tie-break: SCT_ALLO > CART > SCT_AUTO > MED.",
         ""),
        ("FU_PD", "INDUCTION_WINDOW_DAYS", "Induction window",
         "30",
         "Window for picking up the LOT N regimen (LOT1 uses 60). Closes early if the patient is censored first.",
         "n/a",
         "Induction = MAP_START_DT in [LOTN_START_DT, min(LOTN_START_DT + 29, OBS_END_DT)].",
         ""),
        ("FU_PD", "LOTN_BASE_MEDS", "LOT N induction medications",
         "Comma list of MED_ABBR",
         "Non-steroid MM drugs in the 30-day induction window. Biosimilar swaps do not change the regimen.",
         "CL_MMA_CODELIST, CL_MMA_ROLLUP",
         "Exclude steroids (MAP_MED_CLASS != 'STEROID').",
         ""),
        ("FU_PD", "LOTN_MED_CNT", "Distinct induction agents",
         "Integer",
         "Number of distinct drugs in LOTN_BASE_MEDS.",
         "n/a", "", ""),
        ("FU_PD", "LOTN_MED_[MED]", "Per-medication induction flags",
         "0 / 1",
         "One flag per non-steroid drug (e.g. LOTN_MED_BORT, LOTN_MED_DARA). 1 if the drug is in LOTN_BASE_MEDS.",
         "CL_MMA_ROLLUP",
         "Same dynamic flags as LOT1; steroids excluded.",
         ""),
        ("FU_PD", "LOTN_CLASS_[CLASS]", "Per-class induction flags",
         "0 / 1",
         "One flag per non-steroid class (e.g. LOTN_CLASS_IMMUNOMOD). 1 if any LOTN_BASE_MEDS drug is in that class.",
         "CL_MMA_ROLLUP",
         "Same as LOT1.",
         ""),
        # SCT-as-start-of-LOT inheritance flags
        ("FU_PD", "LOTN_TX_AUTO_FLG", "Any valid AUTO SCT during LOT N", "0/1",
         "1 if the patient had >=1 valid AUTO during LOT N.",
         "CL_SCT_CODELIST (AUTO)",
         "Same SCT logic as LOT1.", ""),
        ("FU_PD", "LOTN_TX_AUTO_SING_FLG", "Single (non-tandem) AUTO during LOT N", "0/1",
         "1 if the AUTO is not part of a tandem pair.",
         "CL_SCT_CODELIST", "", ""),
        ("FU_PD", "LOTN_TX_AUTO_TAND_FLG", "Planned tandem AUTO during LOT N", "0/1",
         "1 if two AUTOs are <=180 days apart.",
         "CL_SCT_CODELIST",
         "datediff, no +1.", ""),
        ("FU_PD", "LOTN_TX_AUTO_DT_1 / LOTN_TX_AUTO_DT_2",
         "First / second valid AUTO date in LOT N", "Date / Date",
         "DT_2 only set for a planned tandem.",
         "CL_SCT_CODELIST", "", ""),
        ("FU_PD", "LOTN_TX_AUTO_MAX_DT", "Latest valid AUTO in LOT N", "Date",
         "AUTO_DT_2 if tandem, else AUTO_DT_1, else NULL.",
         "CL_SCT_CODELIST", "", ""),
        ("FU_PD", "contains_mtx_reg_LOTN", "LOT N regimen contains valid maintenance subset", "0/1",
         "1 when induction has BOTH (a) a mono-maintenance drug or a valid dual combo, AND (b) an anchor drug. "
         "Mono: LENA, BORT, DARA, IXAZ, THAL. Dual: BORT+LENA, CARF+LENA, DARA+LENA.",
         "CL_MMA_ROLLUP",
         "Descriptive only; no separate maintenance LOT.", ""),
        ("FU_PD", "LOTN_ALLO_LOT_FLG", "LOT N is an ALLO SCT line", "0/1",
         "1 when START_TYPE = SCT_ALLO. An ALLO LOT has no MM drugs and lasts one day "
         "(start = end = ALLO_DT). The next MM drug starts the following LOT.",
         "CL_SCT_CODELIST (ALLO)", "", ""),
        ("FU_PD", "LOTN_CART_LOT_FLG", "LOT N is a CAR-T line", "0/1",
         "1 when START_TYPE = CART. Drugs within 45 days of FIRST_CART_DT belong to this LOT.",
         "CL_SCT_CODELIST (CART)",
         "Consolidated drugs do not start LOT_(N+1).", ""),
    ]
    write_rows(ws, 2, rows, col_widths=[10, 30, 32, 22, 70, 30, 60, 18])
    ws.row_dimensions[1].height = 36

    # ----- Worked examples appendix -----
    next_row = 2 + len(rows) + 2  # gap row
    ncols = 8

    # Example A: medication-triggered LOT2
    ex_a_narrative = (
        "VRd in LOT1; DARA added 2025-08-20 (LOT1 ends 2025-08-19). LENA refills within 30d. No SCT/CAR-T."
    )
    ex_a_table = [
        ("LOT_NUM", "2", ""),
        ("LOTN_START_DT", "2025-08-20", "First trigger after LOT1 ends = DARA."),
        ("LOTN_START_TYPE", "MED", ""),
        ("LOTN_BASE_MEDS", "DARA, LENA", "Window [2025-08-20, 2025-09-18]. DEXA excluded (steroid)."),
        ("LOTN_MED_CNT", "2", ""),
        ("LOTN_MED_DARA", "1", ""),
        ("LOTN_MED_LENA", "1", ""),
        ("LOTN_CLASS_ANTICD38", "1", "DARA."),
        ("LOTN_CLASS_IMMUNOMOD", "1", "LENA."),
        ("contains_mtx_reg_LOTN", "1", "DARA+LENA is a valid maintenance pair."),
        ("LOTN_ALLO_LOT_FLG / LOTN_CART_LOT_FLG", "0 / 0", ""),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE A - LOT2 starts on a new drug",
                                   ex_a_narrative, ex_a_table, ncols) + 2

    # Example B: ALLO-started LOT
    ex_b_narrative = (
        "VRd in LOT1; ALLO on 2025-09-15 (LOT1 ends 2025-09-14). DARA on 2025-12-10 starts LOT3."
    )
    ex_b_table = [
        ("LOT_NUM", "2", ""),
        ("LOTN_START_DT", "2025-09-15", "ALLO always starts a new LOT."),
        ("LOTN_START_TYPE", "SCT_ALLO", ""),
        ("LOTN_BASE_MEDS", "(empty)", "ALLO LOT has no MM drugs."),
        ("LOTN_MED_CNT", "0", ""),
        ("LOTN_ALLO_LOT_FLG", "1", ""),
        ("LOTN_BASE_END_DT", "2025-09-15", "ALLO LOT = 1 day."),
        ("LOTN_BASE_END_REASON", "SCT_ALLO", ""),
        ("LOT3_START_DT", "2025-12-10", "First MM drug after LOT2."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE B - LOT2 starts on an allogeneic SCT",
                                   ex_b_narrative, ex_b_table, ncols) + 2

    # Example C: AUTO triggers LOT3 (LOT2-5 only)
    ex_c_narrative = (
        "LOT1 ends 2025-04-30 (DISCONTINUATION). LOT2 is MED-started 2025-08-20 (DARA+LENA). "
        "A first-ever AUTO on 2025-12-10 is outside LOT2's 30d window and not a tandem, so it "
        "starts LOT3. (LOT2-5 only; in LOT1 the first AUTO would still be induction.)"
    )
    ex_c_table = [
        ("LOT_NUM", "3", ""),
        ("LOTN_START_DT", "2025-12-10", "AUTO outside LOT2's 30d window, not a tandem."),
        ("LOTN_START_TYPE", "SCT_AUTO", "A first-ever AUTO can start a LOT (LOT2-5 only)."),
        ("LOTN_BASE_MEDS", "(empty)", "No MM drugs in the post-AUTO window [2025-12-10, 2026-01-08]."),
        ("LOTN_MED_CNT", "0", "AUTO-only LOT."),
        ("INDUCTION_WINDOW_DAYS", "30", "Post-AUTO window [2025-12-10, 2026-01-08]."),
        ("LOTN_TX_AUTO_FLG", "1", "AUTO during LOT3."),
        ("LOTN_TX_AUTO_SING_FLG", "1", "Single AUTO (no tandem)."),
        ("LOTN_TX_AUTO_TAND_FLG", "0", ""),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE C - LOT3 starts on a first-ever AUTO",
                                   ex_c_narrative, ex_c_table, ncols) + 2


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
        ("FU_PD", "LOTN_END_DT_TEMP", "Temporary LOT N end date", "Date",
         "PRIMARY: the earliest of (1) run-out (all drugs gone); (2) a new MM drug (day before its start); "
         "(3) ALLO SCT (day before); (4) an AUTO that starts a new LOT (day before); "
         "(5) CAR-T (day before FIRST_CART_DT); "
         "(6) CART_INIT - CAR-T within 45 days of the first drug that breaks LOT N (LOT ends FIRST_CART_DT - 1); "
         "(7) death; (8) study end. Disenrollment is not a primary end. "
         "SENSITIVITY: also cap at ENDDATE_CE when CENSOR_AT_DISENROLLMENT = TRUE.",
         "T_MEDICAL/T_RX, T_DOD, study_end; SENSITIVITY: T_MEMBER_CONT_ENROLLMENT (ELIGEND)",
         "Same as LOT1 except the induction window.", ""),
        ("FU_PD", "LOTN_BASE_DISCON_DT", "LOT N run-out date (last med date)", "Date",
         "Last day of supply across LOT N drugs (max MAP_END_DT). Always set when a run-out exists, "
         "even if a higher-priority reason (death, SCT) ends the LOT. Used as the end date only when reason = DISCONTINUATION.",
         "CL_MMA_CODELIST",
         "T_MEDICAL: FST_DT + medical_day_supply - 1. T_RX: FILL_DT + DAYS_SUP - 1. "
         "Missing DAY_SUPPLY -> 28d (keep claims). Only one 90-day rule exists: the per-drug MAP rule "
         "(no refill in 90d = discontinued). No extra LOT-level wait.",
         ""),
        ("FU_PD", "LOTN_BASE_1ST_ADD_MED_DT / LOTN_BASE_1ST_ADD_MED",
         "First non-induction agent during LOT N", "Date / MED_ABBR",
         "First non-steroid MM drug after the induction window, on/before run-out, not in LOTN_BASE_MEDS or a biosimilar of it.",
         "CL_MMA_CODELIST, permissible_subs",
         "Audit/debug output (in LOT_LONG), not a primary variable. Check permissible_subs first.", ""),
        ("FU_PD", "ALLO_ALWAYS_ENDS_LOT", "ALLO always ends current LOT", "TRUE",
         "Any ALLO ends the current LOT the day before, and starts a new ALLO LOT.",
         "CL_SCT_CODELIST (ALLO)", "", ""),
        ("FU_PD", "AUTO_TANDEM_WINDOW", "Tandem AUTO window",
         "< 60d: same event; 60-180d: tandem; > 180d: new LOT",
         "AUTOs are grouped into events first. Two AUTOs <60 days apart = ONE event (the close one is "
         "not a separate event, so no tandem and no separate trigger). Two distinct AUTOs 60-180 days "
         "apart = planned tandem (same LOT). An AUTO >180 days after the prior one starts a new LOT if "
         "it is also outside LOT N's window.",
         "CL_SCT_CODELIST (AUTO)",
         "The <60d merge happens upstream (tx_auto_dates, sct_auto_gap_days=60), so tandem only needs "
         "the <=180d bound. datediff, no +1.", ""),
        ("FU_PD", "CART_CONSOLIDATION_DAYS", "CAR-T consolidation window", "45",
         "Drugs within 45 days of FIRST_CART_DT belong to the CAR-T LOT.",
         "CL_SCT_CODELIST (CART)",
         "Consolidated drugs do not start LOT_(N+1).", ""),
        ("FU_PD", "LOTN_BASE_END_DT", "Final LOT N end date (PRIMARY)", "Date",
         "Earliest qualifying end from LOTN_END_DT_TEMP. CART_INIT applies if CAR-T is within 45 days "
         "of the first drug that breaks LOT N.",
         "n/a",
         "ALLO LOT = 1 day (start = end = ALLO_DT). CAR-T LOT runs to the last consolidation drug's end. "
         "Under CART_INIT the pre-CAR-T bridge drug only marks the switch (LOT N ends FIRST_CART_DT - 1); "
         "it does not make its own LOT and is not in the CAR-T regimen (CAR-T meds start on/after FIRST_CART_DT).", ""),
        ("FU_PD", "LOTN_BASE_END_REASON", "Final LOT N end reason (PRIMARY)",
         "SCT_ALLO / SCT_CART / SCT_AUTO / CART_INIT / MED_ADD / DEATH / DISCONTINUATION / STUDY_END",
         "Reason for LOTN_BASE_END_DT. DISENROLLMENT only in sensitivity (see *_CE_SENS).",
         "n/a",
         "Priority when events overlap: SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DEATH > "
         "DISCONTINUATION > STUDY_END. DEATH beats DISCONTINUATION, so run-out-then-death keeps DEATH "
         "(run-out date still in LOTN_BASE_DISCON_DT). Exception: if a new LOT trigger (new drug, ALLO, "
         "CART, qualifying AUTO) happens after run-out but before death, DISCONTINUATION wins at the "
         "run-out date and the trigger starts LOT N+1.",
         ""),
        ("FU_PD", "LOTN_BASE_END_DT_CE_SENS", "LOT N end date (SENSITIVITY)", "Date",
         "Same as LOTN_BASE_END_DT but capped at ELIGEND. Emitted when CENSOR_AT_DISENROLLMENT = TRUE.",
         "T_MEMBER_CONT_ENROLLMENT", "Primary end date unchanged.", ""),
        ("FU_PD", "LOTN_BASE_END_REASON_CE_SENS", "LOT N end reason (SENSITIVITY)",
         "(primary set) + DISENROLLMENT",
         "Same as primary, plus DISENROLLMENT when ELIGEND binds.",
         "n/a",
         "Emit DISENROLLMENT (do not collapse to STUDY_END). Differs from LOT1.",
         ""),
        ("FU_PD", "LOTN_BASE_LENGTH", "LOT N duration (days)", "Integer",
         "DISCONTINUATION: DISCON_DT - START_DT + 1. Else: END_DT - START_DT + 1.",
         "n/a", "Confirm censored handling (LOT1 M1).", ""),
    ]
    write_rows(ws, 2, rows, col_widths=[10, 30, 32, 30, 80, 30, 60, 18])
    ws.row_dimensions[1].height = 36

    # ----- Worked examples appendix -----
    next_row = 2 + len(rows) + 2
    ncols = 8

    # Example D: end-reason resolution (priority logic)
    ex_d_narrative = (
        "LOT3 starts 2025-11-01 (KRd). Competing events: run-out 2026-04-15; POMA add 2026-03-20; CAR-T 2026-04-02 (within 45d of POMA); death 2026-05-20. "
        "Priority resolves to CART_INIT."
    )
    ex_d_table = [
        ("LOTN_BASE_END_DT", "2026-04-01", "FIRST_CART_DT - 1."),
        ("LOTN_BASE_END_REASON", "CART_INIT", "CART_INIT outranks MED_ADD; CAR-T within 45d of first add."),
        ("LOTN_BASE_LENGTH", "152", "2026-04-01 - 2025-11-01 + 1."),
        ("LOT_(N+1)_START_DT", "2026-04-02", "LOT4_START_TYPE = CART."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE D - End-reason priority with CART_INIT",
                                   ex_d_narrative, ex_d_table, ncols) + 2

    # Example E: discontinuation - runout directly ends the LOT
    ex_e_narrative = (
        "LOT2 starts 2025-08-20 (DARA+LENA). Last LENA MAP_END_DT 2026-02-06; last DARA 2026-01-15. No new agent, no death, study continues."
    )
    ex_e_table = [
        ("LOTN_BASE_DISCON_DT", "2026-02-06", "Last med date (max MAP_END_DT) across LOT2 drugs."),
        ("LOTN_BASE_END_DT", "2026-02-06", "Run-out = LOT end. Only the per-drug 90d rule applies; no LOT-level wait."),
        ("LOTN_BASE_END_REASON", "DISCONTINUATION", "Run-out reached; nothing higher-priority."),
        ("LOTN_BASE_LENGTH", "171", "2026-02-06 - 2025-08-20 + 1."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE E - Discontinuation (run-out)",
                                   ex_e_narrative, ex_e_table, ncols) + 2

    # Example F: disenrollment - primary vs sensitivity
    ex_f_narrative = (
        "LOT4 starts 2026-01-05. ELIGEND 2026-04-30; no death; study_end 2026-12-31."
    )
    ex_f_table = [
        ("LOTN_BASE_END_DT (PRIMARY)", "2026-12-31", "Disenrollment ignored; min(death, study_end) = study_end."),
        ("LOTN_BASE_END_REASON (PRIMARY)", "STUDY_END", ""),
        ("LOTN_BASE_END_DT_CE_SENS", "2026-04-30", "ELIGEND binds."),
        ("LOTN_BASE_END_REASON_CE_SENS", "DISENROLLMENT", "Required: do NOT collapse to STUDY_END."),
        ("LOTN_BASE_LENGTH (PRIMARY)", "361", "2026-12-31 - 2026-01-05 + 1."),
        ("LOTN_BASE_LENGTH_CE_SENS", "116", "2026-04-30 - 2026-01-05 + 1."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE F - Disenrollment primary vs sensitivity",
                                   ex_f_narrative, ex_f_table, ncols) + 2


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
        ("ALLO SCT", "Always.", "ALLO_DT",
         "No MM drugs in this LOT.", "SCT_ALLO",
         "ALLO LOT = 1 day: start = end = ALLO_DT."),
        ("CAR-T", "Always.", "FIRST_CART_DT",
         "Drugs within 45 days of FIRST_CART_DT belong to this LOT.",
         "SCT_CART (or CART_INIT if CAR-T within 45 days of the first drug that breaks LOT_(N-1))",
         "45-day window. Under CART_INIT the pre-CAR-T bridge drug only marks the switch; it does not "
         "make its own LOT (consolidated drugs do not start LOT_(N+1))."),
        ("AUTO SCT",
         "Always, unless (i) inside LOT_(N-1)'s window (30d MED/AUTO, 1d ALLO, 45d CART) or "
         "(ii) <=180d after a prior AUTO (planned tandem).",
         "AUTO_DT",
         "30d induction from AUTO_DT.", "SCT_AUTO",
         "A first-ever AUTO can start a LOT (LOT2-5 only; in LOT1 the first AUTO is induction). "
         "AUTOs <60 days apart are merged into one event upstream and never count as a separate trigger or tandem."),
        ("New MM agent",
         "Any qualifying MM drug starting after LOT_(N-1) ends (MAP_START_DT > LOT_(N-1)_BASE_END_DT), "
         "unless a higher-priority SCT/CAR-T shares that date.",
         "MAP_START_DT of new agent", "30d induction window.", "n/a",
         "Any non-steroid, non-biosimilar MM drug after LOT_(N-1) ends starts a LOT, whatever the prior "
         "LOT's end reason. Same-day priority: SCT_ALLO > CART > SCT_AUTO > MED."),
        ("Death / STUDY_END (PRIMARY)", "Never starts a LOT; ends follow-up.",
         "n/a", "n/a", "DEATH / STUDY_END",
         "Death and study end never start a LOT. Run-out -> DISCONTINUATION. A new drug after run-out "
         "starts the next LOT. Death is the end reason only if no next-LOT trigger comes first. "
         "Disenrollment is not a primary end."),
        ("Disenrollment (SENSITIVITY only)", "Never starts a LOT.",
         "n/a", "n/a", "DISENROLLMENT (sensitivity)",
         "Cap via ENDDATE_CE only when CENSOR_AT_DISENROLLMENT = TRUE."),
    ]
    write_rows(ws, 2, rows, col_widths=[22, 40, 22, 38, 36, 40])
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
        ("S1. LOT1->LOT2 by MED_ADD",
         "VRd in LOT1; DARA added day 200.",
         "LOT1 ends d199. LOT2 starts d200, TYPE=MED. Induction d200-d229."),
        ("S2. LOT2->LOT3 by AUTO outside window",
         "LOT2 MED-started (30d window). AUTO at d320 - outside LOT2's window, not within 180d of a prior AUTO.",
         "LOT2 ends d319. LOT3 starts d320, TYPE=SCT_AUTO. LOT2-5 only; LOT1's first AUTO stays induction."),
        ("S3. LOT1->LOT2 (ALLO LOT)->LOT3",
         "ALLO during/after LOT1, then later DARA.",
         "LOT2: start = end = ALLO_DT (1-day ALLO LOT, no MM). Next drug starts LOT3."),
        ("S4. LOT1->LOT2 (CAR-T LOT)",
         "CAR-T infusion.",
         "LOT2 starts FIRST_CART_DT, TYPE=CART. Drugs within 45d belong to it."),
        ("S5. LOT2->LOT3 by DISCONTINUATION",
         "Run-out, then new drug 200d later.",
         "LOT2 ends DISCONTINUATION. LOT3 starts on the new drug."),
        ("S6. LOT3 ends by DEATH",
         "Death during LOT3.",
         "LOT3 ends at death (YMDOD), reason=DEATH. No LOT4."),
        ("S6b. Disenrollment (primary vs sensitivity)",
         "ELIGEND during LOT3, no death, study_end later.",
         "PRIMARY: reason=STUDY_END at study_end. SENSITIVITY: *_CE_SENS at ELIGEND, reason=DISENROLLMENT."),
        ("S7. Tandem AUTO in LOT2",
         "Two AUTOs 90d apart.",
         "Planned tandem; LOT2 continues. AUTO_TAND_FLG=1."),
        ("S7b. AUTO claims < 60 days apart",
         "Two AUTOs 40 days apart in LOT2.",
         "Merged into one AUTO event upstream. No tandem (AUTO_TAND_FLG=0) and not a separate "
         "trigger; the single event is still evaluated normally."),
        ("S8. Biosimilar swap in LOT2",
         "DARA -> DARA biosimilar.",
         "LOT does not advance."),
        ("S9. ALLO LOT span",
         "ALLO with no follow-on therapy.",
         "1-day ALLO LOT: start = end = ALLO_DT."),
        ("S10. CART_INIT carryover",
         "CAR-T within 45 days of the first new drug that breaks LOT1.",
         "LOT1 ends with CART_INIT. LOT2 TYPE=CART."),
    ]
    write_rows(ws, 2, rows, col_widths=[36, 50, 70])
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
        ("Q1", "Is there a 90-day LOT-level discontinuation buffer?",
         "RESOLVED: NO. There is only ONE 90-day rule in the pipeline - the MAP-level per-drug rule "
         "(map_discon_gap_days). A drug is considered discontinued if no refill appears within 90 days. "
         "There is NO additional LOT-level 90-day wait on top of that. Once all base meds run out, the LOT "
         "ends at that runout date directly. "
         "Confirmed by Julia 13-May: ship as-is with 'runout = DISCONTINUATION' semantics. Direction of "
         "the labeling change is acknowledged: patients with < 90 d of post-runout observation are now "
         "labeled DISCONTINUATION at the runout date rather than STUDY_END at obs end - aligns with the "
         "intuitive reading of the data. "
         "Two follow-up adjustments to keep the cascade correct: "
         "(a) End-reason priority is DEATH > DISCONTINUATION > STUDY_END so patients who run out and then "
         "die still get REASON = DEATH. "
         "(b) Q1.1: DEATH preempts DISCONTINUATION only when no LOT-(N+1) trigger sits between runout and "
         "death - protects post-runout therapy from being silently absorbed by death.",
         "Julia / Peter", "Resolved"),
        ("Q2", "ALLO LOT span: single day or until next agent?",
         "RESOLVED: single day, start = end = ALLO_DT. ALLO is a punctuation event between LOTs; the next MM agent starts the following LOT.",
         "Julia / Peter", "Resolved"),
        ("Q3", "CAR-T LOT span when no consolidation agents in 45d?",
         "Draft: 1 day, else through last consolidation MAP_END_DT.", "Julia / Peter", "Open"),
        ("Q4", "CART_INIT in LOT1 -> LOT2 = CART. Next AUTO -> LOT3 with SCT_AUTO?",
         "Draft: yes.", "Julia", "Open"),
        ("Q5", "Include MAINTENANCE_END (protocol Rule 8) as LOTN end reason?",
         "Draft: no - follow current LOT1 code (descriptive flag only).", "Julia", "Open"),
        ("Q6", "Cap LOTs at 5?",
         "Draft: yes; LOT5+ indicator TBD.", "Julia", "Open"),
        ("Q7", "AUTO flags LOT-scoped to [LOTN_START_DT, LOTN_BASE_END_DT]?",
         "Draft: yes.", "Onkar", "Open"),
        ("Q8", "Confirm steroid filter applied (LOT1 H1).",
         "Required: MAP_MED_CLASS != 'STEROID' in induction + first-add CTEs.", "Onkar", "Open"),
        ("Q9", "Tandem AUTO window: just <=180 days, or >=60 AND <=180 (protocol)?",
         "RESOLVED per Julia 13-May: tandem classification uses <= sct_tandem_days (180) only. "
         "Context: AUTO claims are first grouped into transplant events in tx_auto_dates, "
         "which already applies a 14-day window grouping and a 60-day event-separation rule "
         "(cfg$sct_auto_gap_days). Claims less than 60 days apart get MERGED into a single AUTO "
         "event upstream, so by the time tandem classification runs, two distinct AUTO events "
         "are always >= 60 days apart. The tandem check then only needs the upper bound: "
         "a second derived AUTO within 180 days of the first is a planned tandem. datediff "
         "used without +1. Matches LOT1's existing behaviour.",
         "Julia / Peter", "Resolved"),
        ("Q10", "Output shape: long (one row per LOT) vs wide?",
         "Draft: long primary + wide pivot.", "Julia / Dominique", "Open"),
        ("Q11", "CAR-T consolidation: 45 vs 30 days?",
         "RESOLVED: 45 days (Apr 22 decision; not 'per protocol').", "Julia", "Resolved"),
        ("Q12", "Disenrollment as end event?",
         "RESOLVED: PRIMARY ignores; SENSITIVITY caps via ENDDATE_CE and emits DISENROLLMENT (do NOT collapse to STUDY_END).",
         "Julia", "Resolved"),
        ("Q13", "Flag prefix LOTN_TX_ vs LOTN_SCT_ - LOT1 uses LOT1_SCT_AUTO_*FLG.",
         "Draft uses LOTN_TX_AUTO_*FLG; consider aligning to LOTN_SCT_AUTO_*FLG.",
         "Onkar / Julia", "Open"),
        ("Q14", "Same-day SCT/ALLO/CART/AUTO representation for LOT2-5.",
         "RESOLVED: keep scalar priority (SCT_ALLO > CART > SCT_AUTO > MED) inherited from LOT1. "
         "LOTN_START_TYPE records the highest-priority event on the start date.",
         "Julia / Peter", "Resolved"),
        ("Q15", "CAR-T LOT end reason when consolidation meds run out: SCT_CART or DISCONTINUATION?",
         "RESOLVED per Onkar 13-May: DISCONTINUATION (current code). Rationale: SCT_CART describes "
         "how the LOT STARTED, not how it ended. When the consolidation regimen runs out of supply, "
         "the LOT ended because the meds stopped - that is DISCONTINUATION. The CAR-T LOT spans "
         "through last consolidation MAP_END_DT and routes the end reason by runout exactly like "
         "any other LOT.",
         "Julia / Onkar", "Resolved"),
        ("Q16", "AUTO trigger: 'always except induction/consolidation window'?",
         "RESOLVED + IMPLEMENTED: AUTO starts a new LOT (in LOT2-5) unless (i) it falls inside LOT_(N-1)'s applicable window "
         "(30d for MED/AUTO-started LOTs, 1d for ALLO-started LOTs, 45d for CART-started LOTs) "
         "or (ii) it is on/before sct_tandem_days (180d) after the immediately prior AUTO (planned tandem). "
         "Scope: LOT2-5 only. LOT1 retains the protocol convention that the first AUTO is part of induction "
         "(lot_program.R:1300-1309 unchanged). "
         "Tandem classification checks only the 180-day upper bound after AUTO events have been grouped upstream (see Q9 resolution). "
         "Code implemented in lot2_5_base.R: auto_cand CTE and lot_n_sct ENDING_AUTO_DT now apply the window-by-type rule; "
         "prev_end CTE pulls PREV_START_DT and PREV_START_TYPE from lot_long for the window lookup.",
         "Julia / Peter", "Resolved"),
    ]
    write_rows(ws, 2, rows, col_widths=[6, 50, 60, 20, 12])
    ws.row_dimensions[1].height = 30


def build_timelines(wb):
    """Gantt-style patient timelines, drawn with colored cells.

    Each scenario is one timeline. Day axis is 14-day buckets (a 'week' pair) for readability.
    Cell colors indicate which LOT each bucket belongs to, with single-cell event markers
    overlaid for SCTs / CAR-T / death.
    """
    name = "8.Timelines"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)

    # Title row
    ws["A1"] = "Patient timelines (Gantt-style) - illustrating LOT2-5 transitions"
    ws["A1"].font = Font(name="Calibri", size=14, bold=True, color="1F4E78")
    ws.merge_cells("A1:R1")
    ws.row_dimensions[1].height = 22

    # Legend
    ws["A2"] = "Legend:"
    ws["A2"].font = BOLD
    legend_items = [
        ("LOT1", "LOT1"), ("LOT2", "LOT2"), ("LOT3", "LOT3"),
        ("LOT4", "LOT4"), ("LOT5", "LOT5"), ("INDUCTION", "30d induction"),
        ("EVENT_SCT_AUTO", "AUTO SCT"), ("EVENT_SCT_ALLO", "ALLO SCT"),
        ("EVENT_CART", "CAR-T"), ("EVENT_DEATH", "Death"),
        ("EVENT_MED_ADD", "Med add"),
    ]
    col = 2
    for key, label in legend_items:
        c = ws.cell(row=2, column=col, value=label)
        c.fill = PatternFill("solid", fgColor=LOT_COLORS[key])
        c.font = Font(name="Calibri", size=9, bold=True,
                      color="FFFFFF" if key in ("EVENT_SCT_ALLO", "EVENT_CART", "EVENT_DEATH") else "000000")
        c.alignment = Alignment(horizontal="center", vertical="center")
        c.border = BORDER
        col += 1
    ws.row_dimensions[2].height = 18

    # Day axis: 0..560 days in 14-day buckets => 41 columns
    BUCKET = 14
    N_BUCKETS = 40
    AXIS_START_COL = 4  # cols A,B,C reserved for labels; day axis starts at D

    # Header row for axis (row 4)
    axis_row = 4
    ws.cell(row=axis_row, column=1, value="Scenario").font = BOLD
    ws.cell(row=axis_row, column=2, value="Description").font = BOLD
    ws.cell(row=axis_row, column=3, value="Day ->").font = BOLD
    for i in range(N_BUCKETS):
        day = i * BUCKET
        c = ws.cell(row=axis_row, column=AXIS_START_COL + i, value=day if day % 56 == 0 else "")
        c.font = Font(name="Calibri", size=8, bold=True)
        c.fill = SECTION_FILL
        c.border = BORDER
        c.alignment = Alignment(horizontal="center")
    for c in range(1, AXIS_START_COL + N_BUCKETS):
        ws.cell(row=axis_row, column=c).fill = SECTION_FILL
        ws.cell(row=axis_row, column=c).border = BORDER

    # Scenarios as (label, description, segments)
    # segments: list of dicts: {"start_day": d, "end_day": d, "kind": "LOT1"/"LOT2"/.../"INDUCTION"/"EVENT_*"}
    scenarios = [
        {
            "label": "S1: LOT1 -> LOT2 by MED_ADD",
            "desc": "VRd LOT1; DARA added day 200 -> LOT2 starts on DARA",
            "segments": [
                {"start_day": 0,   "end_day": 199, "kind": "LOT1"},
                {"start_day": 0,   "end_day": 56,  "kind": "INDUCTION"},  # LOT1 60d induction (overlay)
                {"start_day": 200, "end_day": 199, "kind": "EVENT_MED_ADD"},  # marker only
                {"start_day": 200, "end_day": 540, "kind": "LOT2"},
                {"start_day": 200, "end_day": 228, "kind": "INDUCTION"},  # LOT2 30d induction overlay
            ],
        },
        {
            "label": "S2: LOT2 -> LOT3 by AUTO outside window (Q16, LOT2-5 only)",
            "desc": "LOT1 ends d199 by MED_ADD. LOT2 (MED-started, 30d window d200-d229). First-ever AUTO at d320 - outside LOT2's window and not a tandem -> LOT3 starts d320.",
            "segments": [
                {"start_day": 0,   "end_day": 199, "kind": "LOT1"},
                {"start_day": 0,   "end_day": 56,  "kind": "INDUCTION"},
                {"start_day": 200, "end_day": 319, "kind": "LOT2"},
                {"start_day": 200, "end_day": 228, "kind": "INDUCTION"},
                {"start_day": 320, "end_day": 320, "kind": "EVENT_SCT_AUTO"},
                {"start_day": 320, "end_day": 540, "kind": "LOT3"},
                {"start_day": 320, "end_day": 348, "kind": "INDUCTION"},
            ],
        },
        {
            "label": "S3: LOT1 -> LOT2 (ALLO LOT) -> LOT3",
            "desc": "ALLO d250 = LOT2 (1-day LOT, no MM); next agent d340 starts LOT3",
            "segments": [
                {"start_day": 0,   "end_day": 249, "kind": "LOT1"},
                {"start_day": 250, "end_day": 250, "kind": "EVENT_SCT_ALLO"},
                {"start_day": 250, "end_day": 250, "kind": "LOT2"},  # singleton ALLO LOT
                {"start_day": 340, "end_day": 540, "kind": "LOT3"},
                {"start_day": 340, "end_day": 368, "kind": "INDUCTION"},
            ],
        },
        {
            "label": "S4: LOT1 -> LOT2 (CAR-T LOT)",
            "desc": "CAR-T d220; agents within 45d are consolidated into LOT2",
            "segments": [
                {"start_day": 0,   "end_day": 219, "kind": "LOT1"},
                {"start_day": 220, "end_day": 220, "kind": "EVENT_CART"},
                {"start_day": 220, "end_day": 540, "kind": "LOT2"},
                {"start_day": 220, "end_day": 264, "kind": "INDUCTION"},  # 45d consolidation window
            ],
        },
        {
            "label": "S5: LOT2 -> LOT3 by DISCONTINUATION + new agent",
            "desc": "LOT2 runs out d260; new agent d460 -> LOT3",
            "segments": [
                {"start_day": 0,   "end_day": 199, "kind": "LOT1"},
                {"start_day": 200, "end_day": 260, "kind": "LOT2"},
                {"start_day": 200, "end_day": 228, "kind": "INDUCTION"},
                {"start_day": 460, "end_day": 540, "kind": "LOT3"},
                {"start_day": 460, "end_day": 488, "kind": "INDUCTION"},
            ],
        },
        {
            "label": "S6: LOT3 ends by DEATH",
            "desc": "Death d420 closes LOT3; no LOT4",
            "segments": [
                {"start_day": 0,   "end_day": 199, "kind": "LOT1"},
                {"start_day": 200, "end_day": 339, "kind": "LOT2"},
                {"start_day": 340, "end_day": 419, "kind": "LOT3"},
                {"start_day": 420, "end_day": 420, "kind": "EVENT_DEATH"},
            ],
        },
        {
            "label": "S7: Tandem AUTO during LOT2 (NO new LOT)",
            "desc": "AUTO d250 then AUTO d340 (90d apart, planned tandem) - LOT2 continues",
            "segments": [
                {"start_day": 0,   "end_day": 199, "kind": "LOT1"},
                {"start_day": 200, "end_day": 540, "kind": "LOT2"},
                {"start_day": 200, "end_day": 228, "kind": "INDUCTION"},
                {"start_day": 250, "end_day": 250, "kind": "EVENT_SCT_AUTO"},
                {"start_day": 340, "end_day": 340, "kind": "EVENT_SCT_AUTO"},
            ],
        },
    ]

    row = axis_row + 1
    for sc in scenarios:
        # Label cells
        a = ws.cell(row=row, column=1, value=sc["label"])
        a.font = BOLD
        a.alignment = WRAP
        a.fill = SECTION_FILL
        a.border = BORDER
        b = ws.cell(row=row, column=2, value=sc["desc"])
        b.font = NORMAL
        b.alignment = WRAP
        b.fill = SECTION_FILL
        b.border = BORDER
        ws.cell(row=row, column=3, value="").border = BORDER

        # Initialize axis cells with thin border
        for i in range(N_BUCKETS):
            cell = ws.cell(row=row, column=AXIS_START_COL + i, value="")
            cell.border = BORDER

        # Paint segments in two passes: LOT/INDUCTION (background), then EVENTs (overlay)
        bg_segments = [s for s in sc["segments"] if not s["kind"].startswith("EVENT_")]
        ev_segments = [s for s in sc["segments"] if s["kind"].startswith("EVENT_")]

        for seg in bg_segments:
            start_b = seg["start_day"] // BUCKET
            end_b = max(seg["start_day"] // BUCKET, seg["end_day"] // BUCKET)
            for b_idx in range(start_b, min(end_b + 1, N_BUCKETS)):
                c = ws.cell(row=row, column=AXIS_START_COL + b_idx)
                # Don't overwrite INDUCTION on top of LOT - layer: LOT first, then INDUCTION uses pattern
                if seg["kind"] == "INDUCTION" and c.fill.fgColor.rgb and c.fill.fgColor.rgb != "00000000":
                    # leave LOT background; mark induction via a top border accent
                    c.border = Border(left=THIN, right=THIN, bottom=THIN,
                                      top=Side(style="medium", color=LOT_COLORS["INDUCTION"]))
                else:
                    c.fill = PatternFill("solid", fgColor=LOT_COLORS[seg["kind"]])

        for ev in ev_segments:
            b_idx = ev["start_day"] // BUCKET
            if 0 <= b_idx < N_BUCKETS:
                c = ws.cell(row=row, column=AXIS_START_COL + b_idx)
                c.fill = PatternFill("solid", fgColor=LOT_COLORS[ev["kind"]])
                marker = {
                    "EVENT_SCT_AUTO": "A", "EVENT_SCT_ALLO": "X",
                    "EVENT_CART": "C", "EVENT_DEATH": "+", "EVENT_MED_ADD": "M",
                }[ev["kind"]]
                c.value = marker
                c.font = Font(name="Calibri", size=8, bold=True,
                              color="FFFFFF" if ev["kind"] in ("EVENT_SCT_ALLO", "EVENT_CART", "EVENT_DEATH") else "000000")
                c.alignment = Alignment(horizontal="center", vertical="center")

        ws.row_dimensions[row].height = 30
        row += 1

    # Column widths
    ws.column_dimensions["A"].width = 40
    ws.column_dimensions["B"].width = 50
    ws.column_dimensions["C"].width = 4
    for i in range(N_BUCKETS):
        ws.column_dimensions[get_column_letter(AXIS_START_COL + i)].width = 3.2

    # Footnote
    foot_row = row + 1
    ws.cell(row=foot_row, column=1,
            value="Each cell = ~14 days. Markers: M=Med add, A=AUTO SCT, X=ALLO SCT, C=CAR-T, +=Death. "
                  "Yellow top edge = induction window overlay. Single-cell-only LOT = singleton ALLO LOT (Q2 resolved: ALLO LOT spans a single day).").font = NORMAL
    ws.cell(row=foot_row, column=1).alignment = WRAP
    ws.merge_cells(start_row=foot_row, start_column=1, end_row=foot_row, end_column=AXIS_START_COL + N_BUCKETS - 1)


def build_decision_flow(wb):
    """Text-based decision tree explaining when LOT(N+1) starts."""
    name = "9.Decision_Flow"
    if name in wb.sheetnames:
        del wb[name]
    ws = wb.create_sheet(name)

    ws["A1"] = "Decision flow: when does LOT(N+1) start?"
    ws["A1"].font = Font(name="Calibri", size=14, bold=True, color="1F4E78")
    ws.merge_cells("A1:E1")
    ws.row_dimensions[1].height = 22

    ws["A2"] = ("Date-driven, NOT type-driven. Step 1: collect candidate dates. Step 2: pick earliest. Step 3: tie-break by type only if multiple triggers fall on that same date.")
    ws["A2"].font = NORMAL
    ws["A2"].alignment = WRAP
    ws.merge_cells("A2:E2")
    ws.row_dimensions[2].height = 36

    headers = ["Step", "Action", "Detail", "Output", "Notes"]
    for j, h in enumerate(headers, 1):
        c = ws.cell(row=4, column=j, value=h)
    style_header(ws, 4, len(headers))

    flow = [
        ("1",
         "Collect candidate trigger dates AFTER LOT_N_BASE_END_DT.",
         "Compute, for each trigger type, the earliest qualifying date (if any):\n"
         "  d_MED   = first non-steroid MM agent MAP_START_DT (excl. permissible biosimilar subs)\n"
         "  d_ALLO  = first ALLO SCT date\n"
         "  d_CART  = first CAR-T infusion date (FIRST_CART_DT)\n"
         "  d_AUTO  = first AUTO date (Q16, 06-May): triggers LOT_(N+1) unless "
         "(i) it falls inside LOT_N's applicable window from LOT_N_START_DT "
         "(30d for MED/AUTO-started LOTs, 1d for ALLO-started, 45d for CART-started) "
         "or (ii) it is on/before sct_tandem_days (180d) after the immediately prior AUTO (planned tandem). "
         "First-ever AUTOs CAN trigger a new LOT (LOT2-5 only; LOT1 retains the protocol "
         "convention that the first AUTO is part of induction).",
         "Up to 4 candidate dates",
         "AUTO events are already grouped upstream in tx_auto_dates (14-day window + 60-day event-separation rule). "
         "Among derived AUTO events, a second AUTO within 180 days of the first is a planned tandem (CONTINUATION, not a candidate)."),
        ("2",
         "Pick the earliest candidate date.",
         "LOT_(N+1)_START_DT = min(d_MED, d_ALLO, d_CART, d_AUTO).",
         "LOT_(N+1)_START_DT",
         "An earlier MED beats a later ALLO/CART/AUTO."),
        ("3",
         "If exactly one candidate equals that earliest date, set its type.",
         "LOTN+1_START_TYPE = the type of the unique earliest candidate.",
         "LOTN+1_START_TYPE",
         ""),
        ("3a",
         "Same-day tie-break (Q14 resolved, inherits LOT1).",
         "If multiple triggers share LOT_(N+1)_START_DT: SCT_ALLO > CART > SCT_AUTO > MED.",
         "LOTN+1_START_TYPE",
         "Tie-breaks ONLY on identical dates - never overrides date order."),
        ("4",
         "If no candidate dates exist, evaluate end-of-follow-up.",
         "If DEATH (YMDOD) or STUDY_END is reached, no LOT_(N+1).",
         "No LOT_(N+1)",
         "PRIMARY analysis closes here. Disenrollment is NOT a primary closure."),
        ("5 (SENSITIVITY)",
         "If CENSOR_AT_DISENROLLMENT = TRUE, additionally cap observation at ELIGEND.",
         "LOTN_BASE_END_DT_CE_SENS = min(LOTN_BASE_END_DT, ELIGEND); reason = DISENROLLMENT when ELIGEND binds.",
         "Sensitivity outputs only",
         "Does not affect LOT_(N+1) start. See Q12."),
    ]
    for i, row in enumerate(flow):
        r = 5 + i
        for j, val in enumerate(row, 1):
            c = ws.cell(row=r, column=j, value=val)
            c.alignment = WRAP
            c.font = NORMAL
            c.border = BORDER
            if j == 1:
                c.font = BOLD
                c.fill = SECTION_FILL
        ws.row_dimensions[r].height = 60

    for col, w in enumerate([8, 50, 50, 18, 50], 1):
        ws.column_dimensions[get_column_letter(col)].width = w

    # Footer note - clearly labelled as END-REASON priority (separate from start-trigger priority in Step 3a)
    note_row = 5 + len(flow) + 1
    ws.cell(row=note_row, column=1,
            value="END-REASON priority (separate from LOT-start tie-break in Step 3a; revised per Julia 06-May): "
                  "SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DEATH > DISCONTINUATION > STUDY_END. "
                  "DEATH outranks DISCONTINUATION so patients who run out then die keep REASON = DEATH. "
                  "SENSITIVITY adds DISENROLLMENT before STUDY_END. See LOTN_BASE_END_REASON in tab 4.").font = BOLD
    ws.cell(row=note_row, column=1).alignment = WRAP
    ws.cell(row=note_row, column=1).fill = NOTE_FILL
    ws.merge_cells(start_row=note_row, start_column=1, end_row=note_row, end_column=5)
    ws.row_dimensions[note_row].height = 50


if __name__ == "__main__":
    chunk = os.environ.get("CHUNK", "all")
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
    if chunk in ("timelines", "all"):
        build_timelines(wb)
    if chunk in ("decision_flow", "all"):
        build_decision_flow(wb)
    save(wb)
