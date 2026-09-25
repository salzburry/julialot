# Loaded once at startup. Sources the study package's own registries, then the
# dashboard's, then opens the configured data source.
#
# The package is the authority on what exists: which cohorts, which modules,
# which tables, which open questions and what each may be set to. The dashboard
# imports those rather than restating them, so a module or a question added to
# the package appears here without an edit.

.dash_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(.dash_dir) || !nzchar(.dash_dir)) .dash_dir <- getwd()

DASH_CFG <- local({
  source(file.path(.dash_dir, "config", "dashboard_config.R"), local = TRUE)
  dashboard_config()
})

# The study package. Only the files that declare things - no module is sourced
# and nothing connects to a warehouse from here.
.pkg_dir <- DASH_CFG$package_dir
if (!dir.exists(.pkg_dir))
  .pkg_dir <- file.path(dirname(.dash_dir), "variables")
if (!dir.exists(.pkg_dir))
  stop("DASHBOARD ERROR: cannot find the study package. Set DASH_PACKAGE_DIR ",
       "to the directory holding R/registry.R.", call. = FALSE)

for (f in c("config_223926.R", "db_utils_223926.R", "registry.R", "contract.R",
            "windows.R"))
  source(file.path(.pkg_dir, "R", f))
# The cohort registry declares CRITERION_FLAG and the cohort list.
source(file.path(.pkg_dir, "R", "modules", "01_cohorts.R"))
# WHICH registry this is. Everything below decides from it which tables a
# run wrote and which of them were published suppressed, and a run records
# the hash of the contract it was driven by; a run driven by another one is
# not decidable here and is refused (scenario_contract_bound in R/scenarios.R).
DASH_CONTRACT_MD5 <- study_contract_md5()

source(file.path(.dash_dir, "config", "dashboard_config.R"))
for (f in c("spec.R", "scenarios.R", "aggregate.R", "prepare.R", "synthetic.R",
            "sources.R", "render.R", "tfls.R", "panels.R"))
  source(file.path(.dash_dir, "R", f))

SETTING_ENV <- setting_env_map()

# What a viewer may change without a new run, and what needs one.
#
# Read off the package: a question it applies HERE changes its SQL, so it needs
# a run; one applied upstream needs a different cohort build entirely. Neither
# is a live control, and the UI says which is which rather than offering a
# switch that would quietly do nothing.
SCENARIO_SETTINGS <- names(OPEN_QUESTION_SOURCE)[OPEN_QUESTION_SOURCE == "here"]
UPSTREAM_SETTINGS <- names(OPEN_QUESTION_SOURCE)[OPEN_QUESTION_SOURCE == "upstream"]

DASH_TABLES <- dashboard_tables()

# The warehouse source needs a live connection. It is opened here, where the
# source is built, because the source holds it for the life of the process:
# the package's own connect_db() with the package's own settings, resolved the
# way a run resolves them, so the dashboard cannot connect differently from the
# runs it reads. Closed when the process ends; a Shiny app has no earlier
# moment, since every session shares this one.
#
# Only in warehouse mode: the other two sources read files or generate rows,
# and must not require a Spark method to be configured at all.
DASH_CON <- NULL
if (identical(DASH_CFG$source, "warehouse")) {
  source(file.path(.pkg_dir, "R", "load_inputs.R"))
  load_pipeline_inputs(.pkg_dir, "config.csv")
  # With the catalog and schema this dashboard resolved, not a second
  # resolution of its own: bare, cfg_defaults() checked the schema against
  # DATABRICKS_CATALOG alone and stopped an app given DASH_CATALOG=analytics
  # and WORK_SCHEMA=analytics.usr00000, which dashboard_config() accepts. The
  # package's config only connects and retries here; every table is read
  # under DASH_CFG's names either way.
  set_study_config(cfg_defaults(catalog = DASH_CFG$catalog,
                                work_schema = DASH_CFG$work_schema))
  DASH_CON <- connect_db(study_config())
  reg.finalizer(environment(), function(e) try(disconnect_db(DASH_CON),
                                               silent = TRUE), onexit = TRUE)
}

SRC <- new_source(DASH_CFG, DASH_CON)
SCENARIOS <- load_scenarios(SRC)
SCENARIO_DIFFS <- scenario_diff_keys(SCENARIOS)

PROVENANCE <- list(
  synthetic = isTRUE(SRC$synthetic),
  kind = SRC$kind,
  origin = SRC$origin,
  n_scenarios = length(SCENARIOS),
  usable = sum(vapply(SCENARIOS, scenario_is_usable, logical(1))))

if (!length(SCENARIOS))
  message("No scenario found from ", SRC$kind, " (", SRC$origin,
          "). The dashboard will start and say so.")
