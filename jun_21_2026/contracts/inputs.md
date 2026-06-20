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
- **NDC normalization (the rule).** `normalized_code` for `code_system = 'NDC'`
  is `lpad(regexp_replace(raw_code, '[^0-9]', ''), 11, '0')` — strip non-digits,
  then **left-zero-pad to 11**. Leading zeros are preserved (string, never
  numeric). A raw NDC that is not 10–11 digits after stripping is a
  **rejected record** (not silently matched).
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

## canonical_medical — medical claims (HCPCS / CPT / NDC)

Obeys the **medical runout** rule (never pushed out).

| column | type | req | notes |
|---|---|---|---|
| patient_id | string | required | |
| service_date | date | required | claim service date |
| raw_proc_code | string | nullable | physician/outpatient procedure |
| raw_bill_proc_code | string | nullable | institutional billed procedure |
| raw_ndc | string | nullable | medical NDC (J-code drugs etc.) |
| normalized_code | string | nullable | normalized per code_system |
| code_system | string | nullable | {HCPCS, CPT, NDC} |
| day_supply | int | required | imputed (default 28) where absent — see medical day-supply param |
| place_of_service | string | nullable | |
| claim_status | string | nullable | |
| reversal_status | string | nullable | |
| source_table, source_record_id | string | req/rec | lineage |
| data_vintage | string | required | |

- **Uniqueness:** (patient_id, service_date, normalized_code, code_system, source_record_id).
- **Duplicate resolution:** within (patient_id, normalized_code, service_date) keep **max day_supply, then min normalized_code** (deterministic; matches current dedup).

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
