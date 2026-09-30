# Synthetic MDV: planted patients, each one there for a rule, and the answers
# the cohort build must give for them.
#
# Every code here is invented - disease codes 9xxxxxx, receipt codes 6xxxxxxxx
# and 15xxxxxxx - and so is every patient. The shapes are MDV's as the OC
# business rules describe them (reference/MDV_Ovarian_Cancer_Business_Rules.md):
# t_<table>_2026q2 in clnprw_mdv_all_use, datamonth as yyyyMM, nyugaikbn 1/2,
# utagaiflg, cancerflg, FF1 episodes. Types are left to DuckDB's sniffing, so
# datamonth and fromdate arrive as integers and actdate as a DATE - the build
# has to read both.
#
# write_mdv_fixture(dir) writes the tables and the code lists; EXPECTED holds
# what the suites assert.

.rows <- function(...) do.call(rbind, lapply(list(...), function(r)
  as.data.frame(r, stringsAsFactors = FALSE)))

mdv_fixture <- function() {
  pat <- list(); dx <- list(); act <- list(); ff1 <- list()
  P  <- function(id, sex, birth) pat[[length(pat) + 1L]] <<-
    list(patientid = id, sex = sex, birthyearmonth = birth)
  # datamonth yyyyMM; inout 1 outpatient, 2 inpatient; from yyyyMMdd
  DX <- function(id, month, code, inout = 1, suspect = 0, cancer = 1,
                 from = NA, icd = NA) dx[[length(dx) + 1L]] <<-
    list(patientid = id, datamonth = month, nyugaikbn = inout,
         diseasecode = code, icd10code = icd, utagaiflg = suspect,
         cancerflg = cancer, fromdate = from)
  A  <- function(id, date, code, inout = 1, days = NA) act[[length(act) + 1L]] <<-
    list(patientid = id, actdate = date, receiptcode = code, nyugaikbn = inout,
         kaisu = days)
  F1 <- function(id, start, end, first = 0, chemo = 1, outcome = 1)
    ff1[[length(ff1) + 1L]] <<- list(patientid = id, ff1startdate = start,
      ff1enddate = end, cancerfirstflg = first, chemotherapyflg = chemo,
      taiintenki = outcome)

  MM <- 9000001; PCL <- 9000002; BREAST <- 9100001; COLON <- 9100002
  PLASMACYTOMA <- 9100003; PREG_DX <- 9200001; TRIAL <- 9300001
  APAP <- 610000001; BORT <- 620000001; LEN <- 620000002; DARA <- 620000003
  CARF <- 620000004; BELA <- 620000005; DEX <- 620000006; MELP <- 620000007
  IDECEL <- 620000008; DELIVERY <- 150000001; AUTO <- 150000002; ALLO <- 150000003
  # Listed on cl_mma_codelist.csv only (.listed_only_codes(), in .LISTED_ONLY
  # order): panobinostat is the sixth.
  PANO <- 629000006

  # P01 in. Outpatient months 2019-03 and 2019-05 (two apart). Index at the
  # first bortezomib, 2019-04-10. Later: an autologous transplant, and an
  # outpatient lenalidomide prescription with days supplied.
  P("P01", 1, 195403)
  A("P01", "2018-01-10", APAP)
  DX("P01", 201903, MM); DX("P01", 201905, MM)
  A("P01", "2019-04-10", BORT); A("P01", "2019-04-10", DEX, days = 4)
  A("P01", "2019-04-12", LEN, days = 21); A("P01", "2019-04-17", BORT)
  A("P01", "2019-05-10", LEN, days = 21)
  A("P01", "2019-09-01", AUTO, inout = 2); A("P01", "2019-09-08", MELP, inout = 2)
  A("P01", "2019-09-10", AUTO, inout = 2)
  A("P01", "2020-03-01", APAP)

  # P02 in. One inpatient record inside an FF1 episode of first cancer with
  # chemotherapy - qualifies under every inpatient reading. Inpatient daily
  # lenalidomide, then an outpatient prescription.
  P("P02", 2, 196005)
  A("P02", "2019-01-15", APAP)
  DX("P02", 202006, MM, inout = 2, from = 20200612)
  F1("P02", "2020-06-10", "2020-06-25")
  A("P02", "2020-06-15", BORT, inout = 2)
  A("P02", "2020-06-15", LEN, inout = 2, days = 1)
  A("P02", "2020-06-16", LEN, inout = 2, days = 1)
  A("P02", "2020-06-17", LEN, inout = 2, days = 1)
  A("P02", "2020-06-26", LEN, days = 21)

  # P03 in. Inpatient record whose fromdate is outside the patient's only FF1
  # episode: inpatient by nyugaikbn, not by the FF1 readings.
  P("P03", 1, 195001)
  A("P03", "2018-06-01", APAP)
  DX("P03", 202001, MM, inout = 2, from = 20200105)
  F1("P03", "2020-02-01", "2020-02-10")
  A("P03", "2020-01-20", DARA)

  # P04 out at 1: outpatient months five apart.
  P("P04", 2, 195502)
  A("P04", "2018-01-05", APAP)
  DX("P04", 201901, MM); DX("P04", 201906, MM)
  A("P04", "2019-07-01", BORT)

  # P05 out at 1: both months suspected (utagaiflg 1).
  P("P05", 1, 195506)
  A("P05", "2018-01-05", APAP)
  DX("P05", 201903, MM, suspect = 1); DX("P05", 201904, MM, suspect = 1)
  A("P05", "2019-04-15", BORT)

  # P06 out at 1: cancerflg 0 on both months.
  P("P06", 1, 195507)
  A("P06", "2018-01-05", APAP)
  DX("P06", 201903, MM, cancer = 0); DX("P06", 201904, MM, cancer = 0)
  A("P06", "2019-04-15", BORT)

  # P07 out at 2: 17 in the diagnosis year.
  P("P07", 2, 200205)
  A("P07", "2018-01-05", APAP)
  DX("P07", 201903, MM); DX("P07", 201904, MM)
  A("P07", "2019-04-15", BORT)

  # P08 out at 6: bortezomib in 2018-06 falls in the baseline of the 2019-03
  # index.
  P("P08", 1, 195008)
  A("P08", "2018-01-02", APAP)
  DX("P08", 201805, MM); DX("P08", 201806, MM)
  A("P08", "2018-06-10", BORT); A("P08", "2019-03-01", BORT)

  # P09 out at 3: diagnosed, never treated.
  P("P09", 2, 195009)
  A("P09", "2018-01-05", APAP)
  DX("P09", 201903, MM); DX("P09", 201904, MM)

  # P10 out at 4: first seen 2019-05, indexed 2019-06-10.
  P("P10", 1, 195010)
  DX("P10", 201905, MM); DX("P10", 201906, MM)
  A("P10", "2019-06-10", BORT)

  # P11 out at 7: inpatient breast cancer in the baseline.
  P("P11", 2, 196011)
  A("P11", "2018-10-01", APAP)
  DX("P11", 201909, BREAST, inout = 2)
  DX("P11", 201911, MM); DX("P11", 201912, MM)
  A("P11", "2020-01-10", BORT)

  # P12 out at 7: outpatient colon cancer in adjacent months in the baseline.
  P("P12", 1, 196012)
  A("P12", "2018-12-01", APAP)
  DX("P12", 201910, COLON); DX("P12", 201911, COLON)
  DX("P12", 201912, MM); DX("P12", 202001, MM)
  A("P12", "2020-02-15", BORT)

  # P13 in: outpatient colon cancer two months apart does not pair. Later an
  # allogeneic transplant.
  P("P13", 1, 196013)
  A("P13", "2018-12-01", APAP)
  DX("P13", 201908, COLON); DX("P13", 201910, COLON)
  DX("P13", 201912, MM); DX("P13", 202001, MM)
  A("P13", "2020-02-15", BORT)
  A("P13", "2021-01-15", ALLO, inout = 2)

  # P14 out at 8: a delivery (an act) in 2018.
  P("P14", 2, 198514)
  A("P14", "2018-01-15", APAP); A("P14", "2018-05-20", DELIVERY, inout = 2)
  DX("P14", 201903, MM); DX("P14", 201904, MM)
  A("P14", "2019-04-20", BORT)

  # P15 out at 9: belantamab (found by its English name) in 2018-01, before
  # the baseline of a 2019-06 index.
  P("P15", 1, 195015)
  A("P15", "2018-01-05", APAP)
  DX("P15", 201801, MM); DX("P15", 201802, MM)
  A("P15", "2018-01-15", BELA)
  A("P15", "2019-06-01", DARA)

  # P16 in: an inpatient solitary plasmacytoma in the baseline is the index
  # disease, not another cancer. Later a CAR-T (a drug, by English name).
  P("P16", 2, 195016)
  A("P16", "2018-12-01", APAP)
  DX("P16", 201911, PLASMACYTOMA, inout = 2)
  DX("P16", 201912, MM); DX("P16", 202001, MM)
  A("P16", "2020-02-01", BORT)
  A("P16", "2021-05-01", IDECEL, inout = 2)

  # P17 in, and dies: an FF1 discharge with outcome 6.
  P("P17", 1, 195017)
  A("P17", "2018-11-01", APAP)
  DX("P17", 201912, MM); DX("P17", 202001, MM)
  A("P17", "2020-01-10", BORT)
  F1("P17", "2021-02-20", "2021-03-01", outcome = 6)

  # P18 in, indexed by carfilzomib found by its English name. Belantamab after
  # the index: on the list passed to lot.
  P("P18", 2, 195018)
  A("P18", "2019-01-10", APAP)
  DX("P18", 202002, MM); DX("P18", 202003, MM)
  A("P18", "2020-03-05", CARF)
  A("P18", "2020-09-01", BELA)

  # P20 in, last seen at discharge 2021-01-20: ENDDATE_CE is that day. FF1
  # without chemotherapy - out under the OC inpatient rule.
  P("P20", 1, 195020)
  A("P20", "2019-12-01", APAP)
  DX("P20", 202101, MM, inout = 2, from = 20210110)
  F1("P20", "2021-01-08", "2021-01-20", chemo = 0)
  A("P20", "2021-01-12", BORT, inout = 2)

  # P21 out at 1: an inpatient record for plasma cell leukemia (not C90.0x)
  # cannot qualify alone.
  P("P21", 2, 195021)
  A("P21", "2018-01-05", APAP)
  DX("P21", 201903, PCL, inout = 2, from = 20190305)
  A("P21", "2019-04-15", BORT)

  # P22 in through the ICD-10 column: a disease code no list carries, with
  # ICD-10 C90.01 on mm_dx.csv. No FF1 episode.
  P("P22", 1, 195022)
  A("P22", "2019-02-01", APAP)
  DX("P22", 202003, 9999999, inout = 2, from = 20200310, icd = "C90.01")
  A("P22", "2020-03-15", LEN, days = 21)

  # P23 in, with a trial diagnosis the month before the MM diagnosis. And
  # dexamethasone in the baseline, which the code list spells ' DEX ': a
  # steroid is not MM therapy, so it neither indexes nor excludes her.
  P("P23", 2, 195023)
  A("P23", "2019-03-01", APAP)
  A("P23", "2019-10-01", DEX, days = 5)
  DX("P23", 202002, TRIAL)
  DX("P23", 202003, MM); DX("P23", 202004, MM)
  A("P23", "2020-04-10", BORT)

  # P24 out at 3: her only MM therapy is panobinostat, which protocol I3 bars
  # from setting the 1L index (NDMM_INDEX_EXCLUDED_ABBRS, pinned PANO|ELOT).
  P("P24", 2, 195024)
  A("P24", "2019-01-10", APAP)
  DX("P24", 202002, MM); DX("P24", 202003, MM)
  A("P24", "2020-03-10", PANO, days = 21)

  # P25 out at 5: recorded dead at an FF1 discharge on 2020-06-12, then an
  # act on 2020-06-15 that would be her index. The death date is kept as
  # recorded, and a 1L start after it fails criterion 5 (NDMM_DEATH_CONFLICTS).
  P("P25", 1, 195025)
  A("P25", "2019-01-15", APAP)
  DX("P25", 202004, MM); DX("P25", 202005, MM)
  F1("P25", "2020-06-01", "2020-06-12", outcome = 6)
  A("P25", "2020-06-15", BORT)

  # P26 out at 3: his only drug on the MM list is dexamethasone, spelled
  # ' DEX ' there. A steroid cannot set the index.
  P("P26", 1, 195026)
  A("P26", "2019-02-01", APAP)
  DX("P26", 202005, MM); DX("P26", 202006, MM)
  A("P26", "2020-06-20", DEX, days = 5)

  # P27 in, and dies five days after the index, at an FF1 discharge. Under a
  # 90-day follow-up requirement criterion 5 caps the window at the death, and
  # the final cohort check must apply the same cap.
  P("P27", 1, 195027)
  A("P27", "2019-03-01", APAP)
  DX("P27", 202006, MM); DX("P27", 202007, MM)
  A("P27", "2020-07-10", BORT)
  F1("P27", "2020-07-11", "2020-07-15", outcome = 6)

  drug <- .rows(
    list(receiptcode = APAP,   receiptname_eng = "Acetaminophen Tablets 200mg"),
    list(receiptcode = BORT,   receiptname_eng = "Bortezomib for Injection 3mg"),
    list(receiptcode = LEN,    receiptname_eng = "Lenalidomide Capsules 5mg"),
    list(receiptcode = DARA,   receiptname_eng = "Daratumumab Intravenous Infusion 100mg"),
    list(receiptcode = CARF,   receiptname_eng = "KYPROLIS (Carfilzomib) for Injection 40mg"),
    list(receiptcode = BELA,   receiptname_eng = "Belantamab Mafodotin for Injection 100mg"),
    list(receiptcode = DEX,    receiptname_eng = "Dexamethasone Tablets 4mg"),
    list(receiptcode = MELP,   receiptname_eng = "Melphalan for Injection 50mg"),
    list(receiptcode = IDECEL, receiptname_eng = "Idecabtagene Vicleucel Suspension"),
    list(receiptcode = PANO,   receiptname_eng = "Panobinostat Lactate Capsules 10mg"))
  list(patient = do.call(rbind, lapply(pat, as.data.frame, stringsAsFactors = FALSE)),
       disease = do.call(rbind, lapply(dx,  as.data.frame, stringsAsFactors = FALSE)),
       act     = do.call(rbind, lapply(act, as.data.frame, stringsAsFactors = FALSE)),
       ff1     = do.call(rbind, lapply(ff1, as.data.frame, stringsAsFactors = FALSE)),
       drug    = drug)
}

