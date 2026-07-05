#!/usr/bin/env python3
"""Build the single Excel deliverable answering Julia's July 5 2026 questions.
Reads the archetype synthetic fixtures + real LOT-engine output so every journey
number is reproducible from the engine, not typed by hand."""
import csv, os
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

_BASE = os.path.dirname(os.path.abspath(__file__))
_INP  = os.path.join(_BASE, "patient_journey_examples", "inputs")
_OUTP = os.path.join(_BASE, "patient_journey_examples", "outputs")
OUT   = os.path.join(_BASE, "julia_july5_answers.xlsx")

# ---------- palette ----------
NAVY   = "1F3864"; BLUE = "2E5496"; LBLUE = "D6E0F0"; LBLUE2 = "EAF0FA"
GREY   = "F2F2F2"; AMBER = "FFF2CC"; GREEN = "E2EFDA"; WHITE = "FFFFFF"
RED    = "C00000"; TXT = "1A1A1A"
thin = Side(style="thin", color="BFBFBF")
BORDER = Border(left=thin, right=thin, top=thin, bottom=thin)

def font(sz=11, b=False, color=TXT, italic=False):
    return Font(name="Calibri", size=sz, bold=b, color=color, italic=italic)
def fill(c): return PatternFill("solid", fgColor=c)
WRAP = Alignment(wrap_text=True, vertical="top")
WRAPC = Alignment(wrap_text=True, vertical="center", horizontal="center")
TOP = Alignment(vertical="top")

wb = Workbook()

def sheet(title, tab=None):
    ws = wb.create_sheet(title)
    if tab: ws.sheet_properties.tabColor = tab
    ws.sheet_view.showGridLines = False
    return ws

def title_block(ws, title, subtitle, ncols=1, color=NAVY):
    ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=ncols)
    c = ws.cell(1, 1, title); c.font = font(16, True, WHITE); c.fill = fill(color)
    c.alignment = Alignment(vertical="center", horizontal="left", indent=1)
    ws.row_dimensions[1].height = 30
    ws.merge_cells(start_row=2, start_column=1, end_row=2, end_column=ncols)
    s = ws.cell(2, 1, subtitle); s.font = font(10, False, WHITE, italic=True); s.fill = fill(BLUE)
    s.alignment = Alignment(vertical="center", horizontal="left", indent=1)
    ws.row_dimensions[2].height = 20

def hrow(ws, r, headers, start=1, color=BLUE):
    for i, h in enumerate(headers):
        c = ws.cell(r, start + i, h); c.font = font(10, True, WHITE); c.fill = fill(color)
        c.alignment = WRAPC; c.border = BORDER
    ws.row_dimensions[r].height = 28

def prow(ws, r, values, start=1, wrap=True, fills=None, bolds=None, sz=10, heights=None):
    for i, v in enumerate(values):
        c = ws.cell(r, start + i, v)
        c.font = font(sz, bool(bolds and bolds[i]))
        c.alignment = WRAP if wrap else TOP
        c.border = BORDER
        if fills and fills[i]: c.fill = fill(fills[i])
    if heights: ws.row_dimensions[r].height = heights

def widths(ws, spec):
    for col, w in spec.items(): ws.column_dimensions[col].width = w

def block(ws, r, text, ncols, fillc=AMBER, bold=False, sz=10, height=None, color=TXT):
    ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=ncols)
    c = ws.cell(r, 1, text); c.font = font(sz, bold, color); c.fill = fill(fillc)
    c.alignment = WRAP; c.border = BORDER
    if height: ws.row_dimensions[r].height = height
    return r + 1

def section(ws, r, text, ncols, color=NAVY):
    ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=ncols)
    c = ws.cell(r, 1, text); c.font = font(11, True, WHITE); c.fill = fill(color)
    c.alignment = Alignment(vertical="center", indent=1)
    ws.row_dimensions[r].height = 22
    return r + 1

# ======================================================================
# load engine data
# ======================================================================
roll = {x["code"]: x["med_abbr"] for x in csv.DictReader(open(os.path.join(_INP,"rollup.csv")))}
sctc = {x["code"]: x["sct_type"] for x in csv.DictReader(open(os.path.join(_INP,"sct_codelist.csv")))}
members = {x["patient_id"]: x for x in csv.DictReader(open(os.path.join(_INP,"members.csv")))}
ph = list(csv.DictReader(open(os.path.join(_INP,"pharmacy.csv"))))
pr = list(csv.DictReader(open(os.path.join(_INP,"procedure.csv"))))
mapst = list(csv.DictReader(open(os.path.join(_OUTP,"MAP_STACKED.csv"))))
lotl = list(csv.DictReader(open(os.path.join(_OUTP,"LOT_LONG.csv"))))

ARCH = [
    ("9000000101", "POMA in first line (1L)",
     "A patient whose FIRST-LINE regimen is pomalidomide (POMA) + dexamethasone. Shows how a POMA-1L record is built and why it stands out (POMA is normally a later-line agent). Answers the setup for Q2-Q5."),
    ("9000000102", "Induction triplet + single autologous SCT + maintenance",
     "Bortezomib+lenalidomide+dex induction, one autologous stem-cell transplant, then lenalidomide maintenance. This is STANDARD first-line therapy for a transplant-eligible newly-diagnosed patient: the transplant does NOT start a new line and does NOT imply prior treatment."),
    ("9000000103", "Tandem autologous SCT",
     "Two planned autologous transplants ~100 days apart (60-180 day rule) with continuous lenalidomide bridging them. Classified as a planned TANDEM within LOT1 - still first line."),
    ("9000000104", "Allogeneic SCT ends the line -> new line",
     "Induction, then an ALLOGENEIC transplant. Unlike an autologous SCT, an allo transplant ENDS the line (single-day LOT2), and the next therapy becomes LOT3. Allo/CAR-T around an early line is a red flag for non-treatment-naive status."),
    ("9000000105", "CAR-T with consolidation therapy",
     "First line discontinues, then a CAR-T infusion starts a new line; the daratumumab given within the 45-day consolidation window is captured as that line's regimen. Directly illustrates 'consolidation therapy around CAR-T'."),
    ("9000000106", "Deep progressor: LOT1 -> LOT5",
     "Five sequential drug-based lines over ~3 years (BORT LENA -> DARA POMA -> CARF -> ELOT POMA -> ISAT LENA). Shows how the algorithm advances the line number and assigns end reasons (MED_ADD vs DISCONTINUATION)."),
]
ARCH_TITLE = {p: t for p, t, _ in ARCH}

