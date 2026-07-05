#!/usr/bin/env python3
"""Generate illustrative synthetic archetype fixtures for the LOT engine.
Reserved PATID range (9_000_000_1xx). NOT real cohort data.
Each archetype exercises a journey type Julia asked to see traced."""
import csv, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inputs")
os.makedirs(OUT, exist_ok=True)

# --- codes ---
NDC = {
    "LENA": "11111111111",  # IMID, mono-maintenance
    "BORT": "22222222222",  # PI
    "DARA": "33333333333",  # MAB (anti-CD38)
    "DEX":  "44444444444",  # STEROID (excluded from LOT)
    "POMA": "55555555555",  # IMID (normally later-line)
    "CARF": "66666666666",  # PI
    "ELOT": "77777777777",  # anti-SLAMF7
    "ISAT": "88888888888",  # anti-CD38
}
rollup = [
    ("NDC", NDC["LENA"], "LENA", "IMID", "YES", ""),
    ("NDC", NDC["BORT"], "BORT", "PI", "0", ""),
    ("NDC", NDC["DARA"], "DARA", "MAB", "0", ""),
    ("NDC", NDC["DEX"],  "DEX",  "STEROID", "0", ""),
    ("NDC", NDC["POMA"], "POMA", "IMID", "0", ""),
    ("NDC", NDC["CARF"], "CARF", "PI", "0", ""),
    ("NDC", NDC["ELOT"], "ELOT", "SLAMF7", "0", ""),
    ("NDC", NDC["ISAT"], "ISAT", "MAB", "0", ""),
]
sct_codelist = [
    ("HCPCS", "ALLOCODE", "Allogenic"),
    ("HCPCS", "AUTOCODE", "Autologous"),
    ("HCPCS", "CARTCODE", "CAR-T"),
]

members = []   # patient_id, index_date, obs_end_dt
pharmacy = []  # patient_id, service_date, normalized_code, code_system, days_supply
procedure = [] # patient_id, event_date, normalized_code, code_system

def rx(pid, date, drug, ds=30):
    pharmacy.append((pid, date, NDC[drug], "NDC", ds))
def proc(pid, date, code):
    procedure.append((pid, date, code, "HCPCS"))

# ============ P101: POMA in 1L (simple discontinuation) ============
p = "9000000101"; members.append((p, "2020-01-01", "2022-12-31"))
for d in ("2021-03-01", "2021-03-25", "2021-04-18"):  # POMA continuous MAP
    rx(p, d, "POMA")
rx(p, "2021-03-05", "DEX")                            # steroid (excluded)

# ============ P102: induction triplet + SINGLE autologous SCT + maintenance ============
p = "9000000102"; members.append((p, "2020-06-01", "2023-06-30"))
for d in ("2021-06-01", "2021-06-25", "2021-07-19"): rx(p, d, "LENA")
for d in ("2021-06-05", "2021-06-29"):               rx(p, d, "BORT")
rx(p, "2021-06-03", "DEX")
proc(p, "2021-08-15", "AUTOCODE")                    # single autologous SCT
for d in ("2021-09-15", "2021-10-09", "2021-11-02"): rx(p, d, "LENA")  # maintenance

# ============ P103: TANDEM autologous SCT (two AUTO ~100 days apart) ============
# LENA maintenance runs continuously across both transplants so LOT1 stays open
# through AUTO #2 (otherwise the 2nd AUTO falls after the line ends and is clamped).
p = "9000000103"; members.append((p, "2020-06-01", "2023-06-30"))
for d in ("2021-01-05", "2021-01-29", "2021-02-22", "2021-03-18", "2021-04-11",
          "2021-05-05", "2021-05-29", "2021-06-22", "2021-07-16", "2021-08-09"):
    rx(p, d, "LENA")                                 # continuous LENA (induction + maintenance)
for d in ("2021-01-08", "2021-02-01"):               rx(p, d, "BORT")
rx(p, "2021-01-06", "DEX")
proc(p, "2021-04-01", "AUTOCODE")                    # AUTO #1
proc(p, "2021-07-10", "AUTOCODE")                    # AUTO #2 (100d later -> planned tandem)

# ============ P104: ALLO SCT ends LOT1 -> single-day LOT2 -> next MED line ============
p = "9000000104"; members.append((p, "2020-06-01", "2023-06-30"))
for d in ("2021-03-01", "2021-03-25", "2021-04-15", "2021-05-10"): rx(p, d, "LENA")
rx(p, "2021-03-10", "BORT")
rx(p, "2021-03-05", "DEX")
proc(p, "2021-04-15", "ALLOCODE")                    # allogenic SCT
rx(p, "2021-05-15", "DARA")                          # subsequent line

# ============ P105: later-line CART with CONSOLIDATION therapy around CART ============
p = "9000000105"; members.append((p, "2019-06-01", "2023-12-31"))
# LOT1 induction BORT+LENA
for d in ("2020-01-06", "2020-01-30", "2020-02-23"): rx(p, d, "LENA")
for d in ("2020-01-09", "2020-02-02"):               rx(p, d, "BORT")
rx(p, "2020-01-07", "DEX")
# progression to CART line
proc(p, "2020-09-01", "CARTCODE")                    # CAR-T infusion
rx(p, "2020-09-20", "DARA")                          # consolidation within 45d of CART

# ============ P106: deep progressor LOT1 -> LOT5 (sequential MED lines) ============
p = "9000000106"; members.append((p, "2018-01-01", "2024-12-31"))
lines = [
    ("2018-06-01", ["BORT", "LENA"]),   # LOT1
    ("2019-02-01", ["DARA", "POMA"]),   # LOT2
    ("2019-10-01", ["CARF"]),           # LOT3
    ("2020-06-01", ["ELOT", "POMA"]),   # LOT4
    ("2021-02-01", ["ISAT", "LENA"]),   # LOT5
]
from datetime import date, timedelta
def add(dstr, n):
    y,m,d = map(int, dstr.split("-")); return (date(y,m,d)+timedelta(days=n)).isoformat()
for start, meds in lines:
    for drug in meds:
        # two fills 24 days apart so each drug forms one ~54-day MAP, then a >90d gap to next line
        rx(p, start, drug); rx(p, add(start, 24), drug)
    rx(p, add(start, 2), "DEX")

# --- write ---
def w(name, header, rows):
    with open(os.path.join(OUT, name), "w", newline="") as f:
        wr = csv.writer(f); wr.writerow(header); wr.writerows(rows)

w("members.csv", ["patient_id","index_date","obs_end_dt"], members)
w("pharmacy.csv", ["patient_id","service_date","normalized_code","code_system","days_supply"], pharmacy)
w("medical.csv", ["patient_id","service_date","normalized_code","code_system","day_supply"], [])
w("procedure.csv", ["patient_id","event_date","normalized_code","code_system"], procedure)
w("sct_codelist.csv", ["code_type","code","sct_type"], sct_codelist)
w("rollup.csv", ["code_type","code","med_abbr","med_class","MONOMAINTENANCE","DUALMAINTENANCEWITH"], rollup)
print("wrote fixtures to", OUT)
print("patients:", len(members), "pharmacy rows:", len(pharmacy), "procedures:", len(procedure))