# The code lists, in the shapes codelists/README.md describes.
mdv_codelists <- function() {
  list(
    "mm_dx.csv" = .rows(
      list(code_type = "DISEASECODE", code = "9000001", icd10 = "C90.00", label = "multiple myeloma"),
      list(code_type = "DISEASECODE", code = "9000002", icd10 = "C90.10", label = "plasma cell leukaemia"),
      list(code_type = "ICD10",       code = "C90.01",  icd10 = NA,       label = "multiple myeloma in remission")),
    "other_malig.csv" = .rows(
      list(code_type = "DISEASECODE", code = "9100001", icd10 = "C50.9",  tumor_group = "MALIGNANT NEOPLASM OF BREAST"),
      list(code_type = "DISEASECODE", code = "9100002", icd10 = "C18.9",  tumor_group = "MALIGNANT NEOPLASM OF COLON"),
      list(code_type = "DISEASECODE", code = "9100003", icd10 = "C90.30", tumor_group = "SOLITARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION"),
      list(code_type = "DISEASECODE", code = "9100004", icd10 = "D47.2",  tumor_group = "MONOCLONAL GAMMOPATHY"),
      list(code_type = "DISEASECODE", code = "9100005", icd10 = "C90.10", tumor_group = "PLASMA CELL LEUKEMIA NOT HAVING ACHIEVED REMISSION"),
      list(code_type = "DISEASECODE", code = "9100006", icd10 = "C90.20", tumor_group = "EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION"),
      list(code_type = "DISEASECODE", code = "9100007", icd10 = "C79.51", tumor_group = "SECONDARY MALIGNANT NEOPLASM OF BONE")),
    "pregnancy.csv" = .rows(
      list(code_type = "DISEASECODE", code = "9200001", label = "delivery"),
      list(code_type = "RECEIPTCODE", code = "150000001", label = "vaginal delivery")),
    "clintrial.csv" = .rows(
      list(code_type = "DISEASECODE", code = "9300001", label = "clinical trial examination")),
    "cl_mma_codelist.csv" = .rows(
      list(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = "620000001", CL_MEDICATION_FULL = "bortezomib",   CL_MED_CLASS = "PI",      CL_MED_ABBR = "BORT", CL_ROUTE = "INJ"),
      list(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = "620000002", CL_MEDICATION_FULL = "lenalidomide", CL_MED_CLASS = "IMID",    CL_MED_ABBR = "LEN",  CL_ROUTE = "ORAL"),
      list(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = "620000003", CL_MEDICATION_FULL = "daratumumab",  CL_MED_CLASS = "CD38",    CL_MED_ABBR = "DARA", CL_ROUTE = "INJ"),
      list(CL_CODE_TYPE = "NAME_ENG",    CL_CODE = "%carfilzomib%", CL_MEDICATION_FULL = "carfilzomib", CL_MED_CLASS = "PI",   CL_MED_ABBR = "CARF", CL_ROUTE = "INJ"),
      list(CL_CODE_TYPE = "NAME_ENG",    CL_CODE = "%belantamab%",  CL_MEDICATION_FULL = "belantamab mafodotin", CL_MED_CLASS = "BCMA", CL_MED_ABBR = "BELA", CL_ROUTE = "INJ"),
      # Spelled with the spaces a hand-edited list carries: the steroid
      # drop has to compare it trimmed, the way it is selected.
      list(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = "620000006", CL_MEDICATION_FULL = "dexamethasone", CL_MED_CLASS = "STEROID", CL_MED_ABBR = " DEX ", CL_ROUTE = "ORAL"),
      list(CL_CODE_TYPE = "NAME_ENG",    CL_CODE = "%melphalan%",   CL_MEDICATION_FULL = "melphalan",   CL_MED_CLASS = "ALKYLATOR", CL_MED_ABBR = "MELP", CL_ROUTE = "INJ"),
      list(CL_CODE_TYPE = "NAME_ENG",    CL_CODE = "%pomalidomide%", CL_MEDICATION_FULL = "pomalidomide", CL_MED_CLASS = "IMID",   CL_MED_ABBR = "POM",  CL_ROUTE = "ORAL")),
    # The rest of the LOT engine's code lists. Its rollup needs 20 agents and
    # its code list 20 rows before it believes the lists loaded, so the agents
    # no planted patient takes are listed under receipt codes no act carries.
    "cl_mma_rollup.csv" = .lot_rollup(),
    "permissible_subs.csv" = .rows(
      list(original_med = "DARA", substitute_med = "DARASC")),
    "cl_sct_codelist.csv" = .rows(
      list(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = "150000002",   SCT_TYPE = "AUTO"),
      list(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = "150000003",   SCT_TYPE = "ALLO"),
      list(CL_CODE_TYPE = "NAME_ENG",    CL_CODE = "%vicleucel%", SCT_TYPE = "CAR-T")))
}

