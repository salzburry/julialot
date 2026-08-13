# =============================================================================
# app.R  --  Oncology Real-World Data Explorer (cohort + IE flags edition)
# -----------------------------------------------------------------------------
# Interactive Shiny dashboard, driven by the flag-based cohort
# engine, aligned to the NDMM study: pick a cohort
# (Overall / NDMM), toggle IE criteria, tune filters, choose a line of therapy,
# and every tab (Patient Characteristics, OS/TTD/TTNT/Attrition + exploratory
# PFS, Regimen & Transitions, Attrition funnel, Checks) recomputes off the same
# selected cohort.
#
# Run:  shiny::runApp("cohort_explorer")            # synthetic data, no warehouse
#       COHORT_EXPLORER_DATA=flagged.csv COHORT_EXPLORER_LOTLONG=lotlong.csv \
#         R -e 'shiny::runApp("cohort_explorer")'
# =============================================================================

source(file.path(
  tryCatch(dirname(sys.frame(1)$ofile), error = function(e) getwd()), "global.R"))

`%||%` <- function(a, b) if (is.null(a)) b else a

# time-to-event tabs, derived from the active pack's endpoint dictionary so each
# indication can name/label/order its own endpoints (e.g. EC treats PFS as a
# primary endpoint, MM as exploratory). endpoint key -> short tab label.
KM_TABS <- lapply(EPDICT, function(e) e$tab %||% e$label)
# endpoints computed at the patient level only (1L), not per selected line
PATIENT_LEVEL_ONLY <- names(EPDICT)[!vapply(EPDICT,
  function(e) isTRUE(e$per_line), logical(1))]

