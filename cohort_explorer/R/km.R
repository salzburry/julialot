# =============================================================================
# km.R  --  time-to-event (Kaplan-Meier) for the rwOS / rwPFS / rwTTD / rwTTNT
#           tabs. Uses the `survival` package; plotting is base graphics so the
#           only hard dependency beyond shiny is survival.
# =============================================================================

# Endpoint dictionary: maps a tab key to its (time, event) columns + label.
endpoint_dictionary <- function() {
  list(
    rwOS   = list(time = "os_time",   event = "os_event",
                  label = "Real-World Overall Survival (rwOS)"),
    rwPFS  = list(time = "pfs_time",  event = "pfs_event",
                  label = "Real-World Progression-Free Survival (rwPFS)"),
    rwTTD  = list(time = "ttd_time",  event = "ttd_event",
                  label = "Real-World Time to Treatment Discontinuation (rwTTD)"),
    rwTTNT = list(time = "ttnt_time", event = "ttnt_event",
                  label = "Real-World Time to Next Treatment (rwTTNT)")
  )
}

# Fit a KM curve. Returns list(fit, ep, strata, n). `horizon` (months) is only
# used by the plot/median helpers, not the fit itself.
km_fit <- function(df, endpoint, strata = NULL,
                   ep_dict = endpoint_dictionary()) {
  if (!requireNamespace("survival", quietly = TRUE))
    stop("the 'survival' package is required for KM curves.", call. = FALSE)
  ep <- ep_dict[[endpoint]]
  if (is.null(ep)) stop("unknown endpoint: ", endpoint, call. = FALSE)
  if (!nrow(df)) return(NULL)

  time  <- suppressWarnings(as.numeric(df[[ep$time]]))
  event <- suppressWarnings(as.integer(df[[ep$event]]))
  ok    <- !is.na(time) & !is.na(event) & time >= 0
  d     <- data.frame(time = time[ok], event = event[ok])

  use_strata <- !is.null(strata) && nzchar(strata) && strata %in% names(df)
  if (use_strata) d$grp <- as.character(df[[strata]][ok])

  surv <- survival::Surv(d$time, d$event)
  fit  <- if (use_strata)
    survival::survfit(surv ~ grp, data = d)
  else
    survival::survfit(surv ~ 1, data = d)

  list(fit = fit, ep = ep, strata = if (use_strata) strata else NULL,
       n = nrow(d))
}

# Median survival (+ 95% CI) per stratum as a tidy data.frame.
km_medians <- function(km) {
  if (is.null(km)) return(NULL)
  s <- summary(km$fit)$table
  if (is.matrix(s)) {
    out <- data.frame(
      Group  = sub("^grp=", "", rownames(s)),
      N      = s[, "records"],
      Events = s[, "events"],
      Median = round(s[, "median"], 1),
      LCL    = round(s[, "0.95LCL"], 1),
      UCL    = round(s[, "0.95UCL"], 1),
      row.names = NULL, check.names = FALSE)
  } else {
    out <- data.frame(
      Group = "Overall", N = s["records"], Events = s["events"],
      Median = round(s["median"], 1), LCL = round(s["0.95LCL"], 1),
      UCL = round(s["0.95UCL"], 1), row.names = NULL, check.names = FALSE)
  }
  out
}

# Plot a KM curve (base graphics). horizon = x-axis cap in months.
km_plot <- function(km, horizon = 60) {
  if (is.null(km)) { plot.new(); text(0.5, 0.5, "No data for the current cohort."); return(invisible()) }
  cols <- c("#E8480C", "#1F8A8A", "#6A4C93", "#3A6EA5", "#B5179E", "#666666")
  op <- par(mar = c(4.5, 4.5, 2.5, 1)); on.exit(par(op))
  plot(km$fit, xlim = c(0, horizon), ylim = c(0, 1),
       col = cols, lwd = 2, conf.int = FALSE, mark.time = TRUE,
       xlab = "Months since 1L index", ylab = "Survival probability",
       main = km$ep$label)
  grid(col = "grey90")
  if (!is.null(km$strata)) {
    labs <- sub("^grp=", "", names(km$fit$strata))
    legend("topright", legend = labs, col = cols[seq_along(labs)],
           lwd = 2, bty = "n", title = km$strata, cex = 0.9)
  }
  invisible()
}

# Risk table: # at risk at evenly spaced horizon ticks.
km_risk_table <- function(km, horizon = 60, n_ticks = 6) {
  if (is.null(km)) return(NULL)
  times <- round(seq(0, horizon, length.out = n_ticks))
  s <- summary(km$fit, times = times, extend = TRUE)
  if (is.null(s$strata)) {
    risk <- data.frame(t(s$n.risk), check.names = FALSE); names(risk) <- times
    out <- data.frame(Group = "Overall", risk, check.names = FALSE,
                      stringsAsFactors = FALSE)
  } else {
    grp <- sub("^grp=", "", as.character(s$strata))
    parts <- lapply(split(seq_along(grp), grp), function(ix) {
      r <- data.frame(t(s$n.risk[ix]), check.names = FALSE)
      names(r) <- s$time[ix]; r
    })
    risk <- do.call(rbind, parts)
    out <- data.frame(Group = names(parts), risk, check.names = FALSE,
                      stringsAsFactors = FALSE)
    rownames(out) <- NULL
  }
  out
}
