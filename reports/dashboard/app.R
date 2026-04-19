## resourcetracker — local Shiny dashboard
##
## Reads from outputs/*.csv and the DuckDB warehouse. Run from the repo
## root with:
##   shiny::runApp("reports/dashboard")
## No deployment — local only.

library(shiny)
library(dplyr)
library(readr)
library(ggplot2)
library(DBI)
library(duckdb)
library(fs)

OUTPUTS   <- path("..", "..", "outputs")
WAREHOUSE <- path("..", "..", "data", "warehouse.duckdb")

safe_read <- function(p) {
  if (!file_exists(p)) return(tibble())
  suppressMessages(read_csv(p, show_col_types = FALSE))
}

pull_wh <- function(sql) {
  if (!file_exists(WAREHOUSE)) return(tibble())
  con <- tryCatch(dbConnect(duckdb(), dbdir = WAREHOUSE, read_only = TRUE),
                  error = function(e) NULL)
  if (is.null(con)) return(tibble())
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  tryCatch(as_tibble(dbGetQuery(con, sql)), error = function(e) tibble())
}

ui <- fluidPage(
  titlePanel("resourcetracker — Australian real goods nowcast"),
  tabsetPanel(
    tabPanel("Nowcast",
      fluidRow(
        column(8, plotOutput("nowcast_plot", height = "400px")),
        column(4, tableOutput("nowcast_summary"))
      ),
      downloadButton("dl_nowcast", "Download nowcast_current.csv")
    ),
    tabPanel("Daily tonnage",
      sidebarLayout(
        sidebarPanel(
          uiOutput("commodity_picker"),
          uiOutput("port_picker"),
          width = 3
        ),
        mainPanel(
          plotOutput("tonnage_plot", height = "500px"),
          downloadButton("dl_tonnage", "Download tonnage_daily.csv"),
          width = 9
        )
      )
    ),
    tabPanel("Backtest",
      fluidRow(
        column(8, plotOutput("backtest_plot", height = "400px")),
        column(4, tableOutput("diag_table"))
      )
    )
  )
)

server <- function(input, output, session) {

  # ---- Nowcast tab ----
  history <- reactive(pull_wh(
    "SELECT * FROM mart.nowcast_history ORDER BY run_timestamp"
  ))
  current <- reactive(safe_read(path(OUTPUTS, "nowcast_current.csv")))

  output$nowcast_plot <- renderPlot({
    h <- history()
    if (nrow(h) == 0) {
      plot.new(); title("No nowcast history yet"); return(invisible())
    }
    h |>
      mutate(run_timestamp = as.POSIXct(run_timestamp)) |>
      ggplot(aes(run_timestamp, point_estimate)) +
      geom_ribbon(aes(ymin = lower_95, ymax = upper_95), alpha = 0.15) +
      geom_ribbon(aes(ymin = lower_80, ymax = upper_80), alpha = 0.25) +
      geom_line() + geom_point() +
      labs(x = "Run", y = "A$m (chain-volume)",
           title = "Nowcast evolution") +
      theme_minimal()
  })

  output$nowcast_summary <- renderTable({
    nc <- current()
    if (nrow(nc) == 0) return(tibble(note = "No nowcast yet"))
    nc |>
      mutate(across(where(is.numeric), round, 1)) |>
      tidyr::pivot_longer(everything(), names_to = "metric",
                          values_to = "value",
                          values_transform = list(value = as.character))
  })

  output$dl_nowcast <- downloadHandler(
    filename = function() "nowcast_current.csv",
    content  = function(f) file.copy(path(OUTPUTS, "nowcast_current.csv"), f)
  )

  # ---- Daily tonnage tab ----
  tonnage_daily <- reactive(safe_read(path(OUTPUTS, "tonnage_daily.csv")))

  output$commodity_picker <- renderUI({
    coms <- sort(unique(tonnage_daily()$commodity))
    selectInput("commodity", "Commodity",
                choices = c("All", coms), selected = "All")
  })
  output$port_picker <- renderUI({
    ports <- sort(unique(tonnage_daily()$port_id))
    selectInput("port_id", "Port",
                choices = c("All", ports), selected = "All")
  })

  output$tonnage_plot <- renderPlot({
    df <- tonnage_daily()
    if (nrow(df) == 0) {
      plot.new(); title("No tonnage data"); return(invisible())
    }
    if (!is.null(input$commodity) && input$commodity != "All")
      df <- filter(df, commodity == input$commodity)
    if (!is.null(input$port_id)   && input$port_id   != "All")
      df <- filter(df, port_id   == input$port_id)
    df |>
      mutate(obs_date = as.Date(obs_date)) |>
      group_by(obs_date, commodity) |>
      summarise(tonnage = sum(tonnage, na.rm = TRUE), .groups = "drop") |>
      ggplot(aes(obs_date, tonnage, colour = commodity)) +
      geom_line() +
      labs(x = NULL, y = "Tonnage", colour = "Commodity") +
      theme_minimal()
  })

  output$dl_tonnage <- downloadHandler(
    filename = function() "tonnage_daily.csv",
    content  = function(f) file.copy(path(OUTPUTS, "tonnage_daily.csv"), f)
  )

  # ---- Backtest tab ----
  diag <- reactive(safe_read(path(OUTPUTS, "bridge_diagnostics.csv")))

  output$diag_table <- renderTable({
    d <- diag()
    if (nrow(d) == 0) return(tibble(note = "No diagnostics"))
    d |> mutate(across(where(is.numeric), round, 3))
  })

  output$backtest_plot <- renderPlot({
    d <- diag()
    if (nrow(d) == 0 || !"ratio_vs_naive" %in% names(d)) {
      plot.new(); title("No backtest diagnostics"); return(invisible())
    }
    d |>
      filter(!is.na(ratio_vs_naive)) |>
      ggplot(aes(commodity, ratio_vs_naive)) +
      geom_col() +
      geom_hline(yintercept = 0.7, linetype = 2, colour = "red") +
      labs(x = NULL, y = "RMSE vs seasonal-random-walk",
           subtitle = "Target: ≤ 0.70 (30% below naive)") +
      theme_minimal()
  })
}

shinyApp(ui, server)
