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
         "Sequential index of the line of therapy after LOT1. LOT2 starts after LOT1 ends; LOT3 after LOT2; etc., up to LOT5.",
         "n/a",
         "Derived sequentially. LOT_(N+1)_START_DT must be > LOT_N_BASE_END_DT.",
         ""),
        ("FU_PD", "LOTN_START_DT", "LOT N start date (N in 2..5)",
         "Date",
         "Earliest of, after LOT_(N-1)_BASE_END_DT: "
         "(a) first non-steroid MM oncology agent; "
         "(b) first ALLO SCT; "
         "(c) first CAR-T infusion; "
         "(d) first AUTO SCT, EXCEPT (i) when it falls inside LOT_(N-1)'s applicable window "
         "(30d for MED/AUTO-started LOTs, 1d for ALLO-started LOTs, 45d for CART-started LOTs) "
         "or (ii) when it is on/before sct_tandem_days (180d) after the immediately prior AUTO (planned tandem - continuation, not a trigger). "
         "Permissible biosimilar substitutions do not trigger.",
         "CL_MMA_CODELIST, CL_SCT_CODELIST, CL_MMA_ROLLUP",
         "Source: T_MEDICAL (PROC_CD, BILL_PROC_CD, NDC), T_RX (NDC). Steroids excluded (MAP_MED_CLASS != 'STEROID'). "
         "LOT2-5 only; LOT1 retains protocol convention that first AUTO is part of induction.",
         ""),
        ("FU_PD", "LOTN_START_TYPE", "Trigger that started LOT N",
         "MED / SCT_AUTO / SCT_ALLO / CART",
         "Type of the earliest qualifying trigger.",
         "n/a",
         "Same-day tie-break (Q14 resolved, inherits LOT1): SCT_ALLO > CART > SCT_AUTO > MED.",
         ""),
        ("FU_PD", "INDUCTION_WINDOW_DAYS", "Induction window",
         "30",
         "Window for identifying LOT N regimen. (LOT1 uses 60.) "
         "If the patient is right-censored before the end of the 30-day window, the window closes at the censor date.",
         "n/a",
         "MAP_START_DT in [LOTN_START_DT, min(LOTN_START_DT + 29, OBS_END_DT)] = induction.",
         ""),
        ("FU_PD", "LOTN_BASE_MEDS", "LOT N induction medications",
         "Comma list of MED_ABBR",
         "Non-steroid MM oncology agents within the 30-day induction window. Permissible biosimilar substitutions do not advance the regimen.",
         "CL_MMA_CODELIST, CL_MMA_ROLLUP",
         "Filter MAP_MED_CLASS != 'STEROID'.",
         ""),
        ("FU_PD", "LOTN_MED_CNT", "Distinct induction agents",
         "Integer",
         "Count of distinct MED_ABBR in LOTN_BASE_MEDS.",
         "n/a", "", ""),
        ("FU_PD", "LOTN_MED_[MED]", "Per-medication induction flags",
         "0 / 1",
         "One flag column per non-steroid MED_ABBR in CL_MMA_ROLLUP (e.g. LOTN_MED_BORT, LOTN_MED_LENA, LOTN_MED_DARA, ...). "
         "= 1 if that medication is in LOTN_BASE_MEDS.",
         "CL_MMA_ROLLUP",
         "Mirror LOT1 dynamic flag generation; steroid abbreviations excluded.",
         ""),
        ("FU_PD", "LOTN_CLASS_[CLASS]", "Per-class induction flags",
         "0 / 1",
         "One flag column per non-steroid MED_CLASS in CL_MMA_ROLLUP (e.g. LOTN_CLASS_PROTINHIB, LOTN_CLASS_IMMUNOMOD, ...). "
         "= 1 if any LOTN_BASE_MEDS agent has that class.",
         "CL_MMA_ROLLUP",
         "Mirror LOT1 dynamic class flag generation.",
         ""),
        # SCT-as-start-of-LOT inheritance flags (TODO: confirm prefix LOTN_TX_ vs LOTN_SCT_ - LOT1 uses LOT1_SCT_AUTO_*FLG)
        ("FU_PD", "LOTN_TX_AUTO_FLG", "Any valid AUTO SCT during LOT N", "0/1",
         "Patient had >=1 valid AUTO during LOT N.",
         "CL_SCT_CODELIST (AUTO)",
         "Inherit LOT1 SCT logic: 14-day windowing, 60-day gap validation.", ""),
        ("FU_PD", "LOTN_TX_AUTO_SING_FLG", "Single (non-tandem) AUTO during LOT N", "0/1",
         "AUTO not part of a valid tandem pair.",
         "CL_SCT_CODELIST", "", ""),
        ("FU_PD", "LOTN_TX_AUTO_TAND_FLG", "Planned tandem AUTO during LOT N", "0/1",
         "Two AUTOs within 180 days = planned tandem.",
         "CL_SCT_CODELIST",
         "Use datediff without +1.", ""),
        ("FU_PD", "LOTN_TX_AUTO_DT_1 / LOTN_TX_AUTO_DT_2",
         "First / second valid AUTO date in LOT N", "Date / Date",
         "DT_2 populated only if planned tandem.",
         "CL_SCT_CODELIST", "", ""),
        ("FU_PD", "LOTN_TX_AUTO_MAX_DT", "Latest valid AUTO in LOT N", "Date",
         "AUTO_DT_2 if tandem else AUTO_DT_1 else NULL.",
         "CL_SCT_CODELIST", "", ""),
        ("FU_PD", "contains_mtx_reg_LOTN", "LOT N regimen contains valid maintenance subset", "0/1",
         "Flag is 1 when LOT N induction has BOTH (a) >=1 valid mono-maintenance agent OR a valid dual combo, AND (b) an anchor agent. "
         "Mono: LENA, BORT, DARA, IXAZ, THAL. Dual: BORT+LENA, CARF+LENA, DARA+LENA.",
         "CL_MMA_ROLLUP",
         "Descriptive flag; no standalone maintenance LOT.", ""),
        ("FU_PD", "LOTN_ALLO_LOT_FLG", "LOT N is an ALLO SCT line", "0/1",
         "Flag is 1 when LOTN_START_TYPE = SCT_ALLO. ALLO LOT contains no MM therapies "
         "and spans a single day: start = end = ALLO_DT. ALLO is treated as a punctuation event "
         "between LOTs; the next MM agent starts the following LOT.",
         "CL_SCT_CODELIST (ALLO)", "", ""),
        ("FU_PD", "LOTN_CART_LOT_FLG", "LOT N is a CAR-T line", "0/1",
         "Flag is 1 when LOTN_START_TYPE = CART. Agents within 45 days of FIRST_CART_DT are consolidated into LOT N (study-team decision).",
         "CL_SCT_CODELIST (CART)",
         "Do NOT advance to LOT_(N+1) for consolidated agents.", ""),
    ]
    write_rows(ws, 2, rows, col_widths=[10, 30, 32, 22, 70, 30, 60, 18])
    ws.row_dimensions[1].height = 36

    # ----- Worked examples appendix -----
    next_row = 2 + len(rows) + 2  # gap row
    ncols = 8

    # Example A: medication-triggered LOT2
    ex_a_narrative = (
        "VRd in LOT1; DARA added 2025-08-20 (LOT1 ends 2025-08-19, MED_ADD). LENA refills present within 30d. No SCT/CAR-T."
    )
    ex_a_table = [
        ("LOT_NUM", "2", ""),
        ("LOTN_START_DT", "2025-08-20", "Earliest trigger after LOT1_BASE_END_DT (2025-08-19) = DARA."),
        ("LOTN_START_TYPE", "MED", ""),
        ("LOTN_BASE_MEDS", "DARA, LENA", "Window [2025-08-20, 2025-09-18]. DEXA excluded (steroid)."),
        ("LOTN_MED_CNT", "2", ""),
        ("LOTN_MED_DARA", "1", ""),
        ("LOTN_MED_LENA", "1", ""),
        ("LOTN_CLASS_ANTICD38", "1", "DARA."),
        ("LOTN_CLASS_IMMUNOMOD", "1", "LENA."),
        ("contains_mtx_reg_LOTN", "1", "DARA + LENA is a valid dual maintenance regimen; the two agents anchor each other."),
        ("LOTN_ALLO_LOT_FLG / LOTN_CART_LOT_FLG", "0 / 0", ""),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE A - LOT2 starts on a new medication",
                                   ex_a_narrative, ex_a_table, ncols) + 2

    # Example B: ALLO-started LOT
    ex_b_narrative = (
        "VRd in LOT1; ALLO on 2025-09-15 (LOT1 ends 2025-09-14). Next MM therapy DARA on 2025-12-10 starts LOT3."
    )
    ex_b_table = [
        ("LOT_NUM", "2", ""),
        ("LOTN_START_DT", "2025-09-15", "ALLO_DT (always starts a new LOT)."),
        ("LOTN_START_TYPE", "SCT_ALLO", ""),
        ("LOTN_BASE_MEDS", "(empty)", "ALLO LOT contains NO MM therapies."),
        ("LOTN_MED_CNT", "0", ""),
        ("LOTN_ALLO_LOT_FLG", "1", ""),
        ("LOTN_BASE_END_DT", "2025-09-15", "ALLO LOT spans a single day, so end = ALLO_DT."),
        ("LOTN_BASE_END_REASON", "SCT_ALLO", ""),
        ("LOT3_START_DT", "2025-12-10", "DARA - first MM agent after LOT2."),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE B - LOT2 starts on an allogeneic SCT",
                                   ex_b_narrative, ex_b_table, ncols) + 2

    # Example C: AUTO triggers LOT3 from LOT2 (Q16: LOT2-5 only; LOT1 unchanged)
    ex_c_narrative = (
        "LOT1 ends 2025-04-30 via DISCONTINUATION (VRd run-out, no SCT during LOT1). "
        "LOT2 starts 2025-08-20 via MED_ADD (DARA + LENA, 30d induction window). "
        "First-ever AUTO occurs 2025-12-10, well outside LOT2's 30d induction window "
        "(2025-08-20 to 2025-09-18) and not within sct_tandem_days (<=180d) of any prior AUTO. "
        "Per Q16 (LOT2-5 only), this first-ever AUTO triggers LOT3 starting on the AUTO date. "
        "(LOT1 itself is unchanged - first AUTO in LOT1 would still be protocol-mandated induction.)"
    )
    ex_c_table = [
        ("LOT_NUM", "3", ""),
        ("LOTN_START_DT", "2025-12-10", "AUTO outside LOT2's 30d window (LOT2 was MED-started) and not a planned tandem."),
        ("LOTN_START_TYPE", "SCT_AUTO", "AUTO is a first-class LOT-start trigger for LOT2-5 (Q16). Planned tandem (within sct_tandem_days = 180d of a prior AUTO) would NOT start a new LOT."),
        ("LOTN_BASE_MEDS", "(empty)", "No MM therapies recorded in the [2025-12-10, 2026-01-08] post-AUTO induction window."),
        ("LOTN_MED_CNT", "0", "AUTO-only LOT; med count is 0."),
        ("INDUCTION_WINDOW_DAYS", "30", "LOT3 captures any post-AUTO agents within [2025-12-10, 2026-01-08]."),
        ("LOTN_TX_AUTO_FLG", "1", "AUTO occurred during LOT3."),
        ("LOTN_TX_AUTO_SING_FLG", "1", "Single AUTO during LOT3 (no second AUTO within tandem window)."),
        ("LOTN_TX_AUTO_TAND_FLG", "0", ""),
    ]
    next_row = write_example_block(ws, next_row, "WORKED EXAMPLE C - LOT3 starts on an AUTO (first-ever; LOT2 ended outside its induction window)",
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
         "PRIMARY: earliest of (1) all-agent discontinuation (run-out date); (2) new qualifying MM agent (day before MAP_START_DT); "
         "(3) ALLO SCT (day before); (4) AUTO that triggers a new LOT (day before), per the LOTN_START_DT trigger rule "
         "(any AUTO outside LOT N's applicable window and not within sct_tandem_days (<=180d) of a prior AUTO); "
         "(5) CAR-T (day before FIRST_CART_DT); "
         "(6) CART_INIT: when CAR-T occurs within 45 days of the first new agent that breaks LOT N, the new agent is consolidated into CART_INIT and the LOT ends at FIRST_CART_DT - 1; "
         "(7) death (YMDOD); (8) study_end. "
         "Disenrollment is NOT a primary end event. "
         "SENSITIVITY: additionally cap at ENDDATE_CE when CENSOR_AT_DISENROLLMENT = TRUE.",
         "T_MEDICAL/T_RX, T_DOD, study_end; SENSITIVITY: T_MEMBER_CONT_ENROLLMENT (ELIGEND)",
         "Primary path inherits LOT1 logic; only induction window differs.", ""),
        ("FU_PD", "LOTN_BASE_DISCON_DT", "LOT N run-out date (last med date)", "Date",
         "max(MAP_END_DT) across LOT N induction agents - i.e., the last day of supply for any drug in the regimen. "
         "Populated whenever a runout exists, INCLUDING when a higher-priority reason (DEATH, SCT, etc.) wins the LOT end. "
         "Used as LOTN_BASE_END_DT only when LOTN_BASE_END_REASON = DISCONTINUATION.",
         "CL_MMA_CODELIST",
         "T_MEDICAL: FST_DT + medical_day_supply - 1. T_RX: FILL_DT + DAYS_SUP - 1. Missing DAY_SUPPLY -> 28d default (do not delete claims). "
         "There is only ONE 90-day rule in the pipeline: the MAP-level per-drug rule (map_discon_gap_days). "
         "It says a drug is discontinued if there is no refill within 90 days. There is no additional LOT-level wait on top of that.",
         ""),
        ("FU_PD", "LOTN_BASE_1ST_ADD_MED_DT / LOTN_BASE_1ST_ADD_MED",
         "First non-induction agent during LOT N", "Date / MED_ABBR",
         "First non-steroid MM agent after the induction window with MAP_START_DT <= LOTN_BASE_DISCON_DT, not in LOTN_BASE_MEDS or its biosimilar.",
         "CL_MMA_CODELIST, permissible_subs",
         "Check permissible_subs before classifying as new add.", ""),
        ("FU_PD", "ALLO_ALWAYS_ENDS_LOT", "ALLO always ends current LOT", "TRUE",
         "Any ALLO ends current LOT day before ALLO, and starts a new ALLO LOT.",
         "CL_SCT_CODELIST (ALLO)", "", ""),
        ("FU_PD", "AUTO_TANDEM_WINDOW", "Tandem AUTO window", "<= 180 days",
         "AUTO claims are first grouped into transplant events in tx_auto_dates "
         "(14-day window grouping + 60-day event-separation rule). Among those derived AUTO events, "
         "a second AUTO within 180 days of the first is treated as planned tandem (continuation, no new LOT). "
         "Any other AUTO that falls outside LOT N's applicable window starts a new LOT.",
         "CL_SCT_CODELIST (AUTO)",
         "Per Julia 13-May: tandem classification uses ONLY the upper bound. The < 60 d case is moot "
         "because tx_auto_dates upstream already merges claims < 60 d apart into a single event. "
         "Matches LOT1's existing behaviour. Use datediff without +1.", ""),
        ("FU_PD", "CART_CONSOLIDATION_DAYS", "CAR-T consolidation window", "45",
         "Agents within 45 days of FIRST_CART_DT are consolidated into the CAR-T LOT (study-team decision).",
         "CL_SCT_CODELIST (CART)",
         "Do NOT advance to LOT_(N+1) for consolidated agents.", ""),
        ("FU_PD", "LOTN_BASE_END_DT", "Final LOT N end date (PRIMARY)", "Date",
         "Earliest qualifying end event from LOTN_END_DT_TEMP. "
         "Also: CART_INIT applies when a CAR-T infusion occurs within 45 days of the first new agent that breaks LOT N.",
         "n/a", "ALLO LOT spans a single day, start = end = ALLO_DT. CAR-T LOT spans through last consolidation MAP_END_DT.", ""),
        ("FU_PD", "LOTN_BASE_END_REASON", "Final LOT N end reason (PRIMARY)",
         "SCT_ALLO / SCT_CART / SCT_AUTO / CART_INIT / MED_ADD / DEATH / DISCONTINUATION / STUDY_END",
         "Reason corresponding to LOTN_BASE_END_DT. DISENROLLMENT only in sensitivity (see *_CE_SENS).",
         "n/a",
         "Same-day / overlapping-event priority (revised per Julia 06-May to keep DEATH above DISCONTINUATION): "
         "SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DEATH > DISCONTINUATION > STUDY_END. "
         "DEATH outranks DISCONTINUATION so patients who run out then die keep REASON = DEATH "
         "(the runout date is still recorded in LOTN_BASE_DISCON_DT). "
         "EXCEPTION (Q1.1): if a patient runs out and then starts a new LOT trigger (new MM agent, "
         "ALLO, CART, or qualifying AUTO) before death, DISCONTINUATION wins at the runout date "
         "and the new trigger starts LOT N+1 - DEATH does not silently swallow post-runout therapy.",
         ""),
        ("FU_PD", "LOTN_BASE_END_DT_CE_SENS", "LOT N end date (SENSITIVITY)", "Date",
         "Same as LOTN_BASE_END_DT, additionally capped at ELIGEND. Emitted when CENSOR_AT_DISENROLLMENT = TRUE.",
         "T_MEMBER_CONT_ENROLLMENT", "Primary LOTN_BASE_END_DT untouched.", ""),
        ("FU_PD", "LOTN_BASE_END_REASON_CE_SENS", "LOT N end reason (SENSITIVITY)",
         "(primary set) + DISENROLLMENT",
         "Same as primary, plus DISENROLLMENT when ELIGEND binds.",
         "n/a",
         "REQUIRED: emit DISENROLLMENT (do NOT collapse to STUDY_END). Diverges from current LOT1 behaviour.",
         ""),
        ("FU_PD", "LOTN_BASE_LENGTH", "LOT N duration (days)", "Integer",
         "If reason = DISCONTINUATION: LOTN_BASE_DISCON_DT - LOTN_START_DT + 1. Else: LOTN_BASE_END_DT - LOTN_START_DT + 1.",
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
        ("LOTN_BASE_DISCON_DT", "2026-02-06", "max(MAP_END_DT) across LOT2 induction agents (last med date)."),
        ("LOTN_BASE_END_DT", "2026-02-06", "Runout = LOT end. The only 90-day rule is the per-drug MAP-level one; there is no separate LOT-level wait."),
        ("LOTN_BASE_END_REASON", "DISCONTINUATION", "Runout reached; no death or higher-priority event."),
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
         "No MM therapies in this LOT.", "SCT_ALLO",
         "ALLO LOT spans a single day: start = end = ALLO_DT."),
        ("CAR-T", "Always.", "FIRST_CART_DT",
         "Agents within 45 days of FIRST_CART_DT are consolidated into this LOT.",
         "SCT_CART (or CART_INIT if CAR-T within 45 days of the first new agent that breaks LOT_(N-1))",
         "45-day consolidation window (study-team decision)."),
        ("AUTO SCT", "Always, UNLESS (i) within LOT_(N-1)'s applicable window "
         "(30d MED/AUTO, 1d ALLO, 45d CART) or (ii) within sct_tandem_days (<=180d) of a prior AUTO (planned tandem).",
         "AUTO_DT",
         "30d induction from AUTO_DT.", "SCT_AUTO",
         "First-ever AUTOs CAN trigger a new LOT (LOT2-5 only). LOT1 keeps protocol convention "
         "that the first AUTO is part of induction."),
        ("New MM agent", "Always, when the agent appears after the prior LOT's end date.",
         "MAP_START_DT of new agent", "30d induction window.", "n/a",
         "Starts a new LOT when a non-steroid, non-biosimilar MM agent appears after LOT_(N-1)_BASE_END_DT. The prior LOT's end reason does not matter."),
        ("Death / STUDY_END (PRIMARY)", "Never starts a LOT; ends follow-up.",
         "n/a", "n/a", "DEATH / STUDY_END",
         "Death and study end do not start a new LOT. If the patient runs out of regimen therapy, "
         "the LOT ends as DISCONTINUATION. If the patient starts a new MM therapy after runout, "
         "that therapy starts the next LOT. Death only becomes the end reason when no next-LOT "
         "trigger occurs first. Disenrollment is NOT a primary end event."),
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
         "LOT1 ends d199. LOT2_START_DT=d200, TYPE=MED. Induction d200-d229."),
        ("S2. LOT2->LOT3 by AUTO outside window",
         "LOT2 is MED-started (30d window). AUTO occurs d320 relative to LOT2 start, outside LOT2's window and not within sct_tandem_days (<=180d) of any prior AUTO.",
         "LOT2 ends d319. LOT3_START_DT = d320, TYPE = SCT_AUTO. Q16 applies to LOT2-5 only; LOT1's first AUTO remains part of induction."),
        ("S3. LOT1->LOT2 (ALLO LOT)->LOT3",
         "ALLO during/after LOT1, then later DARA.",
         "LOT2: start = end = ALLO_DT, single-day ALLO LOT, no MM. Next agent starts LOT3."),
        ("S4. LOT1->LOT2 (CAR-T LOT)",
         "CAR-T infusion.",
         "LOT2_START_DT=FIRST_CART_DT, TYPE=CART. Agents within 45d consolidated."),
        ("S5. LOT2->LOT3 by DISCONTINUATION",
         "Run-out, then new agent 200d later.",
         "LOT2 ends DISCONTINUATION. LOT3_START_DT = first new agent."),
        ("S6. LOT3 ends by DEATH",
         "Death during LOT3.",
         "LOT3_BASE_END_DT=YMDOD, reason=DEATH. No LOT4."),
        ("S6b. Disenrollment (primary vs sensitivity)",
         "ELIGEND during LOT3, no death, study_end later.",
         "PRIMARY: reason=STUDY_END at study_end. SENSITIVITY: *_CE_SENS at ELIGEND, reason=DISENROLLMENT."),
        ("S7. Tandem AUTO in LOT2",
         "Two AUTOs 90d apart.",
         "Planned tandem; LOT2 continues. AUTO_TAND_FLG=1."),
        ("S8. Biosimilar swap in LOT2",
         "DARA -> DARA biosimilar.",
         "LOT does not advance."),
        ("S9. ALLO LOT span",
         "ALLO with no follow-on therapy.",
         "Single-day ALLO LOT: start = end = ALLO_DT."),
        ("S10. CART_INIT carryover",
         "CAR-T within 45 days of the first new drug add that breaks LOT1.",
         "LOT1 ends with CART_INIT (LOT1 spec). LOT2_START_TYPE = CART."),
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
