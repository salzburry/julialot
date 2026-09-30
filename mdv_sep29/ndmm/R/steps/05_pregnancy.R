# Pregnancy or childbirth anywhere in the study period.
#

# Every code_type the scan below reads: a diagnosis by MDV disease code or
# ICD-10, and a procedure (a delivery, a caesarean) by receipt code on the act
# table. The Optum list's ICD procedure, HCPCS and revenue types have no MDV
# column to meet; a pregnancy.csv row typed anything else is loaded, joined,
# and matches nothing - the patient is kept and no error is raised. Named here
# so the guard and the scan cannot drift apart.
NDMM_PREG_CODE_TYPES <- c("DISEASECODE", "ICD10", "RECEIPTCODE")

build_ndmm_preg_codes <- function(con) {
  src <- load_codelist_csv("pregnancy.csv", c("code_type", "code"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREG_CODES} AS
    SELECT upper(trim(code_type)) AS code_type,
           {mdv_code_sql('code')} AS code
    FROM {src}
    WHERE code_type IS NOT NULL AND trim(code_type) <> ''
      -- Blank after normalising too, or a punctuation-only row matches every
      -- claim whose code is missing (mdv_code_sql).
      AND {mdv_code_sql('code')} IS NOT NULL
  "))
  # A code type no source produces is a rule that cannot fire. Every other named
  # thing in this package stops the run when it matches nothing - the belantamab
  # abbreviation, the index-excluded agents, the MM-adjacent labels - and this
  # code list is held to the same rule. The file is production and can be
  # re-issued, so an Optum-typed delivery code would otherwise be silent.
  # Before the code types: whether any code survived normalising at all.
  # load_codelist_csv counts raw rows, and the view above drops rows whose code
  # is blank or punctuation-only - so a file carrying one row of 'HCPCS,---'
  # is a nonempty file and an empty code list. Every candidate would then get
  # NO_PREGNANCY = 1 and the exclusion would be off with nothing to show for
  # it. The type check below cannot catch that: it reads this same view, and
  # an empty view has no wrong types in it.
  n <- db_q(con, glue("SELECT count(*) AS N FROM {NDMM_PREG_CODES}"))
  if (as.numeric(n[[1]][1]) == 0)
    stop("pregnancy.csv has rows but no usable codes: every one is blank or ",
         "punctuation-only once non-alphanumerics are stripped. The exclusion ",
         "would match nothing and every candidate would pass it.", call. = FALSE)

  want <- paste(sprintf("'%s'", NDMM_PREG_CODE_TYPES), collapse = ", ")
  bad <- db_q(con, glue("
    SELECT code_type, count(*) AS n
    FROM {NDMM_PREG_CODES}
    WHERE code_type NOT IN ({want})
    GROUP BY code_type ORDER BY code_type"))
  if (nrow(bad))
    stop("pregnancy.csv carries code type(s) no MDV source produces: ",
         paste0(bad$code_type, " (", bad$n, " code(s))", collapse = ", "),
         ".\nThey would match nothing and the exclusion would keep those ",
         "patients silently. The scan emits ",
         paste(NDMM_PREG_CODE_TYPES, collapse = ", "),
         "; retype the rows.",
         call. = FALSE)
  invisible(TRUE)
}

# Distinct NDMM-candidate PATIDs with a pregnancy or childbirth record - a
# confirmed diagnosis, or a delivery procedure - anywhere in the study period.
# Restricted to NDMM LOT1 candidates up front, so the work runs on cohort
# records only.
#
# Confirmed diagnoses only, as everywhere in this build: a suspected pregnancy
# is a test being ordered, not a pregnancy. A diagnosis is dated to the first
# of its claim month.
build_ndmm_pregnancy_patids <- function(con) {
  keep <- glue("d.CONFIRMED = 1
        AND d.DX_MONTH BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_EVENTS} AS
    WITH dx AS (
      SELECT DISTINCT m.PATID, m.DX_MONTH AS event_dt
      FROM {ndmm_dx_join(NDMM_PREG_CODES, 'c.code AS matched_code', keep)} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON m.PATID = l1.PATID
    ),
    act AS (
      SELECT DISTINCT a.PATID, a.ACT_DT AS event_dt
      FROM ({mdv_act_select()}
      ) a
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON a.PATID = l1.PATID
      INNER JOIN {NDMM_PREG_CODES} p
              ON p.code_type = 'RECEIPTCODE' AND p.code = a.RECEIPTCODE
      WHERE a.ACT_DT BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    )
    SELECT DISTINCT PATID, event_dt FROM dx
    UNION
    SELECT DISTINCT PATID, event_dt FROM act
  "))
  # Two readers - the exclusion below and the window counter - so it is
  # materialised rather than left a view, or Spark rescans both MDV sources
  # once per reader.
  checkpoint(con, "NDMM_PREGNANCY_EVENTS")
  # The exclusion, unchanged: distinct patients with a matched claim anywhere in
  # the study period. It reads the dated view rather than repeating the scan, so
  # the window this criterion applies and the window the review table prices
  # cannot drift - which is the failure a second copy of this scan would invite.
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_PATIDS} AS SELECT DISTINCT PATID FROM {NDMM_PREGNANCY_EVENTS}"))
}