# Twenty-one agents for the rollup: the eight the planted patients take or
# name, and thirteen only listed. Classes match cl_mma_codelist.csv's, which
# the LOT engine checks.
.LOT_AGENTS <- list(
  c("BORT", "bortezomib", "PI"), c("LEN", "lenalidomide", "IMID"),
  c("DARA", "daratumumab", "CD38"), c("DARASC", "daratumumab sc", "CD38"),
  c("CARF", "carfilzomib", "PI"), c("BELA", "belantamab mafodotin", "BCMA"),
  c("MELP", "melphalan", "ALKYLATOR"), c("POM", "pomalidomide", "IMID"),
  c("THAL", "thalidomide", "IMID"), c("IXA", "ixazomib", "PI"),
  c("ELOT", "elotuzumab", "SLAMF7"), c("ISA", "isatuximab", "CD38"),
  c("PANO", "panobinostat", "HDAC"), c("SELI", "selinexor", "XPO1"),
  c("TEC", "teclistamab", "BCMA"), c("ELRA", "elranatamab", "BCMA"),
  c("TAL", "talquetamab", "GPRC5D"), c("CYC", "cyclophosphamide", "ALKYLATOR"),
  c("DOXO", "doxorubicin", "ANTHRACYCLINE"), c("BEND", "bendamustine", "ALKYLATOR"),
  c("VEN", "venetoclax", "BCL2"))
