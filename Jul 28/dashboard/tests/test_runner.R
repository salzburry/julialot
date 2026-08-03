#!/usr/bin/env Rscript
# Checks on the dashboard package. No warehouse: every query goes through a
# stub, so what is tested is the wiring, the guards and the HTML.
#
#   Rscript "dashboard/tests/test_runner.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
report <- function() {
  cat("\n", strrep("-", 52), "\n", sep = "")
  cat(sprintf("%d passed, %d failed\n", pass, fail))
  if (fail > 0L) quit(status = 1L)
}

env <- new.env(parent = globalenv())
for (f in c("R/config_dash.R", "R/db_utils_dash.R", "R/sections.R",
            "R/render.R", "R/build_dashboard.R"))
  sys.source(file.path(ROOT, f), envir = env)
# all.names: the section generators are dotted helpers, and ls() hides those
# by default - so the pieces that build the registry were the one part of
# this file nothing could reach.
for (nm in ls(env, all.names = TRUE)) assign(nm, get(nm, envir = env))

SETTINGS <- c("TOP_N", "MAX_RETRIES", "PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME",
              "INPUT_COHORT_TABLE", "LOT_PREFIX", "COHORT_PREFIX", "OUTPUT_DIR",
              paste0("SHOW_", toupper(vapply(DASHBOARD_SECTIONS, `[[`,
                                             character(1), "name"))))
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)
clear()

cat("\n-- the registry is well formed --\n")
runs(validate_sections(), "every shipped section validates")
ok(length(DASHBOARD_SECTIONS) >= 10,
   paste0("the dashboard has something to show (", length(DASHBOARD_SECTIONS),
          " sections)"))
nms <- vapply(DASHBOARD_SECTIONS, `[[`, character(1), "name")
ok(!anyDuplicated(toupper(nms)),
   "no two sections share a name - the switch is SHOW_<NAME>, one per section")
# Every switch the file ships has to name a section, and every section has to
# have a switch. A switch for a section that no longer exists turns nothing off;
# a section with no switch cannot be turned off at all, which is the thing the
# user asked for.
cnames <- local({
  rows <- read.csv(file.path(ROOT, "config.csv"), stringsAsFactors = FALSE,
                   comment.char = "#")
  n <- trimws(as.character(rows$name)); n[nzchar(n) & !startsWith(n, "#")]
})
shows <- grep("^SHOW_", cnames, value = TRUE)
want  <- paste0("SHOW_", toupper(nms))
ok(setequal(shows, want),
   if (setequal(shows, want)) paste0("config.csv has one switch per section (",
                                     length(shows), ")")
   else paste0("switches and sections disagree: ",
               paste(union(setdiff(shows, want), setdiff(want, shows)),
                     collapse = ", ")))

cat("\n-- a section names only the inputs that exist --\n")
INPUTS <- list(cohort = "wk.COH", patients = "wk.p_LOT_PATIENT_INPUT",
               lot_long = "wk.p_LOT_LONG", lot_final = "wk.p_LOT_LONG_FINAL",
               run_meta = "wk.p_LOT_RUN_METADATA", build_st = "wk.p_LOT_BUILD_STATUS",
               attrition = "wk.c_NDMM_ATTRITION",
               lot_attrition = "wk.p_LOT_ATTRITION")
runs(validate_sections(DASHBOARD_SECTIONS, INPUTS),
     "every section's `needs` is an input the run resolves")
stops(validate_sections(list(modifyList(DASHBOARD_SECTIONS[[1]],
                                        list(needs = "nosuchtable"))), INPUTS),
      "a section needing a table that does not exist is refused")
stops(validate_sections(list(modifyList(DASHBOARD_SECTIONS[[1]],
                                        list(render = "pie")))),
      "a render type nothing can draw is refused")
stops(validate_sections(list(DASHBOARD_SECTIONS[[1]], DASHBOARD_SECTIONS[[1]])),
      "two sections with the same name are refused")

cat("\n-- and every placeholder it writes is filled --\n")
cfg <- list(top_n = 10L, journeys_per_category = 3L, attrition_window = 90L,
            owner_run = "run-a")
for (s in DASHBOARD_SECTIONS)
  runs(fill_sql(s$sql, INPUTS, cfg), paste0("'", s$name, "' resolves every {name}"))
stops(fill_sql("SELECT * FROM {nosuch}", INPUTS, cfg),
      "a section naming something else stops the build rather than querying it")
# A setting that is unset leaves its placeholder, and the same check catches it
# by name - rather than gsub throwing on a zero-length replacement.
stops(fill_sql("SELECT {top_n}", INPUTS, list(top_n = NULL)),
      "...and so does a placeholder whose setting is missing")
ok(!grepl("{", fill_sql(DASHBOARD_SECTIONS[[2]]$sql, INPUTS, cfg), fixed = TRUE),
   "...and a filled statement carries no leftover braces")

cat("\n-- the caller supplies the cohort, the package holds none --\n")
base <- modifyList(cfg_defaults, CONTRACT)
set_dash_config(modifyList(base, list(work_schema = "wk")))
t1 <- pin_target(base, "NDMM_COHORT", "ndmm_")
ok(identical(t1$input_cohort_table, "NDMM_COHORT") &&
     identical(t1$lot_prefix, "ndmm_"),
   "a cohort table and prefix are taken as given")
ok(identical(dashboard_inputs(modifyList(t1, list(work_schema = "wk",
       cohort_prefix = "")))$attrition, "hive_metastore.wk.ndmm_NDMM_ATTRITION"),
   "the cohort prefix defaults to the LOT prefix - one study, one prefix")