# ---- UI ---------------------------------------------------------------------
main_tabs <- c(
  list(
    tabPanel("Patient Characteristics",
      br(),
      div(class = "ce-note", PACK$table1_note %||% paste(
          "Baseline characteristics (12-mo pre-index) for the selected cohort.",
          "Strata levels with <25 patients are suppressed.")),
      fluidRow(
        column(5, selectInput("pc_vars", "Select Variables",
                    choices = setNames(SUMMARY_VARS,
                      vapply(SUMMARY_VARS, var_label, character(1), dict = VARDICT)),
                    multiple = TRUE,
                    selected = c("age_band", "gender", "cci_band", "soc_category"))),
        column(4, selectInput("pc_strata", "Select Strata",
                    choices = c("None" = "", STRATA_LABELLED), selected = "")),
        column(3, br(), actionButton("pc_apply", "Apply", class = "btn-apply"))),
      h4(textOutput("pc_title")),
      textOutput("pc_suppressed"),
      h5("Categorical variables"), tableOutput("pc_cat"),
      h5("Continuous variables"),  tableOutput("pc_cont"),
      h5("Baseline safety events of interest (n / % + rate per 100 patient-years)"),
      tableOutput("pc_safety"))
  ),
  if (HAS_SURVIVAL)
    lapply(names(KM_TABS), function(k)
      km_tab_ui(k, EPDICT[[k]]$label, STRATA_LABELLED, KM_TABS[[k]]))
  else list(tabPanel("Time-to-event", br(), div(class = "ce-note",
      "Install the 'survival' package to enable the KM tabs."))),
  list(
    tabPanel("Regimen & Transitions",
      br(),
      div(class = "ce-note", PACK$pathway_note %||% paste(
          "Regimen frequency for the selected Line of Therapy; the full",
          "1L->NL treatment-pattern pathway (patients who stop flow into 'End');",
          "and a per-stage transition detail table.")),
      h4(textOutput("reg_title")), tableOutput("reg_freq"),
      fluidRow(
        column(5, sliderInput("sankey_maxline", "Pathway depth (lines)",
                              min = 2, max = 5, value = 4, step = 1)),
        column(5, checkboxInput("sankey_commercial",
                                PACK$commercial_label %||% "Commercial-insured only", TRUE))),
      h4(textOutput("sankey_title")),
      plotOutput("sankey", height = "460px"),
      fluidRow(column(5, selectInput("trans_from", "Transition detail (from line)",
                    choices = c("1L -> 2L" = 1L, "2L -> 3L" = 2L, "3L -> 4L" = 3L),
                    selected = 1L))),
      h4(textOutput("trans_title")), tableOutput("trans_tbl")),

    tabPanel("Patient Explorer",
      br(),
      div(class = "ce-note",
          "Look INTO the cohort: a sample of individual patients drawn as ",
          "treatment timelines. Each lane is one patient; each segment is a line ",
          "of therapy coloured by regimen; ", tags$b("x"), " marks death and ",
          tags$b(">"), " a censored (still-followed) patient. Filter by 1L ",
          "regimen to see representative journeys for a treatment choice. ",
          "Illustrative, deterministic sample -- not a cohort statistic."),
      fluidRow(
        column(4, selectInput("pe_soc", "Started 1L with",
                    choices = c("All", SOC_LEVELS_1L), selected = "All",
                    multiple = TRUE)),
        column(4, selectInput("pe_then", "Then received (any later line)",
                    choices = c("Any", LATER_SOC_LEVELS), selected = "Any",
                    multiple = TRUE)),
        column(4, selectInput("pe_event", "Journey outcome",
                    choices = c(list("Any" = "any", "Died (OS event)" = "died",
                                "Discontinued after 1L (no 2L)" = "disc1l",
                                "3+ lines of therapy" = "ge3lines"),
                                # pack milestones (reached CAR-T / SCT / surgery / ...)
                                setNames(as.list(paste0("reach:", names(PACK$pe_milestones))),
                                         names(PACK$pe_milestones))),
                    selected = "any"))),
      fluidRow(
        column(4, selectInput("pe_sort", "Order patients by",
                    choices = c("Most lines of therapy" = "lines",
                                "Longest follow-up" = "os",
                                "1L regimen" = "soc"), selected = "lines")),
        column(4, sliderInput("pe_n", "Patients to show",
                              min = 6, max = 40, value = 18, step = 2)),
        column(4, div(class = "ce-note", style = "margin-top:26px",
                      textOutput("pe_count")))),
      plotOutput("pe_swim", height = "580px")),

    if (HAS_SURVIVAL) tabPanel("Adjusted & Compare",
      br(),
      div(class = "ce-note",
          "Adjusted (Cox) models with your choice of covariates, and a KM ",
          "comparison of two saved cohort selections -- all computed in memory ",
          "on the loaded snapshot, so it is instant. Save Group A/B from the ",
          "current sidebar selection (any IE + filter combination)."),
      fluidRow(
        column(4, selectInput("adj_endpoint", "Endpoint",
                    choices = setNames(names(EPDICT),
                              vapply(EPDICT, `[[`, character(1), "label")))),
        column(5, selectInput("adj_covars", "Adjust for covariates",
                    choices = COVARS_LABELLED, multiple = TRUE,
                    selected = c("age_ge70", "cci_band"))),
        column(3, br(), actionButton("adj_run", "Fit Cox model", class = "btn-apply"))),
      h4("Adjusted hazard ratios (95% CI)"), tableOutput("adj_cox"),
      hr(),
      h4("Compare two cohort selections"),
      fluidRow(
        column(4, actionButton("save_a", "Save current -> Group A", class = "btn-apply")),
        column(4, actionButton("save_b", "Save current -> Group B", class = "btn-apply")),
        column(4, br(), actionButton("cmp_run", "Compare A vs B", class = "btn-apply"))),
      div(class = "ce-note", textOutput("grp_status")),
      plotOutput("cmp_plot", height = "420px"),
      h5("Median (95% CI)"), tableOutput("cmp_med")) else NULL,

    tabPanel("Cohort & Attrition",
      br(), h4("Sequential cohort attrition"),
      plotOutput("attr_plot", height = "360px"), tableOutput("attr_tbl")),

    tabPanel("Validation & Checks",
      br(),
      div(class = "ce-kpi", div(class = "v", textOutput("chk_headline_v")),
          div(class = "l", "overall status")),
      h4("LOT structural checks"), tableOutput("lot_chk"),
      h4(paste(PACK$short, "conformance checks")), tableOutput("ndmm_chk"),
      if (is.function(PACK$extra_checks))
        tagList(h4(paste0(PACK$short, "-specific QC")), tableOutput("extra_chk")),
      h4("Data-quality / analysis readiness"), tableOutput("dq_chk"))
  )
)

