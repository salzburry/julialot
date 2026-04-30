"""Build draft LOT2-5 spec workbook in chunks.

Run with optional CHUNK env var: cover, qc, base, base_end, sct_cart, scenarios, open_q, all (default)
"""
import os
from pathlib import Path
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.utils import get_column_letter

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT = str(REPO_ROOT / "Apr 18 2026" / "Program Spec and Scenarios" / "lot2to5_spec_DRAFT_apr30.xlsx")

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
        ("8.Timelines", "Gantt-style patient journey examples (visual)"),
        ("9.Decision_Flow", "Decision tree for when LOT(N+1) starts"),
        ("", ""),
        ("Key differences vs LOT1", ""),
        ("Induction window", "30 days (vs 60 days for LOT1)"),
        ("LOT start trigger", "First MM oncology agent OR ALLO SCT OR CAR-T event (vs LOT1 = first MM agent only)"),
        ("Numbering", "LOT_NUM increments 2..5; same algorithmic rules otherwise"),
        ("Maintenance", "Follows current LOT1 CODE behaviour (descriptive contains_mtx_reg flag; no standalone maintenance LOT). "
                          "Diverges from the protocol Rule 8 wording. Open Q5."),
        ("Permissible subs", "Same as LOT1 - do not advance LOT"),
        ("Steroids", "Excluded from regimen identification (per LOT1 protocol Section 5.1.1)"),
        ("CAR-T consolidation", "45 days (per Apr 22 study-team decision; supersedes 30-day older protocol text). Resolved Q11."),
        ("Disenrollment", "PRIMARY analysis: ignored. SENSITIVITY (CENSOR_AT_DISENROLLMENT=TRUE) caps via ENDDATE_CE and emits DISENROLLMENT reason. Resolved Q12."),
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
         "LOTN_START_DT is the EARLIEST of any of the following competing triggers occurring after LOT_(N-1)_BASE_END_DT: "
         "(a) first MM oncology agent (non-steroid) administered/dispensed; "
         "(b) first UNPLANNED autologous SCT (AUTO) - i.e., an AUTO occurring >180 days after a prior AUTO in LOT_(N-1). "
         "Planned, single, or tandem AUTO SCTs (60-180 day intervals) are continuations of the same LOT and do NOT trigger a new LOT; "
         "(c) first allogeneic SCT (ALLO) - ALLO always starts a new LOT; "
         "(d) first CAR-T infusion - CAR-T is classified as its own LOT. "
         "When LOT_(N-1) ended due to SCT_ALLO / SCT_CART / SCT_AUTO unplanned / CART_INIT, LOTN_START_DT equals the SCT or CAR-T event date itself "
         "(LOT_(N-1) ended the day before that event).",
         "CL_MMA_CODELIST (Tab 41), CL_SCT_CODELIST (Tab 44), CL_MMA_ROLLUP (Tab 40)",
         "Source: T_MEDICAL (PROC_CD, BILL_PROC_CD, NDC), T_RX (NDC), T_MEDICAL procedure codes for SCT/CAR-T. "
         "Steroids excluded from medication-trigger candidates (MAP_MED_CLASS != 'STEROID'). "
         "Permissible biosimilar substitutions do NOT trigger a new LOT.",
         ""),
        ("FU_PD", "LOTN_START_TYPE", "Type of LOT N start event",
         "MED / SCT_AUTO / SCT_ALLO / CART",
         "Indicates which trigger started LOT N: a new MM medication, an unplanned autologous SCT, an allogeneic SCT, or a CAR-T infusion. "
         "All four are first-class competing triggers - whichever is earliest defines LOTN_START_DT and LOTN_START_TYPE.",
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
        ("FU_PD", "LOTN_MED_[MED]", "Per-medication induction flags (one column per MED_ABBR)",
         "0 / 1",
         "For each distinct medication abbreviation in CL_MMA_ROLLUP (Tab 40), emit a flag column LOTN_MED_BORT, LOTN_MED_LENA, LOTN_MED_DARA, "
         "LOTN_MED_CARF, LOTN_MED_IXAZ, LOTN_MED_THAL, LOTN_MED_POMA, LOTN_MED_CYCL, LOTN_MED_MELP, LOTN_MED_BEND, LOTN_MED_IDEC, LOTN_MED_CILT, "
         "LOTN_MED_BELA, LOTN_MED_ISAT, LOTN_MED_ELOT, LOTN_MED_ETOP, LOTN_MED_PANO, LOTN_MED_SELI, LOTN_MED_TECL, LOTN_MED_DOPL, LOTN_MED_DOXO, "
         "LOTN_MED_CISP, LOTN_MED_ELRA, LOTN_MED_LINV, LOTN_MED_TALQ, LOTN_MED_VENE, etc. = 1 if that medication is part of LOTN_BASE_MEDS.",
         "CL_MMA_ROLLUP (Tab 40), CL_MMA_CODELIST (Tab 41)",
         "Mirror LOT1 dynamic flag generation. Steroid abbreviations (DEXA, PRED) excluded since regimen excludes steroids.",
         ""),
        ("FU_PD", "LOTN_CLASS_[CLASS]", "Per-class induction flags (one column per MED_CLASS)",
         "0 / 1",
         "For each MED_CLASS in CL_MMA_ROLLUP, emit a flag column: LOTN_CLASS_PROTINHIB, LOTN_CLASS_IMMUNOMOD, LOTN_CLASS_ANTICD38, "
         "LOTN_CLASS_BCMA, LOTN_CLASS_MUSTARD, LOTN_CLASS_SIGNALING, LOTN_CLASS_TOPOISOMERASE, LOTN_CLASS_HDACINHIBITOR, LOTN_CLASS_XPORTINHIBITOR, "
         "LOTN_CLASS_ANTHRACYCLINE, LOTN_CLASS_PLATINUM, LOTN_CLASS_CELMOD, LOTN_CLASS_BCL2INHIBITOR. = 1 if any agent of that class is in LOTN_BASE_MEDS.",
         "CL_MMA_ROLLUP MED_CLASS",
         "Mirror LOT1 dynamic class flag generation. STEROID class excluded.",
         ""),
        # SCT-as-start-of-LOT inheritance flags
        ("FU_PD", "LOTN_TX_AUTO_FLG", "Flag: any valid AUTO SCT during LOT N",
         "0/1",
         "Binary flag indicating the patient received any valid autologous SCT during LOT N (single or tandem).",
         "CL_SCT_CODELIST (SCT_TYPE='AUTO')",
         "Same logic as LOT1: 14-day windowing of T_MEDICAL procedure code dates; 60-day gap validation between distinct events.",
         ""),
        ("FU_PD", "LOTN_TX_AUTO_SING_FLG", "Flag: single valid AUTO SCT during LOT N",
         "0/1",
         "Single AUTO not part of a valid tandem pair within LOT N.",
         "CL_SCT_CODELIST", "Inherits LOT1 SCT logic.", ""),
        ("FU_PD", "LOTN_TX_AUTO_TAND_FLG", "Flag: planned tandem AUTO SCT during LOT N",
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
         "Set 1 when LOTN_START_TYPE='CART'. CAR-T is its own LOT; oncology agents (incl. supportive, e.g., corticosteroids) "
         "given within 45 days of CAR-T are CONSOLIDATED into the CAR-T LOT and not treated as new induction. "
         "PROVENANCE: 45-day consolidation per Apr 22 study-team decision (supersedes 30-day older protocol text); see Q11.",
         "CL_SCT_CODELIST (SCT_TYPE='CART')",
         "Within 45-day consolidation window, do NOT advance to LOT_(N+1). Use FIRST_CART_DT as LOTN_START_DT.",
         ""),
    ]
    write_rows(ws, 2, rows, col_widths=[10, 30, 32, 22, 70, 30, 60, 18])
    ws.row_dimensions[1].height = 36

    # ----- Worked examples appendix -----
    next_row = 2 + len(rows) + 2  # gap row
    ncols = 8

    # Example A: medication-triggered LOT2
    ex_a_narrative = (
        "Example A - LOT2 starts on a NEW MEDICATION (most common case).\n"
        "Patient was on VRd (bortezomib + lenalidomide + dexamethasone) for LOT1. LOT1 ended on 2025-08-19 with reason MED_ADD because daratumumab "
        "was added on 2025-08-20. The patient receives DARA on 2025-08-20 and lenalidomide refills appear within 30 days. No SCT or CAR-T occurs."
    )
    ex_a_table = [
        ("LOT_NUM", "2", "Sequential index after LOT1."),
        ("LOTN_START_DT", "2025-08-20", "Earliest competing trigger after LOT1_BASE_END_DT (2025-08-19) is the new MM agent DARA on 2025-08-20."),
        ("LOTN_START_TYPE", "MED", "Trigger was a new medication (no SCT/CAR-T present)."),
        ("INDUCTION_WINDOW_DAYS", "30", "LOT2 uses the 30-day induction window (vs 60 for LOT1)."),
        ("LOTN_BASE_MEDS", "DARA, LENA", "Within [2025-08-20, 2025-09-18]: DARA (start) and LENA refills. DEXA excluded (steroid)."),
        ("LOTN_MED_CNT", "2", "Two distinct non-steroid agents."),
        ("LOTN_MED_DARA", "1", "DARA present in LOTN_BASE_MEDS."),
        ("LOTN_MED_LENA", "1", "LENA present in LOTN_BASE_MEDS."),
        ("LOTN_CLASS_ANTICD38", "1", "DARA is class ANTICD38."),
        ("LOTN_CLASS_IMMUNOMOD", "1", "LENA is class IMMUNOMOD."),
        ("contains_mtx_reg_LOTN", "1", "LENA is a valid mono-maintenance agent (a); DARA is the non-maintenance anchor (b)."),
        ("LOTN_ALLO_LOT_FLG / LOTN_CART_LOT_FLG", "0 / 0", "No ALLO or CAR-T trigger."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE A - LOT2 starts on a new medication",
                                   ex_a_narrative, ex_a_table, ncols) + 2

    # Example B: ALLO-started LOT
    ex_b_narrative = (
        "Example B - LOT2 starts on an ALLOGENEIC SCT.\n"
        "Patient on VRd in LOT1 receives an allogeneic SCT on 2025-09-15. Per protocol, ALLO is its own LOT with no other MM therapies. "
        "LOT1 ends 2025-09-14 (day before ALLO). Next MM therapy after the ALLO date is daratumumab on 2025-12-10, which starts LOT3."
    )
    ex_b_table = [
        ("LOT_NUM", "2", ""),
        ("LOTN_START_DT", "2025-09-15", "ALLO_DT (always starts a new LOT)."),
        ("LOTN_START_TYPE", "SCT_ALLO", ""),
        ("LOTN_BASE_MEDS", "(empty)", "ALLO LOT contains NO MM therapies."),
        ("LOTN_MED_CNT", "0", ""),
        ("LOTN_ALLO_LOT_FLG", "1", "Trigger type is SCT_ALLO."),
        ("LOTN_BASE_END_DT (draft)", "2025-09-15", "Draft Q2 assumption: single-day LOT (start = end = ALLO_DT). Next agent (DARA on 2025-12-10) opens LOT3."),
        ("LOTN_BASE_END_REASON", "MED_ADD", "DARA on 2025-12-10 is the next event; LOT2 ends the day before LOT3 starts. (Pending Q2.)"),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE B - LOT2 starts on an allogeneic SCT",
                                   ex_b_narrative, ex_b_table, ncols) + 2

    # Example C: unplanned AUTO triggers LOT2
    ex_c_narrative = (
        "Example C - LOT2 starts on an UNPLANNED autologous SCT.\n"
        "Patient had a single AUTO during LOT1 on 2025-03-01. A second AUTO occurs on 2025-10-15 - 228 days later, which is >180 days, so it is unplanned. "
        "The unplanned AUTO ends LOT1 (2025-10-14) and starts LOT2 on the AUTO date itself."
    )
    ex_c_table = [
        ("LOT_NUM", "2", ""),
        ("LOTN_START_DT", "2025-10-15", "Unplanned AUTO date (>180d after prior AUTO)."),
        ("LOTN_START_TYPE", "SCT_AUTO", "Unplanned AUTO is a first-class LOT-start trigger. (Planned tandem 60-180d would NOT start a new LOT.)"),
        ("INDUCTION_WINDOW_DAYS", "30", "LOT2 captures any post-AUTO agents within [2025-10-15, 2025-11-13]."),
        ("LOTN_TX_AUTO_FLG", "1", "AUTO occurred during LOT2."),
        ("LOTN_TX_AUTO_SING_FLG", "1", "Single AUTO during LOT2 (no second AUTO within tandem window)."),
        ("LOTN_TX_AUTO_TAND_FLG", "0", ""),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE C - LOT2 starts on an unplanned autologous SCT",
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
        ("FU_PD", "LOTN_END_DT_TEMP", "Temporary end date for LOT N base period",
         "Date",
         "PRIMARY analysis - LOT N continues until the earliest of: "
         "(1) Discontinuation of all agents in the regimen (with or without switch to a new agent) - end date is the run-out date "
         "(last MAP_END_DT among induction agents); "
         "(2) Addition of a qualifying new MM oncology agent not in the LOT N induction regimen and not a permissible biosimilar substitute "
         "- end date is the day before the new agent's MAP_START_DT; "
         "(3) SCT/CAR-T events: any ALLO SCT ends the LOT the day before the ALLO; an AUTO SCT >180 days after a previous AUTO ends LOT "
         "the day before; CAR-T infusion ends the LOT the day before FIRST_CART_DT; "
         "(4) Death (T_DOD.YMDOD); "
         "(5) End of the study period (study_end config). "
         "Health plan disenrollment is NOT a primary LOT-ending event. "
         "SENSITIVITY analysis - when CENSOR_AT_DISENROLLMENT = TRUE, LOT N observation end is additionally capped at ENDDATE_CE "
         "(see LOTN_END_REASON_CE_SENS below).",
         "T_MEDICAL/T_RX (MAP_END_DT, MAP_START_DT), T_MEDICAL procedure codes (SCT/CAR-T), T_DOD (YMDOD), study_end config; "
         "SENSITIVITY only: T_MEMBER_CONT_ENROLLMENT (ELIGEND -> ENDDATE_CE)",
         "Primary path mirrors current LOT1 implementation: ignores disenrollment. Same priority logic as LOT1; only the induction window differs.",
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
        ("FU_PD", "CART_CONSOLIDATION_DAYS", "CAR-T consolidation window (days)",
         "45",
         "Oncology therapies (including supportive agents like steroids) given within 45 days of FIRST_CART_DT are consolidated into the CAR-T LOT. "
         "PROVENANCE: per Apr 22, 2026 study-team decision, the CAR-T consolidation window is 45 days. "
         "This supersedes the earlier 30-day language in the protocol extract; treat 45 as the operative value for LOT2-5 (matches LOT1 CART_INIT).",
         "CL_SCT_CODELIST (SCT_TYPE='CART')",
         "Reclassify therapies within 45-day window into the CAR-T LOT; do NOT trigger LOT_(N+1) for those agents.",
         ""),
        ("FU_PD", "LOTN_BASE_END_DT", "Final LOT N base period end date",
         "Date",
         "Earliest of all qualifying end events. For ALLO/CAR-T-started LOTs (LOTN_START_TYPE in ('SCT_ALLO','CART')), "
         "see special handling in Open_Questions tab Q2.",
         "All sources above",
         "Priority logic same as LOT1.",
         ""),
        ("FU_PD", "LOTN_BASE_END_REASON", "Final LOT N base end reason (PRIMARY analysis)",
         "SCT_ALLO / SCT_CART / SCT_AUTO / CART_INIT / MED_ADD / DISCONTINUATION / DEATH / STUDY_END",
         "Final reason for the PRIMARY analysis. Priority when ties on the same day: "
         "SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > STUDY_END. "
         "DISENROLLMENT is NOT a primary end reason - it appears only in the sensitivity output (LOTN_BASE_END_REASON_CE_SENS).",
         "All sources above (excluding T_MEMBER_CONT_ENROLLMENT for primary)",
         "Same priority order as LOT1. CART_INIT applies when CAR-T occurs within 45 days of a first added agent during LOT N.",
         ""),
        ("FU_PD", "LOTN_BASE_END_DT_CE_SENS", "LOT N base end date - sensitivity (censor at disenrollment)",
         "Date",
         "Sensitivity-analysis end date computed identically to LOTN_BASE_END_DT but additionally capped at ENDDATE_CE = "
         "min(YMDOD, ELIGEND, study_end). Only emitted when CENSOR_AT_DISENROLLMENT = TRUE.",
         "T_MEMBER_CONT_ENROLLMENT (ELIGEND), T_DOD, study_end config",
         "Sensitivity flag-gated; primary LOTN_BASE_END_DT remains untouched.",
         ""),
        ("FU_PD", "LOTN_BASE_END_REASON_CE_SENS", "LOT N base end reason - sensitivity",
         "SCT_ALLO / SCT_CART / SCT_AUTO / CART_INIT / MED_ADD / DISCONTINUATION / DEATH / DISENROLLMENT / STUDY_END",
         "Final reason for the sensitivity analysis. DISENROLLMENT is emitted when ELIGEND is the binding earliest cap. "
         "Priority order extends the primary list: SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END.",
         "All sources above plus T_MEMBER_CONT_ENROLLMENT (ELIGEND)",
         "REQUIRED behaviour: when sensitivity ENDDATE_CE binds because of disenrollment (ELIGEND earliest), label the reason DISENROLLMENT (do NOT collapse to STUDY_END). "
         "This is a deliberate divergence from the current LOT1 implementation, which labels the cap as STUDY_END; LOT2-5 should emit DISENROLLMENT for analytic clarity.",
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

    # ----- Worked examples appendix -----
    next_row = 2 + len(rows) + 2
    ncols = 8

    # Example D: end-reason resolution (priority logic)
    ex_d_narrative = (
        "Example D - END-REASON RESOLUTION (priority logic).\n"
        "LOT3 started 2025-11-01 with KRd. The patient has multiple competing end events:\n"
        "  - Run-out date of induction agents (DISCONTINUATION candidate): 2026-04-15\n"
        "  - First add med (POMA) on 2026-03-20 -> LOT3 would end 2026-03-19 (MED_ADD)\n"
        "  - CAR-T infusion on 2026-04-02 (within 45 days of POMA)  -> CART_INIT applies\n"
        "  - Death (YMDOD) on 2026-05-20\n"
        "Apply priority: SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > STUDY_END."
    )
    ex_d_table = [
        ("LOTN_BASE_END_DT", "2026-04-01", "FIRST_CART_DT (2026-04-02) - 1. CART_INIT outranks MED_ADD because CAR-T occurred within 45d of the first add."),
        ("LOTN_BASE_END_REASON", "CART_INIT", "Highest-priority qualifying reason among competing events."),
        ("LOTN_BASE_LENGTH", "152", "2026-04-01 minus 2025-11-01 + 1 = 152 days."),
        ("LOT_(N+1)_START_DT", "2026-04-02", "FIRST_CART_DT becomes LOT4 start; LOT4_START_TYPE = CART."),
        ("LOTN_BASE_END_DT_CE_SENS", "2026-04-01", "Same as primary - no disenrollment cap binds earlier."),
        ("LOTN_BASE_END_REASON_CE_SENS", "CART_INIT", ""),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE D - End-reason priority with CART_INIT",
                                   ex_d_narrative, ex_d_table, ncols) + 2

    # Example E: discontinuation
    ex_e_narrative = (
        "Example E - DISCONTINUATION (regimen runs out, no new agent within gap).\n"
        "LOT2 started 2025-08-20 with DARA + LENA. Last LENA fill (28-day supply) is 2026-01-10, MAP_END_DT = 2026-02-06. "
        "Last DARA infusion MAP_END_DT = 2026-01-15. No new MM agent appears in the next 90 days. Patient is alive and enrolled."
    )
    ex_e_table = [
        ("LOTN_BASE_DISCON_DT", "2026-02-06", "max(MAP_END_DT) across LOT2 induction agents (the later LENA run-out)."),
        ("LOTN_BASE_END_DT", "2026-02-06", "DISCONTINUATION uses the run-out date itself."),
        ("LOTN_BASE_END_REASON", "DISCONTINUATION", "All agents reached run-out and no new agent within 90-day gap."),
        ("LOTN_BASE_LENGTH", "171", "2026-02-06 minus 2025-08-20 + 1."),
        ("Next LOT?", "Only if a new MM agent eventually appears", "If no further therapy, study/death/sensitivity will eventually close follow-up."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE E - Discontinuation (run-out)",
                                   ex_e_narrative, ex_e_table, ncols) + 2

    # Example F: disenrollment - primary vs sensitivity
    ex_f_narrative = (
        "Example F - DISENROLLMENT: primary analysis vs sensitivity analysis.\n"
        "LOT4 started 2026-01-05. Patient disenrolls (ELIGEND) on 2026-04-30 with no death and no further therapy. "
        "study_end is 2026-12-31. This shows how the same patient produces different LOT4 closures under primary vs sensitivity."
    )
    ex_f_table = [
        ("LOTN_BASE_END_DT (PRIMARY)", "2026-12-31", "Disenrollment is IGNORED in primary; earliest of {death, study_end} = study_end."),
        ("LOTN_BASE_END_REASON (PRIMARY)", "STUDY_END", "Primary analysis cannot use DISENROLLMENT."),
        ("LOTN_BASE_END_DT_CE_SENS (SENSITIVITY)", "2026-04-30", "ENDDATE_CE = min(YMDOD, ELIGEND, study_end) = ELIGEND."),
        ("LOTN_BASE_END_REASON_CE_SENS (SENSITIVITY)", "DISENROLLMENT", "Spec requires labelling DISENROLLMENT (do NOT collapse to STUDY_END)."),
        ("LOTN_BASE_LENGTH (PRIMARY)", "361", "2026-12-31 minus 2026-01-05 + 1."),
        ("LOTN_BASE_LENGTH_CE_SENS", "116", "2026-04-30 minus 2026-01-05 + 1."),
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
        ("Allogeneic SCT (ALLO)",
         "Always - any ALLO ends the current LOT and starts a new ALLO LOT.",
         "ALLO_DT",
         "ALLO LOT contains NO MM therapies (per protocol). Subsequent MM therapy starts LOT_(N+1).",
         "SCT_ALLO",
         "Open question Q2: should this LOT be a single-day record (start=end=ALLO_DT) or extend until the next agent?"),
        ("CAR-T infusion",
         "Always - CAR-T is its own LOT.",
         "FIRST_CART_DT",
         "Includes all oncology therapies (and supportive agents like steroids) within 45 days post-CAR-T (consolidation per Apr 22 decision).",
         "SCT_CART (or CART_INIT if CAR-T within 45d of a first-add agent in LOT_(N-1))",
         "Use 45-day consolidation window per Apr 22 study-team decision (supersedes 30-day protocol text)."),
        ("Autologous SCT (AUTO) - unplanned",
         "AUTO occurs >180 days after a previous AUTO in the same line. Competes as a first-class LOT-start trigger alongside MED, ALLO, CAR-T - whichever is earliest wins.",
         "AUTO_DT (the latter, unplanned AUTO)",
         "Induction window 30 days from AUTO_DT.",
         "SCT_AUTO",
         "If within 60-180 days of prior AUTO, it is planned tandem and stays in the same LOT - does not start LOT_(N+1)."),
        ("New MM oncology agent",
         "After LOT_(N-1) ends by DISCONTINUATION/MED_ADD with no SCT/CAR-T trigger.",
         "MAP_START_DT of the first such agent post LOT_(N-1)_BASE_END_DT",
         "30-day induction window from LOTN_START_DT.",
         "n/a (this is the start of LOT N, not the end of LOT_(N-1))",
         "Steroids alone do not start a LOT. Permissible biosimilar substitutes do not start a LOT."),
        ("Death / study end (PRIMARY)",
         "Never - these end follow-up; no LOT_(N+1).",
         "n/a", "n/a",
         "DEATH / STUDY_END",
         "LOT_(N-1) ends; no new LOT begins. Disenrollment is NOT a primary end event."),
        ("Health plan disenrollment (SENSITIVITY ONLY)",
         "Never starts a new LOT. Sensitivity-only: when CENSOR_AT_DISENROLLMENT=TRUE, ELIGEND caps observation via ENDDATE_CE.",
         "n/a", "n/a",
         "DISENROLLMENT (sensitivity only; primary analysis ignores ELIGEND)",
         "PRIMARY analysis does NOT use disenrollment to end any LOT. SENSITIVITY emits LOTN_BASE_END_DT_CE_SENS / LOTN_BASE_END_REASON_CE_SENS only when the sensitivity flag is on. See Q12."),
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
        ("S6b. Disenrollment during LOT3 (primary vs sensitivity)",
         "Patient disenrolls (ELIGEND) during LOT3 with no death and no further therapy. Study end is later.",
         "PRIMARY: disenrollment is ignored. LOT3_BASE_END_REASON = STUDY_END (earliest of death/study_end), LOT3_BASE_END_DT = study_end. "
         "SENSITIVITY (CENSOR_AT_DISENROLLMENT=TRUE): LOT3_BASE_END_DT_CE_SENS = ELIGEND; LOT3_BASE_END_REASON_CE_SENS = DISENROLLMENT."),
        ("S7. Tandem AUTO during LOT2",
         "Two AUTO SCTs 90 days apart during LOT2.",
         "Both are planned tandem; LOT2 continues. LOT2_TX_AUTO_TAND_FLG = 1; LOT2_TX_AUTO_DT_1/DT_2 populated. "
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
         "Draft: NO - follows current LOT1 CODE behaviour (no standalone maintenance LOT) rather than the protocol Rule 8 wording. "
         "Use contains_mtx_reg_LOTN flag only. If the team later reverses this for LOT1, LOT2-5 should follow.",
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
        ("Q11", "CAR-T consolidation window: 45 vs 30 days.",
         "RESOLVED: 45 days. Per Apr 22 study-team decision; supersedes the 30-day language in the older protocol extract. "
         "Document as Apr 22 decision in spec, NOT 'per protocol'.",
         "Julia", "Resolved"),
        ("Q12", "Disenrollment as a LOT end event: primary vs sensitivity treatment.",
         "RESOLVED: PRIMARY analysis ignores disenrollment - LOT N ends only on regimen events, SCT/CAR-T events, death, or study_end. "
         "SENSITIVITY analysis (CENSOR_AT_DISENROLLMENT=TRUE) caps observation at ENDDATE_CE = min(YMDOD, ELIGEND, study_end) and emits "
         "DISENROLLMENT as the end reason when ELIGEND binds. Spec requires the implementation to label sensitivity reason DISENROLLMENT "
         "(not collapse to STUDY_END as current LOT1 code does).",
         "Julia", "Resolved"),
    ]
    write_rows(ws, 2, rows, col_widths=[6, 60, 70, 22, 12])
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
            "label": "S2: LOT1 -> LOT2 by unplanned AUTO",
            "desc": "Single AUTO d100; second AUTO d320 (>180d) is unplanned -> LOT2 starts d320",
            "segments": [
                {"start_day": 0,   "end_day": 319, "kind": "LOT1"},
                {"start_day": 100, "end_day": 100, "kind": "EVENT_SCT_AUTO"},
                {"start_day": 320, "end_day": 320, "kind": "EVENT_SCT_AUTO"},
                {"start_day": 320, "end_day": 540, "kind": "LOT2"},
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
                  "Yellow top edge = induction window overlay. Single-cell-only LOT = singleton ALLO LOT (Q2 draft assumption).").font = NORMAL
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

    ws["A2"] = ("Read top-to-bottom. Each event evaluates AFTER LOT_N_BASE_END_DT. The earliest qualifying trigger "
                "determines LOT_(N+1)_START_DT and LOTN+1_START_TYPE.")
    ws["A2"].font = NORMAL
    ws["A2"].alignment = WRAP
    ws.merge_cells("A2:E2")
    ws.row_dimensions[2].height = 36

    headers = ["Step", "Question", "If YES", "If NO -> next step", "Notes"]
    for j, h in enumerate(headers, 1):
        c = ws.cell(row=4, column=j, value=h)
    style_header(ws, 4, len(headers))

    flow = [
        ("1", "Is there an ALLO SCT after LOT_N ended?",
         "LOT_(N+1) starts at ALLO_DT. LOTN+1_START_TYPE = SCT_ALLO. ALLO LOT contains NO MM therapies.",
         "Step 2", "ALLO always wins ties on the same day."),
        ("2", "Is there a CAR-T infusion after LOT_N ended?",
         "LOT_(N+1) starts at FIRST_CART_DT. LOTN+1_START_TYPE = CART. Agents within 45d are consolidated (Apr 22 decision).",
         "Step 3", "CAR-T outranks AUTO and MED on tie."),
        ("3", "Is there an UNPLANNED AUTO SCT after LOT_N ended?\n(>180d after the prior AUTO in LOT_N, OR an isolated AUTO in a new line)",
         "LOT_(N+1) starts at AUTO_DT. LOTN+1_START_TYPE = SCT_AUTO.",
         "Step 4",
         "Planned/single/tandem AUTO within 60-180d of a prior AUTO is a CONTINUATION - it does NOT start a new LOT."),
        ("4", "Is there a new MM oncology agent (non-steroid, non-permissible-substitute) after LOT_N ended?",
         "LOT_(N+1) starts at MAP_START_DT of that agent. LOTN+1_START_TYPE = MED.",
         "Step 5", "Steroids alone do NOT start a LOT. Biosimilar substitutions do NOT start a LOT."),
        ("5", "Has DEATH (YMDOD) or STUDY_END been reached?",
         "Follow-up ends. No LOT_(N+1).",
         "Step 6 (sensitivity)", "PRIMARY analysis closes here."),
        ("6", "SENSITIVITY ONLY: is CENSOR_AT_DISENROLLMENT = TRUE and ELIGEND earliest?",
         "Sensitivity output caps at ENDDATE_CE; LOTN_BASE_END_REASON_CE_SENS = DISENROLLMENT.",
         "End", "Primary analysis ignores ELIGEND. See Q12."),
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

    # Tie-break note
    note_row = 5 + len(flow) + 1
    ws.cell(row=note_row, column=1,
            value="Same-day tie-break priority (highest wins): SCT_ALLO > SCT_CART > SCT_AUTO (unplanned) > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > STUDY_END (PRIMARY); DISENROLLMENT slots between DEATH and STUDY_END in SENSITIVITY only.").font = BOLD
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