ok(identical(dashboard_inputs(modifyList(t1, list(work_schema = "wk",
       cohort_prefix = "coh_")))$attrition, "hive_metastore.wk.coh_NDMM_ATTRITION"),
   "...and is used when the two differ")
stops(pin_target(base, "", ""), "no cohort and no prefix")
stops(pin_target(base, "sch.NDMM_COHORT", "ndmm_"),
      "a qualified cohort name - schema comes from the settings")
stops(pin_target(base, "COH; DROP TABLE x", "ndmm_"), "anything not a table name")
stops(pin_target(base, "NDMM_COHORT", "ndmm"), "a prefix with no trailing underscore")
# ATTRITION_TABLE reaches a query the same way the cohort table does, and it is
# the one identifier that was taken on trust. Same guard as the rest.
with_at <- function(v) modifyList(base, list(attrition_table = v))
runs(pin_target(with_at("MYSTUDY_FUNNEL"), "NDMM_COHORT", "ndmm_"),
     "a plain attrition table name is taken as given")
stops(pin_target(with_at("wk.FUNNEL"), "NDMM_COHORT", "ndmm_"),
      "a qualified attrition name - the schema is added for you")
stops(pin_target(with_at("F; DROP TABLE x"), "NDMM_COHORT", "ndmm_"),
      "...and anything that is not a table name at all")
stops(pin_target(with_at(""), "NDMM_COHORT", "ndmm_"),
      "an empty ATTRITION_TABLE, which would name the prefix alone")
ok(!length(grep("NDMM|MM_COH", vapply(DASHBOARD_SECTIONS, `[[`, character(1), "sql"),
                value = TRUE)),
   "no section names a cohort of its own")

cat("\n-- a switch that is not TRUE or FALSE stops the build --\n")
clear()
Sys.setenv(SHOW_HEADLINE = "yes")
stops(check_settings(), "SHOW_HEADLINE='yes' is refused, not read as FALSE")
stops(section_enabled(DASHBOARD_SECTIONS[[2]]), "...and the reader refuses it too")
clear()
Sys.setenv(SHOW_HEADLINE = "FALSE")
ok(length(enabled_sections()) == length(DASHBOARD_SECTIONS) - 1L,
   "switching one off removes exactly that section")
clear()
ok(length(enabled_sections()) == length(DASHBOARD_SECTIONS),
   "and the default is every section on")
Sys.setenv(TOP_N = "ten")
stops(check_settings(), "a top-N that will not parse")
clear()

cat("\n-- the run stops without the table the study numbers come from --\n")
# LOT_LONG_FINAL is written LAST, in the line-criteria phase, after LOT_LONG.
# So a LOT run that died in between leaves the one and not the other - and
# requiring only LOT_LONG produced a file that looks like a finished dashboard
# while nearly every panel on it says "not shown".
runner <- paste(readLines(file.path(ROOT, "R", "build_dashboard.R"), warn = FALSE),
                collapse = "\n")
ok(grepl('if (!isTRUE(have[["lot_final"]]))', runner, fixed = TRUE),
   "the runner requires LOT_LONG_FINAL, the study population")
ok(!grepl('if (!isTRUE(have[["lot_long"]]))', runner, fixed = TRUE),
   "...rather than LOT_LONG, which a half-finished LOT run also leaves behind")

cat("\n-- the run reads, and only reads --\n")
src <- paste(unlist(lapply(list.files(file.path(ROOT, "R"), "[.]R$",
                                      full.names = TRUE), readLines, warn = FALSE)),
             collapse = "\n")
code <- grep("^\\s*#", strsplit(src, "\n")[[1]], value = TRUE, invert = TRUE)
ok(!any(grepl("CREATE |INSERT |UPDATE |DELETE |ALTER |DROP ", code)),
   "no statement in the package creates, writes or drops anything")
ok(!any(grepl("dbExecute|db_exec", code)),
   "...and it holds no way to execute one")

cat("\n-- a missing input is a skipped panel, not a failed run --\n")
have <- c(cohort = TRUE, patients = TRUE, lot_long = TRUE, lot_final = TRUE,
          run_meta = TRUE, build_st = TRUE, attrition = FALSE)
sec_attr <- Filter(function(s) identical(s$name, "attrition"), DASHBOARD_SECTIONS)[[1]]
# Into `env`: the package functions close over it, so a stub in globalenv is
# shadowed by the real db_q and the test passes on the wrong path.
assign("db_q", function(con, sql) stop("should not be asked"), envir = env)
p <- build_panel(NULL, sec_attr, INPUTS, have, cfg)
ok(grepl("Not shown", p$html, fixed = TRUE) && grepl("attrition", p$html, fixed = TRUE),
   "a section whose table is absent says so in the panel, naming the table")
# And a query that fails takes only its own panel with it. The other numbers
# are still true, and a run that produced no file at all would be worse.
have2 <- have; have2[["attrition"]] <- TRUE
assign("db_q", function(con, sql) stop("SYNTAX"), envir = env)
p2 <- build_panel(NULL, sec_attr, INPUTS, have2, cfg)
ok(grepl("the query failed", p2$html, fixed = TRUE),
   "a section whose query fails says so, and the run carries on")
assign("db_q", function(con, sql)
  data.frame(label = c("a", "b"), n = c(100L, 40L)), envir = env)
