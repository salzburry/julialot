# Reference material

| file | what it is |
|---|---|
| `MDV_Ovarian_Cancer_Business_Rules.md` | A colleague's MDV ovarian cancer business rules, transcribed from photographs of screens 1–4 of 5 on 29 September 2026. Screen 5 was not photographed. The source document is labelled Proprietary / CSI Internal Only; keep this inside the organisation. It is where this port takes MDV's table names, column names and value codes from. `../MDV_RULES.md`, section 6, says what was taken from it and what was not |

## The search for other MDV documentation

On 29 September 2026 every other repository this GitHub account can reach was
searched for MDV material:

- **Repositories:** salzburry/omop-temp, rwdplatform, prosrdap, prog_score,
  optum_mc, rwddataproduct, codingtool, century, phuseprivacy, qcagent,
  mtppi_new, ttereobust, roberthcc, dlbclrdap, cdmconv, flupredict, and
  phuse-org/Advanced-Data-Privacy-Methods-to-RWD.
- **Scope:** every branch, the full history, and text inside PDFs, Office
  files and zip archives.
- **Terms:** `mdv`, `medical data vision`, `clnprw_mdv`, `nyugaikbn`,
  `utagaiflg`, `ff1data`, `actdata`, `diseasedata`, `receiptcode`,
  `datamonth`, `JMDC_MDV`, `DPC` and others.

**Nothing was found.** There is no data dictionary, no table or column
names, no code list, no MDV-reading code, and no MDV-to-OMOP mapping. The only
MDV text was copies of the LOT porting guide (the same file as
`../lot/PORTING.md`, and an earlier draft of it) inside an uploaded zip in
omop-temp. Nothing was copied from there: the guide is already in this folder.

So the columns `../MDV_RULES.md` marks **(confirm)** stay unconfirmed until
someone checks them against the MDV data dictionary itself. They are the birth
year, the FF1 discharge outcome, an ICD-10 column, and the care setting and
days supplied on `actdata`.
