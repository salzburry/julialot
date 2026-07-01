# =============================================================================
# app.R  --  Oncology Real-World Data Explorer (cohort + IE flags edition)
# -----------------------------------------------------------------------------
# Shiny re-creation of the sample dashboard, driven by the flag-based cohort
# engine and aligned to the NDMM protocol (GSK 223926): pick a cohort
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

# protocol time-to-event tabs: endpoint key -> short tab label
KM_TABS <- list(OS = "OS", TTD = "TTD", TTNT = "TTNT",
                Attrition = "Attrition", PFS_exploratory = "PFS*")
PATIENT_LEVEL_ONLY <- c("Attrition", "PFS_exploratory")  # 1L-only endpoints

# ---- UI ---------------------------------------------------------------------
main_tabs <- c(
  list(
    tabPanel("Patient Characteristics",
      br(),
      div(class = "ce-note",
          "Baseline characteristics (12-mo pre-index) for the selected cohort, ",
          "NDMM protocol Table 1. Strata levels with <25 patients are suppressed."),
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
      h5("Continuous variables"),  tableOutput("pc_cont"))
  ),
  if (HAS_SURVIVAL)
    lapply(names(KM_TABS), function(k)
      km_tab_ui(k, EPDICT[[k]]$label, STRATA_LABELLED, KM_TABS[[k]]))
  else list(tabPanel("Time-to-event", br(), div(class = "ce-note",
      "Install the 'survival' package to enable the KM tabs."))),
  list(
    tabPanel("Regimen & Transitions",
      br(),
      div(class = "ce-note",
          "Regimen frequency for the selected Line of Therapy, and 1L->2L SOC ",
          "transitions (commercial-insured only, per protocol Exploratory Obj 3)."),
      h4(textOutput("reg_title")), tableOutput("reg_freq"),
      h4("1L -> 2L SOC transitions (commercial only)"),
      plotOutput("sankey", height = "420px"), tableOutput("trans_tbl")),

    tabPanel("Cohort & Attrition",
      br(), h4("Sequential cohort attrition"),
      plotOutput("attr_plot", height = "360px"), tableOutput("attr_tbl")),

    tabPanel("Validation & Checks",
      br(),
      div(class = "ce-kpi", div(class = "v", textOutput("chk_headline_v")),
          div(class = "l", "overall status")),
      h4("LOT structural checks"), tableOutput("lot_chk"),
      h4("NDMM protocol conformance"), tableOutput("ndmm_chk"),
      h4("Protocol data-quality / analysis readiness"), tableOutput("dq_chk"))
  )
)

ui <- fluidPage(
  app_css(),
  div(class = "ce-header", "Oncology Real-World Data Explorer Tool",
      span(class = "sub",
           " — Multiple Myeloma (Overall & NDMM) · flag-driven IE selection · GSK 223926 protocol")),
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
                    "Restrict time-to-event to >=3-mo follow-up (protocol)", TRUE),

      h4("Inclusion / Exclusion Criteria"),
      div(class = "ce-note",
          "Tick / untick a criterion to change the cohort definition; tune the ",
          "filters, then Apply. The cohort is re-selected from the flagged ",
          "superset — nothing is re-derived."),
      uiOutput("filters"), br(),
      actionButton("apply_filters", "Apply Filters", class = "btn-apply")),

    column(9,
      uiOutput("kpis"),
      do.call(tabsetPanel, c(list(id = "maintabs"), main_tabs)))
  ),
  div(class = "ce-note", style = "padding:8px 16px",
      "Internal decision-making only. Synthetic data unless COHORT_EXPLORER_DATA ",
      "points at a validated flagged-cohort projection of the apr_30_2026 outputs.")
)

