# What the other repositories say about dataset structure

The first search (`README.md` in this folder) looked for MDV itself and found
nothing. On 30 September 2026 the same repositories were searched again for
dataset structure that could stand in for MDV's missing documentation: data
dictionaries, laboratory tables, and how the house defines myeloma from
electronic health records. `../MDV_RULES.md`, section 5a, is where this is used.

**Still nothing about MDV, or about any Japanese source.** No repository
mentions JLAC10, DPC or JMDC. The MDV lab table's name, its columns and which
hospitals report results still have to come from MDV's data dictionary.

Three things carry over. All three are the house's own work, summarised here
in this folder's words. No vendor document was copied into this folder.

## 1. What an EHR-based myeloma definition measures

**Source:** the variable inventory, `governance/reference/variable_inventory/INVENTORY.yaml`
in salzburry/rwdplatform (the same file is in salzburry/rwddataproduct). Its
multiple myeloma overlay lists 40 variables, drawn from the literature and
checked against PubMed. It is marked reference only: a drafting aid, not a
specification. The registry modules meant to hold them
(`axis/plasma_cell.yaml`, `indication/multiple_myeloma.yaml`) are declared,
empty and unreviewed.

The inventory assumes US EHR-derived data (Flatiron, ConcertAI, COTA) or a
registry. The table sets its variables that bear on finding and describing
NDMM patients beside what MDV would need to supply them.

| variable (inventory name) | what it rests on | on MDV, if the delivery has it |
|---|---|---|
| diagnosis date meeting IMWG criteria (`INDEX_DATE_DIAGNOSIS`) | clonal marrow plasma cells plus a myeloma-defining event: CRAB (calcium, creatinine, haemoglobin, bone lesions) or SLiM (plasma cells of 60% or more, free light chain ratio of 100 or more, more than one MRI lesion) | calcium, creatinine, haemoglobin and free light chains from lab results. The marrow percentage and the imaging findings are reports, unlikely to be structured. The marrow examination, skeletal survey, MRI and PET orders can be seen as billed acts |
| ISS stage (`ISS_STAGE`) | serum beta-2 microglobulin and albumin at diagnosis | two lab results. The inventory notes beta-2 microglobulin is often missing at US community sites |
| R-ISS and R2-ISS | ISS plus LDH plus FISH: del(17p), t(4;14), t(14;16), and 1q21 for R2-ISS | LDH is a lab. FISH is a cytogenetics report: the order may be billed, the result is almost certainly not structured. ISS looks feasible, R-ISS does not |
| isotype (`MM_ISOTYPE`) | electrophoresis and immunofixation | results are often text ("IgG-kappa"), not numbers |
| M-protein, free light chains (`SERUM_M_PROTEIN`, `SERUM_FREE_LIGHT_CHAIN`) | serial results over time | lab results, repeated. These are what an IMWG-style response or progression (`IMWG_RESPONSE`, `RW_PFS`) would be dated from |
| transplant received (`ASCT_RECEIPT`) | the transplant record | the inventory warns that US community networks miss transplants done at outside centres. On MDV the same gap sits between hospitals: a patient referred elsewhere for the transplant has none here |
| transplant eligibility | in RWD, inferred from age and an observed transplant | the same on MDV |
| overall survival | a composite of EHR, social security and obituary deaths in the US | in-hospital deaths only (`../MDV_RULES.md`, section 5, item 6) |

## 2. What a lab table has to give

**Source:** the house engine's lab panel in salzburry/rwdplatform
(`_closest_values_panel` in `platform/engine/stages/clinical.py`), and the
decisions taken for the prostate product's labs (its engine gap `G-LABS`).
It is implemented in both of the engine's languages. Live validation is
still pending.

**Each lab record needs:**

- the patient;
- a test identifier, and a component where one test reports several;
- the value;
- the unit;
- the date the sample was taken and the date the result was reported.

**Rules the house settled:**

- **Date.** A record is dated at the later of its test date and its result
  date.
- **Missing versus Unknown.** A record with no date, no unit, or a zero or
  negative value still shows a test was done. It is Unknown, not Missing, and
  never the chosen value.
- **Unit.** A record is eligible only in the unit the variable names. Units
  are not converted.
