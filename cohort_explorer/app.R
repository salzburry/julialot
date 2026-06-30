# =============================================================================
# app.R  --  Oncology Real-World Data Explorer (cohort + IE flags edition)
# -----------------------------------------------------------------------------
# A Shiny re-creation of the sample dashboard, driven by the flag-based cohort
# engine: pick a cohort (Overall / NDMM), freely toggle the IE criteria, tune
# the inclusion filters, and every tab (Patient Characteristics, rwOS/rwPFS/
# rwTTD/rwTTNT KM, Attrition, Checks) recomputes off the SAME selected cohort.
#
# Run:   shiny::runApp("cohort_explorer")        # synthetic data, no warehouse
#        COHORT_EXPLORER_DATA=path/to/flagged.csv shiny::runApp("cohort_explorer")
# =============================================================================

source(file.path(
  tryCatch(dirname(sys.frame(1)$ofile), error = function(e) getwd()),
  "global.R"))

# ---- UI ---------------------------------------------------------------------
ui <- fluidPage(
  app_css(),
  div(class = "ce-header",
      "Oncology Real-World Data Explorer Tool",
      span(class = "sub", " — Multiple Myeloma (Overall & NDMM) · flag-driven IE selection")),
  br(),
  fluidRow(
    # ---------- sidebar ----------
    column(3, class = "ce-side",
      h4("Cohort Selection"),
      selectInput("cohort", "Select Cohort",
                  choices = setNames(names(COHORTS),
                                     vapply(COHORTS, `[[`, character(1), "label"))),
      actionButton("apply_cohort", "Apply Cohort", class = "btn-apply"),
      div(class = "ce-note", style = "margin-top:6px",
          textOutput("cohort_desc")),

      h4("Inclusion / Exclusion Criteria"),
      div(class = "ce-note",
          "Tick / untick a criterion to change the cohort definition; tune the",
          "filters, then Apply. The cohort is re-selected from the flagged",
          "superset — nothing is re-derived."),
      uiOutput("filters"),
      br(),
      actionButton("apply_filters", "Apply Filters", class = "btn-apply")
    ),

    # ---------- main ----------
    column(9,
      uiOutput("kpis"),
      tabsetPanel(id = "maintabs",
        tabPanel("Patient Characteristics",
          br(),
          fluidRow(
            column(5, selectInput("pc_vars", "Select Variables",
                                  choices = setNames(SUMMARY_VARS,
                                    vapply(SUMMARY_VARS, var_label, character(1),
                                           dict = VARDICT)),
                                  multiple = TRUE,
                                  selected = c("gender", "region", "age_index"))),
            column(4, selectInput("pc_strata", "Select Strata",
                                  choices = c("None" = "",
                                    setNames(STRATA_VARS,
                                      vapply(STRATA_VARS, var_label, character(1),
                                             dict = VARDICT))),
                                  selected = "")),
            column(3, br(), actionButton("pc_apply", "Apply", class = "btn-apply"))),
          h4(textOutput("pc_title")),
          h5("Categorical variables"), tableOutput("pc_cat"),
          h5("Continuous variables"),  tableOutput("pc_cont")
        ),
        if (HAS_SURVIVAL)
          km_tab_ui("rwOS",  EPDICT$rwOS$label,  STRATA_VARS) else NULL,
        if (HAS_SURVIVAL)
          km_tab_ui("rwPFS", EPDICT$rwPFS$label, STRATA_VARS) else NULL,
        if (HAS_SURVIVAL)
          km_tab_ui("rwTTD", EPDICT$rwTTD$label, STRATA_VARS) else NULL,
        if (HAS_SURVIVAL)
          km_tab_ui("rwTTNT", EPDICT$rwTTNT$label, STRATA_VARS) else NULL,
        if (!HAS_SURVIVAL)
          tabPanel("Time-to-event",
            br(), div(class = "ce-note",
              "Install the 'survival' package to enable rwOS/rwPFS/rwTTD/rwTTNT KM curves.")) else NULL,

        tabPanel("Cohort & Attrition",
          br(),
          h4("Attrition waterfall"),
          plotOutput("attr_plot", height = "360px"),
          tableOutput("attr_tbl")),

        tabPanel("Validation & Checks",
          br(),
          div(class = "ce-kpi", div(class = "v", textOutput("chk_headline_v")),
              div(class = "l", "overall status")),
          h4("LOT structural checks"),  tableOutput("lot_chk"),
          h4("NDMM protocol conformance"), tableOutput("ndmm_chk"))
      )
    )
  ),
  div(class = "ce-note", style = "padding:8px 16px",
      "Internal decision-making only. Synthetic data unless COHORT_EXPLORER_DATA",
      "points at a validated flagged-cohort projection of the apr_30_2026 outputs.")
)