def raw_claims(pid):
    rows = []
    for r in ph:
        if r["patient_id"] == pid:
            rows.append((r["service_date"], "Pharmacy fill", roll.get(r["normalized_code"], "?"),
                         "NDC", f'{r["days_supply"]} days'))
    for r in pr:
        if r["patient_id"] == pid:
            rows.append((r["event_date"], "Procedure (SCT)", sctc.get(r["normalized_code"], "?"),
                         "HCPCS", "-"))
    return sorted(rows)

print("loaded", len(lotl), "LOT rows,", len(mapst), "MAP rows for", len(members), "patients")

# ======================================================================
# SHEET 1 — Read Me
# ======================================================================
ws = sheet("Read Me", NAVY)
widths(ws, {"A": 3, "B": 116})
title_block(ws, "Julia's Questions — 5 July 2026", "Answers, patient-journey examples, and the Optum coverage validation  •  prepared 2026-07-05", ncols=2)
r = 4
def rm(text, fillc=WHITE, bold=False, sz=10, h=None, color=TXT):
    global r
    ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=2)
    c = ws.cell(r, 2, text); c.font = font(sz, bold, color); c.alignment = WRAP
    if fillc != WHITE: c.fill = fill(fillc)
    if h: ws.row_dimensions[r].height = h
    r += 1
rm("What this workbook is", NAVY, True, 12, color=WHITE); ws.cell(r-1,2).fill=fill(NAVY)
rm("Julia sent five follow-up questions (see Questions/July 5 2026) plus a request to trace patients from raw claims "
   "through to their final assigned line of therapy (LOT). This single workbook answers all of them and adds the "
   "Optum medical-vs-pharmacy coverage validation you asked for. One tab per question, plus worked patient journeys.", GREY, h=58)
rm("")
rm("  ▶  ONE-LINE COVER NOTE for whoever forwards this to Julia", "375623", True, 11, h=20, color=WHITE)
rm("The patient journeys here are SYNTHETIC, rule-faithful examples that show the complete raw-claims → MAP → LOT journey; "
   "the actual patient examples and the requested counts require running the included SQL against the Databricks "
   "warehouse. Everything else (the Optum coverage validation, the method, and the queries) is final.", GREEN, h=48)
rm("")
rm("  ▶  IMPORTANT — how to read the numbers", AMBER, True, 11, h=20)
rm("The patient-level counts Julia asks for (how many POMA-1L patients have an SCT, another cancer, a clinical trial, etc.) "
   "live in the Databricks warehouse (hive_metastore / Optum CDM), which this repository cannot reach. So this workbook gives, "
   "for each question: (1) the precise answer/interpretation grounded in the protocol + program spec, (2) the exact, ready-to-run "
   "query that produces the count, and (3) the honest limits. Where a query already exists in the codebase it is cited. "
   "The patient-journey tabs ARE fully worked end-to-end — they were produced by running the project's LOT engine on "
   "illustrative synthetic patients, so they show the exact journey format and the algorithm's real behaviour.", AMBER, h=104)
rm("")
rm("The five questions (Julia, 4 Jul 2026)", NAVY, True, 12, color=WHITE); ws.cell(r-1,2).fill=fill(NAVY)
qs = [
 "1.  Trace a few different types of patients from raw claims to final assigned LOT — a mix of LOT1-5, SCT or CAR-T, and consolidation therapy around CAR-T.",
 "2.  For patients receiving POMA in 1L: are there patients who also receive SCT or CAR-T in the cohort? Would indicate they are not treatment-naive.",
 "3.  Is POMA highly associated with evidence of any of the permissible cancers we allow to occur in baseline?",
 "4.  Do POMA patients have evidence of clinical-trial participation?",
 "5.  Do POMA patients have continuous PHARMACY benefit (not just medical)? These cases could hide prior LEN/THAL first-line exposure outside observable pharmacy claims.",
]
for q in qs: rm(q, LBLUE2, h=32)
rm("")
rm("Tabs in this workbook", NAVY, True, 12, color=WHITE); ws.cell(r-1,2).fill=fill(NAVY)
tabs = [
 "Answers at a glance — one-line answer + data status for every question.",
 "Optum coverage (validation) — the medical-vs-pharmacy question, validated against the data dictionary and program spec.",
 "Q1 journeys — guide — what the traces show + how to pull the same trace for a real patient.",
 "Q1 raw claims / Q1 MAP segments / Q1 LOT assignment — the full raw-claims → MAP → LOT chain for six archetype patients.",
 "Q2 POMA & SCT/CAR-T  •  Q3 POMA & other cancers  •  Q4 POMA & clinical trials  •  Q5 POMA & pharmacy benefit.",
 "Method & data sources — provenance, the LOT engine, and every file cited.",
]
for t in tabs: rm("•  " + t, GREY, h=30)

