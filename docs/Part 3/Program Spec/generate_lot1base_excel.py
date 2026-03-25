#!/usr/bin/env python3
"""Generate a formatted Excel file from the lot1base_validated.csv."""

import csv
import os
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

CSV_PATH = os.path.join(os.path.dirname(__file__), "lot1base_validated.csv")
XLSX_PATH = os.path.join(os.path.dirname(__file__), "lot1base_validated.xlsx")

# Read CSV
with open(CSV_PATH, "r", encoding="utf-8") as f:
    reader = csv.reader(f)
    rows = list(reader)

header = rows[0]
data_rows = rows[1:]

wb = Workbook()
ws = wb.active
ws.title = "LOT1 BASE Validated Spec"

# -- Styles --
header_font = Font(name="Calibri", bold=True, size=11, color="FFFFFF")
header_fill = PatternFill(start_color="2F5496", end_color="2F5496", fill_type="solid")
header_align = Alignment(horizontal="center", vertical="center", wrap_text=True)

section_a_fill = PatternFill(start_color="D6E4F0", end_color="D6E4F0", fill_type="solid")
section_a_gap_fill = PatternFill(start_color="FFF2CC", end_color="FFF2CC", fill_type="solid")
section_b_fill = PatternFill(start_color="E2EFDA", end_color="E2EFDA", fill_type="solid")

data_font = Font(name="Calibri", size=10)
data_align = Alignment(vertical="top", wrap_text=True)

thin_border = Border(
    left=Side(style="thin", color="B4C6E7"),
    right=Side(style="thin", color="B4C6E7"),
    top=Side(style="thin", color="B4C6E7"),
    bottom=Side(style="thin", color="B4C6E7"),
)

# Sync status colors
sync_yyy = Font(name="Calibri", size=10, color="006100")
sync_yyy_fill = PatternFill(start_color="C6EFCE", end_color="C6EFCE", fill_type="solid")
sync_partial = Font(name="Calibri", size=10, color="9C5700")
sync_partial_fill = PatternFill(start_color="FFEB9C", end_color="FFEB9C", fill_type="solid")
sync_missing = Font(name="Calibri", size=10, color="9C0006")
sync_missing_fill = PatternFill(start_color="FFC7CE", end_color="FFC7CE", fill_type="solid")

discrep_font = Font(name="Calibri", size=10, color="9C0006")

# Column widths
col_widths = {
    1: 32,   # Section
    2: 28,   # Variable Name
    3: 45,   # Label
    4: 65,   # Definition
    5: 65,   # Additional Notes
    6: 55,   # Optum CDM
    7: 65,   # R Code
    8: 18,   # Sync Status
    9: 55,   # Sync Status Notes
    10: 18,  # Date Modified
    11: 18,  # QC Reviewed
    12: 65,  # Discrepancy
}

# -- Title Row --
ws.merge_cells("A1:L1")
title_cell = ws.cell(row=1, column=1,
    value="LOT1 BASE Program Specification - Validated Against Protocol & Code")
title_cell.font = Font(name="Calibri", bold=True, size=14, color="2F5496")
title_cell.alignment = Alignment(horizontal="center", vertical="center")
ws.row_dimensions[1].height = 30

# -- Subtitle Row --
ws.merge_cells("A2:L2")
subtitle = ws.cell(row=2, column=1,
    value="Generated from lot1base_validated.csv | Protocol: LOT Algorithm (Sections 5.1, 5.1.1, 5.1.2) | "
          "Code: lot_program.R | Sync Status: Spec/Protocol/Code (Y=aligned, N=discrepancy, _=missing)")
subtitle.font = Font(name="Calibri", size=9, italic=True, color="404040")
subtitle.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
ws.row_dimensions[2].height = 25

# -- Legend Row --
ws.merge_cells("A3:L3")
legend = ws.cell(row=3, column=1,
    value="Legend: Green = All aligned (YYY) | Yellow = Partial alignment or protocol gap | "
          "Red = Discrepancy or missing from spec")
legend.font = Font(name="Calibri", size=9, italic=True, color="404040")
legend.alignment = Alignment(horizontal="center", vertical="center")
ws.row_dimensions[3].height = 20

# -- Header Row (row 4) --
HEADER_ROW = 4
for col_idx, col_name in enumerate(header, 1):
    cell = ws.cell(row=HEADER_ROW, column=col_idx, value=col_name)
    cell.font = header_font
    cell.fill = header_fill
    cell.alignment = header_align
    cell.border = thin_border
ws.row_dimensions[HEADER_ROW].height = 40

# Set column widths
for col_idx, width in col_widths.items():
    ws.column_dimensions[get_column_letter(col_idx)].width = width

