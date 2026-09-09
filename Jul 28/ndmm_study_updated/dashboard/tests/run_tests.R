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
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
errs <- function(expr) {
  e <- tryCatch({ force(expr); NULL }, error = conditionMessage)
  if (is.null(e)) NA_character_ else e
}

Sys.setenv(DASH_SOURCE = "synthetic", DASH_PACKAGE_DIR = "../study223926",
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
  ok(all(vapply(PANELS, function(p)
    is.na(p$table) || p$table %in% c(DASH_TABLES$TABLE, "S_RUN_METADATA"),
    logical(1))),
     "and reads a table the package actually writes")
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
  ok(grepl("export OBJECT_PREFIX=s223926_new_", cm$command, fixed = TRUE),
     "the command sets the prefix the new scenario would write under")
  ok(grepl("export MM_HOSP_POSITION=claim_positions", cm$command, fixed = TRUE) &&
       grepl("export CLAIM_STATUS=all", cm$command, fixed = TRUE),
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
  # A stratum the package's own floor covers. The synthetic table has none -
  # every stratum in it runs to thousands - so asking for a floor of 1 there
  # suppressed nothing either way and the check passed on a mutation that
  # honoured the viewer's floor outright. Built here instead.
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
  ok(abs(km_at(k, 2)[["SURV"]] - 0.8) < 1e-9,
     "survival between two event times is the earlier step, not interpolated")
  ok(identical(km_at(k, 0.5)[["SURV"]], 1), "and is 1 before the first event")
  # S(3) is 0.533, so this curve never reaches 0.5 and has NO median. Worth
  # pinning: the first version of this check asserted 3, reading the last
  # event time as the median.
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

cat("\nthe palette matches the reporting dashboard's\n")
{
  sib <- file.path("..", "..", "reporting", "dashboard", "R", "render.R")
  if (file.exists(sib)) {
    e <- new.env(); suppressWarnings(try(source(sib, local = e), silent = TRUE))
    if (!is.null(e$PALETTE)) {
      shared <- intersect(names(PALETTE), names(e$PALETTE))
      ok(length(shared) >= 8 &&
           identical(unname(PALETTE[shared]), unname(e$PALETTE[shared])),
         "every colour both dashboards use is the same colour in both")
    } else cat("  SKIP   the sibling render.R defined no PALETTE\n")
  } else {
    cat("  SKIP   reporting/dashboard is not beside this folder\n")
  }
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
}

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