- **Choosing one value.** The record nearest the index within a stated window,
  with the tie-breaks written down.

For MDV the same questions go to the data dictionary. Does the lab table carry:

- a JLAC10 code, a local code, or both;
- a test name, which will be in Japanese;
- the value as a number, as text, or both;
- the unit;
- a sample date and a result date;
- the hospital?

The hospital matters on MDV in particular. Only some hospitals send lab
results, so a missing result means "not sent" as often as "not done". Counting
Missing and Unknown per hospital is the first check.

## 3. Profile the test vocabulary before writing a code list

**Source:** `nsclc/Aug_30_2026/sql/09_lab_analyte_vocabulary.sql` in
salzburry/prog_score, and its results file beside it. It was run on Optum
Market Clarity's lab table. No vendor document named the tests, so one scan of
every distinct (code, name, unit) with its patient count became the vocabulary,
and the code lists were written against that.

The scan found four hazards. Each has a myeloma form on MDV:

| hazard found there | the myeloma form of it |
|---|---|
| The specimen was only in the test name. A substring match on "albumin" took serum albumin (g/dL) and urine albumin (mg/dL) together: a thousandfold unit error in one variable | serum and urine M-protein, serum and urine free light chains, and serum and urine immunofixation are all separate tests. A match on "M-protein" or "light chain" mixes them |
| The same quantity was reported two ways, percent and absolute count, and only the unit told them apart | M-protein reported as a concentration (g/dL) and as a percentage of total protein. Kappa, lambda and their ratio are three separate tests |
| Terse codes missed an English-word probe | MDV test names will be Japanese, such as 蛋白分画 (protein fractions), 免疫固定法 (immunofixation) and 遊離L鎖 (free light chains). An English pattern finds none of them. Match on codes and read the unfiltered list |
| Censored values (`<`, `>`) and results stored as text | a free light chain below the detection limit is `<`, and immunofixation is "positive" or "negative" |

**Two further lessons:**

- A fill rate across the whole database is an upper bound on the cohort's.
- The tail of the list is where a second spelling of the same test hides.
  Save every row, not only the most common ones.

**Once the MDV lab table is known,** the equivalent first query is one grouped
count over the cohort's patients:

```sql
-- <lab>, <code>, <name>, <unit>, <hospital> are the dictionary's names, not known yet
SELECT <code>, <name>, <unit>,
       count(*)                        AS n_rows,
       count(DISTINCT <patient key>)   AS n_patients,
       count(DISTINCT <hospital>)      AS n_hospitals
FROM   <lab> l
JOIN   <prefix>NDMM_COHORT c ON c.PATID = <patient key>
GROUP  BY <code>, <name>, <unit>
ORDER  BY n_patients DESC
```

The patient key needs care. The cohort's `PATID` is MDV's hospital-level key,
so the lab table has to be joined on the same key the other MDV tables use.

## One more thing the search shows: Optum has labs too, in another product

prog_score's Optum material (vendor documentation, not copied here) is for
**Optum Market Clarity**, which links EHR data to claims and has a lab result
table coded with LOINC. The Optum build this folder translates reads
**Clinformatics**, which is claims only.

That matters for the comparability decision in `../MDV_RULES.md`, section 5a.
Put a lab-confirmed MDV cohort beside a claims-only Clinformatics cohort, and
two differences are mixed together: the definition and the country. If the
study wants a lab-based definition in both countries, the US side would be
Market Clarity.

## Looked at, not used

**salzburry/qcagent, `OMOP/Oncology_DataMart_DataDictionary.md`.** An internal
oncology mart for Flatiron and COTA. Three of its conventions would suit an
MDV lab or death table if one is built:

- every date carries its precision;
- every missing value carries a reason;
- a death date records its source, ranked.

It says nothing about MDV.

**Not relevant to MDV:**

- salzburry/cdmconv: Optum Market Clarity to OMOP, including lab measurements;
- salzburry/codingtool: LOINC coding;
- salzburry/century: a cohort dictionary builder.

**Not read.** A Flatiron data dictionary in salzburry/prog_score. The house's
vendor policy (rwddataproduct, `governance/vendor_policy.yaml`) says Flatiron's
delivered documentation may not be read by AI.