# ======================================================================
# SHEET 2 — Answers at a glance
# ======================================================================
ws = sheet("Answers at a glance", BLUE)
widths(ws, {"A": 4, "B": 40, "C": 62, "D": 20})
title_block(ws, "Answers at a glance", "Short answer + data status for each item. Detail on the per-question tabs.", ncols=4)
hrow(ws, 4, ["", "Question", "Short answer", "Data status"])
rows = [
 ("Q1", "Trace patients raw claims → LOT (LOT1-5, SCT/CAR-T, consolidation)",
  "Done end-to-end on six SYNTHETIC archetype patients (the 'Q1 …' tabs show every step with dates). These prove the format and the algorithm's behaviour; REAL patient examples run the same MAP_STACKED + LOT_LONG extraction against the warehouse (SQL provided).",
  "Synthetic worked examples; real = warehouse run"),
 ("Q2", "POMA-1L patients who also get SCT or CAR-T = not treatment-naive?",
  "Partly. An AUTOLOGOUS SCT after 1L is NORMAL first-line care and is NOT evidence of prior treatment. ALLOGENEIC SCT or CAR-T near 1L IS a red flag. Query breaks POMA-1L down by transplant type.",
  "Needs warehouse run (SQL provided)"),
 ("Q3", "Is POMA associated with permissible (other) cancers in baseline?",
  "Answerable in the ELIG_COH build, which deliberately KEEPS patients flagged for another cancer. Measure the POMA-1L vs non-POMA rate of OTHER_MALIGN_FLAG. An existing script already counts it.",
  "Needs warehouse run (SQL exists)"),
 ("Q4", "Do POMA patients have clinical-trial evidence?",
  "Answerable in ELIG_COH (clinical-trial patients are also kept). Measure CLINTRIAL_BASELINE / _FOLLOWUP among POMA-1L. Existing script already computes it.",
  "Needs warehouse run (SQL exists)"),
 ("Q5", "Do POMA patients have continuous pharmacy benefit (not just medical)?",
  "Concern is largely closed by design: every Optum member has BOTH benefits, and baseline MM-therapy (incl. oral LEN/THAL by NDC) is already an exclusion. Residual = exposure before the 6-month look-back only.",
  "Validated + confirmatory SQL"),
 ("Side", "Does Optum track medical & pharmacy coverage separately?",
  "You are essentially correct — Optum CDM requires BOTH benefits for membership and tracks coverage as one enrollment span, not two separable streams. Full validation on the 'Optum coverage' tab.",
  "Validated against docs"),
]
r = 5
for tag, q, a, st in rows:
    prow(ws, r, [tag, q, a, st],
         fills=[LBLUE, WHITE, WHITE, GREEN if ("Validated" in st or "Worked" in st) else AMBER],
         bolds=[True, False, False, False],
         heights=max(46, 14*(1+len(a)//60)))
    ws.cell(r,1).alignment = WRAPC
    r += 1

# ======================================================================
# SHEET 3 — Optum coverage validation
# ======================================================================
ws = sheet("Optum coverage (validation)", GREEN)
widths(ws, {"A": 3, "B": 116})
title_block(ws, "Validation: does Optum separate medical & pharmacy coverage?", "Your note: \"I do not think Optum has medical and pharmacy coverage as separate.\"  —  Validated below.", ncols=2, color="375623")
r = 4
def cv(text, fillc=WHITE, bold=False, sz=10, h=None, color=TXT):
    global r
    ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=2)
    c = ws.cell(r, 2, text); c.font = font(sz, bold, color); c.alignment = WRAP
    if fillc != WHITE: c.fill = fill(fillc)
    if h: ws.row_dimensions[r].height = h
    r += 1
cv("Bottom line:  you are essentially correct.", GREEN, True, 12, h=22)
cv("In Optum CDM, medical and pharmacy are not two separately-enrollable coverages you can hold one of without the other: "
   "membership requires BOTH benefits, so there is no 'medical-only, no pharmacy' sub-population, and a member's coverage "
   "is modelled as a single continuous-enrollment span rather than as independent medical and pharmacy eligibility "
   "records. (The enrollment record does carry a product / plan-type attribute — so Optum is not 'benefit-blind' — but it "
   "is one record per member, not two benefit-eligibility tables.) This is why the question keeps recurring: the program "
   "spec repeats the phrase 'medical AND pharmacy benefits', which reads as if the two were separable — but in this "
   "cohort they move together.", GREEN, h=100)
cv("")
r = section(ws, r, "The evidence", 2, "375623")
cv("1)  Data asset requires both benefits", LBLUE, True, 11, h=18)
cv("Program spec, DATA_SOURCE (validated from protocol): \"…Optum Clinformatics Data Mart (CDM)… Membership restricted "
   "to individuals with BOTH medical and pharmacy benefits.\"   [docs/Part 3/Program Spec/studypoppage_validated.csv]", LBLUE2, h=44)
cv("2)  Coverage is one enrollment span, not two streams", LBLUE, True, 11, h=18)
cv("Optum business rules: coverage lives in T_MEMBER_ENROLLMENT (one row per member per change, with ELIGEFF/ELIGEND "
   "coverage dates) and is rolled up into T_MEMBER_CONTINUOUS_ENROLLMENT (one span per <30-day-gap continuous period). "
   "There is a single eligibility span per member — the product/plan type is an attribute of that one record, not two "
   "separate medical and pharmacy eligibility tables.   [Apr 18 2026/Optum - Business Rules/optum business rules.pdf]", LBLUE2, h=62)
cv("3)  The cohort's own enrollment rule restates 'both'", LBLUE, True, 11, h=18)
cv("Inclusion Criterion 5 / CE_b (Baseline Continuous Enrollment): \"=1 if patient has six months of continuous "
   "enrollment with medical and pharmacy benefits before the index date… gaps of <=30 days are considered continuously "
   "enrolled.\" This 'medical and pharmacy' wording is a restatement of the Optum both-benefits guarantee, not proof the "
   "two are separable. (Note: the cohort builds these 6-month spans from the RAW ELIGEFF/ELIGEND records with a <=30-day "
   "gap allowance — its own rule, slightly looser than Optum's native <30-day continuous-enrollment rollup table.)   "
   "[studypoppage_validated.csv, CE_b / Criterion 5]", LBLUE2, h=76)
cv("")
r = section(ws, r, "Why this matters for Julia's Q5 (hidden LEN/THAL exposure)", 2, "375623")
cv("Julia's worry: a POMA-1L patient might have had prior lenalidomide/thalidomide first-line therapy that is invisible "
   "because it happened 'outside observable pharmacy claims.' Because of how Optum and this cohort are built, that blind "
   "spot is largely closed — and NOT because pharmacy is a separate benefit:", WHITE, h=48)
cv("•  Every member has pharmacy coverage, so an oral LEN/THAL fill is OBSERVABLE as an NDC pharmacy claim for anyone in the cohort (when adjudicated through the plan).", GREEN, h=30)
cv("•  The cohort already EXCLUDES anyone with a baseline MM-therapy claim — medical (HCPCS/CPT) OR pharmacy (NDC) — in the "
   "6 months before index (Exclusion Criterion 3 / MM_bl_agents). LEN and THAL are captured by NDC provided their codes "
   "are in the study's MM-therapy code list (Tab 41 / CL_MMA_CODELIST) — which is the intended design — so a baseline "
   "oral first-line exposure would have set the flag and excluded the patient.", GREEN, h=62)
cv("⇒  A delivered POMA-1L patient therefore had observable pharmacy coverage in baseline and no MM-therapy claim in that "
   "window. The pharmacy blind spot Julia describes does not exist inside the 6-month baseline.", GREEN, True, 10, h=38)
cv("")
cv("The one real limitation (state it plainly)", AMBER, True, 11, h=18)
cv("Exposure EARLIER than the 6-month (183-day) baseline look-back is not evaluated by the baseline scan. That is a "
   "look-back-window limitation, not a medical-vs-pharmacy-benefit gap. (Optum claims physically go back to 2007, so "
   "earlier fills may exist in the raw data; the limit is the study's fixed 183-day baseline window, not the data.) It "
   "can be quantified for POMA-1L patients by (a) measuring their longest continuous pre-index enrollment span, and "
   "(b) scanning ALL available pre-index pharmacy history for LEN/THAL NDCs — see the Q5 tab. Claims data still only "
   "captures ADJUDICATED fills whose NDC is on the study code list; manufacturer samples, cash-pay / out-of-plan fills, "
   "and any NDC missing from the list are not observable — so 'observable' is the right word, not 'always visible.'", AMBER, h=90)
cv("")
cv("How to say it back to Julia (one line)", NAVY, True, 11, h=18, color=WHITE); ws.cell(r-1,2).fill=fill(NAVY)
cv("\"Optum only enrols members who carry both medical and pharmacy benefits, so there is no medical-only group and oral "
   "LEN/THAL fills are OBSERVABLE as pharmacy claims (when adjudicated and on our code list); combined with the "
   "baseline-therapy exclusion, a POMA-1L patient is very unlikely to be hiding an observable-window first-line oral "
   "agent. The remaining gaps are exposure before the 6-month look-back and non-adjudicated fills — both measurable or "
   "boundable.\"", GREY, h=62)

print("core sheets built")

MONO = Font(name="Consolas", size=9, color=TXT)
def sqlblock(ws, r, sql, ncols):
    ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=ncols)
    c = ws.cell(r, 1, sql); c.font = MONO; c.fill = fill("F7F7F7")
    c.alignment = Alignment(wrap_text=True, vertical="top"); c.border = BORDER
    ws.row_dimensions[r].height = 14 * (sql.count("\n") + 1) + 6
    return r + 1

# ======================================================================
# SHEET — Q1 journeys guide
# ======================================================================
ws = sheet("Q1 journeys — guide", "7030A0")
widths(ws, {"A": 3, "B": 116})
title_block(ws, "Q1 — Patient journeys, raw claims → assigned LOT", "Six archetype patients, each traced end-to-end with dates. Detail on the three 'Q1 …' data tabs.", ncols=2, color="53376B")
r = 4
def jg(text, fillc=WHITE, bold=False, sz=10, h=None, color=TXT):
    global r
    ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=2)
    c = ws.cell(r, 2, text); c.font = font(sz, bold, color); c.alignment = WRAP
    if fillc != WHITE: c.fill = fill(fillc)
    if h: ws.row_dimensions[r].height = h
    r += 1