ui <- fluidPage(
  app_css(),
  div(class = "ce-header", PACK$header_title,
      span(class = "sub", PACK$header_sub)),
  if (isTRUE(PROVENANCE$any_synthetic))
    div(class = "ce-banner",
        strong("SYNTHETIC DATA -- not for analysis. "),
        if (PROVENANCE$cohort_synthetic) "Cohort is synthetic. " else
          "Cohort is real; ",
        if (PROVENANCE$lotlong_synthetic)
          "LOT-long (per-LOT outcomes / regimen / transitions) is SYNTHETIC." else NULL),
  br(),
  fluidRow(
    column(3, class = "ce-side",
      h4("Cohort Selection"),
      selectInput("cohort", "Select Cohort",
                  choices = setNames(names(COHORTS),
                    vapply(COHORTS, `[[`, character(1), "label"))),
      actionButton("apply_cohort", "Apply Cohort", class = "btn-apply"),
      div(class = "ce-note", style = "margin-top:6px", textOutput("cohort_desc")),

      h4("Analysis options"),
      selectInput("lot", "Line of therapy (outcomes)", choices = LOT_CHOICES,
                  selected = 1L),
      checkboxInput("restrict_fu",
                    "Restrict time-to-event to a minimum follow-up", TRUE),
      sliderInput("min_fu_months", "Minimum potential follow-up (months)",
                  min = 0, max = 24, value = MIN_FU_MONTHS, step = 1),
      textInput("landmark_months", "KM landmark times (months, comma-separated)",
                value = paste(LANDMARK_MONTHS, collapse = ", ")),

      h4("Inclusion / Exclusion Criteria"),
      div(class = "ce-note",
          "Tick / untick a criterion to change the cohort definition; tune the ",
          "filters, then Apply. The cohort is re-selected from the flagged ",
          "superset -- nothing is re-derived."),
      uiOutput("filters"), br(),
      actionButton("apply_filters", "Apply Filters", class = "btn-apply")),

    column(9, class = "ce-main",
      uiOutput("kpis"),
      do.call(tabsetPanel, c(list(id = "maintabs"), main_tabs)))
  ),
  div(class = "ce-note", style = "padding:8px 16px",
      "Internal decision-making only. Synthetic data unless COHORT_EXPLORER_DATA ",
      "points at a validated flagged-cohort projection of the production pipeline outputs.")
)