p3 <- build_panel(NULL, sec_attr, INPUTS, have2, cfg)
ok(grepl("bfill", p3$html, fixed = TRUE) && grepl("40", p3$html, fixed = TRUE),
   "and a section that works renders its rows")
rm("db_q", envir = env)

cat("\n-- the HTML is self-contained and safe --\n")
df <- data.frame(a = c(1500L, 2L), b = c("x", "<script>alert(1)</script>"),
                 stringsAsFactors = FALSE)
tbl <- render_table(df)
ok(grepl("&lt;script&gt;", tbl, fixed = TRUE) && !grepl("<script>", tbl, fixed = TRUE),
   "a value that looks like markup is escaped, not rendered")
ok(grepl("1,500", tbl, fixed = TRUE),
   "counts are grouped, so a six-figure cohort is readable")
ok(grepl('class="num"', tbl, fixed = TRUE),
   "numeric columns are right-aligned")
ok(grepl("No rows", render_table(df[0, ]), fixed = TRUE),
   "an empty result says so rather than rendering an empty table")
ok(grepl("kpi-n", render_kpi(data.frame(Patients = 12L)), fixed = TRUE),
   "a KPI section renders a tile per column")
ok(identical(render_bar(data.frame(x = 1)), render_table(data.frame(x = 1))),
   "a bar section without label/n falls back to a table rather than breaking")
doc <- render_document(list(list(tab = "Overview", label = "L", html = "<p>x</p>")),
                       "T", "S")
ok(grepl("<!DOCTYPE html>", doc, fixed = TRUE) && grepl("</html>", doc, fixed = TRUE),
   "the document is a whole HTML file")
# The point of not using plotly/DT/ggplot2: the file has to open from a
# file:// path on a machine with nothing installed, and the source's renderer
# silently produced no dashboard at all when those packages were missing.
ok(!grepl("<script", doc, fixed = TRUE) && !grepl("http://", doc, fixed = TRUE) &&
     !grepl("https://", doc, fixed = TRUE),
   "with no script tag and nothing fetched from the network")
ok(grepl('id="s-overview"', doc, fixed = TRUE) &&
     grepl('href="#s-overview"', doc, fixed = TRUE),
   "and every tab has a nav link that reaches it")

cat("\n-- patient journeys are examples, and they are masked --\n")
jr <- Filter(function(s) identical(s$name, "patient_journeys"), DASHBOARD_SECTIONS)[[1]]
jsql <- fill_sql(jr$sql, INPUTS, cfg)
ok(grepl("substr(p.PATID", jsql, fixed = TRUE) && grepl("concat('...'", jsql, fixed = TRUE),
   "PATID is masked in the SQL, so the identifier never reaches HTML or CSV")
ok(!grepl("p.PATID  *AS `Patient`", jsql) && !grepl("SELECT p.PATID,", jsql, fixed = TRUE),
   "...and no raw identifier is selected beside it")
ok(grepl("LOT_CART_LOT_FLG = 1 OR LOT_START_TYPE = \'CART\'", jsql, fixed = TRUE),
   "CAR-T is the CAR-T line itself, not only a prior line ending on CART_INIT")
ok(length(gregexpr("UNION ALL", jsql, fixed = TRUE)[[1]]) ==
     length(JOURNEY_CATEGORIES) - 1L,
   paste0("one arm per scenario (", length(JOURNEY_CATEGORIES), ")"))
ok(grepl("rn <= 3", jsql, fixed = TRUE),
   "JOURNEYS_PER_CATEGORY decides how many patients each scenario shows")
ok(grepl("ORDER BY PATID", jsql, fixed = TRUE),
   "picked in a fixed order, so the same cohort gives the same examples twice")
# Every scenario in the gallery has a row in the coverage panel, so a scenario
# that matched nobody reads as "none in this cohort" rather than as an omission.
cov <- Filter(function(s) identical(s$name, "journey_coverage"), DASHBOARD_SECTIONS)[[1]]
csql <- fill_sql(cov$sql, INPUTS, cfg)
ok(all(vapply(JOURNEY_CATEGORIES, function(c_i)
       grepl(gsub("'", "''", c_i$label, fixed = TRUE), csql, fixed = TRUE), logical(1))),
   "the coverage panel counts every scenario the gallery offers")

cat("\n-- the attrition table is the cohort build's, so it is named per cohort --\n")
# nndm calls it NDMM_ATTRITION. A different cohort build calls it something
# else, or has none - so the name is a setting rather than a constant in a
# package that is meant to name no study of its own.
set_dash_config(modifyList(base, list(work_schema = "wk")))
tt <- modifyList(t1, list(work_schema = "wk", cohort_prefix = "coh_",
                          attrition_table = "MYSTUDY_FUNNEL"))
ok(identical(dashboard_inputs(tt)$attrition, "hive_metastore.wk.coh_MYSTUDY_FUNNEL"),
   "ATTRITION_TABLE names it, and the cohort prefix still applies")
ok(identical(cfg_defaults$attrition_table, "NDMM_ATTRITION"),
   "...defaulting to what nndm writes")
ok(!any(grepl("NDMM_ATTRITION",
              vapply(DASHBOARD_SECTIONS, `[[`, character(1), "sql"), fixed = TRUE)),
   "and no section spells the name out for itself")

cat("\n-- the CSV export is the numbers on the page --\n")
tmp <- file.path(tempdir(), paste0("dashcsv", Sys.getpid()))
ecfg <- list(output_dir = tmp, csv_dir = "csv")
panels <- list(
  list(name = "a", data = data.frame(x = 1:2, y = c("p", "q"), stringsAsFactors = FALSE)),
  list(name = "b", data = NULL),
  list(name = "c", data = data.frame(x = integer(0))))