# -- Data Rows --
for row_idx, row_data in enumerate(data_rows, HEADER_ROW + 1):
    section = row_data[0] if row_data else ""

    # Determine row fill
    if "Protocol Gap" in section:
        row_fill = section_a_gap_fill
    elif "Section B" in section:
        row_fill = section_b_fill
    elif "Section A" in section:
        row_fill = section_a_fill
    else:
        row_fill = None

    for col_idx, value in enumerate(row_data, 1):
        cell = ws.cell(row=row_idx, column=col_idx, value=value)
        cell.font = data_font
        cell.alignment = data_align
        cell.border = thin_border
        if row_fill:
            cell.fill = row_fill

    # Sync status coloring (column 8)
    sync_val = row_data[7] if len(row_data) > 7 else ""
    sync_cell = ws.cell(row=row_idx, column=8)
    sync_cell.alignment = Alignment(horizontal="center", vertical="top", wrap_text=True)
    if sync_val == "YYY":
        sync_cell.font = sync_yyy
        sync_cell.fill = sync_yyy_fill
    elif "_" in sync_val or sync_val == "":
        sync_cell.font = sync_missing
        sync_cell.fill = sync_missing_fill
    elif "N" in sync_val:
        sync_cell.font = sync_partial
        sync_cell.fill = sync_partial_fill

    # Discrepancy column coloring (column 12)
    discrep_val = row_data[11] if len(row_data) > 11 else ""
    if discrep_val and "no discrepancy" not in discrep_val.lower():
        discrep_cell = ws.cell(row=row_idx, column=12)
        discrep_cell.font = discrep_font

    # Row height based on content length
    max_len = max((len(str(v)) for v in row_data), default=0)
    if max_len > 500:
        ws.row_dimensions[row_idx].height = 180
    elif max_len > 300:
        ws.row_dimensions[row_idx].height = 140
    elif max_len > 150:
        ws.row_dimensions[row_idx].height = 100
    else:
        ws.row_dimensions[row_idx].height = 70

# -- Summary Sheet --
ws2 = wb.create_sheet("Summary")
ws2.merge_cells("A1:D1")
ws2.cell(row=1, column=1, value="LOT1 BASE Validation Summary").font = Font(
    name="Calibri", bold=True, size=14, color="2F5496")
ws2.row_dimensions[1].height = 30

# Count stats
total = len(data_rows)
aligned = sum(1 for r in data_rows if len(r) > 7 and r[7] == "YYY")
partial = sum(1 for r in data_rows if len(r) > 7 and "N" in r[7] and r[7] != "YYY")
missing = sum(1 for r in data_rows if len(r) > 7 and "_" in r[7])
protocol_gaps = sum(1 for r in data_rows if "Protocol Gap" in r[0])
original = total - protocol_gaps
has_discrep = sum(1 for r in data_rows if len(r) > 11 and r[11] and "no discrepancy" not in r[11].lower())

summary_data = [
    ("", ""),
    ("Total Variables/Items", total),
    ("Original Spec Variables", original),
    ("Protocol Gap Items Added", protocol_gaps),
    ("", ""),
    ("Sync Status Breakdown", ""),
    ("  Fully Aligned (YYY)", aligned),
    ("  Partial Alignment (has N)", partial),
    ("  Missing from Spec (has _)", missing),
    ("", ""),
    ("Discrepancies Found", has_discrep),
    ("", ""),
    ("Sections", ""),
    ("  Section A: LOT1 Base Variables", f"{original} variables"),
    ("  Section A: Protocol Gaps", f"{protocol_gaps} items"),
    ("  Section B: Examples", "1 figure"),
]

for i, (label, value) in enumerate(summary_data, 3):
    ws2.cell(row=i, column=1, value=label).font = Font(name="Calibri", size=11,
        bold=("Breakdown" in str(label) or "Total" in str(label) or "Sections" in str(label) or "Discrepancies" in str(label)))
    ws2.cell(row=i, column=2, value=value).font = Font(name="Calibri", size=11)

ws2.column_dimensions["A"].width = 35
ws2.column_dimensions["B"].width = 20

# Freeze panes
ws.freeze_panes = "C5"
ws2.freeze_panes = "A3"

# Auto-filter
ws.auto_filter.ref = f"A{HEADER_ROW}:L{HEADER_ROW + len(data_rows)}"

# Print settings
ws.sheet_properties.pageSetUpPr = None
ws.page_setup.orientation = "landscape"
ws.page_setup.fitToWidth = 1

wb.save(XLSX_PATH)
print(f"Excel file saved to: {XLSX_PATH}")
print(f"Total rows: {total} (header + {total} data rows)")
print(f"Sheets: {wb.sheetnames}")
