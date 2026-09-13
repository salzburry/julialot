#!/usr/bin/env Rscript
# Checks on the dashboard. No Shiny, no browser, no warehouse.
#
#   Rscript dashboard/tests/run_tests.R
#
# Every number the app puts on a page comes from a function in R/ that runs
# without Shiny, which is what makes this possible. app.R is wiring, and the
# last section reads it as text to hold the wiring to the registries.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
  dirname(d)
})
setwd(here)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  # `cond` is evaluated here, not by the caller, so an assertion whose
  # expression raises is a failed assertion rather than a dead run that stops
  # with a stack trace and reports no count at all.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
errs <- function(expr) {
  e <- tryCatch({ force(expr); NULL }, error = conditionMessage)
  if (is.null(e)) NA_character_ else e
}

Sys.setenv(DASH_SOURCE = "synthetic", DASH_PACKAGE_DIR = "../ndmm_study_updated/study223926",
           INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT", OBJECT_PREFIX = "s223926_")
source("global.R")

cat("\nthe dashboard is driven by the package, not by a second copy of it\n")
{
  ok(nrow(DASH_TABLES) == length(unlist(lapply(MODULES, `[[`, "outputs"))),
     "every table the registry declares is a table the dashboard knows")
  ok(all(DASH_TABLES$MODULE %in% names(MODULES)),
     "and each is attributed to the module that writes it")
  # A table with no display spec still appears - as a grid. So a module added
  # to the package is visible without an edit here.
  s <- table_spec("S_SOMETHING_NEW", c("COHORT", "LOT_NUM", "N"))
  ok(identical(s$shape, "grid") && identical(s$keys, c("COHORT", "LOT_NUM")),
     "a table nothing declared is still shown, with the usual keys found")
  ok(isFALSE(s$declared), "and is marked as undeclared rather than pretending")
  ok(all(vapply(PANELS, function(p) p$render %in% PANEL_RENDER, logical(1))),
     "every panel asks for a renderer that exists")
  # A panel reads either this package's tables or the LOT build's, and which
  # one it declares has to match where its table actually comes from. A study
  # panel pointed at a LOT table would be read from the wrong prefix.
  wrong <- Filter(function(p) {
    if (is.na(p$table)) return(FALSE)
    src <- p$source %||% "study"
    if (identical(src, "lot")) !p$table %in% LOT_DASHBOARD_TABLES
    else !p$table %in% c(DASH_TABLES$TABLE, "S_RUN_METADATA")
  }, PANELS)
  ok(length(wrong) == 0,
     paste0("every panel reads a table its declared source actually writes",
            if (length(wrong)) paste0(" [", paste(vapply(wrong, `[[`,
              character(1), "name"), collapse = ", "), "]") else ""))
  ok(all(vapply(PANELS, function(p) (p$source %||% "study") %in% PANEL_SOURCE,
                logical(1))),
     "and declares a source that exists")
  # The two sets do not overlap, so "which build wrote this" is never ambiguous.
  ok(!length(intersect(LOT_DASHBOARD_TABLES, DASH_TABLES$TABLE)),
     "no table is claimed by both builds")
}

cat("\nthe settings map comes from the package's own source\n")
{
  ok(length(SETTING_ENV) > 40, "every setting cfg_defaults() reads is mapped")
  ok(all(names(OPEN_QUESTION_SOURCE) %in% names(SETTING_ENV)),
     "including every open question, so a scenario command can name it")
  ok(identical(unname(SETTING_ENV[["months_as"]]), "MONTHS_AS") &&
       identical(unname(SETTING_ENV[["mm_hosp_position"]]), "MM_HOSP_POSITION"),
     "and the variable it names is the one the package reads")
  # The map is derived. A setting whose env var is renamed in the package must
  # follow here without an edit, and a name invented here must not survive.
  fake <- function() list(made_up = .env_chr("A_NAME_THE_PACKAGE_DOES_NOT_READ", ""))
  ok(!"A_NAME_THE_PACKAGE_DOES_NOT_READ" %in% SETTING_ENV,
     "a variable no cfg_defaults() reads is not in the map")
}

cat("\nscenarios\n")
{
  ok(length(SCENARIOS) == 4, "the synthetic source offers four scenarios")
  ok(all(vapply(SCENARIOS, scenario_is_usable, logical(1))),
     "and all four are complete runs")
  ok(setequal(SCENARIO_DIFFS, c("mm_hosp_position", "claim_status", "months_as",
                                "censor_at_disenrollment")),
     "the settings that differ across them are found, and only those")
  ok(!"pregnancy_window" %in% SCENARIO_DIFFS,
     "a setting every scenario agrees on is not reported as a difference")
  lab <- SCENARIOS[["s223926_q27_"]]$label
  ok(grepl("mm_hosp_position=claim_positions", lab, fixed = TRUE),
     "a scenario is named by what makes it different, not by its prefix")

  # The readings are parsed back setting by setting, with the provenance note
  # kept apart from the value - "2016-01-01" is the value, "upstream, verified"
  # is how it is known.
  r <- parse_readings("months_as=days; study_start=2016-01-01 (upstream, verified); x=1")
  ok(identical(r[["months_as"]]$value, "days") && !nzchar(r[["months_as"]]$note),
     "a plain reading parses to its value")
  ok(identical(r[["study_start"]]$value, "2016-01-01") &&
       identical(r[["study_start"]]$note, "upstream, verified"),
     "and a provenance note is kept out of the value")
  ok(length(parse_readings("")) == 0 && length(parse_readings(NA)) == 0,
     "an empty or missing readings string is no readings, not one bad one")
  # A value containing '=' must survive.
  ok(identical(parse_readings("k=a=b")[["k"]]$value, "a=b"),
     "a value carrying an equals sign is not cut at the first one")

  cmp <- compare_readings(SCENARIOS[["s223926_"]], SCENARIOS[["s223926_q27_"]])
  ok(sum(cmp$DIFFERS) == 1 &&
       cmp$SETTING[cmp$DIFFERS] == "mm_hosp_position",
     "two scenarios differing in one setting differ in exactly one row")
  ok(cmp$SETTING[1] == "mm_hosp_position",
     "and the difference is listed first, not buried among the agreements")
}

cat("\nthe command for a scenario nobody has run\n")
{
  cm <- scenario_command(list(mm_hosp_position = "claim_positions",
                              claim_status = "all"), prefix = "s223926_new_")
  ok(grepl("export OBJECT_PREFIX='s223926_new_'", cm$command, fixed = TRUE),
     "the command sets the prefix the new scenario would write under, quoted")
  ok(grepl("export MM_HOSP_POSITION='claim_positions'", cm$command, fixed = TRUE) &&
       grepl("export CLAIM_STATUS='all'", cm$command, fixed = TRUE),
     "and exports each setting under the name the package reads")
  ok(!length(cm$unsupported), "with nothing unsupported when all are known")
  cm2 <- scenario_command(list(not_a_setting = "x"))
  ok(identical(cm2$unsupported, "not_a_setting"),
     "a setting the package does not have is reported, not silently exported")
}

cat("\nselection: what a viewer can change without a run\n")
{
  sp <- table_spec("S_HCRU_RATES")
  d <- read_table(SRC, "s223926_", "S_HCRU_RATES")
  ok(!is.null(d) && nrow(d) > 0, "a rate table reads back")
  f <- apply_keys(d, sp, list(COHORT = "1L", LOT_NUM = "1", PERIOD = "follow_up"))
  ok(nrow(f) == 3 && all(f$COHORT == "1L"), "selecting on the spec's keys filters")
  ok(nrow(apply_keys(d, sp, list(COHORT = "all"))) == nrow(d),
     "and 'all' filters nothing rather than matching a cohort called all")
  ok(nrow(apply_keys(d, sp, list())) == nrow(d),
     "a key the viewer never touched filters nothing")
}

cat("\nthe suppression floor can be raised and never lowered\n")
{
  sp <- table_spec("S_SAFETY_RATES")
  d <- read_table(SRC, "s223926_", "S_SAFETY_RATES")
  hi <- apply_floor(d, sp, 100000L, package_min_n = 25L)
  ok(all(hi$SUPPRESSED == 1L), "a floor above every stratum withholds every row")
  ok(all(is.na(hi$RATE)) && all(is.na(hi$N_PATIENTS)) && all(is.na(hi$N_AT_RISK)),
     "and takes the count with the values - publishing the n suppresses nothing")
  ok(nrow(hi) == nrow(d),
     "a withheld row is marked, not dropped: absent and suppressed differ")
  # A stratum the package's own floor covers. Every stratum in the synthetic
  # table runs to thousands, so a floor of 1 there suppresses nothing either
  # way and the check would hold nothing. Built here instead.
  small <- data.frame(COHORT = "1L", LOT_NUM = 1L, PERIOD = "follow_up",
                      CONDITION = c("rare", "common"), DOMAIN = "d",
                      ACUTE_CHRONIC = "acute",
                      N_AT_RISK = c(10L, 4000L), N_PATIENTS = c(3L, 900L),
                      N_EVENTS = c(3L, 1200L), PERSON_YEARS = c(4.2, 3100),
                      RATE = c(714.3, 387.1), RATE_LO = c(600, 370),
                      RATE_HI = c(830, 402), stringsAsFactors = FALSE)
  lo <- apply_floor(small, sp, 1L, package_min_n = 25L)
  ok(identical(attr(lo, "floor"), 25L),
     "asking for a floor of 1 applies the package's 25, not the 1")
  ok(lo$SUPPRESSED[1] == 1L && is.na(lo$RATE[1]),
     "so a stratum of 10 is still withheld however low the viewer sets it")
  ok(lo$SUPPRESSED[2] == 0L && !is.na(lo$RATE[2]),
     "and one above the floor is still shown")
  # The floor the viewer asked for is what applies when it is the higher.
  mid <- apply_floor(d, sp, 5000L, package_min_n = 25L)
  ok(identical(attr(mid, "floor"), 5000L),
     "and a viewer raising it above the package's own is honoured")
  ok(sum(mid$SUPPRESSED) > 0 && sum(mid$SUPPRESSED) < nrow(mid),
     "which withholds some rows and not others")
}

cat("\nsummaries\n")
{
  d <- read_table(SRC, "s223926_", "S_DEMOGRAPHICS")
  tb <- tabulate_cat(d, "SEX", min_n = 25L)
  ok(nrow(tb) == 2 && abs(sum(tb$PCT) - 100) < 0.2,
     "a categorical breakdown counts every patient once")
  d2 <- d; d2$SEX[1:5] <- NA
  ok("(Missing)" %in% tabulate_cat(d2, "SEX")$LEVEL,
     "a missing value is a category, not a dropped row")
  tb2 <- tabulate_cat(data.frame(X = c("a", rep("b", 40))), "X", min_n = 25L)
  ok(tb2$SUPPRESSED[tb2$LEVEL == "a"] == 1L && is.na(tb2$N[tb2$LEVEL == "a"]),
     "a level below the floor is withheld")
  s <- summarise_num(d, "AGE_YEARS", min_n = 25L)
  ok(s$N == nrow(d) && !is.na(s$MEDIAN) && s$MIN >= 40 && s$MAX <= 89,
     "a continuous summary reports the stratum it was given")
  s2 <- summarise_num(d[1:3, ], "AGE_YEARS", min_n = 25L)
  ok(s2$SUPPRESSED == 1L && is.na(s2$MEAN),
     "and is withheld when the stratum is under the floor")
}

cat("\nwithholding a cell is not the same as hiding it\n")
# The rules that are easiest to lose: an identifier that reaches the page, a
# cell recoverable by subtraction, a floor that is not applied.
{
  # --- an identifier is dropped whatever case the warehouse returned it in ---
  ok(!"patid" %in% names(drop_identifiers(
       data.frame(patid = "P000001", X = 1, stringsAsFactors = FALSE))),
     "a lower-case patid is an identifier too, and is dropped")
  ok(!"PatId" %in% names(drop_identifiers(
       data.frame(PatId = "P000001", X = 1, stringsAsFactors = FALSE))),
     "...and so is a mixed-case one")
  ok(identical(names(drop_identifiers(
       data.frame(patid = 1, KEEP = 2, clmid = 3))), "KEEP"),
     "...every identifier the warehouse uses, in any case, and nothing else")
  # The two readers have to agree about the same column.
  low <- data.frame(patid = c("A", "B", "A"), X = 1, stringsAsFactors = FALSE)
  ok(identical(population_n(low, list(name = "T", shape = "subject",
                                      id = "PATID")), 2L),
     "the population is counted off that column whatever its case")

  # --- a suppressed level cannot be recovered by subtraction ---
  # 100 patients, 97 in one level and 3 in the other. The caption publishes
  # the stratum size, so withholding only the 3 hides nothing.
  two <- tabulate_cat(data.frame(SEX = c(rep("F", 97), rep("M", 3))),
                      "SEX", min_n = 25L)
  ok(all(two$SUPPRESSED == 1L) && all(is.na(two$N)),
     "one of two levels cannot be withheld alone, so both are")
  three <- tabulate_cat(
    data.frame(G = c(rep("a", 60), rep("b", 37), rep("c", 3))), "G",
    min_n = 25L)
  ok(sum(three$SUPPRESSED) == 2L,
     "a single small level takes the next-smallest with it")
  ok(is.na(three$N[three$LEVEL == "c"]) && is.na(three$N[three$LEVEL == "b"]) &&
       identical(three$N[three$LEVEL == "a"], 60L),
     "...the smallest of the others, so the largest level still publishes")
  ok(sum(three$N, na.rm = TRUE) < 100,
     "...and the published levels no longer add to the stratum")
  none <- tabulate_cat(data.frame(G = c(rep("a", 60), rep("b", 40))), "G",
                       min_n = 25L)
  ok(sum(none$SUPPRESSED) == 0L,
     "where nothing was withheld in the first place, nothing else is")
  both <- tabulate_cat(
    data.frame(G = c(rep("a", 60), rep("b", 3), rep("c", 4))), "G",
    min_n = 25L)
  ok(sum(both$SUPPRESSED) == 2L,
     "two levels already below the floor need no third")

  # --- a suppressed continuous summary does not publish its own count ---
  sn <- summarise_num(data.frame(CCI = c(1, 2, 3, rep(NA, 97))), "CCI",
                      min_n = 25L)
  ok(sn$SUPPRESSED == 1L && is.na(sn$N),
     "three patients with a value is a count of three, and is withheld")
  ok(is.na(sn$N_MISSING),
     "...and so is the number missing, which subtracts to the same thing")
  sn2 <- summarise_num(data.frame(CCI = as.numeric(1:40)), "CCI", min_n = 25L)
  ok(identical(sn2$N, 40L) && !is.na(sn2$MEDIAN),
     "a stratum that clears the floor reports its count and its summary")

  # --- escaping ---
  # The ampersand FIRST, or every other substitution is undone by it: a value
  # of "&lt;script&gt;" would otherwise reach the page as markup.
  ok(identical(html_escape("&lt;script&gt;"), "&amp;lt;script&amp;gt;"),
     "an ampersand is escaped, so an already-escaped value cannot be unescaped")
  ok(identical(html_escape("<b>"), "&lt;b&gt;"), "angle brackets are escaped")
  ok(identical(html_escape('a"b'), "a&quot;b"),
     "and a double quote, which is what closes an attribute")
  ok(identical(html_escape("a'b"), "a&#39;b"), "and a single quote")
  ok(identical(html_escape(NA), ""), "a missing value escapes to nothing")
  ok(!grepl("<script>", html_table(data.frame(X = "<script>alert(1)</script>")),
            fixed = TRUE),
     "a cell value that looks like a script does not reach the page as one")

  # --- a withheld number never reads as a zero ---
  ok(identical(fmt_num(NA_real_, 0), "—"),
     "a withheld cell shows the em dash, not a zero")
  ok(identical(fmt_num(0, 0), "0"), "...and an actual zero shows as one")
  ok(identical(fmt_num(1234, 0), "1,234"), "a count is grouped")
  ok(identical(fmt_num(12.345, 2), "12.35"), "and a rate is rounded")

  # --- the floor's own boundary ---
  sp_r <- table_spec("S_SAFETY_RATES")
  at <- function(n) data.frame(
    COHORT = "1L", LOT_NUM = 1L, PERIOD = "FOLLOWUP", CONDITION = "X",
    N_AT_RISK = as.integer(n), N_EVENTS = 5L, PERSON_YEARS = 10, RATE = 120,
    stringsAsFactors = FALSE)
  ok(is.na(apply_floor(at(24), sp_r, 25L)$RATE[1]),
     "one patient below the floor is withheld")
  ok(!is.na(apply_floor(at(25), sp_r, 25L)$RATE[1]),
     "...and exactly at the floor is published - the rule is at-or-above")

  # --- a comparison needs BOTH sides ---
  a <- at(500); b <- at(30); b$RATE <- 140
  cs <- suppress_comparison(compare_tables(a, b, sp_r, "RATE"), a, b, sp_r,
                            floor_n = 100L)
  ok(is.na(cs$DELTA[1]),
     "a stratum one side of which is under the floor publishes no difference")
  ok(identical(cs$RELEASED[1], 0L),
     "...even though the other side is far above it")

  # --- the bar decisions, without a plot device ---
  rates <- data.frame(
    COHORT = "1L", LOT_NUM = 1L, PERIOD = c("BASELINE", "FOLLOWUP"),
    CONDITION = "NEUTROPENIA", N_AT_RISK = 500L, N_EVENTS = 10L,
    PERSON_YEARS = c(10, 1000), RATE = c(1000, 10), stringsAsFactors = FALSE)
  bd <- stratum_bar_data(rates, sp_r, "CONDITION", "RATE")
  ok(isTRUE(bd$ok) && length(bd$values) == 2L,
     "two strata are two bars")
  ok(identical(sort(bd$values), c(10, 1000)),
     "...each carrying its own rate, and neither their average")
  ok(!any(abs(bd$values - 505) < 1e-9), "...so 505 is never drawn")
  dup <- rbind(rates[1, ], rates[1, ])
  ok(isFALSE(stratum_bar_data(dup, sp_r, "CONDITION", "RATE")$ok),
     "two rows on one stratum are refused, not combined")
  ok(isFALSE(stratum_bar_data(
       transform(rates, RATE = NA_real_), sp_r, "CONDITION", "RATE")$ok),
     "and a selection whose values are all withheld draws nothing")

  sp_lot <- table_spec("LOT_LONG_FINAL")
  lot <- rbind(
    data.frame(PATID = rep(sprintf("B%02d", 1:40), each = 2), LOT_NUM = 1L,
               stringsAsFactors = FALSE),
    data.frame(PATID = rep(sprintf("S%02d", 1:3), each = 2), LOT_NUM = 2L,
               stringsAsFactors = FALSE))
  cb <- count_bar_data(lot, sp_lot, "LOT_NUM", floor_n = 25L)
  ok(isTRUE(cb$ok) && identical(cb$labels, "1"),
     "a line count is drawn for the group that clears the patient floor")
  ok(identical(unname(cb$values), 80L),
     "...counting LINES, which is what a row of that table is")
  ok(identical(cb$patients, 40L),
     "...while the floor was tested on the 40 patients behind them")
  ok(isFALSE(count_bar_data(lot, sp_lot, "LOT_NUM", floor_n = 100L)$ok),
     "and where no group clears it, nothing is drawn")

  # --- a caller that hands in a population is believed over nrow() ---
  sub <- data.frame(PATID = rep("P1", 40), AGE_BAND = "65-74",
                    stringsAsFactors = FALSE)
  sp_d <- table_spec("S_DEMOGRAPHICS")
  ok(all(summarise_subject(sub, sp_d, min_n = 25L, n_population = 1L)$SUPPRESSED == 1L),
     "forty rows for one patient is one patient, and is withheld")
  ok(identical(attr(summarise_subject(sub, sp_d, min_n = 25L,
                                      n_population = 1L), "n_stratum"), 1L),
     "...and the stratum reported is the population, not the row count")

  # --- a count that cannot be read is not a count that cleared the floor ---
  # released() fails closed on an unknown population, and apply_floor() has to
  # decide the same question the same way - they run in different panels.
  unreadable <- function(v) { x <- at(500); x$N_AT_RISK <- v; x }
  ok(is.na(apply_floor(unreadable(NA), sp_r, 25L)$RATE[1]),
     "a row whose denominator is missing publishes no rate")
  ok(is.na(apply_floor(unreadable("<25"), sp_r, 25L)$RATE[1]),
     "...nor one whose denominator arrived as a pre-suppression marker")
  ok(!is.na(apply_floor(unreadable("500"), sp_r, 25L)$RATE[1]),
     "...while a count that reads as a number is still just a number")
  ok(identical(apply_floor(unreadable(NA), sp_r, 25L)$SUPPRESSED[1], 1L),
     "...and the row says it was withheld")

  # --- two readings have to be stratified the same way ---
  ka <- at(500); kb <- ka[, setdiff(names(ka), "PERIOD")]
  cmk <- compare_tables(ka, kb, sp_r, "RATE")
  ok(nrow(cmk) == 0L,
     "a comparison whose two sides carry different keys produces no rows")
  ok(!is.null(attr(cmk, "why")) && grepl("PERIOD", attr(cmk, "why")),
     "...and says which key is on one side only")
  ok(nrow(compare_tables(ka, at(500), sp_r, "RATE")) == 1L,
     "while two readings keyed the same way compare as one row")

  # --- a number that is not a number ---
  ok(identical(fmt_num("n/a", 0), "—"),
     "a value that is not a number reads as withheld, not as zero")
  ok(identical(fmt_num(c(1, NA, 3), 0), c("1", "—", "3")),
     "...and a vector keeps its positions")

  # --- the command a viewer is told to run ---
  # Printed for someone to paste into a shell, so a setting value is a shell
  # injection surface.
  ok(identical(sh_quote("a; rm -rf /"), "'a; rm -rf /'"),
     "a shell metacharacter in a setting is quoted, not passed through")
  ok(identical(sh_quote("a'b"), "'a'\\''b'"),
     "...and an embedded quote closes and reopens rather than escaping the string")
  ok(identical(sh_quote(c("a", "b")), "'a,b'"),
     "a multi-valued setting is one quoted argument")
  sc <- scenario_command(list(months_as = 30, nope = 1), prefix = "s_new_")
  ok(grepl("export OBJECT_PREFIX='s_new_'", sc$command, fixed = TRUE),
     "the command names the prefix the scenario would write under")
  ok(identical(sc$unsupported, "nope"),
     "...and a setting the package has no variable for is reported, not emitted")
  ok(!grepl("nope", sc$command, fixed = TRUE),
     "...and never reaches the command as an export")

  # --- a panel switched off by a typo would be invisible ---
  local({
    old <- Sys.getenv("SHOW_HEADLINE", unset = NA)
    on.exit(if (is.na(old)) Sys.unsetenv("SHOW_HEADLINE") else
              Sys.setenv(SHOW_HEADLINE = old), add = TRUE)
    Sys.setenv(SHOW_HEADLINE = "yes")
    ok(!is.na(errs(panel_enabled(list(name = "headline")))),
       "SHOW_<PANEL> set to anything but TRUE or FALSE stops startup")
    Sys.setenv(SHOW_HEADLINE = "FALSE")
    ok(isFALSE(panel_enabled(list(name = "headline"))), "...FALSE hides it")
    Sys.unsetenv("SHOW_HEADLINE")
    ok(isTRUE(panel_enabled(list(name = "headline"))), "...and unset shows it")
  })

  # --- a run that did not finish is not a scenario ---
  ok(isTRUE(scenario_is_usable(SCENARIOS[[1]])), "a complete run is usable")
  for (st in c("failed", "started", "")) {
    ok(isFALSE(scenario_is_usable(utils::modifyList(SCENARIOS[[1]],
                                                    list(state = st)))),
       paste0("...and a run recorded as '", st, "' is not"))
  }

  # --- path segments ---
  ok(!safe_segment("../../etc"), "a path segment cannot climb out of the root")
  ok(!safe_segment(".."), "...nor be the climb itself")
  ok(!safe_segment("a/b"), "...nor carry a separator")
  ok(!safe_segment(""), "...nor be empty")
  ok(!safe_segment(c("a", "b")), "...nor be two things")
  ok(!safe_segment(".hidden"), "...nor start with a dot")
  ok(safe_segment("s223926_") && safe_segment("S_TTE"),
     "while an ordinary prefix and table name are fine")

  # --- the run a prefix holds is the NEWEST one it recorded ---
  src_md <- list(read = function(prefix, table) data.frame(
    RUN_ID = c("older", "newer"),
    UPDATED_AT = c("2026-01-01 00:00:00", "2026-06-01 00:00:00"),
    stringsAsFactors = FALSE))
  ok(identical(newest_metadata_row(src_md, "p_")$RUN_ID, "newer"),
     "a prefix re-run reports its latest run, not whichever row came back first")
  src_one <- list(read = function(prefix, table) data.frame(
    RUN_ID = "only", stringsAsFactors = FALSE))
  ok(identical(newest_metadata_row(src_one, "p_")$RUN_ID, "only"),
     "...and a table with no timestamp still reports its run")

  # --- the released table is preferred over the raw one ---
  rel_name <- names(SUPPRESSION_SPEC_NAMES())[1]
  if (!is.null(rel_name)) {
    base <- sub("_RELEASE$", "", rel_name)
    src_rel <- list(read = function(prefix, table)
      data.frame(WHICH = if (endsWith(table, "_RELEASE")) "release" else "raw",
                 stringsAsFactors = FALSE))
    ok(identical(read_table(src_rel, "p_", base, TRUE)$WHICH, "release"),
       "a table with a released form is read from that form")
    ok(identical(read_table(src_rel, "p_", base, FALSE)$WHICH, "raw"),
       "...and only a caller that asks for the raw one gets it")
    ok(identical(attr(read_table(src_rel, "p_", base, TRUE), "table_source"),
                 "release"),
       "...with the page able to say which it was given")
  } else {
    ok(FALSE, "the package declares no suppression spec to test the preference against")
  }
}

cat("\nKaplan-Meier\n")
{
  # Hand-worked: 5 subjects, events at 1 and 3, censored at 2, 4, 5.
  #   t=1: 5 at risk, 1 event -> 4/5 = 0.8
  #   t=3: 3 at risk, 1 event -> 0.8 * 2/3 = 0.5333
  k <- km_estimate(c(1, 2, 3, 4, 5), c(1, 0, 1, 0, 0))
  ok(nrow(k) == 2, "one row per event time, not per subject")
  ok(abs(k$SURV[1] - 0.8) < 1e-9, "the first step is right")
  ok(abs(k$SURV[2] - 0.5333333) < 1e-6,
     "and the second accounts for the censoring between them")
  ok(k$N_RISK[2] == 3, "with the risk set reduced by the censored subject")
  # S(3) is 0.533, so this curve never reaches 0.5 and has no median - which is
  # not the same thing as its last event time.
  ok(is.na(km_median(k)),
     "a curve that never reaches 0.5 has no median, and does not report its last event")
  # One that does: 4 subjects, events at 1 and 2 -> 0.75 then 0.5.
  k2 <- km_estimate(c(1, 2, 3, 4), c(1, 1, 0, 0))
  ok(abs(k2$SURV[2] - 0.5) < 1e-9 && abs(km_median(k2) - 2) < 1e-9,
     "and one that reaches exactly 0.5 has its median at that time")
  ok(nrow(km_estimate(numeric(0), numeric(0))) == 0,
     "no subjects is an empty curve, not an error")
  ok(all(k$LOWER <= k$SURV + 1e-9) && all(k$UPPER >= k$SURV - 1e-9),
     "the band contains the estimate")
  ok(all(k$LOWER >= 0) && all(k$UPPER <= 1), "and stays inside 0 and 1")
  # Against survival:: where it is installed. Not required - the estimator is
  # written out precisely so the app needs no such package - but held to it
  # wherever the check can run.
  if (requireNamespace("survival", quietly = TRUE)) {
    set.seed(1); n <- 300
    tt <- round(stats::rexp(n, 1 / 12), 3); ev <- as.integer(stats::runif(n) < 0.6)
    mine <- km_estimate(tt, ev)
    sf <- survival::survfit(survival::Surv(tt, ev) ~ 1)
    theirs <- summary(sf, times = mine$TIME)$surv
    ok(max(abs(mine$SURV - theirs)) < 1e-8,
       "and agrees with survival::survfit to 1e-8 over 300 subjects")
  } else {
    cat("  SKIP   survival:: is not installed, so the cross-check did not run\n")
  }
}

cat("\nwhat a panel is allowed to show\n")
# One preparation layer answers four questions for every renderer: which rows
# are the analysis set, how many patients that is, whether that clears the
# floor, and what to say when it does not.
{
  # --- grain: a row is not always a patient ---
  lot <- data.frame(
    PATID = rep(sprintf("P%02d", 1:10), each = 3),
    LOT_NUM = rep(1:3, times = 10),
    LOT_START_TYPE = "MED", LOT_BASE_MEDS = "BORT LEN",
    LOT_MED_CNT = 2L, LOT_BASE_LENGTH = 100L,
    stringsAsFactors = FALSE)
  sp_lot <- table_spec("LOT_LONG_FINAL", names(lot))
  ok(identical(table_grain(sp_lot), "line"),
     "LOT_LONG_FINAL is one row per patient and LINE, and says so")
  ok(identical(population_n(lot, sp_lot), 10L),
     "...so ten patients with three lines each is ten patients, not thirty")
  pp <- prepare_panel(lot, sp_lot, floor_n = 25L)
  ok(!pp$released,
     "...and at a floor of 25 that stratum is withheld, where 30 rows would have passed")
  h <- panel_table_html(lot, sp_lot, floor_n = 25L)
  ok(grepl("Withheld", h, fixed = TRUE) && !grepl("10 patients", h, fixed = TRUE),
     "...the caption withholds, and does not print the count it is withholding")
  ok(grepl("fewer than 25", h, fixed = TRUE),
     "...naming the threshold instead - the one number the floor protects is the count")
  ok(!grepl("30 patients", h, fixed = TRUE),
     "...and never calls a count of lines a count of patients")
  # 40 patients clear the floor, and the caption still separates the two counts.
  lot2 <- data.frame(
    PATID = rep(sprintf("P%03d", 1:40), each = 3),
    LOT_NUM = rep(1:3, times = 40),
    LOT_START_TYPE = "MED", LOT_BASE_MEDS = "BORT LEN",
    LOT_MED_CNT = 2L, LOT_BASE_LENGTH = 100L, stringsAsFactors = FALSE)
  h2 <- panel_table_html(lot2, table_spec("LOT_LONG_FINAL", names(lot2)),
                         floor_n = 25L)
  ok(grepl("40 patients", h2, fixed = TRUE) && grepl("120 lines", h2, fixed = TRUE),
     "a released line table reports both counts, each named for what it is")
  ok(identical(population_n(data.frame(), sp_lot), 0L),
     "no rows is no patients, not an error")
  # Each LEVEL's floor is on its patients too. 100 patients and 120 lines: a
  # category holding three lines from each of ten patients is thirty rows and
  # ten people, and it was published as N = 30.
  # Three levels, so the withheld one is not given away by the other: with
  # two, the ten patients would be 100 minus 90 and secondary suppression
  # rightly takes the second level as well.
  lot3 <- rbind(
    data.frame(PATID = sprintf("A%03d", 1:80), LOT_NUM = 1L,
               LOT_START_TYPE = "MED", stringsAsFactors = FALSE),
    data.frame(PATID = rep(sprintf("B%02d", 1:10), each = 3), LOT_NUM = 1:3,
               LOT_START_TYPE = "SCT_AUTO", stringsAsFactors = FALSE),
    data.frame(PATID = sprintf("C%02d", 1:10), LOT_NUM = 1L,
               LOT_START_TYPE = "CART", stringsAsFactors = FALSE))
  sp3 <- table_spec("LOT_LONG_FINAL", names(lot3))
  ok(identical(population_n(lot3, sp3), 100L), "the selection is 100 patients")
  sm <- summarise_subject(lot3, sp3, min_n = 25L, n_population = 100L)
  auto <- sm[sm$VARIABLE == "LOT_START_TYPE" & sm$LEVEL == "SCT_AUTO", ]
  ok(nrow(auto) == 1L && identical(auto$SUPPRESSED, 1L) && is.na(auto$N),
     "a category of thirty lines resting on ten patients is withheld")
  med <- sm[sm$VARIABLE == "LOT_START_TYPE" & sm$LEVEL == "MED", ]
  ok(nrow(med) == 1L && identical(med$SUPPRESSED, 0L) && identical(med$N, 80L),
     "...while eighty lines from eighty patients publish, counted as lines")
  tc <- tabulate_cat(lot3, "LOT_START_TYPE", min_n = 25L, id_col = "PATID")
  ok(identical(tc$SUPPRESSED[tc$LEVEL == "SCT_AUTO"], 1L),
     "...and the level test itself counts distinct patients when told the id column")
  # Without an identifier the floor can only be on rows. On lot3 that is not
  # the same as "SCT_AUTO publishes": CART's ten rows are withheld, and with one
  # level gone secondary suppression takes the next smallest. So the fallback
  # is shown on a table with no such neighbour.
  tr <- tabulate_cat(data.frame(X = c(rep("a", 30), rep("b", 40))), "X", min_n = 25L)
  ok(all(tr$SUPPRESSED == 0L) && identical(sort(tr$N), c(30L, 40L)),
     "...falling back to rows only where no identifier is given")

  # A survival curve is one cohort and one line. The same 25 patients with a
  # 1L row (event at month 10) and a 2L row (event at month 1) are 50 rows
  # and one population, and a curve over both is nobody's curve.
  both <- rbind(
    data.frame(PATID = sprintf("E%02d", 1:25), COHORT = "1L", LOT_NUM = 1L,
               TTE_ELIGIBLE = 1L, TTNT_MONTHS = 10, TTNT_EVENT = 1L,
               stringsAsFactors = FALSE),
    data.frame(PATID = sprintf("E%02d", 1:25), COHORT = "2L", LOT_NUM = 2L,
               TTE_ELIGIBLE = 1L, TTNT_MONTHS = 1, TTNT_EVENT = 1L,
               stringsAsFactors = FALSE))
  ok(identical(population_n(both, table_spec("S_TTE", names(both))), 25L),
     "25 patients in two cohorts are 25 patients")
  ok(identical(strata_of(both), c("COHORT", "LOT_NUM")),
     "...and the selection spans two cohorts and two lines, which a curve cannot pool")
  ok(!length(strata_of(both[both$COHORT == "1L", ])),
     "...while one cohort is one stratum and may be drawn")
  ok(grepl("multi <- strata_of(pp$rows)", paste(readLines("app.R", warn = FALSE),
                                                collapse = "\n"), fixed = TRUE),
     "and the survival panel asks before it draws")
  # A table carrying neither an identifier nor a count cannot be shown to
  # clear the floor, and is withheld rather than published.
  blind <- data.frame(LEVEL = c("a", "b"), STUFF = c(1, 2),
                      stringsAsFactors = FALSE)
  sp_blind <- list(name = "X", shape = "subject", id = "PATID",
                   categorical = "LEVEL")
  ok(is.na(population_n(blind, sp_blind)),
     "a table with no identifier and no count has no countable population")
  ok(!prepare_panel(blind, sp_blind, floor_n = 25L)$released,
     "...so it is withheld: an uncountable population has not cleared the floor")

  # --- the analysis set ---
  tte <- rbind(
    data.frame(PATID = sprintf("E%02d", 1:25), COHORT = "1L", LOT_NUM = 1L,
               TTE_ELIGIBLE = 1L, TTNT_MONTHS = 10, TTNT_EVENT = 1L,
               stringsAsFactors = FALSE),
    data.frame(PATID = sprintf("N%02d", 1:25), COHORT = "1L", LOT_NUM = 1L,
               TTE_ELIGIBLE = 0L, TTNT_MONTHS = 1, TTNT_EVENT = 1L,
               stringsAsFactors = FALSE))
  sp_tte <- table_spec("S_TTE", names(tte))
  pt <- prepare_panel(tte, sp_tte, floor_n = 25L, purpose = "tte")
  ok(identical(pt$n, 25L),
     "a survival panel is the 25 eligible patients, not all 50 rows in the table")
  km <- km_estimate(pt$rows$TTNT_MONTHS, pt$rows$TTNT_EVENT)
  ok(nrow(km) == 1 && abs(km$TIME[1] - 10) < 1e-9,
     "...so its first event is at month 10, not the month 1 of an excluded patient")
  ok(identical(attr(km, "n"), 25L), "...over 25 subjects")
  # The same table, described rather than analysed, keeps everyone.
  ok(identical(prepare_panel(tte, sp_tte, floor_n = 25L)$n, 50L),
     "a descriptive summary of the same table still covers the whole cohort")
  # Fails closed where the flag is absent.
  ok(nrow(analysis_rows(tte[, setdiff(names(tte), "TTE_ELIGIBLE")], sp_tte,
                        "tte")) == 0,
     "a table with no eligibility flag yields no analysis set, not all of it")

  # --- an event-free cohort is a result ---
  free <- km_estimate(rep(c(4, 8, 12), times = 10), rep(0L, 30))
  ok(nrow(free) == 0 && identical(attr(free, "n"), 30L) &&
       abs(attr(free, "follow_up") - 12) < 1e-9,
     "thirty patients with no event carry their size and their follow-up")
  st <- km_steps(free)
  ok(nrow(st) == 2 && all(abs(st$SURV - 1) < 1e-9) &&
       abs(max(st$TIME) - 12) < 1e-9,
     "...and draw a flat curve across the follow-up actually observed")
  ok(nrow(km_steps(km_estimate(numeric(0), numeric(0)))) == 0,
     "no subjects at all is still an empty curve")
  k1 <- km_estimate(c(1, 2, 3, 4, 5), c(1, 0, 1, 0, 0))
  s1 <- km_steps(k1)
  ok(abs(s1$SURV[1] - 1) < 1e-9 && abs(s1$TIME[1]) < 1e-9,
     "a curve with events starts at 1")
  ok(abs(max(s1$TIME) - 5) < 1e-9,
     "...and is carried to the last follow-up, not to the last event at 3")

  # --- finished rates are not averaged across strata ---
  rates <- data.frame(
    COHORT = "1L", LOT_NUM = 1L, PERIOD = c("BASELINE", "FOLLOWUP"),
    CONDITION = "NEUTROPENIA", DOMAIN = "HAEM", ACUTE_CHRONIC = "ACUTE",
    N_AT_RISK = c(500L, 500L), N_EVENTS = c(10L, 10L),
    PERSON_YEARS = c(10, 1000), RATE = c(1000, 10),
    stringsAsFactors = FALSE)
  sp_r <- table_spec("S_SAFETY_RATES", names(rates))
  L <- stratum_label(rates, sp_r, "CONDITION")
  ok(length(unique(L)) == 2L && all(grepl("PERIOD=", L, fixed = TRUE)),
     "two periods of one condition are two labelled bars, not one")
  ok(!any(grepl("^NEUTROPENIA$", L)),
     "...and neither bar is left carrying the bare condition name")
  # The old reading. 505 is the mean of 1000 and 10 - neither rate, and not
  # the pooled 19.8 either.
  ok(abs(mean(rates$RATE) - 505) < 1e-9,
     "the average of the two rates is 505, which is what the chart used to draw")
  ok(!any(abs(c(1000, 10) - 505) < 1e-9),
     "...and 505 is not either stratum's rate")

  # --- the floor, in the places that skipped it ---
  fl <- effective_floor(100L, 25L)
  ok(identical(fl, 100L), "the viewer's floor is taken where it is higher")
  ok(identical(effective_floor(5L, 25L), 25L),
     "...and the package's where the viewer's would lower it")
  ok(identical(effective_floor(NA, 25L), 25L),
     "...and an unusable viewer floor falls back to the package's")
  ok(!released(30, 100) && released(100, 100) && !released(NA, 100),
     "release is one test: at or above the floor, and never on an unknown count")

  small <- data.frame(COHORT = "1L", LOT_NUM = 1L, PERIOD = "FOLLOWUP",
                      CONDITION = "X", DOMAIN = "H", ACUTE_CHRONIC = "A",
                      N_AT_RISK = 30L, N_EVENTS = 5L, PERSON_YEARS = 10,
                      RATE = 120, stringsAsFactors = FALSE)
  smb <- small; smb$RATE <- 140
  cm <- compare_tables(small, smb, sp_r, "RATE")
  ok(nrow(cm) == 1 && abs(cm$DELTA[1] - 20) < 1e-9,
     "the comparison finds the stratum and its difference")
  cs <- suppress_comparison(cm, small, smb, sp_r, floor_n = 100L,
                            package_min_n = 25L)
  ok(is.na(cs$A[1]) && is.na(cs$B[1]) && is.na(cs$DELTA[1]),
     "...and at a floor of 100 a 30-patient stratum shows neither value nor delta")
  ok(identical(cs$RELEASED[1], 0L), "...and says on the row that it was withheld")
  cs2 <- suppress_comparison(cm, small, smb, sp_r, floor_n = 25L,
                             package_min_n = 25L)
  ok(!is.na(cs2$A[1]) && abs(cs2$DELTA[1] - 20) < 1e-9,
     "...while a stratum that clears the floor still compares")
  # No count column at all: withhold rather than publish an untested delta.
  sp_nc <- utils::modifyList(sp_r, list(n_col = NULL))
  nc_a <- small[, setdiff(names(small), "N_AT_RISK")]
  nc_b <- smb[, setdiff(names(smb), "N_AT_RISK")]
  cs3 <- suppress_comparison(compare_tables(nc_a, nc_b, sp_nc, "RATE"),
                             nc_a, nc_b, sp_nc, floor_n = 25L)
  ok(all(is.na(cs3$DELTA)),
     "a comparison with no population to test is withheld, not published")

  # A bar chart of counts withholds a level that rests on too few patients.
  # The count itself is of LINES, which is a legitimate figure - it is the
  # floor that is about patients.
  ok(is.function(plot_count_bars) && is.function(plot_stratum_bars),
     "the bar preparation is a function the tests can drive, not server wiring")
  tiny <- data.frame(PATID = c("A", "B", "C"), LOT_NUM = 1L,
                     LOT_START_TYPE = "MED", stringsAsFactors = FALSE)
  ok(identical(population_n(tiny, table_spec("LOT_LONG_FINAL", names(tiny))), 3L),
     "three patients are three patients however many lines they have")

  # The headline row, through the function the app actually calls.
  att <- data.frame(COHORT = c("1L", "2L"), STEP = 9L,
                    N_REMAINING = c(3L, 400L), stringsAsFactors = FALSE)
  k <- kpi_row_html(att, floor_n = 25L)
  ok(grepl("withheld", k, fixed = TRUE) && grepl("400", k, fixed = TRUE),
     "a three-patient cohort is withheld from the headline row and a large one is not")
  ok(!grepl(">3<", k, fixed = TRUE),
     "...and the three never reaches the page")
  ok(grepl("400", kpi_row_html(att, floor_n = 5L), fixed = TRUE) &&
       grepl("withheld", kpi_row_html(att, floor_n = 5L), fixed = TRUE),
     "a viewer cannot lower the headline floor below the package's own 25")
}

cat("\nthe snapshot job publishes a run, or nothing\n")
source(file.path(here, "jobs", "export_lib.R"))
{
  # --- the export runs under the ROW's settings ---
  row <- list(prefix = "sc_a_", WORK_SCHEMA = "scenario_schema",
              LOT_PREFIX = "scenario_lot_", note = "not a setting",
              MONTHS_AS = "NA")
  e <- scenario_env(row)
  ok(identical(e[["OBJECT_PREFIX"]], "sc_a_"),
     "the row's prefix is what the scenario writes under")
  ok(identical(e[["WORK_SCHEMA"]], "scenario_schema") &&
       identical(e[["LOT_PREFIX"]], "scenario_lot_"),
     "...and every other setting on the row travels with it")
  ok(!"MONTHS_AS" %in% names(e),
     "a blank cell written as NA is not a setting of \"NA\"")
  ok(!"note" %in% names(e),
     "and a lower-case column is documentation, not a setting to export")

  # --- the shipped grid, row by row, through the package's own config ---
  # A grid value the package would refuse is found here rather than on the
  # cluster: ED_DEFINITION takes a comma list of revenue, pos and cpt, and a
  # word such as rev_or_pos is never read.
  grid <- read.csv(file.path(here, "scenarios.csv"), stringsAsFactors = FALSE,
                   check.names = FALSE)
  grid_base <- c(INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT", WORK_SCHEMA = "",
                 PROJECT_WORK_SCHEMA = "", DOMINO_USER_NAME = "",
                 DOMINO_STARTING_USERNAME = "")
  # Through cfg_defaults() and check_settings(): the list settings are read by
  # the first and refused by the second, so both have to run.
  grid_cfg <- function(row) with_env(c(grid_base, scenario_env(row)),
                                     { cfg <- cfg_defaults(); check_settings(cfg); cfg })
  refused <- character(0)
  for (i in seq_len(nrow(grid))) {
    msg <- tryCatch({ grid_cfg(grid[i, ]); NA_character_ },
                    error = function(x) conditionMessage(x))
    if (!is.na(msg)) refused <- c(refused, paste0(grid$prefix[i], ": ", msg))
  }
  ok(!length(refused),
     paste0("every row of the shipped grid is a setting the package accepts",
            if (length(refused)) paste0(" [", paste(refused, collapse = " | "), "]") else ""))
  base_cfg <- grid_cfg(grid[1, ])
  ok(identical(base_cfg$ed_definition, c("revenue", "pos")),
     "...and the base case's emergency-visit definition is the package's own: revenue code or place of service")
  # Where the base case departs from the package's defaults, its description
  # says so by name: a reader comparing it with a plain run has to be told.
  dflt <- with_env(grid_base, cfg_defaults())
  cols <- grep("^[A-Z][A-Z0-9_]*$", names(grid), value = TRUE)
  departs <- cols[vapply(cols, function(k)
    !identical(dflt[[tolower(k)]], base_cfg[[tolower(k)]]), logical(1))]
  ok(length(departs) > 0 && all(vapply(departs, function(k)
       grepl(k, grid$description[1], fixed = TRUE), logical(1))),
     paste0("the base case names every setting on which it departs from the package's defaults (",
            paste(departs, collapse = ", "), ")"))
  # One env for both halves: an export that rebuilt the configuration with only
  # OBJECT_PREFIX changed would read the parent's schema.
  jb <- paste(readLines(file.path(here, "jobs", "build_scenarios.R"),
                        warn = FALSE), collapse = "\n")
  ok(grepl("run_one(grid[i, ], envs[[i]])", jb, fixed = TRUE) &&
       grepl("export_one(r$prefix, envs[[i]])", jb, fixed = TRUE),
     "the build and the export are handed the same settings, not two readings")
  ok(grepl("current_work_schema(con)", jb, fixed = TRUE),
     "...and an unset WORK_SCHEMA is resolved the way the build resolves it")

  # --- an empty read, an absent table and a failed read are three things ---
  con <- structure(list(), class = "fake")
  assign("db_q", function(con, sql)
    if (grepl("EMPTY", sql)) data.frame(A = character(0))
    else if (grepl("GONE", sql)) stop("Table or view not found: GONE")
    else if (grepl("BROKEN", sql)) stop("connection reset by peer")
    else data.frame(A = 1), envir = globalenv())
  ok(identical(read_export(con, "FULL")$state, "ok"), "a table with rows reads ok")
  r_empty <- read_export(con, "EMPTY")
  ok(identical(r_empty$state, "ok") && nrow(r_empty$data) == 0L,
     "a table that legitimately holds no rows is still a successful read")
  ok(identical(read_export(con, "GONE", optional = TRUE)$state, "absent"),
     "a table an unselected module never wrote is absent, not a failure")
  ok(identical(read_export(con, "BROKEN", optional = TRUE)$state, "failed"),
     "...while a read that errored for any other reason is a failure")
  ok(identical(read_export(con, "GONE", optional = FALSE)$state, "failed"),
     "and a table that is NOT optional missing is a failure too")
  rm("db_q", envir = globalenv())

  # --- a snapshot becomes visible whole, or not at all ---
  root <- file.path(tempdir(), paste0("snap_", as.integer(runif(1) * 1e8)))
  dir.create(file.path(root, "sc_a_"), recursive = TRUE)
  writeLines("PATID\nOLD", file.path(root, "sc_a_", "S_TTE.csv"))
  writeLines("RUN_ID\nold_run", file.path(root, "sc_a_", "S_RUN_METADATA.csv"))
  stage <- file.path(root, ".sc_a_.staging")
  dir.create(stage)
  writeLines("RUN_ID\nnew_run", file.path(stage, "S_RUN_METADATA.csv"))
  publish(stage, file.path(root, "sc_a_"), 1L, "sc_a_", "")
  got <- list.files(file.path(root, "sc_a_"))
  ok(identical(sort(got), "S_RUN_METADATA.csv"),
     "publishing replaces the directory whole - the old S_TTE does not survive")
  ok(identical(readLines(file.path(root, "sc_a_", "S_RUN_METADATA.csv"))[2],
               "new_run"),
     "...and what is there is the new run")
  ok(!dir.exists(file.path(root, "sc_a_.previous")),
     "...with no half-swapped directory left beside it")

  # A refresh that never reaches publish() leaves the previous snapshot as it
  # was, under its own identity.
  dir.create(file.path(root, "sc_b_"), recursive = TRUE)
  writeLines("RUN_ID\nold_run", file.path(root, "sc_b_", "S_RUN_METADATA.csv"))
  publish(NULL, file.path(root, "sc_b_"), 0L, "sc_b_", "")
  ok(identical(readLines(file.path(root, "sc_b_", "S_RUN_METADATA.csv"))[2],
               "old_run"),
     "a refresh that produced nothing leaves the older snapshot untouched")
  # The LOT prefix has to be owned by the run whose id the directory will
  # carry, at the moment of the copy: the reader trusts that name.
  assign("db_q", function(con, sql) data.frame(
    RUN_ID = c("old_lot", "new_lot"), STATE = "complete",
    UPDATED_AT = c("2026-01-01", "2026-06-01"), stringsAsFactors = FALSE),
    envir = globalenv())
  ok(!lot_prefix_owner_ok(con, "wk.LOT_BUILD_STATUS", "old_lot"),
     "a LOT prefix rebuilt since the study ran is not copied under the old run's id")
  ok(lot_prefix_owner_ok(con, "wk.LOT_BUILD_STATUS", "new_lot"),
     "...and is copied under the run that owns it now")
  assign("db_q", function(con, sql) stop("no status"), envir = globalenv())
  ok(!lot_prefix_owner_ok(con, "wk.LOT_BUILD_STATUS", "new_lot"),
     "...and a prefix whose ownership cannot be read is not copied at all")
  assign("db_q", function(con, sql) data.frame(
    RUN_ID = "new_lot", STATE = "complete",
    UPDATED_AT = as.POSIXct("2026-06-01 00:00:00", tz = "UTC"),
    stringsAsFactors = FALSE), envir = globalenv())
  ok(lot_prefix_owner_ok(con, "wk.LOT_BUILD_STATUS", "new_lot", "20260601T000000Z"),
     "the build the scenario recorded owns the prefix")
  ok(!lot_prefix_owner_ok(con, "wk.LOT_BUILD_STATUS", "new_lot", "20260101T000000Z"),
     "...and another build of the same run does not, so it is not filed under this scenario's name")
  rm("db_q", envir = globalenv())
  ok(identical(lot_dir_name("new_lot", "20260601T000000Z"), "new_lot.20260601T000000Z") &&
       identical(lot_dir_name("new_lot", ""), "new_lot") &&
       safe_segment(lot_dir_name("new_lot", "20260601T000000Z")),
     "a LOT export is filed by run and build, in one path segment")
  # And the snapshot reader looks in exactly that directory.
  local({
    r2 <- file.path(tempdir(), "snap_builds")
    unlink(r2, recursive = TRUE)
    dir.create(file.path(r2, "lot", "L1.20260601T000000Z"), recursive = TRUE)
    writeLines("PATID,LOT_NUM\nP1,1", file.path(r2, "lot", "L1.20260601T000000Z", "LOT_LONG_FINAL.csv"))
    ss <- snapshot_source(utils::modifyList(DASH_CFG, list(snapshot_dir = r2)))
    ok(!is.null(ss$read_lot("L1", "LOT_LONG_FINAL", "20260601T000000Z")),
       "a snapshot filed by build is read by build")
    ok(is.null(ss$read_lot("L1", "LOT_LONG_FINAL", "20260901T000000Z")) &&
         is.null(ss$read_lot("L1", "LOT_LONG_FINAL", "")),
       "...and another build, or no build, does not read it")
    ok(is.null(ss$read_lot("L1", "LOT_LONG_FINAL", "../x")),
       "...nor can a build stamp climb out of the root")
    unlink(r2, recursive = TRUE)
  })
  # The job pins the build before it reads a table and checks it again after
  # the last one, and it will not export a build that is not complete.
  ok(grepl("pin <- newest_metadata_row(meta_src, prefix)", jb, fixed = TRUE) &&
       regexpr("pin <- newest_metadata_row(", jb, fixed = TRUE) <
         regexpr("for (tb in EXPORT)", jb, fixed = TRUE) &&
       regexpr("for (tb in EXPORT)", jb, fixed = TRUE) <
         regexpr("if (!isTRUE(scenario_is_current(meta_src, scen)))", jb, fixed = TRUE),
     "the job pins the build before the first table and re-checks it after the last, with the reader's own check")
  ok(grepl("if (!scenario_is_usable(scen))", jb, fixed = TRUE),
     "...and exports nothing from a build that is not complete")
  ok(grepl("lot_dir_name(lot_id, lot_version)", jb, fixed = TRUE) &&
       grepl("lot_prefix_owner_ok(con, lot_tbl(\"LOT_BUILD_STATUS\"),\n                                          lot_id, lot_version)", jb, fixed = TRUE),
     "...files LOT tables by build and binds the prefix to that build")
  ok(grepl("if (cached && nzchar(lot_version)) return(reuse())", jb, fixed = TRUE) &&
       regexpr("if (!owner())", jb, fixed = TRUE) < regexpr("if (cached) return(reuse())", jb, fixed = TRUE),
     "...and reuses a run-only directory only while the prefix still belongs to the run")
  ok(grepl("scen <- scenario_from_row(prefix, pin)", jb, fixed = TRUE) &&
       grepl("if (!scenario_wrote(scen, tb)) { not_this_run", jb, fixed = TRUE) &&
       grepl("restrict_to_cohorts(r$data, scen)", jb, fixed = TRUE) &&
       regexpr("scen <- scenario_from_row(prefix, pin)", jb, fixed = TRUE) <
         regexpr("for (tb in EXPORT)", jb, fixed = TRUE),
     "the job exports only the tables the pinned run's metadata says it wrote, and only its cohorts' rows")
  ok(grepl("recorded no modules or no cohorts", jb, fixed = TRUE),
     "...and a run that recorded neither exports nothing")
  ok(grepl("with_env(env, system2(", jb, fixed = TRUE) &&
       !grepl("env = paste0(names(env)", jb, fixed = TRUE),
     "the child build inherits its settings from the process, not from a system2 env= Windows ignores")
  ok(identical(with_env(c(DASH_WITH_ENV_T = "seen"), Sys.getenv("DASH_WITH_ENV_T")), "seen") &&
       !nzchar(Sys.getenv("DASH_WITH_ENV_T")),
     "...and with_env sets them for the call and takes them away after")
  ok(grepl("owner <- function() lot_prefix_owner_ok(", jb, fixed = TRUE) &&
       length(gregexpr("if (!owner())", jb, fixed = TRUE)[[1]]) == 2L,
     "...checked before the copy and again after it, so a rebuild in between is caught")
  ok(grepl("NOT PUBLISHED", jb, fixed = TRUE) &&
       grepl("ex_failed", jb, fixed = TRUE),
     "an export that failed is reported as unpublished, not as zero tables")
  # The emitted string, not the word anywhere in the file.
  ok(grepl('" scenario(s) built and published to "', jb, fixed = TRUE) &&
       !grepl('" scenario(s) built and exported to "', jb, fixed = TRUE),
     "...and the footer claims success only for what actually reached the snapshot")
  unlink(root, recursive = TRUE)
}

cat("\na LOT table is bound to the run the scenario named\n")
# The warehouse source reads LOT tables from a prefix a setting names, and
# nothing in those tables says which run wrote them - LOT_LONG_FINAL has no
# RUN_ID column. So the prefix's build status is what binds them, and it has
# to be read BEFORE the tables rather than a column being filtered where one
# happens to exist.
#
# db_q is replaced for this block: what is under test is which statements are
# issued and what comes back, and there is no connection here.
local({
  asked <- character(0)
  status <- data.frame(RUN_ID = "new_run", STATE = "complete",
                       stringsAsFactors = FALSE)
  lines <- data.frame(PATID = "P1", LOT_NUM = 1L, LOT_START_TYPE = "MED",
                      stringsAsFactors = FALSE)
  assign("db_q", function(con, sql) {
    asked <<- c(asked, sql)
    if (grepl("LOT_BUILD_STATUS", sql, fixed = TRUE)) status else lines
  }, envir = globalenv())
  cfg <- utils::modifyList(DASH_CFG, list(
    source = "warehouse", catalog = "cat", work_schema = "wrk",
    lot_prefix = "lot_"))
  src <- warehouse_source(cfg, con = structure(list(), class = "fake"))

  d <- src$read_lot("new_run", "LOT_LONG_FINAL")
  ok(!is.null(d) && nrow(d) == 1L,
     "the run the prefix actually holds reads its lines")
  ok(any(grepl("LOT_BUILD_STATUS", asked, fixed = TRUE)),
     "...and the build status was read to establish that")

  asked <- character(0)
  ok(is.null(src$read_lot("old_run", "LOT_LONG_FINAL")),
     "a DIFFERENT run reads nothing, where before it got the current lines")
  ok(!isTRUE(src$lot_run_ok("old_run")),
     "...and the source says the run is not bound, so a panel can explain itself")

  # Ownership is the NEWEST row, not any row. The producer keeps every run's
  # status and replaces the output tables in place, so an old completed row
  # beside a new one means the old run's tables are gone.
  status <- data.frame(RUN_ID = c("old_run", "new_run"), STATE = "complete",
                       UPDATED_AT = c("2026-01-01 00:00:00", "2026-06-01 00:00:00"),
                       stringsAsFactors = FALSE)
  ok(is.null(src$read_lot("old_run", "LOT_LONG_FINAL")),
     "a run with a completed row that is no longer the newest owns nothing")
  ok(!is.null(src$read_lot("new_run", "LOT_LONG_FINAL")),
     "...and the newest completed run does")
  # And it is asked again every time, so a rebuild after a yes is seen.
  status <- data.frame(RUN_ID = c("new_run", "newer_run"), STATE = "complete",
                       UPDATED_AT = c("2026-06-01 00:00:00", "2026-07-01 00:00:00"),
                       stringsAsFactors = FALSE)
  ok(is.null(src$read_lot("new_run", "LOT_LONG_FINAL")),
     "a prefix rebuilt after a successful check is refused on the next read")
  ok(isTRUE(lot_status_owner(data.frame(RUN_ID = c("b", "a"), STATE = "complete",
                                        stringsAsFactors = FALSE), "a")),
     "without a timestamp the last row written is the newest")
  ok(!lot_status_owner(data.frame(RUN_ID = "a", STATE = "started",
                                  UPDATED_AT = "2026-01-01",
                                  stringsAsFactors = FALSE), "a"),
     "...and a newest row that is not complete owns nothing either")
  st_a <- data.frame(RUN_ID = "a", STATE = "complete",
                     UPDATED_AT = "2026-06-01 00:00:00", stringsAsFactors = FALSE)
  ok(isTRUE(lot_status_owner(st_a, "a", "x", "20260601T000000Z")) &&
       !lot_status_owner(st_a, "a", "x", "20260101T000000Z"),
     "a recorded build has to match the newest row's stamp")
  ok(!lot_status_owner(data.frame(RUN_ID = "a", STATE = "complete",
                                  stringsAsFactors = FALSE), "a", "x", "20260601T000000Z"),
     "...and a status table with no timestamp cannot vouch for a build at all")
  status <- data.frame(RUN_ID = "new_run", STATE = "complete",
                       stringsAsFactors = FALSE)

  # A prefix mid-rebuild is not a run's numbers either.
  status <- data.frame(RUN_ID = "new_run", STATE = "started",
                       stringsAsFactors = FALSE)
  src2 <- warehouse_source(cfg, con = structure(list(), class = "fake"))
  ok(is.null(src2$read_lot("new_run", "LOT_LONG_FINAL")),
     "a build that has not finished is refused, not read as far as it got")

  # A rebuild landing DURING the read. Ownership was asked once, before the
  # data query, so the replacement rows came back under the old run's name
  # with one status query ever issued - the one that had said yes.
  local({
    n_status <- 0L
    assign("db_q", function(con, sql) {
      if (grepl("LOT_BUILD_STATUS", sql, fixed = TRUE)) {
        n_status <<- n_status + 1L
        return(data.frame(RUN_ID = if (n_status == 1L) "new_run" else "newer_run",
                          STATE = "complete", stringsAsFactors = FALSE))
      }
      lines
    }, envir = globalenv())
    src4 <- warehouse_source(cfg, con = structure(list(), class = "fake"))
    ok(is.null(src4$read_lot("new_run", "LOT_LONG_FINAL")) && n_status == 2L,
       "a prefix rebuilt while its table was being read is refused - ownership is asked after the read as well as before")
  })
  # The same run id, another BUILD. The engine keeps its run id for a
  # session, so the newest row can name this run and still not be the build
  # the scenario read; the scenario's recorded build has to match its stamp.
  status <- data.frame(RUN_ID = "new_run", STATE = "complete",
                       UPDATED_AT = as.POSIXct("2026-06-01 00:00:00", tz = "UTC"),
                       stringsAsFactors = FALSE)
  assign("db_q", function(con, sql)
    if (grepl("LOT_BUILD_STATUS", sql, fixed = TRUE)) status else lines,
    envir = globalenv())
  src5 <- warehouse_source(cfg, con = structure(list(), class = "fake"))
  ok(!is.null(src5$read_lot("new_run", "LOT_LONG_FINAL", "20260601T000000Z")),
     "the build the scenario recorded reads its lines")
  ok(is.null(src5$read_lot("new_run", "LOT_LONG_FINAL", "20260101T000000Z")),
     "...and another build of the same run reads nothing")
  ok(!is.null(src5$read_lot("new_run", "LOT_LONG_FINAL", "")),
     "...while a scenario that recorded no build is bound by id alone")
  ok(isTRUE(src5$lot_run_ok("new_run", "20260601T000000Z")) &&
       !isTRUE(src5$lot_run_ok("new_run", "20260101T000000Z")),
     "and the source says which, so a panel can explain itself")

  # No status table at all: fail closed.
  assign("db_q", function(con, sql)
    if (grepl("LOT_BUILD_STATUS", sql, fixed = TRUE)) stop("no such table")
    else lines, envir = globalenv())
  src3 <- warehouse_source(cfg, con = structure(list(), class = "fake"))
  ok(is.null(src3$read_lot("new_run", "LOT_LONG_FINAL")),
     "a prefix with no build status cannot be bound, so nothing is read from it")
  rm("db_q", envir = globalenv())
})
# The snapshot source keys LOT tables by run directory, so it is bound already.
ok(lot_run_bound(SRC, SCENARIOS[[1]]),
   "a source that binds runs by construction needs no second check")

# And the tables a panel reads still belong to the run the sidebar names.
{
  s1 <- SCENARIOS[[1]]
  ok(isTRUE(scenario_is_current(SRC, s1)),
     "a scenario nothing has rebuilt is still the run the app read")
  moved <- utils::modifyList(s1, list(run_id = "a_previous_run"))
  ok(isFALSE(scenario_is_current(SRC, moved)),
     "...and one whose snapshot now holds a different run is not")
  ok(is.na(scenario_is_current(SRC, utils::modifyList(s1, list(run_id = "")))),
     "a scenario that records no run cannot be said to have moved")
  src_none <- list(read = function(prefix, table) NULL)
  ok(is.na(scenario_is_current(src_none, s1)),
     "...and neither can one whose snapshot has no metadata to read")
  # The read itself, with the snapshot swapped underneath it. The source below
  # serves run A's metadata on the first ask and run B's from then on, which
  # is what a refresh landing mid-render looks like from inside a read.
  local({
    asks <- 0L
    flip <- list(read = function(prefix, table) {
      if (identical(table, "S_RUN_METADATA")) {
        asks <<- asks + 1L
        return(data.frame(RUN_ID = if (asks == 1L) "A" else "B",
                          stringsAsFactors = FALSE))
      }
      data.frame(RATE = 770, stringsAsFactors = FALSE)
    })
    full <- list(modules = names(MODULES), cohorts = COHORT_KEYS)
    sc <- c(list(prefix = "p_", run_id = "A", state = "complete"), full)
    ok(is.null(read_scenario_table(flip, sc, "S_SAFETY_RATES", FALSE)),
       "a table read while its snapshot is being replaced is refused, not shown under the old run")
    steady <- list(read = function(prefix, table)
      if (identical(table, "S_RUN_METADATA"))
        data.frame(RUN_ID = "A", STATE = "complete", stringsAsFactors = FALSE)
      else data.frame(RATE = 770, stringsAsFactors = FALSE))
    ok(identical(read_scenario_table(steady, sc, "S_SAFETY_RATES", FALSE)$RATE, 770),
       "...while a snapshot that is still the same run reads normally")
    ok(is.null(read_scenario_table(steady, c(list(prefix = "p_", run_id = "Z", state = "complete"), full),
                                   "S_SAFETY_RATES", FALSE)),
       "...and one that is a different run from the sidebar's reads nothing")
    # A run that did not finish. Its metadata row matches - it is the newest,
    # under this id and state - and its tables are the previous build's.
    for (st in c("started", "failed", "")) {
      md_st <- list(read = function(prefix, table)
        if (identical(table, "S_RUN_METADATA"))
          data.frame(RUN_ID = "A", STATE = st, stringsAsFactors = FALSE)
        else data.frame(RATE = 120, stringsAsFactors = FALSE))
      sc_st <- c(list(prefix = "p_", run_id = "A", state = st), full)
      ok(is.null(read_scenario_table(md_st, sc_st, "S_SAFETY_RATES", FALSE)),
         paste0("a run recorded as '", st, "' reads no result, though its metadata matches"))
      ok(!is.null(read_scenario_table(md_st, sc_st, "S_RUN_METADATA", FALSE)),
         "...while its metadata - what it set out to do - still reads")
    }
    # The same id, rebuilt. DOMINO_RUN_ID is reused by every build inside one
    # Domino run, so a re-run keeps the id while its state and timestamp move;
    # bound by id alone, the page would show the re-run's rows under the
    # earlier build's settings.
    sc2 <- c(list(prefix = "p_", run_id = "A", state = "complete",
                  updated_at = "2026-09-08 12:00:00"), full)
    md_at <- function(state, at) list(read = function(prefix, table)
      if (identical(table, "S_RUN_METADATA"))
        data.frame(RUN_ID = "A", STATE = state, UPDATED_AT = at,
                   stringsAsFactors = FALSE)
      else data.frame(RATE = 990, stringsAsFactors = FALSE))
    ok(identical(read_scenario_table(md_at("complete", "2026-09-08 12:00:00"),
                                     sc2, "S_SAFETY_RATES", FALSE)$RATE, 990),
       "the build the scenario describes reads")
    ok(is.null(read_scenario_table(md_at("started", "2026-09-09 08:00:00"),
                                   sc2, "S_SAFETY_RATES", FALSE)),
       "a re-run under the same id, still going, reads nothing")
    ok(is.null(read_scenario_table(md_at("complete", "2026-09-09 08:30:00"),
                                   sc2, "S_SAFETY_RATES", FALSE)),
       "...and once it completes, its rows are still not shown under the earlier build's settings")
    ok(isFALSE(scenario_is_current(md_at("complete", "2026-09-09 08:30:00"), sc2)),
       "...which is what the page's guard says too")
    ok(isFALSE(scenario_is_current(md_at("complete", "2026-09-09 08:30:00"),
                                   list(prefix = "p_", run_id = "A"))),
       "and a scenario that recorded no state or timestamp is not the build a row that has them describes - the identity is the whole key")
    # What a run WROTE. A run writes only the modules it selected, for the
    # cohorts it selected, and leaves the rest of the prefix as the previous
    # run left it - so a completed run's prefix can hold a safety table it
    # never wrote, a 2L partition it never built, and a released table from
    # before its raw one was rebuilt.
    ok(identical(table_owner("S_SAFETY_RATES"), "safety") &&
         identical(table_owner("S_SAFETY_RATES_RELEASE"), "release") &&
         is.na(table_owner("S_NOTHING")),
       "a table's owner is the module the registry says writes it")
    part <- c(list(prefix = "p_", run_id = "A", state = "complete"),
              list(modules = c("spine", "cohorts", "attrition", "hcru"), cohorts = "1L"))
    kept <- list(read = function(prefix, table)
      if (identical(table, "S_RUN_METADATA"))
        data.frame(RUN_ID = "A", STATE = "complete", stringsAsFactors = FALSE)
      else if (identical(table, "S_HCRU_RATES"))
        data.frame(COHORT = c("1L", "2L"), RATE = c(120, 990), stringsAsFactors = FALSE)
      else if (identical(table, "S_HCRU_RATES_RELEASE"))
        data.frame(COHORT = c("1L", "2L"), RATE = c(60, 900), stringsAsFactors = FALSE)
      else data.frame(COHORT = "1L", RATE = 120, stringsAsFactors = FALSE))
    ok(is.null(read_scenario_table(kept, part, "S_SAFETY_RATES", FALSE)),
       "a table whose module this run did not select is not read, whatever the prefix holds")
    ok(!scenario_wrote(part, "S_SAFETY_RATES") && scenario_wrote(part, "S_HCRU_RATES") &&
         scenario_wrote(part, "S_RUN_METADATA") &&
         !scenario_wrote(utils::modifyList(part, list(modules = character(0))), "S_HCRU_RATES"),
       "...because the run's own metadata says which modules it ran, and none means nothing")
    h <- read_scenario_table(kept, part, "S_HCRU_RATES", TRUE)
    ok(!is.null(h) && identical(h$COHORT, "1L") && identical(h$RATE, 120),
       "a table this run wrote reads only the rows of the cohorts it built - the retained 2L partition stays out")
    ok(identical(attr(h, "table_source"), "raw"),
       "...and the raw table, because this run did not run release: the released copy is the previous run's")
    part_rel <- utils::modifyList(part, list(modules = c(part$modules, "safety", "release")))
    hr <- read_scenario_table(kept, part_rel, "S_HCRU_RATES", TRUE)
    ok(identical(attr(hr, "table_source"), "release") && identical(hr$RATE, 60),
       "...while a run that did run release reads its released copy")
    # An optional output is the module's only when its switch was on. The
    # comorbidity module with COMORBID_SUBGROUPS=FALSE runs and is recorded,
    # and leaves S_COMORB_SUBGROUP as an earlier run left it.
    rd <- function(v) list(comorbid_subgroups = list(key = "comorbid_subgroups", value = v, note = ""))
    com_on  <- c(list(prefix = "p_", run_id = "A", state = "complete"),
                 list(modules = c("spine", "cohorts", "comorbidity"), cohorts = "1L", readings = rd("TRUE")))
    com_off <- utils::modifyList(com_on, list(readings = rd("FALSE")))
    com_na  <- com_on; com_na$readings <- list()
    ok(identical(optional_output_setting("S_COMORB_SUBGROUP"), "comorbid_subgroups") &&
         identical(optional_output_setting("S_FRAILTY"), "frailty") &&
         is.na(optional_output_setting("S_COMORBIDITY")),
       "the registry says which switch turns an optional output on")
    ok(scenario_wrote(com_on, "S_COMORB_SUBGROUP") && scenario_wrote(com_on, "S_COMORBIDITY"),
       "a run that recorded the switch on wrote the optional table")
    ok(!scenario_wrote(com_off, "S_COMORB_SUBGROUP") && scenario_wrote(com_off, "S_COMORBIDITY"),
       "...one that recorded it off did not, though it ran the module and wrote the module's other table")
    ok(!scenario_wrote(com_na, "S_COMORB_SUBGROUP"),
       "...and one that recorded no reading cannot attest it")
    ok(nrow(restrict_to_cohorts(data.frame(COHORT = "1L", X = 1),
                                utils::modifyList(part, list(cohorts = character(0))))) == 0L &&
         identical(restrict_to_cohorts(data.frame(X = 1), part)$X, 1),
       "a run recording no cohorts owns no per-cohort rows, and a table without cohorts passes whole")
    ok(identical(scenario_from_row("p_", data.frame(
         RUN_ID = "A", LOT_RUN_ID = "L", LOT_RUN_VERSION = "20260908T110500Z",
         stringsAsFactors = FALSE))$lot_run_version, "20260908T110500Z") &&
         identical(scenario_from_row("p_", data.frame(RUN_ID = "A", LOT_RUN_ID = "L",
                                                      stringsAsFactors = FALSE))$lot_run_version, ""),
       "a scenario carries which build of its LOT run it read, and none where the run did not record it")
  })
  app <- paste(readLines("app.R", warn = FALSE), collapse = "\n")
  ok(grepl("read_scenario_table(SRC, scenario, p$table", app, fixed = TRUE) &&
       !grepl("read_table(SRC, scenario$prefix", app, fixed = TRUE),
     "a panel reads its table bound to the run the sidebar names, on every read")
  ok(!grepl("scenario_moved <- reactive(", app, fixed = TRUE),
     "...and the check is not a reactive, which a file read cannot invalidate")
  ok(grepl("read_scenario_table(SRC, b, tb", app, fixed = TRUE) &&
       grepl("scenario_moved(s) || scenario_moved(b)", app, fixed = TRUE),
     "and Compare binds BOTH sides, not only the one it was already checking")
  ok(grepl("read_scenario_table(SRC, s, tb, DASH_CFG$prefer_release)", app, fixed = TRUE) &&
       !grepl("read_table(SRC, s$prefix, tb", app, fixed = TRUE),
     "the cohorts offered to select on are the ones this run built, read bound")
  ok(grepl('lot <- read_lot_table(SRC, s, "LOT_LONG_FINAL")', app, fixed = TRUE) &&
       grepl('as.character(lot$LOT_NUM)', app, fixed = TRUE),
     "...and the line selector offers the LOT table's own lines, so a pair from the engine's last line can be picked")
  ok(grepl('if (!scenario_wrote(s, tb)) "A", if (!scenario_wrote(b, tb)) "B"', app, fixed = TRUE) &&
       grepl("has no %s of its own to compare", app, fixed = TRUE),
     "and Compare names the side that did not run a table's module rather than comparing what an earlier run left")
  ok(grepl("rebuilt since the page was opened", app, fixed = TRUE),
     "...and says so, rather than showing an empty table")
  ok(grepl('why <- attr(cm, "why")', app, fixed = TRUE),
     "and a comparison refused for being incomparable says why, not nothing")
}

cat("\nthe readings survive the trip from the producer\n")
# parse_readings() reads a string the study package writes, and the two live in
# different folders. So the producer is driven here rather than a string being
# retyped: a note the writer emits and the reader mangles is something neither
# package's own tests can see.
{
  cfg <- as.list(stats::setNames(rep("x", length(OPEN_QUESTION_SOURCE)),
                                 names(OPEN_QUESTION_SOURCE)))
  cfg$study_start <- "2018-01-01"
  # The upstream contract disagrees, which is when the note gets a semicolon.
  txt <- paste(open_question_readings(cfg, list(study_start = "2016-01-01")),
               collapse = "; ")
  ok(grepl("verified; this run was set to", txt, fixed = TRUE),
     "the writer records both readings when the cohort build disagrees")
  r <- parse_readings(txt)
  ok(identical(r$study_start$value, "2016-01-01"),
     "...and the value read back is the upstream one that shaped the data")
  ok(grepl("2018-01-01", r$study_start$note, fixed = TRUE),
     "...with the configured reading kept in the note, not lost at the semicolon")
  ok(!grepl("upstream", r$study_start$value, fixed = TRUE),
     "...and the provenance never ends up inside the value")
  ok(length(r) == length(OPEN_QUESTION_SOURCE),
     "...and every other setting still parses as its own entry")
  # The minimal shape that needs the note-aware split.
  r2 <- parse_readings("a=1 (note; with a semicolon); b=2")
  ok(length(r2) == 2 && identical(r2$a$value, "1") && identical(r2$b$value, "2"),
     "a semicolon inside a note does not start a new entry")
  ok(identical(r2$a$note, "note; with a semicolon"),
     "...and the note keeps it")
}

cat("\ncomparing two scenarios\n")
{
  sp <- table_spec("S_HCRU_RATES")
  sel <- list(COHORT = "1L", LOT_NUM = "1", PERIOD = "follow_up")
  g <- function(p) apply_keys(read_table(SRC, p, "S_HCRU_RATES"), sp, sel)
  cm <- compare_tables(g("s223926_"), g("s223926_q27_"), sp, "RATE")
  ok(nrow(cm) == 3, "every stratum in either scenario appears once")
  ok(all(c("A", "B", "DELTA", "PCT_CHANGE") %in% names(cm)),
     "with both values and the difference")
  ok("MEASURE" %in% names(cm) && length(unique(cm$MEASURE)) == 3,
     "and the table's own MEASURE column survives - it is not the value's name")
  mm <- cm[cm$MEASURE == "mm_related_hospitalisation", ]
  ok(abs(mm$PCT_CHANGE - 100) < 2,
     "Q27 roughly doubles the MM-related rate, which is what the profile found")
  ok(all(abs(cm$DELTA[cm$MEASURE != "mm_related_hospitalisation"]) < 1e-9),
     "and moves nothing it does not reach - a difference here IS the setting")
  cm2 <- compare_tables(g("s223926_"), g("s223926_q25_"), sp, "RATE")
  ok(all(abs(cm2$PCT_CHANGE - 17) < 1),
     "while Q25 moves every claims-derived measure, by the same 17%")
  ok(abs(cm$DELTA[1]) >= abs(cm$DELTA[nrow(cm)]),
     "the biggest difference is listed first")
  ok(nrow(compare_tables(NULL, NULL, sp, "RATE")) == 0,
     "comparing nothing to nothing is empty, not an error")
}

cat("\nwhat a panel can draw, and what it says when it cannot\n")
{
  s <- SCENARIOS[["s223926_"]]
  ps <- resolve_panels(s)
  ok(length(ps) == length(PANELS), "every panel is offered when none is switched off")
  # A scenario that ran fewer modules.
  s2 <- s; s2$modules <- c("spine", "cohorts", "attrition")
  ps2 <- resolve_panels(s2)
  hcru <- Filter(function(p) identical(p$name, "hcru_rates"), ps2)[[1]]
  ok(!isTRUE(hcru$available) && grepl("hcru", hcru$why),
     "a panel whose module did not run is marked unavailable, naming the module")
  ok(grepl("empty", hcru$why),
     "and says the table is empty rather than hiding the tab")
  attr1 <- Filter(function(p) identical(p$name, "attrition"), ps2)[[1]]
  ok(isTRUE(attr1$available), "while a panel whose module did run is available")
  # A run that did not finish: every study panel says so, the metadata panel
  # and the LOT panels still show.
  s3 <- s; s3$state <- "started"
  ps3 <- resolve_panels(s3, src = SRC)
  get <- function(nm) Filter(function(p) identical(p$name, nm), ps3)[[1]]
  ok(!isTRUE(get("hcru_rates")$available) && grepl("'started', not complete", get("hcru_rates")$why),
     "under a run that is not complete, a result panel is unavailable and says why")
  ok(!isTRUE(get("headline")$available) && !isTRUE(get("attrition")$available),
     "...the headline count and the funnel included")
  ok(isTRUE(get("provenance")$available),
     "...while the metadata panel still shows what the run set out to do")
  ok(isTRUE(get("lot_attrition")$available),
     "...and the LOT panels, which describe the lineage the run recorded")
  app3 <- paste(readLines("app.R", warn = FALSE), collapse = "\n")
  ok(grepl("if (!scenario_is_usable(s) || !scenario_is_usable(b))", app3, fixed = TRUE) &&
       grepl("Only complete runs can be compared", app3, fixed = TRUE),
     "and Compare refuses to draw a difference unless both runs are complete")

  old <- Sys.getenv("SHOW_SAFETY_RATES", unset = NA)
  Sys.setenv(SHOW_SAFETY_RATES = "FALSE")
  ok(!"safety_rates" %in% vapply(resolve_panels(s), `[[`, character(1), "name"),
     "SHOW_<NAME>=FALSE drops a panel")
  Sys.setenv(SHOW_SAFETY_RATES = "probably")
  ok(grepl("neither TRUE nor FALSE", errs(resolve_panels(s)) %||% ""),
     "and anything else stops rather than dropping it silently")
  if (is.na(old)) Sys.unsetenv("SHOW_SAFETY_RATES") else
    Sys.setenv(SHOW_SAFETY_RATES = old)
}

cat("\nthe LOT engine's outputs, which belong to the LOT run\n")
{
  s <- SCENARIOS[["s223926_"]]
  ok(nzchar(s$lot_run_id), "a scenario records the LOT run it read")
  d <- read_lot_table(SRC, s, "LOT_LONG_FINAL")
  ok(!is.null(d) && nrow(d) > 0, "and that run's lines read back")
  ok(all(c("PATID", "LOT_NUM", "LOT_START_TYPE", "LOT_BASE_END_REASON") %in% names(d)),
     "with the columns the engine's own append writes")
  ok(max(d$LOT_NUM) <= 5L, "and no line beyond the engine's five-line cap")
  # Lines thin out: every patient has a 1L and fewer reach each later line.
  n_by <- table(d$LOT_NUM)
  ok(all(diff(as.integer(n_by)) < 0),
     "each later line holds fewer patients than the one before it")

  # LOT_LONG is the same table BEFORE the line criteria, so it holds more.
  raw <- read_lot_table(SRC, s, "LOT_LONG")
  ok(nrow(raw) > nrow(d),
     "LOT_LONG holds more lines than LOT_LONG_FINAL - the criteria removed some")

  # A LOT panel does not depend on which of THIS package's modules ran.
  s2 <- s; s2$modules <- c("spine", "cohorts")
  lot_p <- Filter(function(p) identical(p$name, "lot_attrition"),
                  resolve_panels(s2, src = SRC))[[1]]
  ok(isTRUE(lot_p$available),
     "a LOT panel is available even when this package ran almost no module")
  # It does depend on the scenario naming a run, and on reaching it.
  s3 <- s; s3$lot_run_id <- ""
  p3 <- Filter(function(p) identical(p$name, "lot_attrition"),
               resolve_panels(s3, src = SRC))[[1]]
  ok(!isTRUE(p3$available) && grepl("records no LOT run", p3$why),
     "a scenario naming no LOT run says so rather than drawing an empty funnel")
  s4 <- s; s4$lot_run_id <- "a-run-nothing-exported"
  p4 <- Filter(function(p) identical(p$name, "lot_attrition"),
               resolve_panels(s4, src = SRC))[[1]]
  ok(!isTRUE(p4$available) && grepl("could not be read from this source", p4$why),
     "and a run that was not exported is a different message from one not recorded")
  ok(grepl("DASH_LOT_PREFIX", p4$why) && grepl("build_scenarios", p4$why),
     "which names what to do about it, for either source")

  # The funnel spec: two funnels, different column names, one panel.
  sp_s <- table_spec("S_ATTRITION"); sp_l <- table_spec("LOT_ATTRITION")
  ok(identical(sp_s$order, "STEP") && identical(sp_l$order, "STEP_NUM"),
     "each funnel declares the column it is ordered by")
  ok(identical(sp_s$facet, "CRITERION") && identical(sp_l$facet, "STEP"),
     "and the column that labels a step")
  la <- read_lot_table(SRC, s, "LOT_ATTRITION")
  ok(all(intersect(sp_l$values, names(la)) == sp_l$values),
     "every value the LOT funnel declares is on the table")
  ok("progression" %in% la$KIND && "reconciliation" %in% la$KIND,
     "and the kinds that are not attrition are marked as such")

  # Face validity: the number and its range, not a bare verdict.
  fv <- read_lot_table(SRC, s, "LOT_FACE_VALIDITY")
  spf <- table_spec("LOT_FACE_VALIDITY")
  ok(all(c(spf$value, spf$lo, spf$hi, spf$verdict) %in% names(fv)),
     "a face-validity check carries what it found and what was expected")
  ok(sum(fv$VERDICT != "ok") >= 1,
     "and at least one check is outside its range, so the panel that shows one is exercised")
  outside <- fv[fv$VERDICT != "ok", ]
  ok(all(outside$VALUE < outside$EXPECT_LO | outside$VALUE > outside$EXPECT_HI),
     "a LOOK is a value genuinely outside its range, not a label")
  ok(all(fv$VALUE[fv$VERDICT == "ok"] >= fv$EXPECT_LO[fv$VERDICT == "ok"] &
           fv$VALUE[fv$VERDICT == "ok"] <= fv$EXPECT_HI[fv$VERDICT == "ok"]),
     "and an ok is genuinely inside it")
}

cat("\nline against the next line\n")
# The per-line panels cannot show that a line which ran out was followed the
# next day by an allograft line, or that a regimen came back in full one line
# later. These views pair each patient's consecutive lines and count patients
# per pair, under the floor, with no identifier in what comes back.
{
  lf <- data.frame(
    PATID = c("P1", "P1", "P1", "P2", "P2", "P3", "P3", "P4"),
    LOT_NUM = c(1L, 2L, 3L, 1L, 2L, 1L, 3L, 1L),
    LOT_START_TYPE = c("MED", "SCT_AUTO", "MED", "MED", "MED", "MED", "MED", "MED"),
    LOT_BASE_END_REASON = c("SCT_AUTO", "MED_ADD", "STUDY_END", "DISCONTINUATION",
                            "STUDY_END", "MED_ADD", "STUDY_END", "STUDY_END"),
    LOT_BASE_MEDS = c("BORT LEN", "MELP", "LEN", "BORT LEN", "DARA", "BORT", "LEN", "BORT LEN"),
    stringsAsFactors = FALSE)
  pr <- lot_pairs(lf, "LOT_BASE_END_REASON", "LOT_START_TYPE")
  ok(nrow(pr) == 3L && all(pr$TO_LOT == pr$FROM_LOT + 1L),
     "consecutive lines of one patient are paired, one row per pair")
  ok(!"P3" %in% pr$ID && !"P4" %in% pr$ID,
     "...a patient whose lines skip a number is not paired across the gap, and one line pairs with nothing")
  ok(identical(pr$FROM[pr$ID == "P1" & pr$FROM_LOT == 1L], "SCT_AUTO") &&
       identical(pr$TO[pr$ID == "P1" & pr$FROM_LOT == 1L], "SCT_AUTO"),
     "...with the earlier line's end reason against the later line's start type")
  # Shuffled input pairs the same, so the order rows arrive in cannot matter.
  pr2 <- lot_pairs(lf[c(8, 3, 5, 1, 7, 2, 6, 4), ], "LOT_BASE_END_REASON", "LOT_START_TYPE")
  ok(identical(pr2[order(pr2$ID, pr2$FROM_LOT), c("ID", "FROM", "TO")],
               pr[order(pr$ID, pr$FROM_LOT), c("ID", "FROM", "TO")]),
     "...whatever order the rows arrive in")

  t1 <- lot_transitions(lf, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 1L)
  ok(nrow(t1) == 3L && all(t1$N_PATIENTS == 1L) && all(t1$SUPPRESSED == 0L) &&
       !"ID" %in% names(t1) && !"PATID" %in% names(t1),
     "counted per pair on distinct patients, with no identifier in the result")
  t2 <- lot_transitions(lf, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 2L)
  f1 <- t2[t2$FROM_LOT == 1L, ]; f2 <- t2[t2$FROM_LOT == 2L, ]
  ok(nrow(f1) == 1L && identical(f1$FROM, "(grouped pairs)") && identical(f1$N_PATIENTS, 2L) && f1$SUPPRESSED == 0L,
     "pairs under the floor are grouped into one row per line whose count is their sum")
  ok(nrow(f2) == 1L && is.na(f2$N_PATIENTS) && f2$SUPPRESSED == 1L,
     "...and that row is withheld when the sum is still under the floor")
  ok(all(lot_transitions(lf, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 1L,
                         from_lot = 1L)$FROM_LOT == 1L),
     "the line selector keeps the pairs FROM that line")
  # The TO-group total is published ("what opened each line"), so a single
  # withheld cell in it would be the subtraction: 33 MED starts at line 2,
  # 30 of them after end A, and the 3 after end B would be there to read.
  leak <- data.frame(
    PATID = c(sprintf("A%02d", 1:30), sprintf("B%d", 1:3), sprintf("A%02d", 1:30), sprintf("B%d", 1:3)),
    LOT_NUM = c(rep(1L, 33), rep(2L, 33)),
    LOT_START_TYPE = c(rep("MED", 33), rep("MED", 33)),
    LOT_BASE_END_REASON = c(rep("A", 30), rep("B", 3), rep("STUDY_END", 33)),
    LOT_BASE_MEDS = "X", stringsAsFactors = FALSE)
  tl <- lot_transitions(leak, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 25L)
  ok(!"A" %in% tl$FROM && nrow(tl) == 1L && identical(tl$N_PATIENTS, 33L),
     "where one cell of a published group is withheld, the smallest open one goes with it, so the pair is not the subtraction")
  ok(grepl("grouped", tl$FROM) && !grepl("under the floor", tl$FROM) && !grepl("under the floor", tl$TO),
     "...and the grouped row does not claim that every pair in it was under the floor - the 30 was not")
  # The pairs' population is published in the caption and as "lines by line
  # number", so a line with one common pair and one rare one would show the
  # common count beside that total: 50 patients, 49 shown, and the rare 1 is
  # the subtraction. So the line's own total is a published group too.
  two_pairs <- function(common, rare) data.frame(
    PATID = rep(c(sprintf("C%03d", seq_len(common)), sprintf("R%03d", seq_len(rare))), 2),
    LOT_NUM = rep(1:2, each = common + rare),
    LOT_START_TYPE = c(rep("MED", common + rare), rep("MED", common), rep("SCT_ALLO", rare)),
    LOT_BASE_END_REASON = c(rep("MED_ADD", common), rep("SCT_ALLO", rare), rep("STUDY_END", common + rare)),
    LOT_BASE_MEDS = c(rep("BORT LEN", common), rep("MELP", rare), rep("DARA", common), rep("", rare)),
    stringsAsFactors = FALSE)
  v49 <- lot_sequence_view(two_pairs(49, 1), "end_to_start", 25)
  ok(v49$released && identical(v49$n, 50L) && nrow(v49$rows) == 1L &&
       identical(v49$rows$N_PATIENTS, 50L) && !49 %in% v49$rows$N_PATIENTS,
     "one common pair beside one rare pair is shown only as a group, so the rare count is not the caption minus the common one")
  html49 <- html_table(v49$rows, caption = v49$note)
  ok(grepl("50 patients", html49, fixed = TRUE) && !grepl(">49<", html49, fixed = TRUE) &&
       !grepl(">49.00<", html49, fixed = TRUE) && !grepl(">1<", html49, fixed = TRUE),
     "...and the rendered panel carries neither the common count nor the rare one")
  leaky <- 0L
  for (common in c(25L, 49L, 100L)) for (rare in c(1L, 12L, 24L)) {
    r <- lot_transitions(two_pairs(common, rare), "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 25L)
    if (any(r$N_PATIENTS %in% c(common, rare), na.rm = TRUE)) leaky <- leaky + 1L
    r2 <- lot_transitions(two_pairs(common, rare), "LOT_BASE_MEDS", "LOT_BASE_MEDS", min_n = 25L)
    if (any(r2$N_PATIENTS %in% c(common, rare), na.rm = TRUE)) leaky <- leaky + 1L
  }
  ok(leaky == 0L,
     "...for every combination of a common and a rare pair, in the end-to-start and the regimen views alike")
  ok(identical(lot_transitions(two_pairs(30, 30), "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 25L)$N_PATIENTS, c(30L, 30L)),
     "while two pairs both over the floor are both shown - nothing is hidden that need not be")
  rg <- lot_sequence_view(two_pairs(30, 30), "regimen", 25)$rows
  ok("(no regimen)" %in% rg$TO && !"(Missing)" %in% rg$TO,
     "an allograft or CAR-T line's empty regimen reads as no regimen, not as missing data")

  # "How each line ended" publishes, for the selected line, the count of lines
  # ending each way - with or without a line after them - and the pairs from an
  # end reason sum to it less the lines with none. The fixture is four
  # histories weighted 1, 49, 49 and 51, every patient with exactly two lines:
  # 50 DISCONTINUATION endings, 49 of them shown, and the hidden pair readable
  # as 1 unless this group is held. `alone` adds line-1 DISCONTINUATION
  # endings with no line after them.
  histories <- function(w = c(1L, 49L, 49L, 51L), alone = 0L) {
    from <- c("DISCONTINUATION", "DISCONTINUATION", "SCT_AUTO", "MED_ADD")
    to <- c("SCT_AUTO", "MED", "SCT_AUTO", "MED")
    id <- unlist(lapply(seq_along(w), function(i) sprintf("H%d_%03d", i, seq_len(w[i]))))
    d <- data.frame(
      PATID = c(id, id, sprintf("X%03d", seq_len(alone))),
      LOT_NUM = c(rep(1L, length(id)), rep(2L, length(id)), rep(1L, alone)),
      LOT_START_TYPE = c(rep("MED", length(id)), rep(to, w), rep("MED", alone)),
      LOT_BASE_END_REASON = c(rep(from, w), rep("STUDY_END", length(id)), rep("DISCONTINUATION", alone)),
      LOT_BASE_MEDS = "X", stringsAsFactors = FALSE)
    d[order(d$LOT_NUM, decreasing = TRUE), ]   # line 2 first: order cannot matter
  }
  # The subtraction a reader makes: every total the other panels publish for
  # these lines, less the pairs shown beside it. A difference under the floor
  # and above zero is a count under the floor read off the page.
  read_off <- function(d, tr, from_col = "LOT_BASE_END_REASON", to_col = "LOT_START_TYPE", min_n = 25L) {
    open <- tr[tr$SUPPRESSED == 0L & !startsWith(tr$FROM, "("), , drop = FALSE]
    pub <- function(rows, col) { t <- tabulate_cat(rows, col, min_n); t[!is.na(t$N), , drop = FALSE] }
    l1 <- d[d$LOT_NUM == 1L, ]; l2 <- d[d$LOT_NUM == 2L, ]
    ends <- pub(l1, from_col); starts <- pub(l2, to_col)
    diffs <- c(
      ends$N - vapply(ends$LEVEL, function(l) sum(open$N_PATIENTS[open$FROM == l]), numeric(1)),
      starts$N - vapply(starts$LEVEL, function(l) sum(open$N_PATIENTS[open$TO == l]), numeric(1)),
      nrow(l2) - sum(open$N_PATIENTS))
    diffs[diffs > 0 & diffs < min_n]
  }
  h <- histories()
  ends1 <- tabulate_cat(h[h$LOT_NUM == 1L, ], "LOT_BASE_END_REASON", 25L)
  ok(identical(ends1$N[ends1$LEVEL == "DISCONTINUATION"], 50L) && nrow(h[h$LOT_NUM == 1L, ]) == nrow(h[h$LOT_NUM == 2L, ]),
     "the selected-line summary publishes 50 DISCONTINUATION endings at line 1, and the per-line counts say every line 1 had a line 2")
  th <- lot_transitions(h, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 25L)
  shown <- th[!startsWith(th$FROM, "("), ]
  ok(nrow(shown) == 1L && identical(shown$FROM, "MED_ADD") && identical(shown$TO, "MED") &&
       identical(shown$N_PATIENTS, 51L) && !"DISCONTINUATION" %in% shown$FROM,
     "so DISCONTINUATION -> MED is not shown on its own beside that total: only MED_ADD -> MED is")
  ok(sum(startsWith(th$FROM, "(")) == 1L && identical(th$FROM[startsWith(th$FROM, "(")], "(grouped pairs)") &&
       identical(th$N_PATIENTS[startsWith(th$FROM, "(")], 99L),
     "...and the other three pairs are one grouped row of 99 that does not say it holds three")
  ok(!length(read_off(h, th)),
     "...so no total the other panels publish - an end reason, a start type, the line - less what is shown is under the floor")
  hv <- html_table(lot_sequence_view(h, "end_to_start", 25)$rows)
  counts <- regmatches(hv, gregexpr("<td>[^<]*</td></tr>", hv))[[1]]   # the last cell of each row
  ok(setequal(counts, c("<td>51.00</td></tr>", "<td>99.00</td></tr>")),
     "...and the rendered panel's counts are 51 and 99 - neither 49 nor 1")
  # What the three tables say together. From the published end-reason and
  # start-type totals less the one shown pair, a reader has the row and column
  # totals of the hidden cells, and every way of filling them with whole
  # numbers is a candidate. A grouped row saying how many pairs it held would
  # pick one of the fifty candidates out.
  fillings <- function(rows, cols) {
    # Every non-negative integer matrix with these margins, one row per candidate.
    fill <- function(r, remaining_cols) {
      if (r > length(rows)) return(if (all(remaining_cols == 0)) list(integer(0)) else list())
      if (r == length(rows)) {
        if (sum(remaining_cols) != rows[r]) return(list())
        return(list(remaining_cols))
      }
      out <- list()
      parts <- function(k, left, acc) {
        if (k > length(cols)) { if (left == 0) out[[length(out) + 1L]] <<- acc; return(invisible()) }
        for (v in 0:min(left, remaining_cols[k])) parts(k + 1L, left - v, c(acc, v))
      }
      parts(1L, rows[r], integer(0))
      unlist(lapply(out, function(cells) lapply(fill(r + 1L, remaining_cols - cells), function(rest) c(cells, rest))),
             recursive = FALSE)
    }
    do.call(rbind, fill(1L, cols))
  }
  hidden_margins <- function(d, tr) {
    open <- tr[tr$SUPPRESSED == 0L & !startsWith(tr$FROM, "("), , drop = FALSE]
    ends <- tabulate_cat(d[d$LOT_NUM == 1L, ], "LOT_BASE_END_REASON", 25L)
    starts <- tabulate_cat(d[d$LOT_NUM == 2L, ], "LOT_START_TYPE", 25L)
    rows <- setNames(ends$N - vapply(ends$LEVEL, function(l) sum(open$N_PATIENTS[open$FROM == l]), numeric(1)), ends$LEVEL)
    cols <- setNames(starts$N - vapply(starts$LEVEL, function(l) sum(open$N_PATIENTS[open$TO == l]), numeric(1)), starts$LEVEL)
    list(rows = rows[rows > 0], cols = cols[cols > 0])
  }
  hm <- hidden_margins(h, th)
  cand <- fillings(hm$rows, hm$cols)
  cell_names <- paste(rep(names(hm$rows), each = length(hm$cols)), names(hm$cols), sep = " -> ")
  colnames(cand) <- cell_names   # row-major, as fillings() lays them out
  ok(nrow(cand) == 50L && sum(rowSums(cand > 0) == 3L) == 1L &&
       cand[rowSums(cand > 0) == 3L, "DISCONTINUATION -> SCT_AUTO"] == 1,
     "fifty fillings fit the published totals, and saying the grouped row held three pairs left exactly one - the rare pair at 1")
  pinned <- vapply(cell_names, function(cl) length(unique(cand[, cl])) == 1L, logical(1))
  ok(!any(pinned & cand[1, ] > 0 & cand[1, ] < 25),
     "...without that number, no hidden cell is pinned to a count under the floor by the three tables together")
  ok(!grepl("[0-9]", th$FROM[startsWith(th$FROM, "(")]) &&
       !grepl("[0-9]", lot_sequences(two_pairs(49, 1), "LOT_START_TYPE", min_n = 25L)$SEQUENCE),
     "...because neither grouped row carries a number of any kind")
  # Lines that ended that way with no line after them are the part of the
  # total the pairs do not account for. Thirty of them are cover enough for
  # the 49 to show; five are not.
  h30 <- histories(alone = 30L)
  t30 <- lot_transitions(h30, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 25L)
  ok(any(t30$FROM == "DISCONTINUATION" & t30$TO == "MED" & t30$N_PATIENTS == 49L & t30$SUPPRESSED == 0L) &&
       !length(read_off(h30, t30)),
     "with thirty line-1 DISCONTINUATION endings that had no line 2, the 49 has cover and is shown - and nothing is read off")
  h5 <- histories(alone = 5L)
  t5 <- lot_transitions(h5, "LOT_BASE_END_REASON", "LOT_START_TYPE", min_n = 25L)
  ok(!any(t5$FROM == "DISCONTINUATION") && !length(read_off(h5, t5)),
     "...with five it is not, because 55 less 49 is the six that had no line 2 or went somewhere rare")
  le <- lot_line_ends(h30, "LOT_BASE_END_REASON")
  ok(identical(le$N[le$FROM_LOT == 1L & le$FROM == "DISCONTINUATION"], 30L) &&
       identical(le$N[le$FROM_LOT == 2L & le$FROM == "STUDY_END"], 150L) && !any(le$FROM_LOT == 1L & le$FROM != "DISCONTINUATION"),
     "the lines with no line after them are counted by line and end reason, on distinct patients")
  unread <- TRUE
  for (case in list(two_pairs(49, 1), two_pairs(30, 3), two_pairs(30, 30), leak, h, h30, h5))
    for (cols in list(c("LOT_BASE_END_REASON", "LOT_START_TYPE"), c("LOT_BASE_MEDS", "LOT_BASE_MEDS")))
      unread <- unread && !length(read_off(case, lot_transitions(case, cols[1], cols[2], min_n = 25L), cols[1], cols[2]))
  ok(unread,
     "no fixture, in either view, lets an end reason, a start type, a regimen or a line total be read down to a count under the floor")

  sq <- lot_sequences(lf, "LOT_START_TYPE", min_n = 1L)
  ok(identical(sq$SEQUENCE[1], "MED > MED") && identical(sq$N_PATIENTS[1], 2L) &&
       identical(sq$N_LINES[1], 2L) && identical(sq$PCT[1], 50),
     "a sequence is what opened each of a patient's lines, in order, counted on patients")
  ok("MED > SCT_AUTO > MED" %in% sq$SEQUENCE && "MED" %in% sq$SEQUENCE && nrow(sq) == 3L,
     "...one row per distinct sequence")
  sq2 <- lot_sequences(lf, "LOT_START_TYPE", min_n = 2L)
  ok(nrow(sq2) == 2L && identical(sq2$SEQUENCE[1], "MED > MED") &&
       identical(sq2$SEQUENCE[2], "(grouped sequences)") && identical(sq2$N_PATIENTS[2], 2L),
     "rare sequences are grouped into one row rather than listed shaded")
  sq49 <- lot_sequences(two_pairs(49, 1), "LOT_START_TYPE", min_n = 25L)
  ok(nrow(sq49) == 1L && identical(sq49$N_PATIENTS, 50L) && grepl("grouped", sq49$SEQUENCE),
     "...and one common sequence beside one rare one is shown only as a group, for the same reason")
  ok(identical(hide_for_disclosure(c(40L, 30L, 15L, 12L), list(rep("a", 4)), 25L), c(FALSE, FALSE, TRUE, TRUE)),
     "two rare rows whose sum clears the floor hide nothing else")
  ok(identical(hide_for_disclosure(c(60L, 45L, 3L, 2L), list(rep("a", 4)), 25L), c(FALSE, TRUE, TRUE, TRUE)),
     "...but when their sum is under the floor the smallest open row goes with them until it is not")
  seq_leak <- data.frame(PATID = c(sprintf("A%02d", 1:30), "B1", "B2", "B3"), LOT_NUM = 1L,
                         LOT_START_TYPE = c(rep("MED", 30), rep("SCT_AUTO", 3)),
                         stringsAsFactors = FALSE)
  sl <- lot_sequences(seq_leak, "LOT_START_TYPE", min_n = 25L)
  ok(nrow(sl) == 1L && identical(sl$SEQUENCE, "(grouped sequences)") && identical(sl$N_PATIENTS, 33L),
     "...and a single rare sequence takes the smallest common one with it, because the total is published")

  v <- lot_sequence_view(lf, "end_to_start", 25)
  ok(!v$released && !nrow(v$rows) && grepl("Withheld: fewer than 25", v$note),
     "a view over fewer patients than the floor is withheld whole, before any cell is looked at")
  v1 <- lot_sequence_view(lf, "end_to_start", 1, package_min_n = 1L)
  ok(v1$released && nrow(v1$rows) == 3L && identical(v1$n, 2L) &&
       grepl("2 patients with a line and the one after it", v1$note),
     "...and one over enough is released, with the patients (not the pairs) in the caption")
  ok(identical(lot_sequence_view(lf, "end_to_start", 1, from_lot = 1L, package_min_n = 1L)$n, 2L),
     "...counting only the patients whose pairs are from the selected line")
  ok(identical(lot_sequence_view(lf, "sequences", 1, package_min_n = 1L)$n, 4L),
     "...and every patient with a line, for the sequences")
  ok(!is.na(errs(lot_sequence_view(lf, "not_a_view", 1))),
     "a view nobody registered stops rather than drawing something")
  d_syn <- read_lot_table(SRC, SCENARIOS[[1]], "LOT_LONG_FINAL")
  for (vw in LOT_SEQUENCE_VIEWS) {
    r <- lot_sequence_view(d_syn, vw, 25)
    ok(r$released && nrow(r$rows) > 0 && !any(c("PATID", "ID") %in% names(r$rows)) &&
         "SUPPRESSED" %in% names(r$rows),
       paste0("the '", vw, "' view over the synthetic run is released, carries the shading column and no identifier"))
  }

  # Registered and wired.
  seq_panels <- Filter(function(p) identical(p$render, "sequence"), PANELS)
  ok(length(seq_panels) == 3L && all(vapply(seq_panels, `[[`, character(1), "tab") == "LOT engine") &&
       setequal(vapply(seq_panels, `[[`, character(1), "view"), LOT_SEQUENCE_VIEWS) &&
       all(vapply(seq_panels, `[[`, character(1), "table") == "LOT_LONG_FINAL") &&
       "sequence" %in% PANEL_RENDER,
     "three line-to-line panels sit on the LOT engine tab, one per view, off LOT_LONG_FINAL")
  app_seq <- paste(readLines("app.R", warn = FALSE), collapse = "\n")
  ok(grepl("sequence = ui_sequence(p, s)", app_seq, fixed = TRUE) &&
       grepl("d <- read_lot_table(SRC, s, p$table)", app_seq, fixed = TRUE) &&
       grepl("lot_sequence_view(d, p$view, input$floor, from_lot", app_seq, fixed = TRUE) &&
       grepl("if (!v$released) return(div(class = \"note\", v$note))", app_seq, fixed = TRUE),
     "...drawn off the bound LOT read, through the view that applies the floor, and withheld with a reason")
}

cat("\nwhether two scenarios rest on the same lines\n")
{
  a <- SCENARIOS[["s223926_"]]; b <- SCENARIOS[["s223926_q27_"]]
  ok(isTRUE(same_lot_run(a, b)),
     "scenarios sharing a LOT run are reported as sharing it")
  b2 <- b; b2$lot_run_id <- "another-lot-run"
  ok(isFALSE(same_lot_run(a, b2)),
     "and two reading different runs are reported as differing")
  b3 <- b; b3$lot_run_id <- ""
  ok(is.na(same_lot_run(a, b3)),
     "while a scenario naming no run gives NA - not knowing is not the same as knowing they match")
  a4 <- a; a4$lot_run_version <- "20260601T000000Z"
  b4 <- b; b4$lot_run_version <- "20260601T000000Z"
  b5 <- b; b5$lot_run_version <- "20260901T000000Z"
  ok(isTRUE(same_lot_run(a4, b4)),
     "one run id and one build is the same lines")
  ok(isFALSE(same_lot_run(a4, b5)),
     "...one run id and two builds is not - the engine keeps its id for a session")
  b6 <- b; b6$lot_run_version <- ""
  ok(is.na(same_lot_run(a4, b6)),
     "...and where only one of them recorded its build, it cannot be said")
  ok(grepl("Different LOT builds", paste(readLines("app.R", warn = FALSE), collapse = "\n"),
           fixed = TRUE),
     "and the Compare tab names that case rather than calling it a different run")
  # This is what makes a delta readable. Two scenarios on one LOT run differ
  # only in what this package did; on two runs the lines differ too, and the
  # comparison carries both without being able to separate them.
  src <- paste(readLines("app.R", warn = FALSE), collapse = "\n")
  ok(grepl("same_lot_run(s, b)", src, fixed = TRUE),
     "the Compare tab asks the question before it draws a difference")
  ok(grepl("Different LOT runs", src, fixed = TRUE),
     "and says so when the answer is no")
}

cat("\nthe LOT table list matches the engine's own\n")
{
  # lot/ is a sibling of this folder, so one hop up.
  eng <- file.path("..", "lot", "engine", "R", "build_lot.R")
  if (file.exists(eng)) {
    txt <- paste(readLines(eng, warn = FALSE), collapse = "\n")
    blk <- regmatches(txt, regexpr("LOT_TABLES <- c\\((?:[^()]|\\([^()]*\\))*\\)",
                                   txt, perl = TRUE))
    declared <- unique(regmatches(blk, gregexpr('"[A-Z0-9_]+"', blk))[[1]])
    declared <- gsub('"', "", declared)
    unknown <- setdiff(LOT_DASHBOARD_TABLES, declared)
    ok(length(unknown) == 0,
       paste0("every LOT table this dashboard reads is one the engine declares",
              if (length(unknown)) paste0(" [not: ", paste(unknown, collapse = ", "), "]")
              else ""))
    ok(length(declared) > length(LOT_DASHBOARD_TABLES),
       "and the engine writes more than the dashboard shows, which is expected")
  } else {
    cat("  SKIP   lot/engine is not beside this folder\n")
  }
}

cat("\nthe requested table shells, on a tab of their own\n")
{
  shell_panels <- Filter(function(p) identical(p$tab, "Tables"), PANELS)
  ok(length(shell_panels) == 2,
     "the Tables tab carries the filled shells and the class mapping")
  ok("shell" %in% PANEL_RENDER &&
       all(vapply(shell_panels, function(p) p$render %in% PANEL_RENDER, logical(1))),
     "each asks for the 'shell' renderer, which is a render type")
  ok(all(vapply(shell_panels, function(p)
    is.na(p$table) && identical(p$source %||% "study", "study"), logical(1))),
     "neither names a study table of its own - the shells say what each row reads")
  ok("Tables" %in% PANEL_TABS(), "and the tab is offered")

  # The switch, and it behaves like every other panel's.
  s <- SCENARIOS[["s223926_"]]
  old <- Sys.getenv("SHOW_SHELL_TABLES", unset = NA)
  Sys.setenv(SHOW_SHELL_TABLES = "FALSE")
  ok(!"shell_tables" %in% vapply(resolve_panels(s), `[[`, character(1), "name"),
     "SHOW_SHELL_TABLES=FALSE drops the panel")
  Sys.setenv(SHOW_SHELL_TABLES = "probably")
  ok(grepl("neither TRUE nor FALSE", errs(resolve_panels(s)) %||% ""),
     "and anything else stops rather than dropping it silently")
  if (is.na(old)) Sys.unsetenv("SHOW_SHELL_TABLES") else
    Sys.setenv(SHOW_SHELL_TABLES = old)

  # The shells are a sibling delivery. Without them this tab says so, and
  # nothing else on the page changes - a deployment that left one folder out
  # is not a dashboard that will not start.
  absent <- tfls_ready(file.path(tempdir(), "no-such-shell-folder"))
  ok(isFALSE(absent$ok) && is.null(absent$env),
     "with the shells absent the engine is not loaded")
  ok(grepl("DASH_TFLS_DIR", absent$why, fixed = TRUE),
     "...and the panel is told what to set, rather than an empty table")
  ok(is.na(errs(resolve_panels(s, src = SRC))),
     "...while the dashboard still resolves its panels")
  ps <- resolve_panels(s, src = SRC)
  ok(isTRUE(Filter(function(p) identical(p$name, "shell_tables"), ps)[[1]]$available),
     "...and the panel itself is still offered, because its rows name the tables")
}

cat("\nthe shells are filled at the sidebar's floor, and no lower\n")
{
  ready <- tfls_ready()
  if (!isTRUE(ready$ok)) {
    cat("  SKIP   the shells are not beside this folder\n")
  } else {
    s <- SCENARIOS[["s223926_"]]
    ok(nrow(ready$shells$tables) > 0 && nrow(ready$shells$classes) > 0,
       "the shells beside the dashboard load, tables and classes")
    ok(length(shell_table_choices(ready)) == nrow(ready$shells$tables) &&
         all(ready$shells$tables$table_id %in% shell_table_choices(ready)),
       "and every table in the file is one a viewer can pick, by its title")

    f <- shell_fill(ready, "T4", SRC, s, 25L)
    ok(sum(f$cells$FILLED == 1L) > 0,
       "a table filled from this scenario has cells in it")
    ok(identical(f$floor_n, 25L), "the floor reaching the engine is the sidebar's")
    ok(identical(shell_fill(ready, "T4", SRC, s, 1L)$floor_n, 25L),
       "asking for 1 fills at the package's 25, not at the 1")
    ok(identical(shell_floor(1L, 25L, ready), 25L) &&
         identical(shell_floor(60L, 25L, ready), 60L),
       "the floor a viewer may only raise is decided in one place")
    hi <- shell_fill(ready, "T4", SRC, s, 60000L)
    ok(identical(hi$floor_n, 60000L), "and a viewer raising it is honoured")

    # A withheld cell reaches the page as the engine's own text.
    shown <- f$cells$TEXT[f$cells$FILLED == 1L & f$cells$SECTION == 0L][1]
    h <- shell_panel_html(ready, f)
    hh <- shell_panel_html(ready, hi)
    ok(nzchar(shown) && grepl(shown, h, fixed = TRUE),
       "a cell the floor allows is on the page")
    ok(!grepl(shown, hh, fixed = TRUE),
       "...and is gone once the floor covers it")
    ok(grepl("&lt;60000", hh, fixed = TRUE) && !grepl("<60000", hh, fixed = TRUE),
       "...replaced by the engine's withheld text, escaped, never by a blank")
    supp <- hi$cells[hi$cells$SUPPRESSED == 1L, , drop = FALSE]
    ok(nrow(supp) > 0 && all(supp$TEXT == "<60000") &&
         all(is.na(supp$N)) && all(is.na(supp$DENOM)),
       "and the withheld cell carries no number at all, its denominator included")
    ok(grepl("withheld at a floor of 60,000", hh, fixed = TRUE),
       "the page says how many cells were withheld and at what floor")
    ok(!grepl("P[0-9]{6}", h), "no patient id reaches the filled table")
    ok(grepl("DISCLOSURE", errs(ready$env$assert_no_identifiers(
         data.frame(PATID = "P000001"), "a cell frame")) %||% ""),
       "and the engine's own identifier guard is the one in the path")
    ok(grepl("assert_no_identifiers", paste(readLines("R/tfls.R", warn = FALSE),
                                            collapse = "\n"), fixed = TRUE),
       "...called on the way to the page, not only on the way to a file")

    # The reader is the dashboard's own, bound to the run - not a second one.
    cut <- s; cut$modules <- c("spine", "cohorts", "attrition")
    fc <- shell_fill(ready, "T4", SRC, cut, 25L)
    ok(sum(fc$cells$FILLED == 1L) == 0 &&
         any(grepl("S_TTE was not read by this run", fc$unfilled$REASON, fixed = TRUE)),
       "a table this run did not write fills nothing here either, and says so")

    # The eligibility flag is a decision, and the table says which way it went.
    ft <- shell_fill(ready, "T4", SRC, s, 25L, tte_eligible_only = TRUE)
    ok(any(grepl("TTE_ELIGIBLE = 1", ft$notes, fixed = TRUE)),
       "applying the eligibility flag is stated on the page")
    ok(any(grepl("leaves to the reader", f$notes, fixed = TRUE)),
       "and leaving it off, which is the default, says that instead")

    # What nothing could fill, and whose gap each one is.
    u <- shell_unfilled_html(ready, f)
    ok(all(unique(f$unfilled$REASON_KIND) %in% ready$env$TFLS_REASON_KINDS),
       "every unfilled row carries one of the three kinds the engine records")
    ok(all(vapply(unique(f$unfilled$REASON_KIND), function(k)
      grepl(paste0("<h5>", k), u, fixed = TRUE), logical(1))),
       "and the listing groups them under it")
    ok(grepl("not filled", h, fixed = TRUE),
       "a row nothing could fill reads as unfilled in the table, not as a blank")
  }
}

cat("\nthe snapshot is rebuilt while a shell table is being filled\n")
{
  ready <- tfls_ready()
  if (!isTRUE(ready$ok)) {
    cat("  SKIP   the shells are not beside this folder\n")
  } else {
    # shiny is not installed in this environment, so the panel is not driven
    # through testServer(). The decision it makes is driven directly instead:
    # scenario_moved() in app.R is isFALSE(scenario_is_current()), and the
    # fill it is asked about here is a real one.
    s <- SCENARIOS[["s223926_"]]
    # A source whose run is rebuilt once the fill's first table has been read.
    # read_scenario_table() asks the metadata twice per table, before the read
    # and after it, so the third question is the second table's.
    md <- 0L
    moving <- list(read = function(prefix, table) {
      if (identical(table, "S_RUN_METADATA")) {
        md <<- md + 1L
        return(data.frame(RUN_ID = s$run_id, STATE = s$state,
                          UPDATED_AT = if (md > 2L) "2026-09-09 13:00:00"
                                       else s$updated_at,
                          stringsAsFactors = FALSE))
      }
      SRC$read(prefix, table)
    })
    f <- shell_fill(ready, "T4", moving, s, 25L)
    ok(sum(f$cells$FILLED == 1L) > 0 && nrow(f$cells) > 0,
       "a run rebuilt mid-fill leaves the rows read before it in the filled table")
    ok(isFALSE(scenario_is_current(moving, s)),
       "...and the check the panel makes is the one that says the run has moved")
    ok(grepl('table class="grid"', shell_panel_html(ready, f), fixed = TRUE),
       "...so a filled table drawn from it would put the previous run's rows on the page")
    # What keeps them off it: the same check, asked again between the fill and
    # anything being drawn. A text check, because the placement is the fix -
    # the answer itself is driven above.
    app <- paste(readLines("app.R", warn = FALSE), collapse = "\n")
    after <- substring(app, regexpr("shell_fill(ready, tid", app, fixed = TRUE))
    at <- function(x) regexpr(x, after, fixed = TRUE)
    ok(at("scenario_moved(s)") > 0 &&
         at("scenario_moved(s)") < at("shell_panel_html(ready, filled)"),
       "the panel asks again once the fill is back, before the grid is built")
    ok(at("scenario_moved(s)") < at("shell_unfilled_html(ready, filled"),
       "...and before the rows nothing could fill, which are read off the same fill")
    ok(grepl("if (scenario_moved(s)) return(moved_alert())", after, fixed = TRUE),
       "...and shows the notice the other panels show, not a second one of its own")
    # The class mapping is the exception, and it is one for a reason: it is
    # read off the shells folder's file, not off the run, so a rebuild changes
    # nothing in it.
    hc <- shell_class_html(ready)
    ok(identical(hc, shell_class_html(tfls_ready())),
       "the class mapping is the same table whatever the run has done since")
    ok(!grepl("SRC", paste(deparse(shell_class_table), collapse = "\n"), fixed = TRUE) &&
         !grepl("read_scenario_table",
                paste(deparse(shell_class_html), collapse = "\n"), fixed = TRUE),
       "...because it reads the shells folder's own file and never the run's tables")
  }
}

cat("\nthe class mapping is the thing to edit\n")
{
  ready <- tfls_ready()
  if (!isTRUE(ready$ok)) {
    cat("  SKIP   the shells are not beside this folder\n")
  } else {
    cm <- shell_class_table(ready)
    ok(nrow(cm) == nrow(ready$shells$classes),
       "the class mapping lists every class in the file")
    hc <- shell_class_html(ready)
    ok(all(vapply(ready$shells$classes$class_id, function(id)
      grepl(id, hc, fixed = TRUE), logical(1))),
       "and every one of them reaches the page")
    ok(all(c("CLASS", "STUDY_CATEGORIES", "DRUG_REFINEMENT") %in% names(cm)),
       "with the study categories it rolls up and any drug refinement beside it")
    ok(grepl("regimen_classes.csv", hc, fixed = TRUE) &&
         grepl("the columns change with it", hc, fixed = TRUE),
       "the panel says which file to edit and that editing it changes the columns")
    # A class the study's vocabulary cannot separate yet is not an empty column.
    gap <- cm$STUDY_CATEGORIES[cm$CLASS_ID == "POM_TRIP"]
    ok(length(gap) == 1L && grepl("unfilled", gap, fixed = TRUE),
       "a class mapped to no category says so rather than reading as nobody")
    ok(!grepl("P[0-9]{6}", hc), "and the mapping carries nothing patient-level")
  }
}

cat("\nthe source refuses to make numbers up when it was told not to\n")
{
  ok(SRC$synthetic, "the synthetic source says it is synthetic")
  ok(isTRUE(PROVENANCE$synthetic),
     "and the provenance the page shows says so too")
  cfg <- DASH_CFG; cfg$source <- "synthetic"; cfg$allow_synthetic <- FALSE
  ok(grepl("must not fall back to made-up ones", errs(new_source(cfg)) %||% ""),
     "DASH_ALLOW_SYNTHETIC=FALSE refuses to start on generated numbers")
  cfg2 <- DASH_CFG; cfg2$source <- "nowhere"
  ok(grepl("not one of snapshot, warehouse, synthetic", errs(new_source(cfg2)) %||% ""),
     "and an unknown source is named rather than falling back to one")
  cfg3 <- DASH_CFG; cfg3$source <- "warehouse"
  ok(grepl("needs a connection", errs(new_source(cfg3)) %||% ""),
     "the warehouse source without a connection stops, rather than reading nothing")
}

cat("\nno per-patient row reaches the page\n")
{
  # A `subject` table drawn as a grid is a line listing: one row per patient,
  # PATID included, on a dashboard several people can open.
  d <- read_table(SRC, "s223926_", "S_DEMOGRAPHICS")
  ok("PATID" %in% names(d), "the underlying table does carry PATID")
  sp <- table_spec("S_DEMOGRAPHICS")
  out <- summarise_subject(d, sp, min_n = 25L)
  ok(nrow(out) > 0 && nrow(out) < nrow(d),
     "a subject table is summarised to levels, not listed per patient")
  ok(!"PATID" %in% names(out), "and the summary carries no identifier")
  ok(!grepl("P[0-9]{6}", html_table(out)),
     "so no patient id reaches the rendered HTML")
  ok(all(c("VARIABLE", "LEVEL", "N", "PCT") %in% names(out)),
     "the summary is counts and percentages per level")
  # It goes through the two helpers that summarise a column, so they are
  # called rather than merely tested.
  src_all <- paste(vapply(list.files("R", "[.]R$", full.names = TRUE),
                          function(f) paste(readLines(f, warn = FALSE), collapse = "\n"),
                          character(1)), collapse = "\n")
  ok(grepl("tabulate_cat(", src_all, fixed = TRUE) &&
       grepl("summarise_num(", src_all, fixed = TRUE),
     "and the summary helpers are called by something, not only by tests")
  # Driven, not grepped. A branch inside server() can only be checked by
  # looking for the word "summarise_subject" in the file, which says nothing
  # about what the branch does.
  h <- panel_table_html(d, sp, floor_n = 25L)
  ok(!grepl("P[0-9]{6}", h),
     "the panel renderer emits no patient id for a subject table")
  ok(grepl("Per-patient rows are never shown", h, fixed = TRUE),
     "and says on the page that it summarised rather than listed")
  ok(grepl("AGE_BAND", h, fixed = TRUE) && grepl("<td>", h, fixed = TRUE),
     "while still showing the breakdown")
  # A rate table is NOT summarised - it is already aggregated.
  hr <- panel_table_html(read_table(SRC, "s223926_", "S_SAFETY_RATES"),
                         table_spec("S_SAFETY_RATES"), floor_n = 25L)
  ok(!grepl("Per-patient rows", hr, fixed = TRUE) && grepl("CONDITION", hr, fixed = TRUE),
     "and an already-aggregated table is shown as itself")
  # Even a non-subject table gives up an identifier column.
  hid <- panel_table_html(data.frame(PATID = "P000001", N_AT_RISK = 900L),
                          table_spec("S_ODD", c("N_AT_RISK")), floor_n = 25L)
  ok(!grepl("P000001", hid, fixed = TRUE),
     "and an id column on any shape of table is dropped before rendering")
  ok(grepl("panel_table_html", paste(readLines("app.R", warn = FALSE), collapse = "\n"),
           fixed = TRUE),
     "with app.R calling that renderer rather than deciding for itself")
  ok(!"PATID" %in% names(drop_identifiers(d)), "drop_identifiers removes an id column")
  ok(!any(toupper(names(drop_identifiers(
       data.frame(PATID = 1, PAT_PLANID = 2, CLMID = 3, KEEP = 4)))) %in%
       c("PATID", "PAT_PLANID", "CLMID")),
     "and every identifier this warehouse uses, not only PATID")
  small <- summarise_subject(d[1:3, ], sp, min_n = 25L)
  ok(all(small$SUPPRESSED == 1L) && all(is.na(small$N)),
     "a stratum of 3 publishes nothing about itself, level by level or overall")
}

cat("\nnothing escapes the suppression floor\n")
{
  # A spec that names no n_col - every subject, funnel, check and undeclared
  # table - must not mean the floor is skipped, or "a new module appears in the
  # dashboard on its own" would also mean "and publishes raw".
  sp <- table_spec("S_BRAND_NEW", c("COHORT", "N_PATIENTS", "RATE"))
  g <- apply_floor(data.frame(COHORT = "1L", N_PATIENTS = 2L, RATE = 99.9),
                   sp, 25L, 25L)
  ok(identical(g$SUPPRESSED, 1L) && is.na(g$N_PATIENTS[1]),
     "an undeclared table publishing a small count is suppressed, not shown raw")
  ok(identical(infer_n_col(list(), c("COHORT", "N_AT_RISK", "N_PATIENTS")), "N_AT_RISK"),
     "the population column is preferred over the event count when both are there")
  ok(is.null(infer_n_col(list(), c("COHORT", "RATE"))),
     "and a table carrying no count at all is left alone rather than guessed at")
  ok(identical(infer_n_col(list(n_col = "N_DENOM"), c("N_DENOM", "N_PATIENTS")),
               "N_DENOM"),
     "a spec that names its denominator is honoured over the guess")
}

cat("\nthe pasteable command cannot inject\n")
{
  # The page invites a viewer to paste this block, so an unquoted value
  # carrying a newline would put a line of its own in it.
  payload <- "days\nrm -rf /\necho pwned"
  cm <- scenario_command(list(months_as = payload), prefix = "p_")
  ok(sum(grepl("^export ", strsplit(cm$command, "\n", fixed = TRUE)[[1]])) == 2L,
     "the injected newlines did not become extra export lines")
  # The property that matters is the shell's, so a shell decides it: run the
  # block and read back what the variable actually holds, rather than checking
  # the shape of the text.
  shell_value <- function(value, var = "MONTHS_AS") {
    if (!nzchar(Sys.which("bash"))) return(NULL)
    blk <- sub("\nRscript.*$", "", scenario_command(list(months_as = value),
                                                    prefix = "p_")$command)
    f <- tempfile(fileext = ".sh")
    writeLines(c(blk, sprintf("printf %%s \"$%s\"", var)), f)
    out <- suppressWarnings(system2("bash", f, stdout = TRUE, stderr = TRUE))
    paste(out, collapse = "\n")
  }
  got <- shell_value(payload)
  if (is.null(got)) cat("  SKIP   no bash, so the shell round-trip did not run\n")
  else {
    ok(identical(got, payload),
       "a shell assigns the whole payload as the value, executing none of it")
    tw <- file.path(tempdir(), "TRIPWIRE_A")
    file.create(tw)
    hostile <- sprintf("a'; rm -f %s; echo '", tw)
    got2 <- shell_value(hostile)
    ok(identical(got2, hostile) && file.exists(tw),
       "and a value trying to close the quote is still just a value - the tripwire survives")
    unlink(tw)
  }
  ok(identical(sh_quote("plain"), "'plain'"), "an ordinary value is simply quoted")
  ok(identical(sh_quote(c("a", "b")), "'a,b'"), "and a vector joins before quoting")
  cm3 <- scenario_command(list(), prefix = "p_; rm -rf ~")
  ok(grepl("OBJECT_PREFIX='p_; rm -rf ~'", cm3$command, fixed = TRUE),
     "the prefix is quoted too")
}

cat("\na path segment cannot leave the snapshot\n")
{
  # A LOT run id comes from a metadata table, so anyone who can write to the
  # warehouse chooses it: "../../PRIVATE" must not reach a file outside the
  # snapshot root.
  ok(safe_segment("s223926_") && safe_segment("run-1.2_3"),
     "an ordinary prefix or run id is accepted")
  for (bad in list("../PRIVATE", "..", ".", "a/b", "/etc/passwd", "", NA_character_,
                   "~root", "-rf", "a\nb"))
    ok(!safe_segment(bad),
       paste0("rejected as a path segment: ",
              if (is.na(bad)) "NA" else sprintf("'%s'", gsub("\n", "\\\\n", bad))))
  root <- tempfile("snap"); dir.create(file.path(root, "lot"), recursive = TRUE)
  outside <- file.path(dirname(root), "OUTSIDE"); dir.create(outside, showWarnings = FALSE)
  utils::write.csv(data.frame(secret = 1), file.path(outside, "LOT_LONG.csv"),
                   row.names = FALSE)
  cfg <- DASH_CFG; cfg$source <- "snapshot"; cfg$snapshot_dir <- root
  s <- new_source(cfg)
  ok(is.null(s$read_lot("../../OUTSIDE", "LOT_LONG")),
     "read_lot refuses a run id that would climb out of the snapshot root")
  ok(is.null(s$read("../OUTSIDE", "LOT_LONG")),
     "and read refuses a prefix that would")
  ok(is.null(s$read("s223926_", "../../OUTSIDE/LOT_LONG")),
     "and a table name cannot climb either")
}

cat("\na duplicated stratum is not silent\n")
{
  sph <- table_spec("S_HCRU_RATES")
  d <- data.frame(COHORT = "1L", LOT_NUM = 1L, PERIOD = "p", MEASURE = c("m", "m"),
                  N_AT_RISK = 100L, N_PATIENTS = 1L, N_EVENTS = 1L,
                  PERSON_YEARS = 1, RATE = c(10, 90), stringsAsFactors = FALSE)
  cm <- compare_tables(d, d, sph, "RATE")
  ok("N_ROWS_FOR_KEY" %in% names(cm) && cm$N_ROWS_FOR_KEY[1] == 2L,
     "a key matching two rows says so - match() takes the first and dropped the other")
  clean <- read_table(SRC, "s223926_", "S_HCRU_RATES")
  ok(!"N_ROWS_FOR_KEY" %in% names(compare_tables(clean, clean, sph, "RATE")),
     "and a table with one row per key carries no such column")
}

cat("\nreadings parse to clean keys\n")
{
  ok(identical(names(parse_readings("  spaced  =  value  ")), "spaced"),
     "a key with padding is trimmed - untrimmed it read as a different setting")
  ok(identical(parse_readings("  k  =  v  ")[["k"]]$value, "v"), "and so is the value")
  ok(length(parse_readings("=novalue")) == 0,
     "a reading with an empty key is dropped, not kept under the name ''")
  ok(length(parse_readings("a=1;;b=2")) == 2, "empty parts between separators are skipped")
  r <- parse_readings("x=1;x=2;y=3")
  ok(length(r) == 2 && identical(r[["x"]]$value, "1"),
     "a repeated key keeps one reading, the first - so names() and [[ ]] agree")
}

cat("\nHTML the app writes\n")
{
  h <- html_table(data.frame(A = "<script>alert(1)</script>", B = 1))
  ok(!grepl("<script>", h, fixed = TRUE) && grepl("&lt;script&gt;", h, fixed = TRUE),
     "a value that looks like markup is escaped, not rendered")
  ok(grepl("Nothing to show", html_table(data.frame())),
     "an empty table says so rather than drawing an empty grid")
  h2 <- html_table(data.frame(N = c(1, 2), SUPPRESSED = c(0L, 1L)))
  ok(grepl('class="supp"', h2, fixed = TRUE) && !grepl("SUPPRESSED</th>", h2),
     "a withheld row is shaded, and the flag itself is not a column")
  ok(identical(fmt_num(NA), "—"), "a missing number reads as missing, not as 0")
  ok(identical(fmt_num(12345, 0), "12,345"), "and a count is grouped")
  ok(!grepl("http", paste(readLines("app.R", warn = FALSE), collapse = ""),
            fixed = TRUE),
     "the app loads nothing over the network")
}

cat("\nthe palette is this folder's own\n")
{
  # The palette is this folder's own, so what is held is that it is complete
  # and usable: every colour the renderer names is defined, and each one is a
  # hex colour.
  used <- c("orange", "orange_dark", "orange_pale", "paper", "ink", "slate",
            "line", "wash", "alert_ink", "alert_bg", "alert_line")
  ok(all(used %in% names(PALETTE)),
     paste0("every colour the renderer names is in the palette (",
            length(PALETTE), ")"))
  ok(all(grepl("^#[0-9A-Fa-f]{6}$", PALETTE)),
     "...and each one is a hex colour")
  src_all <- paste(vapply(list.files("R", "[.]R$", full.names = TRUE),
                          function(f) paste(readLines(f, warn = FALSE),
                                            collapse = "\n"), character(1)),
                   collapse = "\n")
  named <- unique(unlist(regmatches(src_all, gregexpr(
    '(?<=PALETTE\\[\\[")[a-z_]+', src_all, perl = TRUE))))
  ok(all(named %in% names(PALETTE)),
     paste0("and nothing reads a colour the palette does not define",
            if (!all(named %in% names(PALETTE)))
              paste0(" [", paste(setdiff(named, names(PALETTE)), collapse = ", "),
                     "]") else ""))
}

cat("\napp.R is wiring, and the wiring matches the registries\n")
{
  src <- paste(readLines("app.R", warn = FALSE), collapse = "\n")
  ok(grepl("source(\"global.R\")", src, fixed = TRUE),
     "the app loads the package's registries rather than restating them")
  # Every renderer a panel can ask for is wired.
  for (r in PANEL_RENDER)
    if (r %in% vapply(PANELS, `[[`, character(1), "render"))
      ok(grepl(paste0("\\b", r, "\\s*="), src),
         paste0("the '", r, "' renderer a panel asks for is wired in app.R"))
  ok(!grepl("PANELS\\s*<-", src),
     "and app.R declares no panel of its own")
  ok(grepl("DASH_CFG$suppress_min_n", src, fixed = TRUE),
     "the floor the app applies is the configured one, not a literal")

  # Every renderer goes through the preparation layer rather than deciding the
  # population, the floor and the caption for itself. This is a text check
  # because the wiring is what it is about - the decisions themselves are
  # driven directly above, and each has its own fixture there.
  ok(grepl('prepare_panel(d, sp, input$floor, purpose = "tte"', src, fixed = TRUE),
     "the survival panel asks for the tte analysis set, not the whole table")
  ok(grepl("kpi_row_html(last, input$floor", src, fixed = TRUE),
     "the headline row goes through the function that applies the floor")
  ok(grepl("suppress_comparison(cm, da, db, sp, input$floor", src, fixed = TRUE),
     "the comparison is suppressed before it is rendered")
  ok(grepl("plot_stratum_bars(d, sp, lab, val", src, fixed = TRUE) &&
       !grepl("FUN = function(x) mean(x, na.rm = TRUE)", src, fixed = TRUE),
     "a rate chart preserves its strata rather than averaging them")
  ok(grepl("plot_count_bars(d, sp, lab, p$label, input$floor)", src, fixed = TRUE),
     "and a count chart withholds a bar resting on too few patients")
  ok(grepl("shell_fill(ready, tid, SRC, s, input$floor", src, fixed = TRUE),
     "a table shell is filled at the sidebar's floor, not at one of its own")
  ok(!grepl("sys.source", src, fixed = TRUE) && grepl("tfls_ready()", src, fixed = TRUE),
     "and the shell engine is loaded by R/tfls.R rather than sourced in app.R")
  # No renderer reads straight from the source. A floor change can re-run one
  # renderer past the panel guard, which would put a rebuilt snapshot's counts
  # under the old run's settings, so every read goes through
  # read_scenario_table().
  raw <- sum(gregexpr("SRC$read(", src, fixed = TRUE)[[1]] > 0)
  ok(raw == 0L,
     paste0("no renderer reads straight from the source (",
            raw, " direct reads)"))
  ok(!grepl("read_table(SRC", src, fixed = TRUE),
     "...nor through the unbound reader")
  ok(length(gregexpr("nothing_or_moved(s)", src, fixed = TRUE)[[1]]) >= 2L,
     "...and a renderer whose bound read came back empty says the snapshot moved rather than showing an empty table")
}

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