assign("log_msg", function(...) invisible(NULL), envir = env)
n <- write_csv_exports(panels, ecfg)
ok(identical(n, 1L), "a panel with rows is written; an empty or skipped one is not")
# The folder is one run. A file from a previous run - a panel since switched
# off, or another cohort into the same OUTPUT_DIR - carries no cohort or run id
# in its name, so it reads as current. It has to go.
stale <- file.path(tmp, "csv", "was_on_last_time.csv")
writeLines("x", stale)
write_csv_exports(panels, ecfg)
ok(!file.exists(stale), "a CSV left by a previous run is cleared, not left looking current")
ok(file.exists(file.path(tmp, "csv", "a.csv")), "...while this run's files are written")
keep <- file.path(tmp, "csv", "notes.txt"); writeLines("x", keep)
write_csv_exports(panels, ecfg)
ok(file.exists(keep), "and only .csv is touched")
ok(file.exists(file.path(tmp, "csv", "a.csv")) &&
     !file.exists(file.path(tmp, "csv", "b.csv")),
   "...and the file is named after the section")
back <- read.csv(file.path(tmp, "csv", "a.csv"), stringsAsFactors = FALSE)
ok(identical(back$x, 1:2) && identical(back$y, c("p", "q")),
   "the CSV round-trips the frame the panel rendered, not a second query")
# With the export off the writer never ran, so last run's files sat beside this
# run's HTML looking current. "The folder is this run" has to hold when the
# answer is "no files" as much as when it is nineteen.
ok(file.exists(file.path(tmp, "csv", "a.csv")), "a CSV is there to begin with")
clear_csv_exports(ecfg, "EXPORT_CSV is FALSE")
ok(!file.exists(file.path(tmp, "csv", "a.csv")) && file.exists(keep),
   "turning the export off clears the folder too, and still only .csv")
ok(identical(clear_csv_exports(list(output_dir = file.path(tmp, "nope"),
                                    csv_dir = "csv"), "x"), 0L),
   "and a folder that was never created is not an error")
unlink(tmp, recursive = TRUE)
clear()
Sys.setenv(EXPORT_CSV = "Y")
stops(check_settings(), "EXPORT_CSV='Y' is refused - as.logical('Y') is NA, which reads as off")
clear()
Sys.setenv(JOURNEYS_PER_CATEGORY = "3.5")
stops(check_settings(), "a fractional number of examples is refused")
clear()

getsec <- function(nm) Filter(function(s) identical(s$name, nm), DASHBOARD_SECTIONS)[[1]]

cat("\n-- the panels ask for columns that exist, and for one run --\n")
# ATTRITION_COLS in nndm declares RUN_ID, STEP_NUM, CRITERION, N_PATIENTS,
# PCT_OF_START, RECORDED_AT. This asked for STEP_LABEL, which is not one of
# them - so on every real run the query failed, build_panel caught it, and the
# HTML rendered with the cohort funnel replaced by a notice.
asql <- fill_sql(getsec("attrition")$sql, INPUTS, cfg)
ok(grepl("a.CRITERION AS label", asql, fixed = TRUE) &&
     !grepl("STEP_LABEL", asql, fixed = TRUE),
   "the attrition panel reads CRITERION, the column the cohort build writes")
# Both tables are history: each build deletes and re-inserts only its own
# RUN_ID. Unfiltered, a reused prefix returns several funnels interleaved by
# STEP_NUM - and the bar takes its denominator from the first row.
ok(grepl("ORDER BY RECORDED_AT DESC LIMIT 1", asql, fixed = TRUE) &&
     grepl("a.RUN_ID = l.RUN_ID", asql, fixed = TRUE),
   "...and only the latest run's rows, not every run the table has kept")
psql <- fill_sql(getsec("run_provenance")$sql, INPUTS, cfg)
# Neither "latest" nor "latest completed": the run that OWNS these tables,
# resolved before any panel runs. Completeness alone was not enough - see the
# resolve_owner_run block below for the rerun case it still got wrong.
ok(grepl("WHERE RUN_ID = 'run-a'", psql, fixed = TRUE),
   "provenance is the run that wrote these tables, named before the panel runs")
ok(!grepl("ORDER BY", psql, fixed = TRUE),
   "...so the panel has nothing left to sort or choose between")

cat("\n-- which run owns the tables, not which run finished --\n")
# LOT writes LOT_LONG_FINAL with CREATE OR REPLACE in the line-criteria phase
# and validates it AFTER. So a rerun that replaced the table and then died
# leaves its own table on disk with an incomplete metadata row - and the
# previous run's complete row is still the newest one any completeness test
# accepts. Provenance from run A over numbers from run B.
#
# LOT_BUILD_STATUS settles it: "complete" is the last write of the build, so
# the latest row on the prefix is the run that last wrote these tables.
oi <- list(run_meta = "wk.META", build_st = "wk.ST")
ohave <- c(run_meta = TRUE, build_st = TRUE)
ocfg <- list(lot_prefix = "p_")
stub <- function(f) assign("db_q", f, envir = env)
# Run B replaced the tables and failed; run A completed earlier.
stub(function(con, sql)
  if (grepl("wk.ST", sql, fixed = TRUE))
    data.frame(RUN_ID = "run-b", STATE = "failed", UPDATED_AT = "2026-01-02 10:00:00")
  else data.frame(RUN_ID = "run-a", RUN_TIMESTAMP = "2026-01-01 10:00:00"))
