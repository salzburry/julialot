#' Shiny GUI for Attrition Cohort Analysis
#'
#' Interactive application for configuring and running attrition cohort analysis
#' with user-configurable inclusion/exclusion criteria.

#' Launch the Shiny application
#' @param data Optional pre-loaded data frame
#' @export
launch_attrition_app <- function(data = NULL) {
  if (!requireNamespace("shiny", quietly = TRUE)) {
    stop("Package 'shiny' is required. Install with: install.packages('shiny')")
  }
  if (!requireNamespace("DT", quietly = TRUE)) {
    stop("Package 'DT' is required. Install with: install.packages('DT')")
  }

  shiny::shinyApp(
    ui = attrition_ui(),
    server = function(input, output, session) {
      attrition_server(input, output, session, preloaded_data = data)
    }
  )
}

#' Shiny UI
#' @keywords internal
attrition_ui <- function() {
  shiny::fluidPage(
    shiny::titlePanel("Multiple Myeloma Attrition Cohort Builder"),

    shiny::sidebarLayout(
      shiny::sidebarPanel(
        width = 4,

        # Data Upload Section
        shiny::h4("1. Data Input"),
        shiny::fileInput("data_file", "Upload Patient Data (CSV/RDS)",
                        accept = c(".csv", ".rds")),
        shiny::hr(),

        # Study Period Configuration
        shiny::h4("2. Study Periods"),
        shiny::dateRangeInput("study_period",
                             "Full Study Period",
                             start = "2015-07-01",
                             end = "2025-06-30"),
        shiny::dateRangeInput("id_period",
                             "Identification Period",
                             start = "2016-01-01",
                             end = "2025-06-30"),
        shiny::hr(),

        # Enrollment Parameters
        shiny::h4("3. Enrollment Parameters"),
        shiny::numericInput("baseline_months", "Baseline Period (months)", 6, min = 1, max = 24),
        shiny::numericInput("allowable_gap", "Allowable Enrollment Gap (days)", 30, min = 0, max = 90),
        shiny::checkboxInput("require_medical", "Require Medical Benefits", TRUE),
        shiny::checkboxInput("require_pharmacy", "Require Pharmacy Benefits", TRUE),
        shiny::hr(),

        # Diagnosis Window
        shiny::h4("4. Diagnosis Window"),
        shiny::checkboxGroupInput("diagnosis_windows",
                                 "Outpatient Claim Windows to Evaluate",
                                 choices = c("30 days" = 30, "60 days" = 60, "90 days" = 90),
                                 selected = c(30, 60, 90)),
        shiny::selectInput("primary_window",
                          "Primary Window for Analysis",
                          choices = c("30 days" = 30, "60 days" = 60, "90 days" = 90),
                          selected = 90),
        shiny::hr(),

        # Action Buttons
        shiny::actionButton("run_analysis", "Run Attrition Analysis",
                           class = "btn-primary btn-lg"),
        shiny::downloadButton("download_results", "Download Results")
      ),

      shiny::mainPanel(
        width = 8,
        shiny::tabsetPanel(
          id = "main_tabs",

          # Criteria Configuration Tab
          shiny::tabPanel(
            "Inclusion/Exclusion Criteria",
            shiny::br(),
            shiny::h4("Configure Criteria (Toggle On/Off)"),
            shiny::p("Enable or disable each criterion. Adjust parameters as needed."),
            shiny::hr(),

            # Criterion 0 - Base (always on)
            shiny::wellPanel(
              shiny::h5("Criterion 0: Base Cohort (Required)"),
              shiny::p(shiny::tags$em(">=1 medical claims for multiple myeloma (ICD-9-CM=203.x or ICD-10-CM=C90.x)")),
              shiny::p(shiny::tags$strong("This criterion cannot be disabled - it defines the base cohort."))
            ),

            # Criterion 1 - Inpatient/Outpatient
            shiny::wellPanel(
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 1: MM Diagnosis Confirmation"),
                  shiny::p(">=1 inpatient OR >=2 outpatient claims within specified window")
                ),
                shiny::column(4,
                  shiny::checkboxInput("c1_enabled", "Enabled", TRUE)
                )
              ),
              shiny::conditionalPanel(
                condition = "input.c1_enabled",
                shiny::fluidRow(
                  shiny::column(6,
                    shiny::numericInput("c1_outpatient_count", "Required Outpatient Claims", 2, min = 1, max = 5)
                  ),
                  shiny::column(6,
                    shiny::selectInput("c1_window", "Window (days)",
                                      choices = c(30, 60, 90), selected = 90)
                  )
                )
              )
            ),

            # Criterion 2 - Age
            shiny::wellPanel(
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 2: Age Requirement"),
                  shiny::p("Patients must be at least minimum age in index year")
                ),
                shiny::column(4,
                  shiny::checkboxInput("c2_enabled", "Enabled", TRUE)
                )
              ),
              shiny::conditionalPanel(
                condition = "input.c2_enabled",
                shiny::numericInput("c2_min_age", "Minimum Age", 18, min = 0, max = 100)
              )
            ),

            # Criterion 3 - MM Therapy Follow-up
            shiny::wellPanel(
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 3: MM Therapy in Follow-up (Inclusion)"),
                  shiny::p("Evidence of FDA-approved MM oncology therapy during follow-up period")
                ),
                shiny::column(4,
                  shiny::checkboxInput("c3_enabled", "Enabled", TRUE)
                )
              )
            ),

            # Criterion 4 - MM Therapy Baseline (Exclusion)
            shiny::wellPanel(
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 4: MM Therapy in Baseline (Exclusion)"),
                  shiny::p("Exclude patients with MM therapy during baseline period (ensures newly diagnosed)")
                ),
                shiny::column(4,
                  shiny::checkboxInput("c4_enabled", "Enabled", TRUE)
                )
              )
            ),

            # Criterion 5 - Baseline CE
            shiny::wellPanel(
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 5: Baseline Continuous Enrollment"),
                  shiny::p("Required months of CE before index date")
                ),
                shiny::column(4,
                  shiny::checkboxInput("c5_enabled", "Enabled", TRUE)
                )
              ),
              shiny::conditionalPanel(
                condition = "input.c5_enabled",
                shiny::numericInput("c5_months", "Required CE Months", 6, min = 1, max = 24)
              )
            ),

            # Criterion 6 - Follow-up CE
            shiny::wellPanel(
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 6: Follow-up Enrollment"),
                  shiny::p("Minimum days of CE starting on index date")
                ),
                shiny::column(4,
                  shiny::checkboxInput("c6_enabled", "Enabled", TRUE)
                )
              ),
              shiny::conditionalPanel(
                condition = "input.c6_enabled",
                shiny::numericInput("c6_days", "Minimum CE Days", 1, min = 1, max = 365)
              )
            ),

            # Criterion 7 - Other Cancer (Exclusion)
            shiny::wellPanel(
              style = "background-color: #fff3cd;",
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 7: Other Cancer (Exclusion)"),
                  shiny::p("Exclude patients with another cancer in baseline period"),
                  shiny::p(shiny::tags$em("Note: Disabled by default per protocol"))
                ),
                shiny::column(4,
                  shiny::checkboxInput("c7_enabled", "Enabled", FALSE)
                )
              )
            ),

            # Criterion 8 - Pregnancy (Exclusion)
            shiny::wellPanel(
              style = "background-color: #fff3cd;",
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 8: Pregnancy/Childbirth (Exclusion)"),
                  shiny::p("Exclude patients with pregnancy or childbirth"),
                  shiny::p(shiny::tags$em("Note: Disabled by default per protocol"))
                ),
                shiny::column(4,
                  shiny::checkboxInput("c8_enabled", "Enabled", FALSE)
                )
              )
            ),

            # Criterion 9 - Clinical Trial (Exclusion)
            shiny::wellPanel(
              style = "background-color: #fff3cd;",
              shiny::fluidRow(
                shiny::column(8,
                  shiny::h5("Criterion 9: Clinical Trial (Exclusion)"),
                  shiny::p("Exclude patients with clinical trial participation"),
                  shiny::p(shiny::tags$em("Note: Disabled by default per protocol"))
                ),
                shiny::column(4,
                  shiny::checkboxInput("c9_enabled", "Enabled", FALSE)
                )
              )
            )
          ),

          # Results Tab
          shiny::tabPanel(
            "Attrition Table",
            shiny::br(),
            shiny::h4("Attrition Results"),
            shiny::verbatimTextOutput("config_summary"),
            shiny::hr(),
            DT::DTOutput("attrition_table"),
            shiny::br(),
            shiny::plotOutput("attrition_plot", height = "400px")
          ),

          # Data Preview Tab
          shiny::tabPanel(
            "Data Preview",
            shiny::br(),
            shiny::h4("Patient Data Preview"),
            shiny::verbatimTextOutput("data_summary"),
            shiny::hr(),
            DT::DTOutput("data_preview")
          ),

          # Help Tab
          shiny::tabPanel(
            "Help",
            shiny::br(),
            shiny::h4("How to Use This Application"),
            shiny::tags$ol(
              shiny::tags$li("Upload your patient-level data file (CSV or RDS format)"),
              shiny::tags$li("Configure study periods and enrollment parameters in the sidebar"),
              shiny::tags$li("Review and toggle inclusion/exclusion criteria on the Criteria tab"),
              shiny::tags$li("Click 'Run Attrition Analysis' to process the cohort"),
              shiny::tags$li("View results in the Attrition Table tab"),
              shiny::tags$li("Download results using the Download button")
            ),
            shiny::hr(),
            shiny::h4("Required Data Variables"),
            shiny::p("Your data should include the following variables (or similar):"),
            shiny::tags$ul(
              shiny::tags$li("Patient ID (PATID, patient_id, ENROLID)"),
              shiny::tags$li("Index Date (INDEX_DATE, index_date)"),
              shiny::tags$li("Birth Year/Date (BIRTH_YR, birth_date)"),
              shiny::tags$li("MM diagnosis flags"),
              shiny::tags$li("Enrollment flags (CE_b, CE_f)"),
              shiny::tags$li("Therapy flags (MM_FU_agents, MM_bl_agents)")
            ),
            shiny::hr(),
            shiny::h4("Criteria Descriptions"),
            shiny::p("Each criterion is applied sequentially. Inclusion criteria INCLUDE patients who meet the requirement. Exclusion criteria EXCLUDE patients who meet the requirement."),
            shiny::p("Criteria shown in yellow are disabled by default per the study protocol but can be enabled for sensitivity analyses.")
          )
        )
      )
    )
  )
}