# ---- server -----------------------------------------------------------------
server <- function(input, output, session) {

  cohort_choice <- reactiveVal("overall")
  refresh       <- reactiveVal(0L)        # bumped to force re-selection

  cohort_def <- reactive(COHORTS[[cohort_choice()]])

  output$cohort_desc <- renderText(cohort_def()$desc)

  # (re)render the criteria/filter accordion when the applied cohort changes
  output$filters <- renderUI({
    render_filter_accordion(FLAGGED, cohort_def()$active_flags, REG)
  })

  observeEvent(input$apply_cohort, {
    cohort_choice(input$cohort)           # triggers renderUI with new defaults
    refresh(refresh() + 1L)
  })
  observeEvent(input$apply_filters, refresh(refresh() + 1L))

  # gather the active criteria from the controls, falling back to cohort/registry
  # defaults if a control has not rendered yet (robust on first load)
  gather_selection <- function() {
    cdef <- cohort_def()
    flag_ids <- registry_flag_ids(REG)
    active_flags <- Filter(function(id) {
      v <- input[[crit_input_id(id)]]
      if (is.null(v)) id %in% cdef$active_flags else isTRUE(v)
    }, flag_ids)

    param_ids <- registry_param_ids(REG)
    pvals <- list()
    for (id in param_ids) {
      v <- input[[crit_input_id(id)]]
      pvals[[id]] <- if (is.null(v)) REG[[id]]$default else v
    }
    list(active_flags = unlist(active_flags), param_values = pvals,
         active_params = param_ids)
  }

  selected <- reactive({
    refresh()                              # depend on the Apply buttons
    sel <- isolate(gather_selection())
    select_cohort(FLAGGED, sel$active_flags, sel$param_values,
                  sel$active_params, REG)
  })

  # KPI strip
  output$kpis <- renderUI({
    s <- selected()
    div(style = "margin-bottom:8px",
      kpi(format(s$n_out, big.mark = ","), "Patients (selected cohort)"),
      kpi(sprintf("%.1f%%", 100 * s$n_out / s$n_in), "of superset"),
      kpi(format(s$n_in, big.mark = ","), "Superset (flagged) N"),
      kpi(COHORTS[[cohort_choice()]]$label, "Active cohort"))
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

  # ----- KM tabs (one handler set per endpoint) -----
  if (HAS_SURVIVAL) for (.k in names(EPDICT)) local({
    key <- .k
    km_react <- eventReactive(input[[paste0("km_", key, "_apply")]], {
      st <- input[[paste0("km_", key, "_strata")]]
      km_fit(selected()$data, key, strata = if (nzchar(st)) st else NULL, EPDICT)
    }, ignoreNULL = FALSE)

    output[[paste0("km_", key, "_plot")]] <- renderPlot({
      km_plot(km_react(), horizon = input[[paste0("km_", key, "_horizon")]])
    })
    output[[paste0("km_", key, "_med")]]  <- renderTable(km_medians(km_react()),
                                                         bordered = TRUE, na = "")
    output[[paste0("km_", key, "_risk")]] <- renderTable(
      km_risk_table(km_react(), horizon = input[[paste0("km_", key, "_horizon")]]),
      bordered = TRUE, na = "")
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
  output$attr_tbl <- renderTable(selected()$attrition, striped = TRUE,
                                 bordered = TRUE)

  # ----- Validation & Checks -----
  lot_tbl  <- reactive(lot_checks(selected()$data, MAX_LOT))
  ndmm_tbl <- reactive({
    sel <- isolate(gather_selection())
    ndmm_protocol_checks(selected()$data, sel$active_flags, REG)
  })
  output$chk_headline_v <- renderText({
    t1 <- lot_tbl(); t2 <- ndmm_tbl()
    checks_headline(rbind(t1, t2))
  })
  render_checks <- function(tbl) {
    tbl$Status <- vapply(tbl$Status, status_html, character(1))
    tbl
  }
  output$lot_chk  <- renderTable(render_checks(lot_tbl()), sanitize.text.function = identity,
                                 striped = TRUE, bordered = TRUE)
  output$ndmm_chk <- renderTable(render_checks(ndmm_tbl()), sanitize.text.function = identity,
                                 striped = TRUE, bordered = TRUE)
}

shinyApp(ui, server)
