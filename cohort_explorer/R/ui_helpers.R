# =============================================================================
# ui_helpers.R  --  theme + registry-driven control builders for the Shiny UI
# -----------------------------------------------------------------------------
# The sidebar (IE criteria + inclusion-filter accordion) is generated FROM the
# criteria registry, so adding a criterion in criteria_registry.R automatically
# adds a control here -- no UI edits needed. That is the reuse contract on the
# presentation side.
# =============================================================================

# canonical accordion buckets, in a standard IE-panel order
UI_CATEGORIES <- c("Demographics", "Clinical", "Labs", "Treatments", "Other")

# input id for a criterion control
crit_input_id <- function(id) paste0("crit_", id)

# ---- theme ------------------------------------------------------------------
# A self-contained design system (no CSS framework, no web fonts): design tokens
# + component styles for the header, sidebar, accordions, KPI tiles, tabs, form
# controls (incl. the ionRangeSlider "rulers"), tables and status chips.
app_css <- function() {
  tags$style(HTML("
    :root{
      --accent:#E8480C; --accent-600:#C63D09; --accent-050:#FEF1EC;
      --teal:#0E7C7B; --teal-050:#E6F3F2;
      --ink:#1A1F2B; --muted:#5B6472; --faint:#8A93A2;
      --line:#E7E9EE; --line-2:#EDEFF3; --bg:#F4F5F8; --surface:#FFFFFF;
      --ok:#127A3E; --warn:#B4770B; --bad:#C0392B;
      --r-lg:14px; --r-md:10px; --r-sm:8px;
      --sh-1:0 1px 2px rgba(16,24,40,.05),0 1px 3px rgba(16,24,40,.08);
      --sh-2:0 6px 18px rgba(16,24,40,.10),0 2px 6px rgba(16,24,40,.06);
      --font:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
    }
    html,body{background:var(--bg);}
    body{font-family:var(--font);color:var(--ink);-webkit-font-smoothing:antialiased;
      font-size:14px;line-height:1.5;}
    .container-fluid{padding:0;max-width:1560px;margin:0 auto;}
    h1,h2,h3,h4,h5{color:var(--ink);font-weight:650;letter-spacing:-.01em;}
    h4{font-size:15px;} h5{font-size:13px;color:var(--muted);
      text-transform:uppercase;letter-spacing:.04em;font-weight:600;margin-top:18px;}

    /* ---- header (white + orange brand identity) ---- */
    .ce-header{position:sticky;top:0;z-index:50;background:var(--surface);
      color:var(--ink);padding:15px 26px;font-weight:700;font-size:19px;letter-spacing:-.01em;
      box-shadow:var(--sh-1);display:flex;align-items:baseline;gap:6px;
      border-bottom:3px solid var(--accent);}
    .ce-header::before{content:'';width:9px;height:22px;border-radius:3px;
      background:linear-gradient(180deg,var(--accent),#F47C20);
      display:inline-block;margin-right:12px;transform:translateY(4px);}
    .ce-header .sub{font-weight:400;font-size:13px;color:var(--muted);letter-spacing:0;}

    /* ---- layout shells ---- */
    .ce-side{background:var(--surface);border:1px solid var(--line);
      border-radius:var(--r-lg);padding:16px 16px 20px;margin:16px 6px 16px 16px;
      box-shadow:var(--sh-1);position:sticky;top:78px;}
    .ce-main{margin:16px 16px 16px 6px;}
    .ce-side h4{color:var(--ink);font-size:12px;text-transform:uppercase;
      letter-spacing:.06em;font-weight:700;margin:18px 0 8px;padding-bottom:7px;
      border-bottom:1px solid var(--line);}
    .ce-side h4:first-child{margin-top:2px;}

    /* ---- card / panel ---- */
    .ce-card{background:var(--surface);border:1px solid var(--line);
      border-radius:var(--r-lg);box-shadow:var(--sh-1);padding:18px 20px;margin-bottom:16px;}
    .tab-content{background:var(--surface);border:1px solid var(--line);border-top:none;
      border-radius:0 0 var(--r-lg) var(--r-lg);padding:20px 22px;box-shadow:var(--sh-1);}

    /* ---- accordion (IE criteria) ---- */
    details.ce-acc{border:1px solid var(--line);border-radius:var(--r-md);
      margin-bottom:8px;background:var(--surface);overflow:hidden;transition:box-shadow .15s;}
    details.ce-acc[open]{box-shadow:var(--sh-1);}
    details.ce-acc>summary{cursor:pointer;padding:11px 14px;font-weight:600;font-size:13px;
      list-style:none;display:flex;align-items:center;justify-content:space-between;
      color:var(--ink);user-select:none;transition:background .12s;}
    details.ce-acc>summary:hover{background:var(--accent-050);}
    details.ce-acc>summary::-webkit-details-marker{display:none;}
    details.ce-acc>summary::after{content:'';width:8px;height:8px;
      border-right:2px solid var(--faint);border-bottom:2px solid var(--faint);
      transform:rotate(-45deg);transition:transform .18s;margin-left:8px;}
    details.ce-acc[open]>summary::after{transform:rotate(45deg);}
    details.ce-acc[open]>summary{border-bottom:1px solid var(--line-2);}
    .ce-acc-body{padding:12px 14px 6px;}

    /* ---- KPI tiles ---- */
    .ce-kpi-row{display:flex;flex-wrap:wrap;gap:12px;margin:16px 0 4px;}
    .ce-kpi{flex:1 1 150px;background:var(--surface);border:1px solid var(--line);
      border-radius:var(--r-md);padding:14px 18px;box-shadow:var(--sh-1);
      position:relative;overflow:hidden;transition:transform .12s,box-shadow .12s;}
    .ce-kpi::before{content:'';position:absolute;left:0;top:0;bottom:0;width:4px;
      background:linear-gradient(180deg,var(--accent),#F47C20);}
    .ce-kpi:hover{transform:translateY(-2px);box-shadow:var(--sh-2);}
    .ce-kpi .v{font-size:27px;font-weight:750;color:var(--ink);letter-spacing:-.02em;
      line-height:1.1;font-variant-numeric:tabular-nums;}
    .ce-kpi .l{font-size:11.5px;color:var(--muted);text-transform:uppercase;
      letter-spacing:.04em;font-weight:600;margin-top:3px;}

    /* ---- buttons ---- */
    .btn-apply,.btn-primary{background:var(--accent);color:#fff;border:none;
      font-weight:650;border-radius:var(--r-sm);padding:9px 16px;
      box-shadow:0 1px 2px rgba(232,72,12,.3);transition:background .12s,transform .05s;}
    .btn-apply{width:100%;} .btn-apply:hover,.btn-primary:hover{background:var(--accent-600);color:#fff;}
    .btn-apply:active{transform:translateY(1px);}
    .btn-default{border-radius:var(--r-sm);border:1px solid var(--line);background:var(--surface);
      color:var(--ink);font-weight:600;}
    .btn-default:hover{background:var(--bg);border-color:var(--faint);}

    /* ---- tabs ---- */
    .nav-tabs{border-bottom:1px solid var(--line);background:var(--surface);
      border-radius:var(--r-lg) var(--r-lg) 0 0;padding:6px 8px 0;gap:2px;
      box-shadow:var(--sh-1);}
    .nav-tabs>li{margin:0;}
    .nav-tabs>li>a{border:none!important;color:var(--muted);font-weight:600;font-size:13px;
      padding:10px 15px;border-radius:var(--r-sm) var(--r-sm) 0 0;margin:0;
      background:transparent;transition:color .12s,background .12s;}
    .nav-tabs>li>a:hover{background:var(--accent-050);color:var(--accent-600);}
    .nav-tabs>li.active>a,.nav-tabs>li.active>a:hover,.nav-tabs>li.active>a:focus{
      color:var(--accent);background:transparent;border:none;
      box-shadow:inset 0 -3px 0 var(--accent);}

    /* ---- form controls ---- */
    .control-label,label{font-weight:600;font-size:12.5px;color:var(--muted);margin-bottom:5px;}
    .form-control,.selectize-input{border:1px solid var(--line);border-radius:var(--r-sm);
      box-shadow:none;font-size:13px;color:var(--ink);min-height:36px;transition:border-color .12s,box-shadow .12s;}
    .form-control:focus,.selectize-input.focus{border-color:var(--accent);
      box-shadow:0 0 0 3px var(--accent-050);}
    .selectize-input{padding:6px 10px;}
    .selectize-input .item{background:var(--accent-050)!important;color:var(--accent-600)!important;
      border:1px solid #F6C6B2!important;border-radius:6px;font-weight:600;font-size:12px;}
    .selectize-dropdown .active{background:var(--accent-050);color:var(--accent-600);}
    .checkbox label,.radio label{font-weight:500;color:var(--ink);font-size:13px;}
    input[type=checkbox]{accent-color:var(--accent);width:15px;height:15px;}

    /* ---- ionRangeSlider 'rulers' ---- */
    .irs--shiny .irs-bar{background:linear-gradient(90deg,var(--accent),#F47C20);
      border:none;height:6px;top:27px;}
    .irs--shiny .irs-line{background:var(--line-2);border:none;height:6px;top:27px;border-radius:6px;}
    .irs--shiny .irs-handle{border:2px solid var(--accent);background:#fff;
      box-shadow:var(--sh-1);width:18px;height:18px;top:21px;cursor:grab;}
    .irs--shiny .irs-handle:active{cursor:grabbing;}
    .irs--shiny .irs-from,.irs--shiny .irs-to,.irs--shiny .irs-single{
      background:var(--ink);border-radius:6px;font-size:11px;font-weight:600;padding:1px 6px;}
    .irs--shiny .irs-from:before,.irs--shiny .irs-to:before,.irs--shiny .irs-single:before{
      border-top-color:var(--ink);}
    .irs--shiny .irs-min,.irs--shiny .irs-max{background:var(--line-2);color:var(--muted);
      border-radius:5px;font-size:10px;}
    .irs--shiny .irs-grid-text{color:var(--faint);font-size:9px;}

    /* ---- tables ---- */
    .table{background:var(--surface);border-radius:var(--r-md);overflow:hidden;
      border:1px solid var(--line);font-size:13px;margin-bottom:16px;}
    .table>thead>tr>th{background:#F7F8FA;color:var(--muted);font-weight:650;
      text-transform:uppercase;letter-spacing:.03em;font-size:11px;border-bottom:1px solid var(--line);
      padding:10px 12px;vertical-align:middle;}
    .table>tbody>tr>td{padding:9px 12px;border-top:1px solid var(--line-2);
      font-variant-numeric:tabular-nums;color:var(--ink);}
    .table>tbody>tr:nth-child(even){background:#FBFBFD;}
    .table>tbody>tr:hover{background:var(--accent-050);}

    /* ---- misc ---- */
    .ce-note{font-size:12px;color:var(--muted);line-height:1.5;}
    .ce-banner{background:linear-gradient(90deg,#FDECEA,#FEF4F2);border:1px solid #F5C4BA;
      color:#8A2418;padding:10px 22px;font-size:13px;font-weight:600;}
    .well{background:var(--surface);border:1px solid var(--line);border-radius:var(--r-md);
      box-shadow:var(--sh-1);}
    hr{border-top:1px solid var(--line);}
    .st-PASS{color:var(--ok);font-weight:650;} .st-WARN{color:var(--warn);font-weight:650;}
    .st-FAIL{color:var(--bad);font-weight:750;}
    ::selection{background:var(--accent-050);}
  "))
}

# KPI tile. Optional `sub` adds a small caption under the label; the row wrapper
# `.ce-kpi-row` (flex) lays multiple tiles out evenly.
kpi <- function(value, label, sub = NULL) {
  div(class = "ce-kpi",
      div(class = "v", value),
      div(class = "l", label),
      if (!is.null(sub)) div(class = "ce-note", style = "margin-top:2px;", sub))
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
      lv <- cat_levels(df[[crit$variable]])  # incl "(Missing)" so neutral keeps NA rows
      # NULL default = all observed levels (neutral); else intersect
      sel <- if (is.null(crit$default)) lv else intersect(crit$default, lv)
      selectInput(iid, crit$label, choices = lv, selected = sel, multiple = TRUE)
    }
  })
  tags$details(class = "ce-acc",
    open = if (cat == "Demographics") NA else NULL,
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