stops(resolve_owner_run(NULL, oi, ohave, ocfg),
      "a last run that did not finish stops the dashboard, rather than showing the run before it as its provenance")
Sys.setenv(DASH_IGNORE_BUILD_STATE = "TRUE")
o <- resolve_owner_run(NULL, oi, ohave, ocfg)
ok(identical(o$run_id, "run-a") && !isTRUE(o$exact),
   "...unless the operator says they know it failed early, and then the claim is the weaker one")
Sys.unsetenv("DASH_IGNORE_BUILD_STATE")
# The ordinary case: the last run finished, so it owns them.
stub(function(con, sql)
  if (grepl("wk.ST", sql, fixed = TRUE))
    data.frame(RUN_ID = "run-b", STATE = "complete", UPDATED_AT = "2026-01-02 10:00:00")
  else data.frame(x = 1))
o <- resolve_owner_run(NULL, oi, ohave, ocfg)
ok(identical(o$run_id, "run-b") && isTRUE(o$exact),
   "the last run, when it completed, is the run that owns the tables")
# Complete in one table and absent from the other is a contradiction, not
# something to fall back from: the two are written seconds apart.
stub(function(con, sql)
  if (grepl("wk.ST", sql, fixed = TRUE))
    data.frame(RUN_ID = "run-b", STATE = "complete", UPDATED_AT = "2026-01-02 10:00:00")
  else data.frame())
stops(resolve_owner_run(NULL, oi, ohave, ocfg),
      "complete in the status table but not in the metadata is refused, not papered over")
# No status table at all - an older LOT build. Fall back, and say it is weaker.
stub(function(con, sql) data.frame(RUN_ID = "run-a", RUN_TIMESTAMP = "2026-01-01 10:00:00"))
o <- resolve_owner_run(NULL, oi, c(run_meta = TRUE, build_st = FALSE), ocfg)
ok(identical(o$run_id, "run-a") && !isTRUE(o$exact),
   "with no build status table it falls back to the newest completed run, flagged as the weaker claim")
ok(any(grepl("N_LOT_FINAL_ROWS IS NOT NULL",
             deparse(get("resolve_owner_run", envir = env)), fixed = TRUE)),
   "...and that fallback still uses lot's own completeness predicate")

cat("\n-- the funnel's shape differs by cohort build, not only its name --\n")
# Making ATTRITION_TABLE a setting fixed the name. overall writes a different
# SHAPE - row_order/step_id/description/n_30/n_60/n_90 against nndm's
# STEP_NUM/CRITERION/N_PATIENTS - so one fixed query fails outright on it, and
# the page reads as "this study has no funnel".
NDMM_COLS <- c("RUN_ID", "STEP_NUM", "CRITERION", "N_PATIENTS", "PCT_OF_START",
               "RECORDED_AT")
OVERALL_COLS <- c("ROW_ORDER", "RUN_ID", "FINAL_TABLE_NAME", "CREATED_AT",
                  "STEP_ID", "DESCRIPTION", "N_30", "N_60", "N_90")
ai <- list(attrition = "wk.FUNNEL")
ahave <- c(attrition = TRUE)
acfg <- list(attrition_window = 60L, cohort_run = "coh-a")
noowner <- list(run_id = NA_character_, ts = NA, exact = FALSE)
asec <- function(secs) Filter(function(s) identical(s$name, "attrition"), secs)[[1]]
lay <- function(cols, owner = noowner, stamp = "2026-01-01 09:00:00") {
  stub(function(con, sql)
    if (grepl("^DESCRIBE", trimws(sql))) data.frame(col_name = cols)
    else data.frame(ATTR_AT = stamp))
  asec(resolve_attrition(DASHBOARD_SECTIONS, NULL, ai, ahave, acfg, owner))
}
s <- lay(NDMM_COLS)
ok(grepl("a.CRITERION AS label", s$sql, fixed = TRUE) && is.null(s$skip),
   "an nndm-shaped funnel gets the nndm query")
s <- lay(OVERALL_COLS)
ok(grepl("description AS label", s$sql, fixed = TRUE) && is.null(s$skip),
   "an overall-shaped funnel gets the overall query - the panel that used to fail outright")
ok(grepl("n_60 AS n", fill_sql(s$sql, ai, acfg), fixed = TRUE),
   "...reading the window the build was configured with, not whichever column came first")
ok(grepl("60-day", s$label, fixed = TRUE),
   "...and the label says which of the three it is showing")
s <- lay(c("PATID", "SOMETHING"))
ok(!is.null(s$skip) && grepl("PATID", s$skip, fixed = TRUE),
   "a shape neither layout matches skips that panel and prints the columns it found")
s <- lay(character(0))
ok(!is.null(s$skip), "a table whose columns cannot be read skips it too")
# Detection matches a layout when its columns are a SUBSET of the table's, so
# two layouts where one's columns contain the other's would both match and the
# choice between them would be the order they happen to be written in.
amb <- local({
  cs <- lapply(ATTRITION_LAYOUTS, function(L) toupper(L$cols))
  ns <- vapply(ATTRITION_LAYOUTS, `[[`, character(1), "name")
  out <- character(0)
  for (i in seq_along(cs)) for (j in seq_along(cs))
    if (i != j && all(cs[[i]] %in% cs[[j]])) out <- c(out, paste(ns[i], "in", ns[j]))
  out
})
ok(!length(amb), if (length(amb)) paste("layouts overlap:", paste(amb, collapse = "; "))
                 else paste0("no layout's columns contain another's, so detection ",
                             "cannot pick by registry order (", length(ATTRITION_LAYOUTS), ")"))
