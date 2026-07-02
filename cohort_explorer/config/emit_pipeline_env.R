#!/usr/bin/env Rscript
# Turn the ONE study_config into the env vars the upstream LOT pipeline +
# analytic-cohort materialisation consume, so a study is defined in one place.
#
#   Rscript cohort_explorer/config/emit_pipeline_env.R [out.sh]
#
# then, on the warehouse host:
#   source out.sh && Rscript run_pipeline.R                    # your LOT pipeline entry point: build ELIG_COH_FINAL + LOT
#   source out.sh && Rscript cohort_explorer/warehouse/08_analytic_cohort.R  # materialise ANALYTIC_COHORT (skeleton)
#
# Env vars already set in the shell OVERRIDE study_config (resolved_study_config),
# so ad-hoc overrides still win. Prints the mapping to stdout and writes the file.

.here <- tryCatch(dirname(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1])),
          error = function(e) ".")
source(file.path(.here, "study_config.R"))

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[1] else file.path(.here, "pipeline_env.sh")

kv <- emit_pipeline_env(file = out)
cat("study_config -> pipeline env mapping (written to ", out, "):\n\n", sep = "")
for (k in names(kv)) cat(sprintf("  %-28s = %s\n", k, kv[[k]]))
cat("\nUsage:  source ", out, " && Rscript run_pipeline.R\n", sep = "")
