#!/usr/bin/env Rscript
# validate_config.R
# Typed configuration validation (Increment 1A). One layered config:
# code defaults < study file < env vars/secrets. Validates types, allowed
# values, ranges, and required fields, and FAILS FAST with all errors before
# any expensive claims scan. Pure R; runnable.

# --- the config spec (extend as params are folded onto one object) --------
# Each entry: type, required, default, allowed (optional), min/max (optional).
CONFIG_SPEC <- list(
  induction_window_days        = list(type = "integer", required = TRUE,  default = 60L, min = 1L, max = 365L),
  lot_n_induction_window_days  = list(type = "integer", required = TRUE,  default = 30L, min = 1L, max = 365L),
  map_discon_gap_days          = list(type = "integer", required = TRUE,  default = 90L, min = 1L, max = 365L),
  medical_day_supply           = list(type = "integer", required = TRUE,  default = 28L, min = 1L, max = 365L),
  sct_auto_window_days         = list(type = "integer", required = TRUE,  default = 13L, min = 1L, max = 60L),
  sct_auto_gap_days            = list(type = "integer", required = TRUE,  default = 60L, min = 1L, max = 365L),
  sct_tandem_days              = list(type = "integer", required = TRUE,  default = 180L, min = 1L, max = 730L),
  cart_consolidation_days      = list(type = "integer", required = TRUE,  default = 45L, min = 1L, max = 365L),
  max_lot                      = list(type = "integer", required = TRUE,  default = 5L,  min = 2L, max = 9L),
  allo_lot_span                = list(type = "character", required = TRUE, default = "single_day",
                                      allowed = c("single_day", "extend_to_next")),
  censor_at_disenrollment      = list(type = "logical", required = TRUE,  default = FALSE),
  study_start                  = list(type = "date", required = TRUE),
  study_end                    = list(type = "date", required = TRUE),
  id_start                     = list(type = "date", required = TRUE),
  id_end                       = list(type = "date", required = TRUE)
)

.is_type <- function(v, type) {
  switch(type,
    integer   = is.numeric(v) && length(v) == 1 && v == as.integer(v),
    character = is.character(v) && length(v) == 1,
    logical   = is.logical(v) && length(v) == 1,
    date      = is.character(v) && length(v) == 1 &&
                !is.na(as.Date(v, format = "%Y-%m-%d")),
    FALSE)
}

validate_config <- function(cfg, spec = CONFIG_SPEC) {
  errors <- character(0)
  for (name in names(spec)) {
    s <- spec[[name]]
    present <- name %in% names(cfg) && !is.null(cfg[[name]])
    if (!present) {
      if (isTRUE(s$required) && is.null(s$default))
        errors <- c(errors, sprintf("[%s] required but missing", name))
      next
    }
    v <- cfg[[name]]
    if (!.is_type(v, s$type)) {
      errors <- c(errors, sprintf("[%s] expected %s, got '%s'", name, s$type, paste(v, collapse = ",")))
      next
    }
    if (!is.null(s$allowed) && !(v %in% s$allowed))
      errors <- c(errors, sprintf("[%s] '%s' not in {%s}", name, v, paste(s$allowed, collapse = ", ")))
    if (!is.null(s$min) && is.numeric(v) && v < s$min)
      errors <- c(errors, sprintf("[%s] %s < min %s", name, v, s$min))
    if (!is.null(s$max) && is.numeric(v) && v > s$max)
      errors <- c(errors, sprintf("[%s] %s > max %s", name, v, s$max))
  }
  # cross-field sanity on the study period + identification window. The ID window
  # must be ordered AND contained within the study period (you cannot identify
  # patients outside the observation window).
  d <- function(x) as.Date(cfg[[x]], "%Y-%m-%d")
  isd <- function(x) x %in% names(cfg) && .is_type(cfg[[x]], "date")
  if (isd("study_start") && isd("study_end") && d("study_start") >= d("study_end"))
    errors <- c(errors, "[study_period] study_start must be < study_end")
  if (isd("id_start") && isd("id_end") && d("id_start") > d("id_end"))
    errors <- c(errors, "[study_period] id_start must be <= id_end")
  if (isd("id_start") && isd("study_start") && d("id_start") < d("study_start"))
    errors <- c(errors, "[study_period] id_start must be >= study_start (ID window inside the study period)")
  if (isd("id_end") && isd("study_end") && d("id_end") > d("study_end"))
    errors <- c(errors, "[study_period] id_end must be <= study_end (ID window inside the study period)")
  errors
}

# Apply defaults for any missing-but-defaulted field (returns resolved config).
apply_defaults <- function(cfg, spec = CONFIG_SPEC) {
  for (name in names(spec)) {
    s <- spec[[name]]
    if ((is.null(cfg[[name]])) && !is.null(s$default)) cfg[[name]] <- s$default
  }
  cfg
}

validate_or_die <- function(cfg, spec = CONFIG_SPEC) {
  cfg <- apply_defaults(cfg, spec)
  errs <- validate_config(cfg, spec)
  if (length(errs)) {
    cat("CONFIG INVALID -- aborting before any claims scan:\n")
    for (e in errs) cat("  -", e, "\n")
    quit(status = 1)
  }
  cfg
}

if (sys.nframe() == 0 && !interactive()) {
  good <- list(study_start = "2015-07-01", study_end = "2025-06-30",
               id_start = "2016-01-01", id_end = "2025-06-30")
  e1 <- validate_config(apply_defaults(good))
  cat("self-test valid config:", if (length(e1) == 0) "OK\n" else paste(e1, collapse = "\n"))
  e2 <- validate_config(apply_defaults(c(good, list(max_lot = 99L, allo_lot_span = "bogus"))))
  cat("self-test invalid config caught:", length(e2) > 0, "->",
      paste(e2, collapse = " | "), "\n")
}