.LISTED_ONLY <- c("DARASC", "THAL", "IXA", "ELOT", "ISA", "PANO", "SELI", "TEC",
                  "ELRA", "TAL", "CYC", "DOXO", "BEND", "VEN")

.lot_rollup <- function() do.call(rbind, lapply(.LOT_AGENTS, function(a)
  data.frame(CL_MEDICATION_FULL = a[2], CL_MED_CLASS = a[3], CL_MED_ABBR = a[1],
             MONOMAINTENANCE = if (a[1] %in% c("LEN", "BORT")) "YES" else "NO",
             DUALMAINTENANCEWITH = NA,
             CONDITIONING = if (a[1] == "MELP") "YES" else "NO",
             USED_FOR_OTHER_CANCERS = "NO", stringsAsFactors = FALSE)))

.listed_only_codes <- function() do.call(rbind, lapply(seq_along(.LISTED_ONLY), function(i) {
  a <- .LOT_AGENTS[[which(vapply(.LOT_AGENTS, `[`, "", 1) == .LISTED_ONLY[i])]]
  data.frame(CL_CODE_TYPE = "RECEIPTCODE", CL_CODE = sprintf("6290000%02d", i),
             CL_MEDICATION_FULL = a[2], CL_MED_CLASS = a[3], CL_MED_ABBR = a[1],
             CL_ROUTE = if (a[1] %in% c("THAL", "IXA", "PANO", "SELI", "CYC", "VEN")) "ORAL" else "INJ",
             stringsAsFactors = FALSE)
}))