# ---- server -----------------------------------------------------------------
server <- function(input, output, session) {

  cohort_choice <- reactiveVal("overall")
  refresh       <- reactiveVal(0L)
  cohort_def    <- reactive(COHORTS[[cohort_choice()]])

  output$cohort_desc <- renderText(cohort_def()$desc)
  output$filters <- renderUI(
    render_filter_accordion(FLAGGED, cohort_def()$active_flags, REG))

  observeEvent(input$apply_cohort, {
    cohort_choice(input$cohort); refresh(refresh() + 1L) })
  observeEvent(input$apply_filters, refresh(refresh() + 1L))

  gather_selection <- function() {
    cdef <- cohort_def(); flag_ids <- registry_flag_ids(REG)
    active_flags <- Filter(function(id) {
      v <- input[[crit_input_id(id)]]
      if (is.null(v)) id %in% cdef$active_flags else isTRUE(v)
    }, flag_ids)
    param_ids <- registry_param_ids(REG); pvals <- list()
    for (id in param_ids) {
      v <- input[[crit_input_id(id)]]
      pvals[[id]] <- if (is.null(v)) REG[[id]]$default else v
    }
    list(active_flags = unlist(active_flags), param_values = pvals,
         active_params = param_ids)
  }

  selected <- reactive({
    refresh()
    sel <- isolate(gather_selection())
    select_cohort(FLAGGED, sel$active_flags, sel$param_values, sel$active_params, REG)
  })

  output$kpis <- renderUI({
    s <- selected()
    div(style = "margin-bottom:8px",
      kpi(format(s$n_out, big.mark = ","), "Patients (selected cohort)"),
      kpi(sprintf("%.1f%%", 100 * s$n_out / s$n_in), "of superset"),
      kpi(format(s$n_in, big.mark = ","), "Superset (flagged) N"),
      kpi(COHORTS[[cohort_choice()]]$label, "Active cohort"),
      kpi(paste0(input$lot, "L"), "Line of therapy"))
  })

  # ----- Patient Characteristics -----
  pc <- eventReactive(input$pc_apply, {
    list(df = selected()$data, vars = input$pc_vars, strata = input$pc_strata)
  }, ignoreNULL = FALSE)

  output$pc_title <- renderText({
    s <- selected()
    sprintf("Summary statistics — %s (N = %s)",
            COHORTS[[cohort_choice()]]$label, format(s$n_out, big.mark = ","))
  })
  pc_cat_tbl <- reactive({
    p <- pc(); req(nrow(p$df) > 0); summarize_categorical(p$df, p$vars, p$strata, VARDICT)
  })
  output$pc_suppressed <- renderText({
    supp <- attr(pc_cat_tbl(), "suppressed")
    if (length(supp)) paste0("Suppressed strata (<25 patients): ",
                             paste(supp, collapse = ", ")) else ""
  })
  output$pc_cat <- renderTable({
    res <- pc_cat_tbl()
    if (is.null(res)) data.frame(Note = "Select 1+ categorical variable.") else res
  }, striped = TRUE, bordered = TRUE, na = "")
  output$pc_cont <- renderTable({
    p <- pc(); req(nrow(p$df) > 0)
    res <- summarize_continuous(p$df, p$vars, p$strata, VARDICT)
    if (is.null(res)) data.frame(Note = "Select 1+ continuous variable.") else res
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
  if (HAS_SURVIVAL) for (.k in names(KM_TABS)) local({
    key <- .k
    km_react <- eventReactive(input[[paste0("km_", key, "_apply")]], {
      line <- as.integer(input$lot)
      src <- km_source(key, line)
      if (!isTRUE(src$ok)) return(structure(list(), msg = src$msg))
      st <- input[[paste0("km_", key, "_strata")]]
      mf <- if (isTRUE(input$restrict_fu) && key != "Attrition") MIN_FU_MONTHS else NULL
      km_fit(src$df, key, strata = if (nzchar(st)) st else NULL, EPDICT, min_fu = mf)
    }, ignoreNULL = FALSE)

    output[[paste0("km_", key, "_plot")]] <- renderPlot({
      k <- km_react()
      if (is.null(k) || !length(k)) { plot.new()
        text(0.5, 0.5, attr(k, "msg") %||% "No data."); return() }
      km_plot(k, horizon = input[[paste0("km_", key, "_horizon")]])
    })
    output[[paste0("km_", key, "_landmark")]] <- renderTable(
      km_landmark(km_react()), bordered = TRUE, na = "")
    output[[paste0("km_", key, "_med")]]  <- renderTable(
      km_medians(km_react()), bordered = TRUE, na = "")
    output[[paste0("km_", key, "_risk")]] <- renderTable(
      km_risk_table(km_react(), horizon = input[[paste0("km_", key, "_horizon")]]),
      bordered = TRUE, na = "")
  })

  # ----- Regimen & Transitions -----
  output$reg_title <- renderText(sprintf("Regimen frequency — %sL", input$lot))
  output$reg_freq <- renderTable({
    rf <- regimen_frequency(LOT_LONG, selected()$data$patient_id, as.integer(input$lot))
    if (is.null(rf)) data.frame(Note = "No patients reach this line.") else rf
  }, striped = TRUE, bordered = TRUE)
  trans <- reactive(lot_transition_table(LOT_LONG, selected()$data$patient_id, 1L))
  output$sankey    <- renderPlot(sankey_plot(trans()))
  output$trans_tbl <- renderTable({
    t <- trans(); if (is.null(t)) data.frame(Note = "No transitions.") else t
  }, striped = TRUE, bordered = TRUE)

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
                          isolate(gather_selection())$active_flags, REG))
  dq_tbl   <- reactive(protocol_dq_checks(selected()$data,
                          min_fu = if (isTRUE(input$restrict_fu)) MIN_FU_MONTHS else 3L))
  output$chk_headline_v <- renderText(
    checks_headline(rbind(lot_tbl(), ndmm_tbl(), dq_tbl())))
  render_checks <- function(tbl) { tbl$Status <- vapply(tbl$Status, status_html, character(1)); tbl }
  output$lot_chk  <- renderTable(render_checks(lot_tbl()),  sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
  output$ndmm_chk <- renderTable(render_checks(ndmm_tbl()), sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
  output$dq_chk   <- renderTable(render_checks(dq_tbl()),   sanitize.text.function = identity, striped = TRUE, bordered = TRUE)
}

shinyApp(ui, server)