jg("How the algorithm turns claims into lines of therapy", "53376B", True, 12, h=22, color=WHITE)
jg("Each drug claim opens a Medication Available Period (MAP) that runs for its days-supply; refills push the MAP end "
   "out; a >90-day gap with no cover = discontinuation. LOT1 starts at the first non-steroid MAP; the induction window "
   "(60 days) fixes the regimen; steroids (dexamethasone) are supportive and never count as a myeloma agent. A transplant "
   "or a newly-added agent can end a line and start the next one. The three data tabs show, for six patients, the raw "
   "claims, the MAP segments the engine built, and the final LOT assignment — all with dates.", GREY, h=86)
jg("")
jg("The six archetypes (why each was chosen)", "53376B", True, 12, h=22, color=WHITE)
hdrs_done = False
for pid, ttl, desc in ARCH:
    jg(f"{pid} — {ttl}", LBLUE, True, 11, h=18)
    jg(desc, LBLUE2, h=48)
jg("")
jg("⚠  These six are illustrative SYNTHETIC patients (reserved ID range 9000000000+), run through the project's actual "
   "LOT engine (jun_21_2026/engine) so the journeys are the algorithm's real, rule-faithful output — not hand-drawn. "
   "They demonstrate the exact format Julia will get for real patients. The repository holds no real patient data; a "
   "real cohort trace runs the same extraction against the warehouse. The inputs, outputs, and a one-command reproduce "
   "step are committed next to this workbook in  Questions/July 5 2026/patient_journey_examples/.", AMBER, h=72)
jg("")
jg("To pull the same journey for a REAL patient (Databricks SQL)", NAVY, True, 11, h=18, color=WHITE); ws.cell(r-1,2).fill=fill(NAVY)
r = sqlblock(ws, r, (
"-- 1. Raw pharmacy + medical claims for one patient (chronological)\n"
"SELECT 'pharmacy' src, FILL_DT dt, NDC code, DAYS_SUP FROM <cdm>.t_rx      WHERE PATID = :pid\n"
"UNION ALL\n"
"SELECT 'medical'  src, FST_DT  dt, PROC_CD, NULL   FROM <cdm>.t_medical    WHERE PATID = :pid\n"
"ORDER BY dt;\n\n"
"-- 2. The MAP segments the engine built, and the final line assignment\n"
"SELECT * FROM <work>.MAP_STACKED WHERE PATID = :pid ORDER BY MAP_START_DT;\n"
"SELECT LOT_NUM, LOT_START_DT, LOT_START_TYPE, LOT_BASE_MEDS, LOT_BASE_END_DT,\n"
"       LOT_BASE_END_REASON, LOT_ALLO_LOT_FLG, LOT_CART_LOT_FLG,\n"
"       LOT_TX_AUTO_SING_FLG, LOT_TX_AUTO_TAND_FLG, LOT_TX_AUTO_DT_1, LOT_TX_AUTO_DT_2\n"
"FROM   <work>.LOT_LONG WHERE PATID = :pid ORDER BY LOT_NUM;"), 2)
jg("Pick example patients automatically (the dashboard's own logic — deepest progressors + one per terminal reason) with "
   "apr_30_2026/lot1_studyteam_qs.R (question Q3 in that script). Swap :pid for a PATID of interest.", GREY, h=32)

# ======================================================================
# SHEET — Q1 raw claims
# ======================================================================
ws = sheet("Q1 raw claims", "7030A0")
widths(ws, {"A": 14, "B": 30, "C": 13, "D": 16, "E": 14, "F": 12})
title_block(ws, "Q1 — Raw claims (input to the algorithm)", "Every pharmacy fill and transplant procedure for the six archetype patients. DEX = dexamethasone (steroid, excluded from LOT).", ncols=6, color="53376B")
hrow(ws, 4, ["Patient", "Archetype", "Claim date", "Claim type", "Drug / SCT", "Detail"])
r = 5
for pid, ttl, _ in ARCH:
    for (d, typ, drug, sysm, det) in raw_claims(pid):
        steroid = (drug == "DEX")
        prow(ws, r, [pid, ttl, d, typ, drug, det],
             wrap=True, sz=9,
             fills=[LBLUE2, WHITE, WHITE, WHITE, GREY if steroid else WHITE, WHITE],
             heights=15)
        ws.cell(r,1).alignment = TOP; ws.cell(r,3).alignment = TOP
        r += 1
ws.freeze_panes = "A5"

