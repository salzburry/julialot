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
for (nm in ls(env)) assign(nm, get(nm, envir = env))

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
               run_meta = "wk.p_LOT_RUN_METADATA", attrition = "wk.c_NDMM_ATTRITION")
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
cfg <- list(top_n = 10L)
for (s in DASHBOARD_SECTIONS)
  runs(fill_sql(s$sql, INPUTS, cfg), paste0("'", s$name, "' resolves every {name}"))
stops(fill_sql("SELECT * FROM {nosuch}", INPUTS, cfg),
      "a section naming something else stops the build rather than querying it")
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
          run_meta = TRUE, attrition = FALSE)
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

report()