# lot records COHORT_RUN_ID - the cohort build it verified before pinning its
# input - so the funnel shown is the one belonging to that cohort. Warning text
# over the wrong rows is not enough: a funnel is read as the funnel for the
# study beside it, so the query is pinned to the recorded run, and the panel is
# skipped when that run's rows are gone.
lay2 <- function(cols, owner, n_rows, funnel_at = "2026-01-01 09:00:00") {
  stub(function(con, sql)
    if (grepl("^DESCRIBE", trimws(sql))) data.frame(col_name = cols)
    else if (grepl("max(", sql, fixed = TRUE)) data.frame(T = funnel_at)
    else data.frame(n = n_rows))
  asec(resolve_attrition(DASHBOARD_SECTIONS, NULL, ai, ahave, acfg, owner))
}
own <- list(run_id = "lot-1", ts = "2026-01-02 10:00:00", exact = TRUE,
            cohort_run = "coh-a", cohort_stamp = "2026-01-01 09:00:00")
s <- lay2(NDMM_COLS, own, 8L)
ok(grepl("a.RUN_ID = '{cohort_run}'", s$sql, fixed = TRUE) && is.null(s$skip),
   "the funnel is pinned to the cohort run LOT read, not to the newest one")
ok(grepl("RUN_ID = 'coh-a'", fill_sql(s$sql, ai, acfg), fixed = TRUE),
   "...and that run id reaches the query")
ok(grepl("cohort run coh-a", s$label, fixed = TRUE),
   "...with the panel saying which cohort run it is showing")
s <- lay2(OVERALL_COLS, own, 8L)
ok(grepl("run_id = '{cohort_run}'", s$sql, fixed = TRUE),
   "both layouts pin to the run, each by its own column name")
# The cohort was rebuilt and its funnel replaced, so the matching rows are gone.
# Showing the newer one would put one cohort's funnel above another's numbers.
s <- lay2(NDMM_COLS, own, 0L)
ok(!is.null(s$skip) && grepl("coh-a", s$skip, fixed = TRUE),
   "a funnel whose matching run is gone is skipped, not shown with a warning")
# An older lot recorded no link. Say so on the panel, not only in a log.
s <- lay2(NDMM_COLS, list(run_id = "lot-1", ts = NA, exact = FALSE,
                          cohort_run = NA_character_,
                          cohort_stamp = NA_character_), 8L)
ok(is.null(s$skip) && grepl("not tied to the LOT run", s$label, fixed = TRUE),
   "with no recorded link the funnel is still shown, and says it is not tied")
# A cohort re-run keeps its run id and rewrites its attrition under it, so
# matching ids is not matching attempts. lot records the status row's timestamp
# as well; a funnel written after it belongs to a later attempt.
s <- lay2(NDMM_COLS, own, 8L, funnel_at = "2026-02-01 09:00:00")
ok(!is.null(s$skip) && grepl("later attempt", s$skip, fixed = TRUE),
   "a funnel rewritten under the same run id after LOT read it is skipped")
s <- lay2(NDMM_COLS, own, 8L, funnel_at = "2026-01-01 09:00:00")
ok(is.null(s$skip),
   "...and the attempt LOT actually read is shown")

cat("\n-- the panels name no study, in their labels either --\n")
# The attrition table belongs to whichever cohort build wrote it, so the panel
# above it cannot describe that build's criteria. "ends before the LOT
# belantamab criterion" was true of nndm and false of anything else; nothing in
# the warehouse even keys a cohort run to a LOT run.
labs <- vapply(DASHBOARD_SECTIONS, `[[`, character(1), "label")
ok(!length(grep("NDMM|belantamab|myeloma|newly diagnosed", labs,
                ignore.case = TRUE)),
   "no label names a study, a drug or a criterion of one particular cohort")
ok(identical(getsec("attrition")$label, "Cohort attrition, as the cohort build recorded it"),
   "...the attrition panel says whose funnel it is showing, and no more")

cat("\n-- the study panels describe the study population --\n")
# LOT_LONG_FINAL is the population; LOT_LONG is that table before the line
# criteria, and a patient-level truncate criterion makes the two hold different
# PATIENTS. A clinical panel on LOT_LONG describes people the study excluded,
# with nothing on the page saying so.
VALIDATION_ONLY <- c("criteria_impact", "line_integrity", "headline")
pre <- Filter(function(s) grepl("{lot_long}", s$sql, fixed = TRUE) &&
                !(s$name %in% VALIDATION_ONLY), DASHBOARD_SECTIONS)
ok(!length(pre),
   if (length(pre)) paste0("panels still on the pre-criteria table: ",
                           paste(vapply(pre, `[[`, character(1), "name"), collapse = ", "))
   else "no clinical panel reads LOT_LONG - only the validation ones do")
# And a cohort-level panel has to restrict to the survivors, or it counts
# patients whose lines were all removed.
coh <- Filter(function(s) grepl("{patients}", s$sql, fixed = TRUE) &&
                !(s$name %in% VALIDATION_ONLY), DASHBOARD_SECTIONS)
ok(length(coh) > 0 && all(vapply(coh, function(s)
     grepl("PATID IN (SELECT DISTINCT PATID FROM {lot_final})", s$sql, fixed = TRUE),
     logical(1))),
   paste0("every cohort panel restricts to patients still in LOT_LONG_FINAL (",
          length(coh), ")"))
