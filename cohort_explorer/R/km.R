# =============================================================================
# km.R  --  time-to-event (Kaplan-Meier) for the protocol endpoints:
#           OS (time to death), TTD, TTNT, Attrition (dx -> 1L), and a clearly
#           labelled EXPLORATORY PFS (protocol §6.9: PFS not ascertainable).
#           Uses `survival`; plotting is base graphics.
# =============================================================================

# Endpoint dictionary. `event = NA` => an all-events endpoint (Attrition: every
# patient reaches 1L, so the KM is the distribution of the gap).
endpoint_dictionary <- function() {
  list(
    OS   = list(time = "os_time",   event = "os_event",
                label = "Overall Survival — time to death (OS)", protocol = TRUE),
    TTD  = list(time = "ttd_time",  event = "ttd_event",
                label = "Time to Treatment Discontinuation (TTD)", protocol = TRUE),
    TTNT = list(time = "ttnt_time", event = "ttnt_event",
                label = "Time to Next Treatment (TTNT)", protocol = TRUE),
    Attrition = list(time = "dx_to_1l_months", event = NA,
                label = "Attrition — time from diagnosis to 1L", protocol = TRUE),
    PFS_exploratory = list(time = "pfs_time", event = "pfs_event",
                label = "PFS — EXPLORATORY (NOT a protocol endpoint; §6.9)",
                protocol = FALSE)
  )
}

LANDMARK_MONTHS <- c(6, 9, 12, 18, 24)   # protocol §6.7.2 survival probabilities
MIN_FU_MONTHS   <- 3                      # protocol §6.7.2 potential-follow-up cut

# Fit a KM curve. `min_fu` (months) applies the protocol >=3-mo potential
# follow-up restriction when the cohort carries `fu_potential_months`.
km_fit <- function(df, endpoint, strata = NULL, ep_dict = endpoint_dictionary(),
                   min_fu = NULL) {
  if (!requireNamespace("survival", quietly = TRUE))
    stop("the 'survival' package is required for KM curves.", call. = FALSE)
  ep <- ep_dict[[endpoint]]
  if (is.null(ep)) stop("unknown endpoint: ", endpoint, call. = FALSE)
  if (!is.null(min_fu) && "fu_potential_months" %in% names(df))
    df <- df[!is.na(df$fu_potential_months) & df$fu_potential_months >= min_fu, ,
             drop = FALSE]
  if (!nrow(df)) return(NULL)

  time  <- suppressWarnings(as.numeric(df[[ep$time]]))
  event <- if (is.na(ep$event)[1]) rep(1L, nrow(df))
           else suppressWarnings(as.integer(df[[ep$event]]))
  ok    <- !is.na(time) & !is.na(event) & time >= 0
  d     <- data.frame(time = time[ok], event = event[ok])

  use_strata <- !is.null(strata) && nzchar(strata) && strata %in% names(df)
  if (use_strata) {
    d$grp <- as.character(df[[strata]][ok])
    # drop <25-patient strata (protocol §6.5)
    keep_lv <- names(which(table(d$grp) >= 25))
    d <- d[d$grp %in% keep_lv, , drop = FALSE]
    if (!nrow(d)) return(NULL)
  }
  surv <- survival::Surv(d$time, d$event)
  fit  <- if (use_strata) survival::survfit(surv ~ grp, data = d)
          else survival::survfit(surv ~ 1, data = d)
  list(fit = fit, ep = ep, strata = if (use_strata) strata else NULL, n = nrow(d))
}

# Median survival (+ 95% CI) per stratum.
km_medians <- function(km) {
  if (is.null(km)) return(NULL)
  s <- summary(km$fit)$table
  if (is.matrix(s))
    data.frame(Group = sub("^grp=", "", rownames(s)), N = s[, "records"],
               Events = s[, "events"], Median = round(s[, "median"], 1),
               LCL = round(s[, "0.95LCL"], 1), UCL = round(s[, "0.95UCL"], 1),
               row.names = NULL, check.names = FALSE)
  else
    data.frame(Group = "Overall", N = s["records"], Events = s["events"],
               Median = round(s["median"], 1), LCL = round(s["0.95LCL"], 1),
               UCL = round(s["0.95UCL"], 1), row.names = NULL, check.names = FALSE)
}

# Landmark survival probabilities (+95% CI) at protocol time points.
km_landmark <- function(km, times = LANDMARK_MONTHS) {
  if (is.null(km)) return(NULL)
  s <- summary(km$fit, times = times, extend = TRUE)
  cell <- function(p, lo, hi) sprintf("%.1f%% (%.1f-%.1f)", 100 * p, 100 * lo, 100 * hi)
  if (is.null(s$strata)) {
    vals <- cell(s$surv, s$lower, s$upper)
    out <- as.data.frame(as.list(vals), check.names = FALSE)
    names(out) <- paste0(s$time, "mo"); cbind(Group = "Overall", out)
  } else {
    grp <- sub("^grp=", "", as.character(s$strata))
    parts <- lapply(split(seq_along(grp), grp), function(ix) {
      r <- as.data.frame(as.list(cell(s$surv[ix], s$lower[ix], s$upper[ix])),
                         check.names = FALSE)
      names(r) <- paste0(s$time[ix], "mo"); r
    })
    data.frame(Group = names(parts), do.call(rbind, parts),
               check.names = FALSE, row.names = NULL)
  }
}

# Plot a KM curve (base graphics). horizon = x-axis cap in months.
km_plot <- function(km, horizon = 60) {
  if (is.null(km)) { plot.new()
    text(0.5, 0.5, "No data for the current cohort / follow-up restriction."); return(invisible()) }
  cols <- c("#E8480C", "#1F8A8A", "#6A4C93", "#3A6EA5", "#B5179E", "#666666",
            "#2E8B57", "#D62828")
  op <- par(mar = c(4.5, 4.5, 2.5, 1)); on.exit(par(op))
  plot(km$fit, xlim = c(0, horizon), ylim = c(0, 1), col = cols, lwd = 2,
       conf.int = FALSE, mark.time = TRUE, xlab = "Months since index",
       ylab = "Probability", main = km$ep$label)
  grid(col = "grey90")
  if (!is.null(km$strata)) {
    labs <- sub("^grp=", "", names(km$fit$strata))
    legend("topright", legend = labs, col = cols[seq_along(labs)], lwd = 2,
           bty = "n", title = km$strata, cex = 0.9)
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
    data.frame(Group = "Overall", risk, check.names = FALSE, stringsAsFactors = FALSE)
  } else {
    grp <- sub("^grp=", "", as.character(s$strata))
    parts <- lapply(split(seq_along(grp), grp), function(ix) {
      r <- data.frame(t(s$n.risk[ix]), check.names = FALSE); names(r) <- s$time[ix]; r })
    data.frame(Group = names(parts), do.call(rbind, parts),
               check.names = FALSE, row.names = NULL)
  }
}
