# The Shiny app. Wiring only.
#
# Every number on the page comes from a function in R/ that runs without Shiny,
# so the arithmetic is tested by tests/run_tests.R with no browser and no
# warehouse. What is here is the layout, the inputs and which function each
# output calls.

library(shiny)
source("global.R")

.p <- PALETTE
CSS <- sprintf('
:root{--o:%s;--od:%s;--opl:%s;--pa:%s;--ink:%s;--sl:%s;--ln:%s;--wa:%s;--ai:%s;--ab:%s;--al:%s}
body{background:var(--wa);color:var(--ink);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.hdr{background:var(--o);color:var(--pa);padding:18px 24px;margin:-15px -15px 16px}
.hdr h1{margin:0;font-size:19px;font-weight:600}
.hdr p{margin:4px 0 0;font-size:13px;opacity:.92}
.well,.panel{background:var(--pa);border:1px solid var(--ln);border-radius:6px}
table.grid{border-collapse:collapse;width:100%%;font-size:13px;background:var(--pa)}
table.grid th{background:var(--opl);text-align:left;padding:7px 9px;border-bottom:1px solid var(--ln);font-weight:600}
table.grid td{padding:6px 9px;border-bottom:1px solid var(--ln)}
table.grid tr.supp td{background:var(--ab);color:var(--ai)}
.kpis{display:flex;flex-wrap:wrap;gap:12px;margin:6px 0 14px}
.kpi{background:var(--pa);border:1px solid var(--ln);border-radius:6px;padding:12px 16px;min-width:130px}
.kpi-v{font-size:22px;font-weight:600;color:var(--o)}
.kpi-k{font-size:12px;color:var(--sl);margin-top:2px}
.note,.cap{font-size:12px;color:var(--sl);margin:6px 0}
.empty{color:var(--sl);font-style:italic;padding:14px 0}
.alert{background:var(--ab);border:1px solid var(--al);color:var(--ai);padding:10px 13px;border-radius:6px;font-size:13px;margin-bottom:12px}
.scn{font-size:12px;color:var(--sl);border-left:3px solid var(--o);padding-left:9px;margin:8px 0}
pre.cmd{background:#1B1B1B;color:#EDEDED;padding:11px;border-radius:6px;font-size:12px;white-space:pre-wrap}
',
.p[["orange"]], .p[["orange_dark"]], .p[["orange_pale"]], .p[["paper"]],
.p[["ink"]], .p[["slate"]], .p[["line"]], .p[["wash"]], .p[["alert_ink"]],
.p[["alert_bg"]], .p[["alert_line"]])

scn_choices <- function() {
  if (!length(SCENARIOS)) return(character(0))
  stats::setNames(names(SCENARIOS),
                  vapply(SCENARIOS, function(s)
                    sprintf("%s%s", s$label,
                            if (scenario_is_usable(s)) "" else
                              sprintf("  [%s]", s$state)), character(1)))
}

ui <- fluidPage(
  tags$head(tags$style(HTML(CSS)), tags$title(DASH_CFG$title)),
  div(class = "hdr",
      h1(DASH_CFG$title),
      p(sprintf("%d scenario(s) from %s (%s)", PROVENANCE$n_scenarios,
                PROVENANCE$kind, PROVENANCE$origin))),
  if (PROVENANCE$synthetic)
    div(class = "alert", strong("Synthetic data. "),
        "Every number on this page is generated, not measured. Point ",
        "DASH_SOURCE at a snapshot or the warehouse to see the study's own.")
  else NULL,
  sidebarLayout(
    sidebarPanel(
      width = 3,
      selectInput("scenario", "Scenario", choices = scn_choices()),
      uiOutput("scn_readings"),
      tags$hr(),
      h5("Selection"),
      uiOutput("key_controls"),
      sliderInput("floor", "Suppress cells below N",
                  min = DASH_CFG$suppress_min_n, max = 200L,
                  value = DASH_CFG$suppress_min_n, step = 5L),
      helpText("The floor can be raised, never lowered: the package already",
               "withheld cells under its own."),
      tags$hr(),
      h5("Compare"),
      selectInput("scenario_b", "Against", choices = c("(none)" = "", scn_choices())),
      helpText("An open question changes the SQL, so it cannot be filtered on",
               "a finished table. Comparing two runs is how you see one.")
    ),
    mainPanel(
      width = 9,
      do.call(tabsetPanel, c(list(id = "tabs"), lapply(PANEL_TABS(), function(tb)
        tabPanel(tb, uiOutput(paste0("tab_", make.names(tb)))))))
    )
  )
)

server <- function(input, output, session) {

  scn <- reactive({
    req(input$scenario)
    SCENARIOS[[input$scenario]]
  })
  scn_b <- reactive({
    if (is.null(input$scenario_b) || !nzchar(input$scenario_b)) return(NULL)
    SCENARIOS[[input$scenario_b]]
  })

  # The keys a viewer can select on, offered from what the scenario's own
  # tables carry rather than from a hard-coded list.
  key_levels <- reactive({
    s <- scn()
    tabs <- unique(stats::na.omit(vapply(PANELS, function(p)
      as.character(p$table), character(1))))
    lv <- list()
    for (tb in intersect(tabs, DASH_TABLES$TABLE)) {
      d <- read_table(SRC, s$prefix, tb, DASH_CFG$prefer_release)
      if (is.null(d) || !nrow(d)) next
      for (k in intersect(GENERIC_KEYS, names(d)))
        lv[[k]] <- sort(unique(c(lv[[k]], as.character(d[[k]]))))
    }
    lv
  })

  output$key_controls <- renderUI({
    lv <- key_levels()
    if (!length(lv)) return(helpText("This scenario wrote no table to select on."))
    lapply(names(lv), function(k)
      selectInput(paste0("key_", k), gsub("_", " ", k),
                  choices = c("all", lv[[k]]),
                  selected = if (k == "COHORT") DASH_CFG$default_cohort else "all"))
  })

  selection <- reactive({
    lv <- key_levels()
    stats::setNames(lapply(names(lv), function(k) input[[paste0("key_", k)]]),
                    names(lv))
  })

  output$scn_readings <- renderUI({
    s <- scn()
    if (!length(s$readings)) return(NULL)
    keys <- if (length(SCENARIO_DIFFS)) SCENARIO_DIFFS else names(s$readings)
    bits <- vapply(intersect(keys, names(s$readings)), function(k)
      sprintf("%s = %s", k, s$readings[[k]]$value), character(1))
    tagList(div(class = "scn", HTML(paste(html_escape(bits), collapse = "<br>"))),
            if (!scenario_is_usable(s))
              div(class = "alert", sprintf("This run is '%s', not complete.", s$state)))
  })

  # Has the snapshot been replaced since the app read it?
  #
  # Checked once per render rather than once per session: the scenarios are
  # loaded at startup and a table is read when a panel opens, so a refresh in
  # between put the new run's rows under the old run's metadata. Cached by
  # Shiny's own reactive machinery, so it is one read per invalidation.
  scenario_moved <- reactive({
    s <- scn()
    isFALSE(scenario_is_current(SRC, s))
  })

  # One table, read and filtered the way every panel wants it.
  panel_data <- function(p, scenario) {
    if (is.na(p$table)) return(NULL)
    # Fail closed: rows from a run the sidebar is not describing are not this
    # scenario's, whatever the directory is called.
    if (isTRUE(scenario_moved())) return(NULL)
    # A LOT panel reads the run this scenario named, not the scenario's own
    # prefix - the lines were built by a different build.
    d <- if (identical(p$source %||% "study", "lot"))
      read_lot_table(SRC, scenario, p$table)
    else read_table(SRC, scenario$prefix, p$table, DASH_CFG$prefer_release)
    if (is.null(d) || !nrow(d)) return(d)
    sp <- table_spec(p$table, names(d))
    d <- apply_keys(d, sp, selection())
    apply_floor(d, sp, input$floor, DASH_CFG$suppress_min_n)
  }

  render_panel <- function(p) {
    s <- scn()
    if (!isTRUE(p$available))
      return(div(class = "alert", html_escape(p$why)))
    # Said once, on every panel, rather than a page of empty tables.
    if (isTRUE(scenario_moved()))
      return(tagList(h4(p$label), div(class = "alert", paste0(
        "This snapshot has been rebuilt since the page was opened, so the ",
        "settings and the LOT run named beside it belong to the previous run. ",
        "Nothing is shown until the page is reloaded.")), tags$hr()))
    body <- switch(p$render,
      kpi    = ui_kpi(p, s),
      table  = ui_table(p, s),
      funnel = ui_funnel(p, s),
      bar    = ui_plot(p, s),
      km     = ui_plot(p, s),
      flow   = ui_table(p, s),
      check  = ui_check(p, s),
      delta  = ui_delta(p, s),
      ui_table(p, s))
    tagList(h4(p$label),
            if (!is.null(p$note)) div(class = "note", p$note) else NULL,
            body, tags$hr())
  }

  # A table panel NEVER renders one row per patient.
  #
  # A `subject` table is one row per PATID, and putting it on the page as a
  # grid is a line listing with the identifier attached. It is summarised
  # instead - counts and percentages per level, mean/median for the continuous
  # columns - and every identifier column is dropped whatever shape the table
  # is, so a spec that forgets to declare one cannot leak it.
  ui_table <- function(p, s) {
    id <- paste0("tbl_", p$name)
    output[[id]] <- renderUI({
      if (identical(p$name, "settings"))
        return(HTML(html_table(settings_table(s), max_rows = DASH_CFG$max_rows)))
      if (identical(p$table, "S_RUN_METADATA"))
        return(HTML(html_table(drop_identifiers(SRC$read(s$prefix, "S_RUN_METADATA")),
                               max_rows = DASH_CFG$max_rows)))
      d <- panel_data(p, s)
      if (is.null(d) || !nrow(d)) return(HTML(html_table(NULL)))
      HTML(panel_table_html(
        d, table_spec(p$table, names(d)),
        floor_n = max(as.integer(input$floor),
                      as.integer(DASH_CFG$suppress_min_n)),
        max_rows = DASH_CFG$max_rows))
    })
    uiOutput(id)
  }

  # A headline count is a released number like any other. This one went
  # straight from S_ATTRITION to the page, so a three-patient cohort was
  # displayed at a floor of 25 while every table beside it withheld the same
  # stratum.
  ui_kpi <- function(p, s) {
    id <- paste0("kpi_", p$name)
    output[[id]] <- renderUI({
      d <- SRC$read(s$prefix, "S_ATTRITION")
      if (is.null(d) || !nrow(d)) return(HTML(html_table(NULL)))
      last <- do.call(rbind, lapply(split(d, d$COHORT), function(x)
        x[which.max(x$STEP), , drop = FALSE]))
      HTML(kpi_row_html(last, input$floor, DASH_CFG$suppress_min_n))
    })
    uiOutput(id)
  }

  # Two funnels with different column names - this package's S_ATTRITION and
  # the LOT build's LOT_ATTRITION - drawn by one panel, off the spec.
  ui_funnel <- function(p, s) {
    id <- paste0("fun_", p$name)
    output[[id]] <- renderPlot({
      d <- panel_data(p, s)
      if (is.null(d) || !nrow(d)) return(plot_empty())
      sp <- table_spec(p$table, names(d))
      ord <- sp$order %||% "STEP"
      lab <- sp$facet %||% "CRITERION"
      val <- intersect(sp$values, names(d))[1]
      if (!all(c(ord, lab) %in% names(d)) || is.na(val)) return(plot_empty())
      d <- d[order(d[[ord]]), , drop = FALSE]
      tag <- if ("KIND" %in% names(d)) paste0(" [", d$KIND, "]") else ""
      plot_bar(paste0(d[[ord]], ". ", d[[lab]], tag), d[[val]],
               main = p$label, xlab = val)
    }, height = 420)
    plotOutput(id, height = "420px")
  }

  ui_plot <- function(p, s) {
    id <- paste0("plt_", p$name)
    output[[id]] <- renderPlot({
      d <- panel_data(p, s)
      sp <- table_spec(p$table, names(d %||% data.frame()))
      if (identical(p$render, "km")) {
        if (is.null(d) || !nrow(d)) return(plot_empty())
        # The ANALYSIS set, not the table. S_TTE deliberately keeps the whole
        # cohort and marks the restricted population with TTE_ELIGIBLE; the
        # curve drawn over every row was a different cohort from the one the
        # producer defined, with a first event that belonged to patients the
        # analysis excludes.
        pp <- prepare_panel(d, sp, input$floor, purpose = "tte",
                            package_min_n = DASH_CFG$suppress_min_n)
        if (!pp$released) return(plot_empty(pp$note))
        eps <- sp$endpoints
        curves <- stats::setNames(lapply(names(eps), function(e)
          km_estimate(pp$rows[[eps[[e]][["time"]]]],
                      pp$rows[[eps[[e]][["event"]]]])),
          names(eps))
        return(plot_km(curves, main = paste0(p$label, "  (n = ", pp$n, ")")))
      }
      if (is.null(d) || !nrow(d)) return(plot_empty())
      # A panel may name the column to break down by; otherwise the spec's
      # facet. A patient-level table has no value column, so the bar is a
      # count of rows - which is what "lines by line number" is.
      lab <- p$by %||% sp$facet %||% sp$keys[1]
      val <- sp$rate %||% sp$pct %||% sp$n_col
      if (is.null(lab) || !lab %in% names(d)) return(plot_empty())
      if (is.null(val) || !val %in% names(d))
        return(plot_count_bars(d, sp, lab, p$label, input$floor))
      plot_stratum_bars(d, sp, lab, val, p$label)
    }, height = 420)
    plotOutput(id, height = "420px")
  }

  # A check table: what was found, what was expected, and the verdict. The
  # number is shown beside the range rather than replaced by a tick, because a
  # verdict without its value cannot be argued with.
  ui_check <- function(p, s) {
    id <- paste0("chk_", p$name)
    output[[id]] <- renderUI({
      d <- panel_data(p, s)
      if (is.null(d) || !nrow(d)) return(HTML(html_table(NULL)))
      sp <- table_spec(p$table, names(d))
      v <- sp$verdict
      if (!is.null(v) && v %in% names(d)) {
        # Anything not a clean pass first: a page of greens with one LOOK
        # buried at the bottom is a page nobody reads to the bottom of.
        bad <- !toupper(trimws(as.character(d[[v]]))) %in% c("OK", "PASS")
        d <- rbind(d[bad, , drop = FALSE], d[!bad, , drop = FALSE])
        n_bad <- sum(bad)
      } else n_bad <- 0L
      HTML(paste0(
        if (n_bad > 0) sprintf(
          '<div class="alert">%d check(s) did not come back clean. They are listed first.</div>',
          n_bad) else "",
        html_table(drop_identifiers(d), max_rows = DASH_CFG$max_rows)))
    })
    uiOutput(id)
  }

  ui_delta <- function(p, s) {
    id <- paste0("dlt_", p$name)
    output[[id]] <- renderUI({
      b <- scn_b()
      if (is.null(b))
        return(div(class = "note", "Pick a scenario in 'Against' to compare."))
      rd <- compare_readings(s, b)
      # Before any difference is drawn: do these two rest on the SAME lines?
      # Two scenarios sharing a LOT run differ only in what this package did.
      # Two reading different runs differ in the lines as well, and a delta
      # between them carries both without saying so.
      same <- same_lot_run(s, b)
      lot_html <- if (isTRUE(same))
        sprintf('<p class="note">Both rest on LOT run <b>%s</b>, so every difference below is this package\'s.</p>',
                html_escape(s$lot_run_id))
      else if (isFALSE(same))
        sprintf('<div class="alert"><b>Different LOT runs.</b> A is %s and B is %s, so the lines themselves differ. A difference below carries both that and the settings, and the two cannot be told apart here.</div>',
                html_escape(s$lot_run_id), html_escape(b$lot_run_id))
      else
        '<div class="alert">At least one of these scenarios records no LOT run, so it cannot be said whether they rest on the same lines.</div>'
      diff_html <- paste0(lot_html,
        html_table(rd[rd$DIFFERS, c("SETTING", "A", "B")],
                   caption = "Settings that differ"))
      rate_tables <- intersect(
        c("S_SAFETY_RATES", "S_HCRU_RATES", "S_MALIGNANCY_RATES"),
        DASH_TABLES$TABLE)
      blocks <- lapply(rate_tables, function(tb) {
        sp <- table_spec(tb)
        da <- apply_keys(read_table(SRC, s$prefix, tb, DASH_CFG$prefer_release), sp, selection())
        db <- apply_keys(read_table(SRC, b$prefix, tb, DASH_CFG$prefer_release), sp, selection())
        cm <- compare_tables(da, db, sp, sp$rate)
        if (!nrow(cm)) return("")
        # The comparison is a released number too. It was built from the two
        # scenarios' rows and rendered straight to the page, so a stratum both
        # normal panels withheld came back here as A, B and their delta.
        cm <- suppress_comparison(cm, da, db, sp, input$floor,
                                  DASH_CFG$suppress_min_n)
        paste0("<h5>", html_escape(sp$label), "</h5>",
               html_table(cm, max_rows = DASH_CFG$max_rows))
      })
      HTML(paste0(diff_html, paste(blocks, collapse = "")))
    })
    uiOutput(id)
  }

  # Every open question, where it is answered, and what this run said.
  settings_table <- function(s) {
    keys <- names(OPEN_QUESTION_SOURCE)
    data.frame(
      SETTING = keys,
      APPLIED = ifelse(OPEN_QUESTION_SOURCE[keys] == "here",
                       "this package", "the cohort build"),
      THIS_RUN = vapply(keys, function(k)
        if (k %in% names(s$readings)) s$readings[[k]]$value else "—", character(1)),
      PROVENANCE = vapply(keys, function(k)
        if (k %in% names(s$readings)) s$readings[[k]]$note else "", character(1)),
      ENV_VAR = vapply(keys, function(k)
        if (k %in% names(SETTING_ENV)) SETTING_ENV[[k]] else "—", character(1)),
      LIVE = "no - needs a run",
      stringsAsFactors = FALSE)
  }

  for (tb in PANEL_TABS()) local({
    this_tab <- tb
    output[[paste0("tab_", make.names(this_tab))]] <- renderUI({
      ps <- Filter(function(p) identical(p$tab, this_tab), resolve_panels(scn(), src = SRC))
      if (!length(ps)) return(div(class = "note", "No panel on this tab."))
      do.call(tagList, lapply(ps, render_panel))
    })
  })
}

shinyApp(ui, server)