#' Shiny Server
#' @keywords internal
attrition_server <- function(input, output, session, preloaded_data = NULL) {

  # Reactive values
  values <- shiny::reactiveValues(
    data = preloaded_data,
    results = NULL,
    attrition_table = NULL,
    config = NULL
  )

  # Load data from file
  shiny::observeEvent(input$data_file, {
    req(input$data_file)
    ext <- tools::file_ext(input$data_file$name)

    if (ext == "csv") {
      values$data <- read.csv(input$data_file$datapath, stringsAsFactors = FALSE)
    } else if (ext == "rds") {
      values$data <- readRDS(input$data_file$datapath)
    }

    shiny::showNotification(
      sprintf("Loaded %d patients", nrow(values$data)),
      type = "message"
    )
  })

  # Build configuration from inputs
  build_config <- shiny::reactive({
    config <- create_default_config()

    # Study periods
    config$study_periods$study_start_date <- input$study_period[1]
    config$study_periods$study_end_date <- input$study_period[2]
    config$study_periods$id_period_start <- input$id_period[1]
    config$study_periods$id_period_end <- input$id_period[2]

    # Enrollment
    config$enrollment$baseline_months <- input$baseline_months
    config$enrollment$allowable_gap_days <- input$allowable_gap
    config$enrollment$require_medical_benefits <- input$require_medical
    config$enrollment$require_pharmacy_benefits <- input$require_pharmacy

    # Diagnosis windows
    config$diagnosis_window$windows_to_use <- as.numeric(input$diagnosis_windows)
    config$diagnosis_window$primary_window <- as.numeric(input$primary_window)

    # Criteria toggles
    config$criteria$c1_mm_diagnosis_strict$enabled <- input$c1_enabled
    config$criteria$c1_mm_diagnosis_strict$options$outpatient_count <- input$c1_outpatient_count
    config$criteria$c1_mm_diagnosis_strict$options$window_days <- as.numeric(input$c1_window)

    config$criteria$c2_age$enabled <- input$c2_enabled
    config$criteria$c2_age$options$min_age <- input$c2_min_age

    config$criteria$c3_mm_therapy_followup$enabled <- input$c3_enabled
    config$criteria$c4_mm_therapy_baseline$enabled <- input$c4_enabled

    config$criteria$c5_baseline_enrollment$enabled <- input$c5_enabled
    config$criteria$c5_baseline_enrollment$options$required_months <- input$c5_months

    config$criteria$c6_followup_enrollment$enabled <- input$c6_enabled
    config$criteria$c6_followup_enrollment$options$min_days <- input$c6_days

    config$criteria$c7_other_cancer$enabled <- input$c7_enabled
    config$criteria$c8_pregnancy$enabled <- input$c8_enabled
    config$criteria$c9_clinical_trial$enabled <- input$c9_enabled

    config
  })

  # Run analysis
  shiny::observeEvent(input$run_analysis, {
    req(values$data)

    config <- build_config()
    values$config <- config

    shiny::withProgress(message = "Running attrition analysis...", {
      shiny::incProgress(0.2)

      # Apply criteria
      values$results <- apply_attrition_criteria(values$data, config, verbose = FALSE)

      shiny::incProgress(0.6)

      # Generate attrition table
      values$attrition_table <- generate_attrition_table(values$results, config)

      shiny::incProgress(0.2)
    })

    shiny::showNotification(
      sprintf("Analysis complete. Final cohort: %d patients",
              sum(values$results$in_final_cohort == 1, na.rm = TRUE)),
      type = "message"
    )

    # Switch to results tab
    shiny::updateTabsetPanel(session, "main_tabs", selected = "Attrition Table")
  })

  # Config summary output
  output$config_summary <- shiny::renderPrint({
    req(values$config)
    print_config_summary(values$config)
  })

  # Attrition table output
  output$attrition_table <- DT::renderDT({
    req(values$attrition_table)
    DT::datatable(
      values$attrition_table,
      options = list(
        pageLength = 15,
        scrollX = TRUE,
        dom = 'Bfrtip'
      ),
      rownames = FALSE
    )
  })

  # Attrition plot
  output$attrition_plot <- shiny::renderPlot({
    req(values$attrition_table)

    # Get n columns
    n_cols <- grep("Cohort \\(n\\)", names(values$attrition_table), value = TRUE)
    if (length(n_cols) == 0) return(NULL)

    # Use first window for plot
    n_col <- n_cols[1]
    window_name <- gsub(" \\(n\\)", "", n_col)

    # Prepare data for plotting
    plot_data <- data.frame(
      step = seq_len(nrow(values$attrition_table)),
      n = values$attrition_table[[n_col]],
      label = paste0("Step ", seq_len(nrow(values$attrition_table)) - 1)
    )

    # Create bar plot
    barplot(
      plot_data$n,
      names.arg = plot_data$label,
      main = paste("Patient Attrition -", window_name),
      xlab = "Step",
      ylab = "Number of Patients",
      col = "steelblue",
      las = 2
    )

    # Add count labels
    text(
      x = seq(0.7, by = 1.2, length.out = nrow(plot_data)),
      y = plot_data$n + max(plot_data$n) * 0.02,
      labels = format(plot_data$n, big.mark = ","),
      cex = 0.8
    )
  })

  # Data summary
  output$data_summary <- shiny::renderPrint({
    req(values$data)
    cat(sprintf("Dataset: %d patients, %d variables\n\n", nrow(values$data), ncol(values$data)))
    cat("Variables:\n")
    cat(paste(names(values$data), collapse = ", "))
  })

  # Data preview
  output$data_preview <- DT::renderDT({
    req(values$data)
    DT::datatable(
      head(values$data, 100),
      options = list(scrollX = TRUE, pageLength = 10),
      rownames = FALSE
    )
  })

  # Download handler
  output$download_results <- shiny::downloadHandler(
    filename = function() {
      paste0("attrition_results_", Sys.Date(), ".csv")
    },
    content = function(file) {
      req(values$attrition_table)
      write.csv(values$attrition_table, file, row.names = FALSE)
    }
  )
}