# ======================================================================
# SHEET — Q1 MAP segments
# ======================================================================
ws = sheet("Q1 MAP segments", "7030A0")
widths(ws, {"A": 14, "B": 10, "C": 10, "D": 6, "E": 13, "F": 13, "G": 11})
title_block(ws, "Q1 — MAP segments (engine intermediate)", "Each drug's Medication Available Period(s) with start/end and the discontinuation flag. Built from the raw claims on the previous tab.", ncols=7, color="53376B")
hrow(ws, 4, ["Patient", "Drug", "Class", "MAP #", "MAP start", "MAP end", "Discon?"])
r = 5
for pid, _, _ in ARCH:
    segs = sorted([m for m in mapst if m["patient_id"] == pid], key=lambda x: (x["map_start_dt"], x["med_abbr"]))
    for m in segs:
        prow(ws, r, [pid, m["med_abbr"], m["med_class"], m["map_cnt"], m["map_start_dt"], m["map_end_dt"],
                     "yes" if m["map_discon_flg"] == "1" else "no"],
             wrap=False, sz=9,
             fills=[LBLUE2, GREY if m["med_class"]=="STEROID" else WHITE, WHITE, WHITE, WHITE, WHITE,
                    AMBER if m["map_discon_flg"]=="1" else WHITE],
             heights=15)
        r += 1
ws.freeze_panes = "A5"

# ======================================================================
# SHEET — Q1 LOT assignment
# ======================================================================
ws = sheet("Q1 LOT assignment", "7030A0")
widths(ws, {"A": 14, "B": 6, "C": 12, "D": 12, "E": 16, "F": 12, "G": 12, "H": 18, "I": 8, "J": 8, "K": 14})
title_block(ws, "Q1 — Final LOT assignment (algorithm output)", "The line-of-therapy record for each patient. SCT/CAR-T flags and transplant dates are shown. This is the deliverable Julia asked to see.", ncols=11, color="53376B")
hrow(ws, 4, ["Patient", "LOT", "Start", "Start type", "Regimen", "End date", "Length (d)", "End reason", "ALLO", "CAR-T", "AUTO SCT"])
r = 5
def auto_txt(row):
    if row["lot_tx_auto_flg"] != "1": return "-"
    if row["lot_tx_auto_tand_flg"] == "1":
        return f"tandem {row['lot_tx_auto_dt_1']} + {row['lot_tx_auto_dt_2']}"
    return f"single {row['lot_tx_auto_dt_1']}"
last_pid = None
for pid, _, _ in ARCH:
    for row in sorted([l for l in lotl if l["patient_id"] == pid], key=lambda x: int(x["lot_num"])):
        band = LBLUE2 if pid != last_pid else WHITE
        reason = row["lot_base_end_reason"]
        rfill = {"SCT_ALLO": "FCE4D6", "SCT_CART": "FCE4D6", "CART": "FCE4D6",
                 "MED_ADD": AMBER, "DISCONTINUATION": GREEN}.get(reason, WHITE)
        prow(ws, r, [pid, row["lot_num"], row["lot_start_dt"], row["lot_start_type"],
                     row["lot_base_meds"] or "(transplant only)", row["lot_base_end_dt"],
                     row["lot_base_length"], reason,
                     "✔" if row["lot_allo_lot_flg"]=="1" else "",
                     "✔" if row["lot_cart_lot_flg"]=="1" else "",
                     auto_txt(row)],
             wrap=False, sz=9,
             fills=[LBLUE2, WHITE, WHITE, WHITE, WHITE, WHITE, WHITE, rfill, WHITE, WHITE, WHITE],
             heights=15)
        for cc in (9,10): ws.cell(r,cc).alignment = WRAPC
        r += 1
    last_pid = pid
ws.freeze_panes = "A5"
# reading notes under the table
r += 1
r = block(ws, r, "Reading the journeys:", 11, NAVY, True, 10, 18, WHITE)
notes = [
 "9000000102 (single autologous SCT): the transplant on 2021-08-15 is flagged as an AUTO SCT but does NOT open a new line — LOT1 continues on maintenance to a clean discontinuation. Autologous SCT is part of first line.",
 "9000000104 (allogeneic SCT): the allo transplant ENDS LOT1 (reason SCT_ALLO), creates a single-day LOT2, and the next drug (DARA) becomes LOT3. Allo behaves very differently from auto.",
 "9000000105 (CAR-T + consolidation): after LOT1 discontinues, the CAR-T on 2020-09-01 starts LOT2 and the daratumumab given 19 days later is captured as the CAR-T line's consolidation regimen.",
 "9000000106 (deep progressor): five lines; note two ended by MED_ADD (a new agent added before a full 90-day discontinuation) and three by DISCONTINUATION.",
]
for n in notes:
    r = block(ws, r, "•  " + n, 11, GREY, False, 9, 30)

print("Q1 journey sheets built")

