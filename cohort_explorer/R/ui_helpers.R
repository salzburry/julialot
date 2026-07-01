# =============================================================================
# ui_helpers.R  --  theme + registry-driven control builders for the Shiny UI
# -----------------------------------------------------------------------------
# The sidebar (IE criteria + inclusion-filter accordion) is generated FROM the
# criteria registry, so adding a criterion in criteria_registry.R automatically
# adds a control here -- no UI edits needed. That is the reuse contract on the
# presentation side.
# =============================================================================

# canonical accordion buckets, in the order the sample dashboard shows them
UI_CATEGORIES <- c("Demographics", "Clinical", "Labs", "Treatments", "Other")

# input id for a criterion control
crit_input_id <- function(id) paste0("crit_", id)

# ---- theme ------------------------------------------------------------------
app_css <- function() {
  tags$style(HTML("
    :root { --accent:#E8480C; --teal:#1F8A8A; --ink:#222; }
    body { font-family: 'Segoe UI', Arial, sans-serif; color: var(--ink); }
    .ce-header { background: linear-gradient(90deg,#E8480C,#F47C20);
      color:#fff; padding:10px 16px; font-weight:700; font-size:18px; }
    .ce-header .sub { font-weight:400; font-size:13px; opacity:.92; }
    .ce-side { background:#fafafa; border-right:1px solid #eee; padding:12px; }
    .ce-side h4 { color:var(--accent); border-bottom:2px solid var(--accent);
      padding-bottom:4px; margin-top:14px; font-size:15px; }
    details.ce-acc { border:1px solid #e3e3e3; border-radius:6px;
      margin-bottom:6px; background:#fff; }
    details.ce-acc > summary { cursor:pointer; padding:8px 10px; font-weight:600;
      list-style:none; }
    details.ce-acc > summary::-webkit-details-marker { display:none; }
    details.ce-acc[open] > summary { border-bottom:1px solid #eee; }
    .ce-acc-body { padding:8px 12px; }
    .btn-apply { background:var(--accent); color:#fff; border:none;
      font-weight:600; width:100%; }
    .btn-apply:hover { background:#c63d09; color:#fff; }
    .ce-kpi { display:inline-block; background:#fff; border:1px solid #eee;
      border-radius:8px; padding:10px 16px; margin:6px 8px 6px 0; text-align:center; }
    .ce-kpi .v { font-size:22px; font-weight:700; color:var(--accent); }
    .ce-kpi .l { font-size:12px; color:#666; }
    .ce-note { font-size:12px; color:#777; }
    .ce-banner { background:#fde8e8; border:1px solid #f5b5b5; color:#7a1f1f;
      padding:8px 16px; font-size:13px; }
    .st-PASS { color:#1a7f37; font-weight:600; }
    .st-WARN { color:#b58100; font-weight:600; }
    .st-FAIL { color:#c0392b; font-weight:700; }
  "))
}

kpi <- function(value, label) {
  div(class = "ce-kpi", div(class = "v", value), div(class = "l", label))
}

# ---- IE criteria + filter accordion (rendered server-side per cohort) -------
# Build one accordion section (<details>) for a ui_category, containing every
# registry criterion in it (flags as checkboxes, params as sliders/selects).
.acc_section <- function(cat, df, active_flags, reg) {
  ids <- names(reg)[vapply(reg, function(c) c$ui_category == cat, logical(1))]
  if (!length(ids)) {
    if (cat == "Labs")
      return(tags$details(class = "ce-acc",
        tags$summary(cat),
        div(class = "ce-acc-body ce-note",
            "No lab-based criteria configured. Add one in criteria_registry.R.")))
    return(NULL)
  }
  controls <- lapply(ids, function(id) {
    crit <- reg[[id]]
    iid  <- crit_input_id(id)
    if (identical(crit$type, "flag")) {
      checkboxInput(iid, label = crit$label, value = id %in% active_flags)
    } else if (identical(crit$filter, "range")) {
      rng <- range(df[[crit$variable]], na.rm = TRUE)
      lo <- floor(rng[1]); hi <- ceiling(rng[2])
      # NULL default = full data range (neutral); else clamp into bounds
      val <- if (is.null(crit$default)) c(lo, hi)
             else c(max(lo, crit$default[1]), min(hi, crit$default[2]))
      sliderInput(iid, crit$label, min = lo, max = hi, value = val, step = 1)
    } else { # categorical
      lv <- sort(unique(as.character(df[[crit$variable]])))
      # NULL default = all observed levels (neutral); else intersect
      sel <- if (is.null(crit$default)) lv else intersect(crit$default, lv)
      selectInput(iid, crit$label, choices = lv, selected = sel, multiple = TRUE)
    }
  })
  tags$details(class = "ce-acc", open = (cat == "Demographics") || NULL,
    tags$summary(cat),
    div(class = "ce-acc-body", controls))
}

render_filter_accordion <- function(df, active_flags, reg) {
  tagList(lapply(UI_CATEGORIES, .acc_section, df = df,
                 active_flags = active_flags, reg = reg))
}

# ---- KM tab UI factory ------------------------------------------------------
km_tab_ui <- function(key, ep_label, strata_choices, tab_label = key) {
  tabPanel(tab_label,
    br(),
    fluidRow(
      column(4, sliderInput(paste0("km_", key, "_horizon"),
                            "Time Horizon (Months)", min = 6, max = 150,
                            value = 60, step = 6)),
      column(4, selectInput(paste0("km_", key, "_strata"), "Select Strata",
                            choices = c("None" = "", strata_choices),
                            selected = "")),
      column(4, br(), actionButton(paste0("km_", key, "_apply"), "Apply",
                                   class = "btn-apply"))),
    h4(ep_label),
    plotOutput(paste0("km_", key, "_plot"), height = "420px"),
    h5("Landmark survival probability (95% CI) at 6/9/12/18/24 months"),
    tableOutput(paste0("km_", key, "_landmark")),
    h5("Median (95% CI)"), tableOutput(paste0("km_", key, "_med")),
    h5("Number at risk"),  tableOutput(paste0("km_", key, "_risk")))
}

# status cell -> coloured HTML (for checks tables)
status_html <- function(s) {
  sprintf("<span class='st-%s'>%s</span>", s, s)
}
