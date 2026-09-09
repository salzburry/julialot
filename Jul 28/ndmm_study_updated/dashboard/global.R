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
if (!dir.exists(.pkg_dir)) .pkg_dir <- file.path(dirname(.dash_dir), "study223926")
if (!dir.exists(.pkg_dir))
  stop("DASHBOARD ERROR: cannot find the study package. Set DASH_PACKAGE_DIR ",
       "to the directory holding R/registry.R.", call. = FALSE)

for (f in c("config_223926.R", "db_utils_223926.R", "registry.R", "windows.R"))
  source(file.path(.pkg_dir, "R", f))
# The cohort registry declares CRITERION_FLAG and the cohort list.
source(file.path(.pkg_dir, "R", "modules", "01_cohorts.R"))

source(file.path(.dash_dir, "config", "dashboard_config.R"))
for (f in c("spec.R", "scenarios.R", "aggregate.R", "synthetic.R", "sources.R",
            "render.R", "panels.R"))
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

SRC <- new_source(DASH_CFG)
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