# needs has to name what the SQL reads, or probe_inputs cannot skip the panel
# when its table is missing and the query fails instead.
mism <- Filter(function(s) {
  u <- gsub("[{}]", "", unique(regmatches(s$sql,
         gregexpr("\\{(lot_long|lot_final|patients|attrition|run_meta|cohort)\\}",
                  s$sql))[[1]]))
  !all(u %in% s$needs)
}, DASHBOARD_SECTIONS)
ok(!length(mism),
   if (length(mism)) paste0("needs does not match what the SQL reads: ",
                            paste(vapply(mism, `[[`, character(1), "name"), collapse = ", "))
   else "every section declares the inputs its SQL actually reads")

cat("\n-- a bar says what its percentage is of --\n")
bars <- Filter(function(s) identical(s$render, "bar"), DASHBOARD_SECTIONS)
ok(all(vapply(bars, function(s) !is.null(s$pct) && s$pct %in% BAR_PCT, logical(1))),
   paste0("every bar declares a denominator (", length(bars), ")"))
stops(validate_sections(list(modifyList(
        Filter(function(s) identical(s$render, "bar"), DASHBOARD_SECTIONS)[[1]],
        list(pct = NULL)))),
      "a bar that declares none is refused rather than assuming one")
getp <- function(nm) getsec(nm)$pct
ok(identical(getp("attrition"), "first"),
   "the funnel is a share of its first row, which is the cohort it started from")
ok(identical(getp("index_by_year"), "total") &&
     identical(getp("lines_per_patient"), "total"),
   "a partition is a share of the whole")
ok(identical(getp("journey_coverage"), "none"),
   "and overlapping scenarios get no percentage at all")
d <- data.frame(label = c("a", "b", "c"), n = c(50L, 30L, 20L), stringsAsFactors = FALSE)
ok(grepl("60.0%", render_bar(d, "first"), fixed = TRUE),
   "first: the second bar is 60% of the first")
ok(grepl("30.0%", render_bar(d, "total"), fixed = TRUE),
   "total: the second bar is 30% of all three")
# bpct is the span the percentage lives in. The width: style carries a % of its
# own, so the test has to look for the span rather than for the character.
ok(!grepl("bpct", render_bar(d, "none"), fixed = TRUE) &&
     grepl("bpct", render_bar(d, "first"), fixed = TRUE),
   "none: no percentage is printed, where first prints one")

cat("\n-- transitions render as an SVG sankey --\n")
tr <- Filter(function(s) identical(s$name, "lot1_to_lot2"), DASHBOARD_SECTIONS)[[1]]
ok(identical(tr$render, "sankey") && identical(tr$tab, "Transitions"),
   "LOT1 to LOT2 is a sankey on the Transitions tab")
# Through MAX_LOT, which is 5 - stopping at LOT4 would leave the last
# transition the build produces undrawn.
trs <- vapply(Filter(function(s) identical(s$tab, "Transitions"), DASHBOARD_SECTIONS),
              `[[`, character(1), "name")
ok(setequal(trs, c("lot1_to_lot2", "lot2_to_lot3", "lot3_to_lot4", "lot4_to_lot5")),
   paste0("every consecutive pair up to MAX_LOT is drawn (", length(trs), ")"))
tsql <- fill_sql(tr$sql, INPUTS, cfg)
# LEFT JOIN, so the patients who stopped after LOT{a} are a terminal node
# rather than absent. Progressors-only could not show the one thing a reader
# looks at a transition for: how many went on at all.
ok(grepl("LEFT JOIN b ON a.PATID = b.PATID", tsql, fixed = TRUE) &&
     grepl("'No LOT2'", tsql, fixed = TRUE),
   "a left join, so those who stopped are drawn instead of vanishing")
# Ranked out of the top-N: on a cohort with many regimens the largest single
# answer is usually "stopped", and ranking it with them would fold it into
# "Other".
ok(grepl("WHERE stopped = 0 GROUP BY tgt", tsql, fixed = TRUE) &&
     grepl("CASE WHEN s.stopped = 1 THEN s.tgt", tsql, fixed = TRUE),
   "...and the stopped node cannot be collapsed into Other")
# Generated from MAX_LOT, not written out per pair: pinned to five, a run that
# built six would silently lose LOT5 to LOT6 and one that built three would
# draw two empty panels.
ok(length(.transition_sections(3)) == 2L &&
     identical(.transition_sections(3)[[2]]$name, "lot2_to_lot3"),
   "the pairs follow MAX_LOT rather than a hardcoded five")
stops(.transition_sections(1), "...and a MAX_LOT with no transition in it is refused")
# A second copy of lot's setting can disagree with the run being drawn, and
# too low is the case that costs something: the moves above it are in the
# tables and on no panel.
bd2 <- readLines(file.path(ROOT, "R", "build_dashboard.R"), warn = FALSE)
ok(any(grepl("check_max_lot(con, inputs, have, cfg)", bd2, fixed = TRUE)) &&
     any(grepl("SELECT max(LOT_NUM) AS n FROM ", bd2, fixed = TRUE)),
   "the setting is checked against the lines the run actually built")
ok(any(grepl("on no panel", bd2, fixed = TRUE)),
   "...and a MAX_LOT below what was built is a warning, not a silent gap")
ok(grepl("LIMIT 10", tsql, fixed = TRUE) && grepl("coalesce(t.tgt, \'Other\')", tsql, fixed = TRUE),
   "top N sources, and everything else collapses to Other rather than vanishing")