write_mdv_fixture <- function(dir, vintage = "2026q2", schema = "clnprw_mdv_all_use") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  fx <- mdv_fixture()
  map <- c(patient = "patientdata", disease = "diseasedata", act = "actdata",
           ff1 = "ff1data", drug = "m_drug")
  for (k in names(map))
    utils::write.csv(fx[[k]], file.path(dir, sprintf("%s.t_%s_%s.csv", schema,
                                                     map[[k]], vintage)),
                     row.names = FALSE, na = "")
  cl <- file.path(dir, "codelists")
  dir.create(cl, showWarnings = FALSE)
  lists <- mdv_codelists()
  lists[["cl_mma_codelist.csv"]] <- rbind(lists[["cl_mma_codelist.csv"]],
                                          .listed_only_codes())
  for (f in names(lists))
    utils::write.csv(lists[[f]], file.path(cl, f), row.names = FALSE, na = "")
  invisible(list(tables = dir, codelists = cl))
}

# What the cohort build must say about these patients.
EXPECTED <- list(
  attrition = c(22, 21, 18, 17, 16, 15, 13, 12, 11),
  cohort = c("P01", "P02", "P03", "P13", "P16", "P17", "P18", "P20", "P22", "P23",
             "P27"),
  index  = c(P01 = "2019-04-10", P02 = "2020-06-15", P03 = "2020-01-20",
             P13 = "2020-02-15", P16 = "2020-02-01", P17 = "2020-01-10",
             P18 = "2020-03-05", P20 = "2021-01-12", P22 = "2020-03-15",
             P23 = "2020-04-10", P27 = "2020-07-10"),
  # who dies, on the FF1 discharge date as recorded
  death  = c(P17 = "2021-03-01", P27 = "2020-07-15"),
  mm_dx  = c(P01 = "2019-03-01", P02 = "2020-06-01", P22 = "2020-03-01"),
  # criterion 1 alone, by reading (NDMM_MM_DX_RULES)
  dx_rules = c("as configured" = 22,
               "inpatient: nyugaikbn alone (the Optum rule)" = 22,
               "inpatient: inside an FF1 episode" = 20,
               "inpatient: FF1 first cancer with chemotherapy (the OC rule)" = 19,
               "suspected diagnoses included" = 23,
               "cancerflg not required" = 23)
)