# ---- server -----------------------------------------------------------------
server <- function(input, output, session) {

  cohort_choice <- reactiveVal("overall")
  cohort_def    <- reactive(COHORTS[[cohort_choice()]])

  # neutral (all-data) values for every param filter
  neutral_params <- function() {
    pv <- list()
    for (id in registry_param_ids(REG)) {
      crit <- REG[[id]]
      pv[[id]] <- if (identical(crit$filter, "range")) {
        rng <- range(FLAGGED[[crit$variable]], na.rm = TRUE)
        c(floor(rng[1]), ceiling(rng[2]))
      } else cat_levels(FLAGGED[[crit$variable]])  # incl "(Missing)" so neutral keeps NA
    }
    pv
  }

  # BLOCKER fix #10: an authoritative selection state, set EXPLICITLY on
  # Apply Cohort (to the cohort defaults) and on Apply Filters (from the
  # controls). selected() depends on this, never on raw input values, so a
  # cohort switch deterministically resets the IE flags regardless of any stale
  # checkbox state left over from a prior cohort.
  active_state <- reactiveVal(list(
    active_flags  = COHORTS[["overall"]]$active_flags,
    param_values  = NULL,   # NULL -> neutral, resolved in selected()
    active_params = registry_param_ids(REG)))

  output$cohort_desc <- renderText(cohort_def()$desc)
  # render the accordion ONCE (structure is cohort-independent); cohort switches
  # drive the control VALUES via update*(), not a re-render.
  output$filters <- renderUI(
    render_filter_accordion(FLAGGED, COHORTS[["overall"]]$active_flags, REG))

  observeEvent(input$apply_cohort, {
    cohort_choice(input$cohort)
    cdef <- COHORTS[[input$cohort]]
    active_state(list(active_flags = cdef$active_flags, param_values = NULL,
                      active_params = registry_param_ids(REG)))
    # reset the visible controls to match the new cohort
    for (id in registry_flag_ids(REG))
      updateCheckboxInput(session, crit_input_id(id),
                          value = id %in% cdef$active_flags)
    np <- neutral_params()
    for (id in registry_param_ids(REG)) {
      crit <- REG[[id]]
      if (identical(crit$filter, "range"))
        updateSliderInput(session, crit_input_id(id), value = np[[id]])
      else updateSelectInput(session, crit_input_id(id), selected = np[[id]])
    }
  })

  gather_selection <- function() {
    cur <- active_state()
    cur_flags <- cur$active_flags
    cur_pv <- if (is.null(cur$param_values)) neutral_params() else cur$param_values
    # a control that has not (yet) registered a value falls back to the current
    # applied state, so Apply Filters only changes what the user actually touched.
    active_flags <- Filter(function(id) {
      v <- input[[crit_input_id(id)]]
      if (is.null(v)) id %in% cur_flags else isTRUE(v)
    }, registry_flag_ids(REG))
    pvals <- list()
    for (id in registry_param_ids(REG)) {
      v <- input[[crit_input_id(id)]]
      pvals[[id]] <- if (is.null(v)) cur_pv[[id]] else v
    }
    list(active_flags = unlist(active_flags), param_values = pvals,
         active_params = registry_param_ids(REG))
  }

  observeEvent(input$apply_filters, active_state(gather_selection()))

  selected <- reactive({
    st <- active_state()
    pv <- if (is.null(st$param_values)) neutral_params() else st$param_values
    select_cohort(FLAGGED, st$active_flags, pv, st$active_params, REG)
  })

  output$kpis <- renderUI({
    s <- selected()
    div(class = "ce-kpi-row",
      kpi(format(s$n_out, big.mark = ","), "Patients (selected cohort)"),
      kpi(sprintf("%.1f%%", 100 * s$n_out / s$n_in), "of superset"),
      kpi(format(s$n_in, big.mark = ","), "Superset (flagged) N"),
      kpi(COHORTS[[cohort_choice()]]$label, "Active cohort"),
      kpi(paste0(input$lot, "L"), "Line of therapy"))
  })

  # ----- Patient Characteristics -----
  # capture the cohort + label at Apply time so the header N, safety table, and
  # cat/cont tables ALL describe the same snapshot -- reading selected() live
  # in one place and gating on Apply in another makes them disagree.
  pc <- eventReactive(input$pc_apply, {
    list(df = selected()$data, vars = input$pc_vars, strata = input$pc_strata,
         label = COHORTS[[cohort_choice()]]$label)
  }, ignoreNULL = FALSE)

  output$pc_title <- renderText({
    p <- pc()
    sprintf("Summary statistics -- %s (N = %s)",
            p$label, format(nrow(p$df), big.mark = ","))
  })
  output$pc_suppressed <- renderText({
    p <- pc(); req(nrow(p$df) > 0)
    supp <- suppressed_strata(p$df, p$strata)   # from data, not a single table
    if (length(supp)) paste0("Suppressed strata (<25 patients): ",
                             paste(supp, collapse = ", ")) else ""
  })
  output$pc_cat <- renderTable({
    p <- pc(); req(nrow(p$df) > 0)
    res <- summarize_categorical(p$df, p$vars, p$strata, VARDICT)
    if (is.null(res)) data.frame(Note = "Select 1+ categorical variable.") else res
  }, striped = TRUE, bordered = TRUE, na = "")
  output$pc_cont <- renderTable({
    p <- pc(); req(nrow(p$df) > 0)
    res <- summarize_continuous(p$df, p$vars, p$strata, VARDICT)
    if (is.null(res)) data.frame(Note = "Select 1+ continuous variable.") else res
  }, striped = TRUE, bordered = TRUE, na = "")
  output$pc_safety <- renderTable({
    p <- pc(); req(nrow(p$df) > 0); safety_baseline_table(p$df)
  }, striped = TRUE, bordered = TRUE, na = "")

  # data source for a KM endpoint at the chosen line
  km_source <- function(endpoint, line) {
    ids <- selected()$data$patient_id
    if (line == 1L) return(list(df = selected()$data, ok = TRUE))
    if (endpoint %in% PATIENT_LEVEL_ONLY)
      return(list(df = NULL, ok = FALSE,
                  msg = sprintf("%s is a 1L-level endpoint; switch Line of therapy to 1L.",
                                endpoint)))
    list(df = lot_slice(LOT_LONG, ids, line), ok = TRUE)
  }

  # ----- KM tabs -----
  # shared time-to-event controls: the follow-up cut (0/off => none) and the
  # landmark grid, both movable in-memory (no re-query).
  mf_val   <- reactive(if (isTRUE(input$restrict_fu))
                         as.integer(input$min_fu_months %||% MIN_FU_MONTHS) else NULL)
  lm_times <- reactive(parse_landmark_months(input$landmark_months))

  if (HAS_SURVIVAL) for (.k in names(KM_TABS)) local({
    key <- .k
    km_react <- eventReactive(input[[paste0("km_", key, "_apply")]], {
      line <- as.integer(input$lot)
      src <- km_source(key, line)
      if (!isTRUE(src$ok)) return(structure(list(), msg = src$msg))
      st <- input[[paste0("km_", key, "_strata")]]
      # hard-warn (not silently ignore) if the requested stratum is unavailable
      if (nzchar(st) && !(st %in% names(src$df)))
        return(structure(list(), msg = sprintf(
          "Stratum '%s' is not available at %dL (not carried onto later lines). Pick another stratum or 1L.",
          st, line)))
      mf <- if (key != "Attrition") mf_val() else NULL
      km_fit(src$df, key, strata = if (nzchar(st)) st else NULL, EPDICT, min_fu = mf)
    }, ignoreNULL = FALSE)

    output[[paste0("km_", key, "_plot")]] <- renderPlot({
      k <- km_react()
      if (is.null(k) || !length(k)) { plot.new()
        text(0.5, 0.5, attr(k, "msg") %||% "No data."); return() }
      km_plot(k, horizon = input[[paste0("km_", key, "_horizon")]])
    })
    output[[paste0("km_", key, "_landmark")]] <- renderTable(
      km_landmark(km_react(), times = lm_times()), bordered = TRUE, na = "")
    output[[paste0("km_", key, "_med")]]  <- renderTable(
      km_medians(km_react()), bordered = TRUE, na = "")
    output[[paste0("km_", key, "_risk")]] <- renderTable(
      km_risk_table(km_react(), horizon = input[[paste0("km_", key, "_horizon")]]),
      bordered = TRUE, na = "")
  })

  # ----- Adjusted (Cox) model + A/B comparison -----
  if (HAS_SURVIVAL) {
    grpA <- reactiveVal(NULL); grpB <- reactiveVal(NULL)
    observeEvent(input$save_a, grpA(selected()$data$patient_id))
    observeEvent(input$save_b, grpB(selected()$data$patient_id))
    output$grp_status <- renderText(sprintf(
      "Group A: %s | Group B: %s   (save from the current sidebar selection)",
      if (is.null(grpA())) "unset" else paste(length(grpA()), "patients"),
      if (is.null(grpB())) "unset" else paste(length(grpB()), "patients")))

    cox_tbl <- eventReactive(input$adj_run, {
      km_cox(selected()$data, input$adj_endpoint, input$adj_covars, EPDICT, min_fu = mf_val())
    })
    output$adj_cox <- renderTable({
      t <- cox_tbl()
      if (is.null(t)) data.frame(Note = "Select an endpoint + covariates, then Fit.") else t
    }, striped = TRUE, bordered = TRUE, na = "")

    cmp_km <- eventReactive(input$cmp_run, {
      validate(need(!is.null(grpA()) && !is.null(grpB()),
                    "Save Group A and Group B first."))
      mf <- if (input$adj_endpoint != "Attrition") mf_val() else NULL
      km_compare(FLAGGED, input$adj_endpoint, grpA(), grpB(), EPDICT, min_fu = mf)
    })
    output$cmp_plot <- renderPlot({
      k <- cmp_km()
      if (is.null(k) || !length(k)) { plot.new()
        text(0.5, 0.5, "Save Group A + Group B, then Compare."); return() }
      km_plot(k, horizon = 60)
    })
    output$cmp_med <- renderTable(km_medians(cmp_km()), bordered = TRUE, na = "")
  }

  # ----- Regimen & Transitions -----
  output$reg_title <- renderText(sprintf("Regimen frequency -- %sL", input$lot))
  output$reg_freq <- renderTable({
    rf <- regimen_frequency(LOT_LONG, selected()$data$patient_id, as.integer(input$lot))
    if (is.null(rf)) data.frame(Note = "No patients reach this line.") else rf
  }, striped = TRUE, bordered = TRUE)
  # configurable 1L->NL patient-journey pathway (Sankey): depth + payer toggle.
  # NULL-guarded so it is robust to reactive timing (defaults: depth 4, commercial).
  sankey_depth <- reactive(as.integer(input$sankey_maxline %||% 4L))
  sankey_comm  <- reactive(isTRUE(input$sankey_commercial %||% TRUE))
  sankey_lbl   <- reactive(sprintf("1L -> %dL treatment pathway (%s)",
    sankey_depth(), if (sankey_comm()) "commercial only" else "all payers"))
  output$sankey_title <- renderText(sankey_lbl())
  output$sankey <- renderPlot(
    lot_pathway_sankey(lot_pathway_data(LOT_LONG, selected()$data$patient_id,
        max_line = sankey_depth(), commercial_only = sankey_comm()),
      title = sankey_lbl()))
  # per-stage transition detail table (from-line + payer toggle)
  output$trans_title <- renderText(
    sprintf("%dL -> %dL SOC transition detail (%s)",
            as.integer(input$trans_from), as.integer(input$trans_from) + 1L,
            if (sankey_comm()) "commercial only" else "all payers"))
  trans <- reactive(lot_transition_table(LOT_LONG, selected()$data$patient_id,
                                         as.integer(input$trans_from),
                                         commercial_only = sankey_comm()))
  output$trans_tbl <- renderTable({
    t <- trans(); if (is.null(t)) data.frame(Note = "No transitions at this stage.") else t
  }, striped = TRUE, bordered = TRUE)

  # ----- Patient Explorer (swimlanes) -----
  # Resolve the sidebar controls into engine args (pack milestone -> reached_regimen).
  pe_args <- reactive({
    ev <- input$pe_event %||% "any"
    reached <- NULL
    if (startsWith(ev, "reach:")) {
      reached <- PACK$pe_milestones[[sub("^reach:", "", ev)]]; ev <- "any"
    }
    thn <- input$pe_then %||% "Any"
    list(soc = input$pe_soc %||% "All",
         then = if (is.null(thn) || "Any" %in% thn) NULL else thn,
         reached = reached, event = ev, sort = input$pe_sort %||% "lines",
         n = as.integer(input$pe_n %||% 18L))
  })
  pe_data <- reactive({
    a <- pe_args()
    patient_timeline_data(LOT_LONG, selected()$data, n = a$n, soc_filter = a$soc,
      then_soc = a$then, reached_regimen = a$reached, event = a$event, sort_by = a$sort)
  })
  output$pe_swim <- renderPlot({
    a <- pe_args(); td <- pe_data()
    socf <- a$soc
    lbl <- if (is.null(socf) || "All" %in% socf) "1L: all regimens"
           else paste0("1L: ", paste(socf, collapse = "/"))
    if (!is.null(a$then)) lbl <- paste0(lbl, "  ->  then: ", paste(a$then, collapse = "/"))
    patient_swimlane_plot(td, title = sprintf("Patient journeys - %s (%d shown)",
      lbl, if (is.null(td)) 0L else td$n))
  })
  # how many patients in the selected cohort MATCH the pathway filter (vs shown).
  # count_only skips building every matching patient's timeline -> cheap at scale.
  output$pe_count <- renderText({
    a <- pe_args()
    nm <- patient_timeline_data(LOT_LONG, selected()$data, soc_filter = a$soc,
      then_soc = a$then, reached_regimen = a$reached, event = a$event, count_only = TRUE)
    sprintf("%s patient(s) match this pathway; showing up to %d.",
            format(nm %||% 0L, big.mark = ","), a$n)
  })

  # ----- Attrition -----
  output$attr_plot <- renderPlot({
    a <- selected()$attrition
    op <- par(mar = c(11, 4.5, 2, 1)); on.exit(par(op))
    bp <- barplot(a$n_remaining, names.arg = a$criterion, las = 2,
                  col = ifelse(a$polarity == "excl", "#E8480C",
                        ifelse(a$polarity == "incl", "#1F8A8A", "#999999")),
                  ylab = "Patients remaining", cex.names = 0.8,
                  main = "Sequential cohort attrition")
    text(bp, a$n_remaining, labels = format(a$n_remaining, big.mark = ","),
         pos = 3, cex = 0.75, xpd = NA)
  })
  output$attr_tbl <- renderTable(selected()$attrition, striped = TRUE, bordered = TRUE)

  # ----- Validation & Checks -----
  lot_tbl  <- reactive(lot_checks(selected()$data, MAX_LOT))
  ndmm_tbl <- reactive(ndmm_protocol_checks(selected()$data,
                          active_state()$active_flags, REG))
  dq_tbl   <- reactive(protocol_dq_checks(selected()$data,
                          min_fu = as.integer(input$min_fu_months %||% MIN_FU_MONTHS)))
  extra_tbl <- reactive(cohort_specific_checks(selected()$data))  # pack QC (may be NULL)
  output$chk_headline_v <- renderText(
    checks_headline(rbind(lot_tbl(), ndmm_tbl(), dq_tbl(), extra_tbl())))
  render_checks <- function(tbl) { tbl$Status <- vapply(tbl$Status, status_html, character(1)); tbl }
  output$lot_chk  <- renderTable(render_checks(lot_tbl()),  sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
  output$ndmm_chk <- renderTable(render_checks(ndmm_tbl()), sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
  output$dq_chk   <- renderTable(render_checks(dq_tbl()),   sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
  output$extra_chk <- renderTable({
    t <- extra_tbl(); if (is.null(t)) data.frame(Note = "No cohort-specific checks configured.")
    else render_checks(t)
  }, sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
}

shinyApp(ui, server)