# ======================================================================
# Q2–Q5 question tabs (shared layout)
# ======================================================================
def qsheet(title, tab, htitle, hsub, blocks):
    ws = sheet(title, tab)
    widths(ws, {"A": 3, "B": 116})
    title_block(ws, htitle, hsub, ncols=2, color=NAVY)
    r = 4
    for kind, text in blocks:
        ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=2)
        c = ws.cell(r, 2, text); c.alignment = WRAP
        if kind == "sec":
            c.font = font(11, True, WHITE); c.fill = fill(NAVY); ws.row_dimensions[r].height = 20
        elif kind == "sub":
            c.font = font(11, True); c.fill = fill(LBLUE); ws.row_dimensions[r].height = 18
        elif kind == "amber":
            c.font = font(10); c.fill = fill(AMBER)
            ws.row_dimensions[r].height = 14 * (1 + len(text)//95) + 8
        elif kind == "green":
            c.font = font(10); c.fill = fill(GREEN)
            ws.row_dimensions[r].height = 14 * (1 + len(text)//95) + 8
        elif kind == "sql":
            c.font = MONO; c.fill = fill("F7F7F7")
            ws.row_dimensions[r].height = 14 * (text.count("\n") + 1) + 6
        elif kind == "gap":
            ws.row_dimensions[r].height = 6
        else:
            c.font = font(10)
            ws.row_dimensions[r].height = 14 * (1 + len(text)//95) + 8
        c.border = BORDER if kind in ("amber","green","sql","sub") else Border()
        r += 1
    return ws

# ---------- Q2 ----------
qsheet("Q2 POMA & SCT-CART", "C55A11",
 "Q2 — POMA-1L patients who also receive SCT or CAR-T",
 "\"Are there patients who receive SCT or CAR-T that get included in our cohort? Would indicate patients are not treatment-naive.\"",
 [
 ("sec", "Short answer"),
 ("green", "Yes, some POMA-1L patients will have transplant/CAR-T evidence — but it does NOT all point to non-naive status, and "
  "WHERE the transplant sits matters. An AUTOLOGOUS SCT at first line is standard care for a transplant-eligible "
  "newly-diagnosed patient (induction → auto-SCT → maintenance) and is expected. What flags a NON-treatment-naive patient "
  "is an ALLOGENEIC SCT or a CAR-T infusion AT OR CLOSING first line. Critically, allo/CAR-T on a LATER line is NOT a "
  "red flag — a genuine POMA-1L patient can progress to CAR-T months later. The query therefore separates 'near 1L' from "
  "'any later line' instead of counting transplant on any line."),
 ("gap",""),
 ("sec", "Why this is the right read (clinical framing)"),
 ("p", "• POMA (pomalidomide) is itself normally a relapsed/refractory agent, so POMA appearing in 1L is the anomaly worth investigating — the transplant question is a way of triaging those patients."),
 ("p", "• Autologous SCT → part of first line. Not evidence of prior treatment. (See journey 9000000102 on the Q1 tabs.)"),
 ("p", "• Allogeneic SCT or CAR-T AT/closing 1L → strong signal of earlier, unobserved lines (journeys 9000000104, 9000000105). The SAME therapy several lines later is expected progression, not a red flag."),
 ("gap",""),
 ("sec", "Query (Databricks) — POMA-1L transplant broken down by WHEN it occurs"),
 ("sql",
"WITH poma1l AS (\n"
"  SELECT DISTINCT PATID FROM <work>.LOT_LONG\n"
"  WHERE LOT_NUM = 1 AND array_contains(split(LOT_BASE_MEDS,' '), 'POMA')\n"
"),\n"
"near_1l AS (   -- transplant / CAR-T AT or CLOSING the first line (the 'near 1L' red-flag signal)\n"
"  SELECT PATID,\n"
"    max(CASE WHEN LOT_NUM=1 AND (LOT_TX_AUTO_SING_FLG=1 OR LOT_TX_AUTO_TAND_FLG=1) THEN 1 ELSE 0 END) auto_1l,\n"
"    max(CASE WHEN (LOT_NUM=1 AND LOT_BASE_END_REASON='SCT_ALLO')\n"
"               OR (LOT_NUM<=2 AND LOT_ALLO_LOT_FLG=1) THEN 1 ELSE 0 END)                              allo_near_1l,\n"
"    max(CASE WHEN (LOT_NUM=1 AND LOT_BASE_END_REASON='SCT_CART')\n"
"               OR (LOT_NUM<=2 AND LOT_CART_LOT_FLG=1) THEN 1 ELSE 0 END)                              cart_near_1l\n"
"  FROM <work>.LOT_LONG GROUP BY PATID\n"
"),\n"
"context AS (   -- allo/CAR-T on ANY line, for context only (does NOT imply non-naive)\n"
"  SELECT PATID, max(LOT_ALLO_LOT_FLG) allo_any, max(LOT_CART_LOT_FLG) cart_any\n"
"  FROM <work>.LOT_LONG GROUP BY PATID\n"
")\n"
"SELECT count(*)                                                          AS poma_1l_pts,\n"
"       sum(n.auto_1l)                                                    AS autologous_at_1l,   -- normal 1L care\n"
"       sum(n.allo_near_1l)                                               AS allogeneic_near_1l, -- red flag\n"
"       sum(n.cart_near_1l)                                               AS cart_near_1l,       -- red flag\n"
"       sum(CASE WHEN n.allo_near_1l=1 OR n.cart_near_1l=1 THEN 1 ELSE 0 END) AS red_flag_near_1l,\n"
"       sum(CASE WHEN c.allo_any=1  OR c.cart_any=1  THEN 1 ELSE 0 END)   AS allo_or_cart_any_line  -- context only\n"
"FROM poma1l p JOIN near_1l n USING (PATID) JOIN context c USING (PATID);"),
 ("gap",""),
 ("sec", "Honest limits"),
 ("amber", "For the authoritative CAR-T-relative-to-LOT1 timing, use the existing pattern in apr_30_2026/R/validation_qs.R "
  "(vqs_q6_cart), which bounds CAR-T to the LOT1 span [LOT1_START, LOT1_END] — extended by one day only when CAR-T closes "
  "LOT1 — and reads 'before LOT1' from raw CAR-T claim dates. The LOT_LONG-only query above is a good first pass; "
  "vqs_q6_cart is the precise version. Either way, a POMA-1L patient with a near-1L allo/CAR-T most likely had prior "
  "line(s) OUTSIDE the observable window (Exclusion Criterion 3 already removes OBSERVABLE prior MM therapy) — the "
  "transplant is the tell, not a claims error. Pair with the pharmacy look-back on the Q5 tab."),
 ])

# ---------- Q3 ----------
qsheet("Q3 POMA & other cancers", "C55A11",
 "Q3 — POMA vs. permissible (other) cancers in baseline",
 "\"Is POMA highly associated with having evidence of any of the permissible cancers we allow to occur in baseline?\"",
 [
 ("sec", "What 'permissible cancers we allow in baseline' means"),
 ("p", "The analytic build (ELIG_COH) deliberately does NOT apply Exclusion Criterion 7 (another cancer in baseline). "
  "Patients who would normally be excluded for a second cancer are KEPT so the LOT algorithm can run on them and the "
  "team can measure exactly this kind of overlap. So 'permissible cancers' = the other-malignancy codes (spec Tab 44) "
  "that Criterion 7 would exclude but ELIG_COH retains. There is no separate benign-cancer carve-out list — it is the "
  "whole other-malignancy code set, made non-excluding in this build."),
 ("gap",""),
 ("sec", "Short answer"),
 ("green", "Answerable directly, and the code to count it already exists. Measure the rate of OTHER_MALIGN_FLAG among POMA-1L "
  "patients and compare it to non-POMA 1L patients (a relative risk). apr_30_2026/lot1_studyteam_qs.R already computes "
  "the POMA-1L other-cancer count (its question Q1a), index-date-aligned, plus a blind-spot quantification."),
 ("gap",""),
 ("sec", "Query (Databricks) — association of POMA-1L with baseline other-cancer"),
 ("sql",
"WITH poma1l AS (\n"
"  SELECT DISTINCT cast(PATID AS string) PATID FROM <work>.LOT_LONG\n"
"  WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'POMA')\n"
"),\n"
"lot1 AS (SELECT DISTINCT cast(PATID AS string) PATID FROM <work>.LOT_LONG WHERE LOT_NUM=1),\n"
"-- align each patient's flag to the INDEX_DATE that actually produced LOT1\n"
"f AS (\n"
"  SELECT cast(a.PATID AS string) PATID, a.OTHER_MALIGN_FLAG\n"
"  FROM <work>.ELIG_COH_ALLFLAGS a\n"
"  JOIN <work>.ELIG_COH_FINAL   e ON e.PATID=a.PATID AND e.INDEX_DATE=a.INDEX_DATE\n"
")\n"
"SELECT CASE WHEN p.PATID IS NOT NULL THEN 'POMA-1L' ELSE 'other-1L' END grp,\n"
"       count(*)                                                    AS n_pts,\n"
"       sum(coalesce(f.OTHER_MALIGN_FLAG,0))                        AS n_other_cancer,\n"
"       round(100.0*sum(coalesce(f.OTHER_MALIGN_FLAG,0))/count(*),1) AS pct_other_cancer\n"
"FROM lot1 l JOIN f USING (PATID) LEFT JOIN poma1l p USING (PATID)\n"
"GROUP BY 1;"),
 ("gap",""),
 ("sec", "Honest limits"),
 ("amber", "Use OTHER_MALIGN_FLAG from ELIG_COH_ALLFLAGS, not a hand-rolled diagnosis query. That flag applies the other-cancer "
  "tumour-group codelist (spec Tab 44) with the '>=2 codes on separate days within 30 days for the same tumour type' rule. "
  "Note: the protocol also describes a 1-inpatient-or-2-outpatient confirmation, but the pipeline code implements the "
  "30-day-window codelist rule only (no inpatient/outpatient distinction), so treat the flag as codelist-based. A raw "
  "ICD-10 C-code scan (e.g. the Kaposi C46* hypothesis) is only a best-effort supplement; lot1_studyteam_qs.R marks it as such."),
 ])

# ---------- Q4 ----------
qsheet("Q4 POMA & clinical trials", "C55A11",
 "Q4 — POMA patients and clinical-trial participation",
 "\"Do POMA patients have evidence of clinical-trial participation?\"",
 [
 ("sec", "Short answer"),
 ("green", "Answerable in the ELIG_COH build, and already coded. Like other-cancer, clinical-trial participation "
  "(Exclusion Criterion 9) is NOT applied in ELIG_COH, so those patients are retained and their CLINTRIAL_BASELINE / "
  "CLINTRIAL_FOLLOWUP flags are available. apr_30_2026/lot1_studyteam_qs.R computes these among POMA-1L (its question Q1c)."),
 ("gap",""),
 ("sec", "Why Julia is asking"),
 ("p", "Clinical-trial participation is a plausible explanation for an apparent POMA-1L: a patient could have received an "
  "unobserved investigational first-line therapy on trial (study drug not billed through normal claims), making the "
  "first CLAIMS-visible regimen look like line 1 when it is really a later line. A high trial rate among POMA-1L would "
  "support the 'not truly first-line / not treatment-naive' hypothesis and would pair with the Q2 transplant signal."),
 ("gap",""),
 ("sec", "Query (Databricks) — clinical-trial evidence among POMA-1L"),
 ("sql",
"WITH poma1l AS (\n"
"  SELECT DISTINCT cast(PATID AS string) PATID FROM <work>.LOT_LONG\n"
"  WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'POMA')\n"
"),\n"
"f AS (   -- index-aligned flags\n"
"  SELECT cast(a.PATID AS string) PATID,\n"
"         a.CLINTRIAL_BASELINE, a.CLINTRIAL_FOLLOWUP\n"
"  FROM <work>.ELIG_COH_ALLFLAGS a\n"
"  JOIN <work>.ELIG_COH_FINAL   e ON e.PATID=a.PATID AND e.INDEX_DATE=a.INDEX_DATE\n"
")\n"
"SELECT count(*)                                                       AS poma_1l_pts,\n"
"       sum(coalesce(f.CLINTRIAL_BASELINE,0))                          AS trial_baseline,\n"
"       sum(coalesce(f.CLINTRIAL_FOLLOWUP,0))                          AS trial_followup,\n"
"       sum(CASE WHEN f.CLINTRIAL_BASELINE=1 OR f.CLINTRIAL_FOLLOWUP=1 THEN 1 ELSE 0 END) AS trial_any\n"
"FROM poma1l JOIN f USING (PATID);"),
 ("gap",""),
 ("sec", "Honest limits"),
 ("amber", "Clinical-trial participation in claims is itself imperfectly captured (trial dx/procedure/revenue codes, spec Tab 46) — "
  "an on-trial patient with the study drug fully masked may carry no trial code at all, so this is a lower bound. Report it "
  "alongside the Q2 transplant breakdown and the Q5 look-back for a fuller non-naive picture."),
 ])

# ---------- Q5 ----------
qsheet("Q5 POMA & pharmacy benefit", "375623",
 "Q5 — POMA patients and continuous pharmacy benefit",
 "\"Do POMA patients have continuous pharmacy benefit (not just medical)? These cases could hide prior LEN/THAL first-line exposure outside observable pharmacy claims.\"",
 [
 ("sec", "Short answer (see the 'Optum coverage' tab for the full validation)"),
 ("green", "The premise that a patient could have medical-but-not-pharmacy coverage does not really apply to Optum: membership "
  "requires BOTH benefits, so every cohort patient has pharmacy coverage and oral LEN/THAL fills are visible as NDC "
  "claims (given those NDCs are in the study's Tab 41 code list). Combined with the baseline-therapy exclusion "
  "(Criterion 3, which already screens medical AND pharmacy claims for prior MM therapy), a delivered POMA-1L patient "
  "cannot be hiding an observable-window oral first-line agent. The only genuine gap is exposure BEFORE the 6-month look-back."),
 ("gap",""),
 ("sec", "Confirmatory query — pharmacy-benefit continuity + extended LEN/THAL look-back"),
 ("p", "Even though Optum guarantees pharmacy benefit, you can prove it per-patient and push the look-back as far back as each "
  "patient's enrollment allows, to quantify the true residual:"),
 ("p", "Table names below follow the repo's config_prompts.R: CDM sources are read via cdm_src(), which resolves to the "
  "quarterly tables when USE_QUARTERLY_TABLES=TRUE — e.g. cdm_src('rx') → <cdm>.t_rx_2025q2, "
  "cdm_src('member_cont_enrollment') → <cdm>.t_member_cont_enrollment_2025q2. LEN/THAL NDCs come from the study's own "
  "therapy code list (cl_mma_codelist.csv), the same source the pipeline's mm_therapy_codes view uses."),
 ("sql",
"WITH poma1l AS (\n"
"  SELECT DISTINCT cast(PATID AS string) PATID FROM <work>.LOT_LONG\n"
"  WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'POMA')\n"
"),\n"
"idx AS (SELECT cast(PATID AS string) PATID, INDEX_DATE FROM <work>.ELIG_COH_FINAL),\n"
"-- LEN/THAL NDCs from the study MM-therapy codelist (cl_mma_codelist), 11-digit normalized\n"
"len_thal AS (\n"
"  SELECT DISTINCT lpad(regexp_replace(CL_CODE,'[^0-9]',''),11,'0') AS ndc\n"
"  FROM <ref>.cl_mma_codelist\n"
"  WHERE upper(CL_CODE_TYPE)='NDC' AND upper(CL_MED_ABBR) IN ('LENA','THAL')\n"
"),\n"
"-- longest continuous pre-index enrollment span per patient (proxy for observable history)\n"
"enr AS (\n"
"  SELECT cast(PATID AS string) PATID, min(ELIGEFF) first_cov, max(ELIGEND) last_cov\n"
"  FROM <cdm>.t_member_cont_enrollment_2025q2 GROUP BY PATID     -- = cdm_src('member_cont_enrollment')\n"
"),\n"
"-- earliest LEN/THAL pharmacy fill (any time observable)\n"
"early_oral AS (\n"
"  SELECT cast(r.PATID AS string) PATID, min(cast(r.FILL_DT AS date)) first_len_thal\n"
"  FROM <cdm>.t_rx_2025q2 r                                        -- = cdm_src('rx')\n"
"  JOIN len_thal t\n"
"    ON lpad(regexp_replace(coalesce(cast(r.NDC AS string),''),'[^0-9]',''),11,'0') = t.ndc\n"
"  GROUP BY r.PATID\n"
")\n"
"SELECT count(*)                                                            AS poma_1l_pts,\n"
"       sum(CASE WHEN datediff(i.INDEX_DATE, e.first_cov) > 183 THEN 1 ELSE 0 END) AS obs_history_gt_6mo,\n"
"       sum(CASE WHEN o.first_len_thal < date_sub(i.INDEX_DATE,183) THEN 1 ELSE 0 END) AS early_len_thal_pre_baseline\n"
"FROM poma1l p JOIN idx i USING (PATID)\n"
"             JOIN enr e USING (PATID)\n"
"             LEFT JOIN early_oral o USING (PATID);"),
 ("gap",""),
 ("sec", "Honest limits"),
 ("amber", "'early_len_thal_pre_baseline' finds prior oral exposure that sits before the 6-month exclusion window — that is exactly "
  "the residual blind spot, and it is measurable. What remains truly unobservable is any therapy before a patient's first "
  "Optum enrollment date; report obs_history_gt_6mo so Julia can see how many POMA-1L patients even have enough pre-index "
  "history for the look-back to be meaningful."),
 ])

print("Q2-Q5 sheets built")

# ======================================================================
# SHEET — Method & data sources
# ======================================================================
ws = sheet("Method & data sources", "808080")
widths(ws, {"A": 3, "B": 116})
title_block(ws, "Method & data sources", "Provenance for every answer in this workbook.", ncols=2, color="404040")
r = 4
def md(text, fillc=WHITE, bold=False, sz=10, h=None, color=TXT):
    global r
    ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=2)
    c = ws.cell(r, 2, text); c.font = font(sz, bold, color); c.alignment = WRAP
    if fillc != WHITE: c.fill = fill(fillc)
    if h: ws.row_dimensions[r].height = h
    r += 1
md("Data access", "404040", True, 11, 18, WHITE)
md("The patient-level data (Optum CDM) lives in Databricks (hive_metastore, schema clnprw_optum). This repository — the "
   "one this workbook was built from — contains program specifications, code, and synthetic test fixtures ONLY; no real "
   "patient rows. Every 'needs warehouse run' item ships with the exact query so it can be run where the data lives.", GREY, h=58)
md("")
md("The LOT engine used for the Q1 journeys", "404040", True, 11, 18, WHITE)
md("jun_21_2026/engine is a documented, spec-faithful re-implementation of the line-of-therapy algorithm "
   "(MAP → LOT1 → SCT → LOT1-end → LOT2-5). Its README describes it as a verification oracle, not the production engine "
   "(production is Databricks SQL on hive_metastore). It reproduces the hand-derived golden traces in "
   "engine/fixtures/expected/TRACE.md. We ran it on six illustrative synthetic patients (reserved ID range 9000000000+) "
   "to produce the journeys on the Q1 tabs, so those journeys are the algorithm's real output, not mock-ups.", GREY, h=76)
md("")
md("Files cited in this workbook", "404040", True, 11, 18, WHITE)
cites = [
 ("Optum coverage / Q5", "docs/Part 3/Program Spec/studypoppage_validated.csv — DATA_SOURCE, CE_b, Criterion 3 (MM_bl_agents), Criterion 5"),
 ("Optum coverage", "Apr 18 2026/Optum - Business Rules/optum business rules.pdf — member enrollment & continuous enrollment tables, join legend"),
 ("Q3 / Q4 (build design)", "docs/Part 3/Program Spec/studypoppage_validated.csv — ELIG_COH, MM_baseline_other/Criterion 7, CT_part/Criterion 9"),
 ("Q2 / Q3 / Q4 (existing SQL)", "apr_30_2026/lot1_studyteam_qs.R — POMA-at-1L other-cancer (Q1a), payer (Q1b), clinical-trial (Q1c), journey-example picker (Q3)"),
 ("Q1 journeys", "jun_21_2026/engine/ (run_engine.R, map/lot1/sct/lot_end/lot_long.R), engine/fixtures/expected/TRACE.md, jun_21_2026/README.md"),
 ("Q1 journeys (reproduce)", "Questions/July 5 2026/patient_journey_examples/ — committed inputs, engine outputs, generator + README (one-command reproduce)"),
 ("Questions", "Questions/July 5 2026/questiond jul 5.pdf — the source chat"),
 ("This workbook (reproducible)", "Questions/July 5 2026/build_workbook.py — regenerates this .xlsx from the committed journey bundle (openpyxl); no hidden state"),
]
for tag, f in cites:
    prow(ws, r, ["", f"[{tag}]  {f}"], start=1, wrap=True, sz=9, fills=[WHITE, LBLUE2], heights=30)
    ws.column_dimensions["A"].width = 3
    r += 1
md("")
md("Prepared 2026-07-05. Counts flagged 'needs warehouse run' should be executed against the live cohort before sharing "
   "figures externally; this workbook fixes the method and the queries, not the final numbers.", AMBER, False, 9, 34)

# ======================================================================
wb.remove(wb["Sheet"])
wb.save(OUT)
print("SAVED:", OUT)
print("sheets:", wb.sheetnames)