sk <- render_sankey(data.frame(
  source = c("BORT DEX LEN", "BORT DEX LEN", "DARA LEN", "DARA LEN"),
  target = c("CARF DEX", "POM DEX", "CARF DEX", "Other"),
  n = c(400L, 120L, 90L, 30L), stringsAsFactors = FALSE))
ok(grepl("<svg", sk, fixed = TRUE) && grepl("</svg>", sk, fixed = TRUE),
   "it draws an SVG")
ok(length(gregexpr("<path", sk, fixed = TRUE)[[1]]) == 4L,
   "one ribbon per flow")
ok(length(gregexpr("<rect", sk, fixed = TRUE)[[1]]) == 5L,
   "...and one node per distinct regimen on either side (2 + 3)")
# No plotly, no script, no fetch: the whole point of drawing it ourselves.
ok(!grepl("<script", sk, fixed = TRUE) && !grepl("plotly", sk, fixed = TRUE),
   "with no script tag and no plotting library")
ok(grepl("<title>", sk, fixed = TRUE) && grepl("400 patients", sk, fixed = TRUE),
   "and every ribbon carries its count as a tooltip")
# A flow of one patient among thousands still has to be visible, or the chart
# says it does not exist.
thin <- render_sankey(data.frame(source = c("A", "B"), target = c("X", "Y"),
                                 n = c(10000L, 1L), stringsAsFactors = FALSE))
hs <- as.numeric(regmatches(thin, gregexpr('(?<=height=")[0-9.]+(?=")', thin, perl = TRUE))[[1]])
ok(all(hs[hs < 50] >= 2), "a one-patient flow is still drawn, not rounded away")
ok(grepl("No rows", render_sankey(NULL), fixed = TRUE),
   "an empty result says so")
ok(identical(render_sankey(data.frame(x = 1)), render_table(data.frame(x = 1))),
   "and a frame without source/target/n falls back to a table")

cat("\n-- the palette is in one place --\n")
css <- get(".CSS", envir = env)
PALETTE <- get("PALETTE", envir = env)
ok(grepl("#F36633", css, fixed = TRUE), "GSK orange is the primary")
# Orange and white. A third brand colour crept in when this was first written.
ok(grepl("--pa:#FFFFFF", css, fixed = TRUE) &&
     grepl("header{background:var(--o);color:var(--pa)", css, fixed = TRUE),
   "...on a white page, with the header band the orange itself")
ok(all(vapply(names(PALETTE), function(k) grepl(PALETTE[[k]], css, fixed = TRUE),
              logical(1))),
   paste0("every colour in the palette reaches the stylesheet (", length(PALETTE), ")"))
# Every rule refers to a variable, so changing PALETTE changes the page. A
# literal hex in the rules would survive the swap and look like a bug in it.
rules <- sub("^.*\\}", "", css)
ok(!grepl("#[0-9A-Fa-f]{6}", sub(":root\\{[^}]*\\}", "", css)) ||
     length(gregexpr("#[0-9A-Fa-f]{6}", sub(":root\\{[^}]*\\}", "", css))[[1]]) <= 3,
   "the rules use variables, not a scatter of literals")

cat("\n-- the LOT funnel is its own panel, not rows on the cohort's --\n")
sec_by <- function(nm) Filter(function(s) identical(s$name, nm), DASHBOARD_SECTIONS)[[1]]
la <- sec_by("lot_attrition"); lp <- sec_by("lot_progression")
# The cohort funnel counts patients INTO the cohort; this one counts what
# happened to them afterwards. One bar chart running from the end of the first
# into the second would read as a single narrowing when the populations and the
# reasons are different.
ok(!identical(la$needs, sec_by("attrition")$needs),
   "it reads the LOT build's own table, not the cohort build's")
ok(grepl("KIND <> 'progression'", la$sql, fixed = TRUE) &&
     grepl("KIND = 'progression'", lp$sql, fixed = TRUE),
   "...and progression is split off, since nobody was removed there")
# pct='first' over rows ordered by STEP_NUM: the funnel's first row is the
# cohort handed over, and progression's first row is LOT1 - so each panel's
# percentages are of the base that panel is about.
ok(identical(la$pct, "first") && identical(lp$pct, "first") &&
     grepl("ORDER BY STEP_NUM", la$sql, fixed = TRUE) &&
     grepl("ORDER BY STEP_NUM", lp$sql, fixed = TRUE),
   "...each panel's percentages are of its own first row")
# A bar carries one number. Lines and the step-to-step share need a table.
ok(identical(sec_by("lot_attrition_detail")$render, "table"),
   "the lines and step-to-step shares get a table, which a bar cannot carry")
# One run's funnel over another run's numbers is the failure worth naming.
ok(all(grepl("RUN_ID = '{owner_run}'", c(la$sql, lp$sql,
                                         sec_by("lot_attrition_detail")$sql),
             fixed = TRUE)),
   "every LOT panel is scoped to the run that wrote the tables on the page")
bd <- readLines(file.path(ROOT, "R", "build_dashboard.R"), warn = FALSE)
ok(any(grepl("resolve_lot_attrition(secs, con, inputs, have, cfg)", bd, fixed = TRUE)),
   "...and rows belonging to some other LOT run skip the panels rather than render")
ok(any(grepl("one run's funnel above another run's numbers", bd, fixed = TRUE)),
   "...saying which run is missing rather than drawing an empty chart")

report()
