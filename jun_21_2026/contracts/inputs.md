# Canonical input contracts (DRAFT)

The **source-system-agnostic, Spark-native** core reads only these canonical
entities. A source adapter (Optum first) produces them as views over physical
tables. Core SQL must never reference a physical (Optum) table or column name.

Status: **draft for engineering + clinical review.** Column sets are derived from
the current Optum-bound pipeline and must be parity-checked against the live
schema during Increment 1B before anything depends on them.

## Shared conventions (apply to every entity)

- **Identity & lineage.** Every row carries `patient_id`, `source_table`, and
  `source_record_id` so any canonical row traces back to its physical claim.
- **Raw + normalized together.** Code-bearing rows keep both `raw_code` and
  `normalized_code` (+ `code_system`) for auditability — normalization is never
  destructive.
- **NDC (require validated 11-digit).** The canonical layer requires an NDC
  already in **11-digit** form (`normalized_code` = the 11 digits, leading zeros
  preserved as a string). A bare **10-digit** value is **ambiguous** — which
  package segment (4-4-2 / 5-3-2 / 5-4-1) is missing its leading zero depends on
  the source's segment format — so the canonical layer does **not** guess:
  segment-aware 10→11 conversion is the **source adapter's** responsibility, from
  the source's known segment format. A non-11-digit NDC is a **rejected record**
  (not silently padded or matched).
  - **Validator limitation (Increment 1B decision).** The canonical validator
    confirms `normalized_code` *is* 11 digits; it deliberately does **not** verify
    the raw→normalized conversion, so an adapter that converts a 10-digit NDC to
    the **wrong** 11-digit value would still pass this check. Before 1B the adapter
    contract must close this with **one** of: (a) an authoritative 11-digit source
    field (no conversion); (b) a source **segment-format** field + a validated
    segment-aware converter; or (c) a retained `conversion_method` lineage field
    **plus per-format test vectors** the converter must reproduce. Until one is
    chosen, raw→normalized correctness is **not** guaranteed by this layer.
- **HCPCS/CPT normalization.** Strip non-alphanumeric, uppercase. `code_system`
  distinguishes `HCPCS` vs `CPT`.
- **Null/invalid dates.** A required date that is null or unparseable makes the
  row a **rejected record**; rejected rows are reported (counts + sample), never
  silently dropped, and excluded from core inputs.
- **Reversals / voids.** `claim_status` and `reversal_status` are carried so the
  adapter (not core) decides reversal handling per the documented policy; a
  reversed/void claim is flagged, not deleted, so counts reconcile.
- **Duplicates.** Each entity declares its uniqueness key and a deterministic
  duplicate-resolution rule (below). De-dup is deterministic (no random choice).
- **Data vintage.** Every row carries `data_vintage` (the source snapshot id /
  Optum quarter) so the source-data version axis is attributable.

The adapter emits a **validation report before core runs**: schema conformance,
uniqueness, null rates, invalid dates, domain-value checks, and NDC/HCPCS
normalization collisions (two raw forms normalizing to the same code).

---

## canonical_medical — medical claims, ONE ROW PER CODE (HCPCS / CPT / NDC)

Obeys the **medical runout** rule (never pushed out). A medical claim that
carries more than one code (e.g. a procedure code *and* an NDC) becomes **one
canonical row per code**, with `source_code_field` recording which physical field
it came from — so the single `normalized_code`/`code_system` is never ambiguous.
This unifies the grain with `canonical_diagnosis` / `canonical_procedure`.

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | |
| service_date | date | required | claim service date |
| raw_code | string | required | the source code value |
| normalized_code | string | required | normalized per code_system |
| code_system | string | required | {HCPCS, CPT, NDC} |
| source_code_field | string | required | {proc_cd, bill_proc_cd, ndc} - the physical field |
| day_supply | int | required | imputed (default 28) where absent |
| place_of_service | string | nullable | |
| claim_status | string | nullable | |
| reversal_status | string | nullable | |
| source_table | string | required | lineage |
| source_record_id | string | required | lineage (in the key) |
| data_vintage | string | required | |

- **Uniqueness:** (patient_id, service_date, normalized_code, code_system, source_record_id).
  `source_code_field` is **lineage, not part of the key**: the same physical record
  may carry one code in more than one field (e.g. `PROC_CD` and `BILL_PROC_CD`), and
  those collapse to **one** canonical row so a single billed service is not
  double-counted downstream.
- **Duplicate resolution (deterministic, no random choice):** (1) when one record
  yields the same `normalized_code`+`code_system` from more than one field, keep a
  single row by field precedence **`proc_cd` > `bill_proc_cd` > `ndc`** (the
  surviving row records the winner in `source_code_field`); (2) across records,
  within (patient_id, normalized_code, service_date) keep **max day_supply, then min
  normalized_code**. The validator's key-uniqueness check **enforces** step (1): a
  residual same-key collision (two rows differing only by `source_code_field`) is a
  blocking error, never silently merged.

## canonical_pharmacy — pharmacy (rx) claims (NDC)

Obeys the **pharmacy runout** rule (pushout / reset-without-pushout).

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | |
| service_date | date | required | fill date |
| raw_ndc | string | required | |
| normalized_code | string | required | 11-digit NDC |
| code_system | string | required | constant `NDC` |
| days_supply | int | required | imputed to 28 where null or < 1 |
| claim_status, reversal_status | string | nullable | |
| source_table, source_record_id | string | req/rec | |
| data_vintage | string | required | |

- **Uniqueness:** (patient_id, service_date, normalized_code, source_record_id).
- **Duplicate resolution:** same rule as medical (max days_supply, then min code).

## canonical_diagnosis — diagnosis events

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | |
| event_date | date | required | |
| raw_code, normalized_code | string | required | ICD-9/10-CM |
| code_system | string | required | {ICD9DIAG, ICD10DIAG} |
| source_table, source_record_id, data_vintage | string | req/rec | |

- **Uniqueness:** (patient_id, event_date, normalized_code, code_system, source_record_id).

## canonical_procedure — procedure events (ICD-tagged, for SCT)

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | |
| event_date | date | required | |
| raw_code, normalized_code | string | required | |
| code_system | string | required | {ICD9PROC, ICD10PROC, HCPCS} |
| source_table, source_record_id, data_vintage | string | req/rec | |

- **Uniqueness:** (patient_id, event_date, normalized_code, code_system, source_record_id).

## canonical_enrollment — continuous-enrollment spans

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | |
| span_start | date | required | |
| span_end | date | required | |
| coverage_type | string | nullable | medical / pharmacy where distinguished |
| data_vintage | string | required | |

- **Uniqueness:** (patient_id, span_start, span_end, coverage_type).
- **Semantics:** spans are merged with the configured `gap_days` tolerance by the
  gate modules, not the adapter; the adapter delivers raw spans + the vintage.

## canonical_death — date of death

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | one row per patient |
| death_date | date | required | |
| death_date_source | string | nullable | |
| data_vintage | string | required | |

- **Uniqueness:** patient_id (one row). Used for `OBS_END_DT` capping.

---

## Output contracts

Output entities (`MAP_STACKED`, `LOT1_BASE`, `LOT_LONG`) are specified in
`outputs.md`, including keys, columns, and the intentionally-nondeterministic
fields excluded from the strict comparison.
