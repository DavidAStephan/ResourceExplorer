#' Write CSV exports to `outputs/`
#'
#' Writes the four artefact CSVs named in the brief. In Phase 1 all
#' inputs are empty, so this produces header-only CSVs -- confirming
#' schemas flow through the DAG.
#'
#' @param nowcast_current One-row tibble from [run_nowcast()].
#' @param portwatch Daily tonnage tibble.
#' @param bridge_fits Output of [fit_bridge()].
#' @param backtest_results Tibble from [backtest_rmse()].
#' @param cfg Config list.
#' @return Invisibly, a character vector of file paths written.
#' @export
write_csv_outputs <- function(nowcast_current, portwatch, bridge_fits,
                              backtest_results, cfg) {
  out <- cfg$paths$outputs
  fs::dir_create(out)

  paths <- c(
    nowcast_current     = fs::path(out, "nowcast_current.csv"),
    tonnage_daily       = fs::path(out, "tonnage_daily.csv"),
    tonnage_monthly     = fs::path(out, "tonnage_monthly.csv"),
    bridge_diagnostics  = fs::path(out, "bridge_diagnostics.csv")
  )

  readr::write_csv(nowcast_current, paths[["nowcast_current"]])
  readr::write_csv(portwatch,       paths[["tonnage_daily"]])

  tonnage_monthly <- portwatch |>
    dplyr::mutate(
      month_end = lubridate::ceiling_date(.data$obs_date, "month") - 1
    ) |>
    dplyr::group_by(.data$month_end, .data$commodity) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop")
  readr::write_csv(tonnage_monthly, paths[["tonnage_monthly"]])

  # Pull per-commodity diagnostics from fits, augment with validation RMSE.
  fit_diag <- purrr::map_dfr(bridge_fits, function(f) f$diagnostics)
  valid_rmse <- if (nrow(backtest_results) > 0) {
    backtest_results |>
      dplyr::summarise(
        rmse_valid = sqrt(mean(.data$err^2,       na.rm = TRUE)),
        rmse_naive = sqrt(mean(.data$err_naive^2, na.rm = TRUE))
      )
  } else {
    tibble::tibble(rmse_valid = NA_real_, rmse_naive = NA_real_)
  }
  diagnostics <- fit_diag |>
    dplyr::mutate(
      rmse_valid      = valid_rmse$rmse_valid,
      rmse_naive      = valid_rmse$rmse_naive,
      ratio_vs_naive  = .data$rmse_valid / .data$rmse_naive
    )
  readr::write_csv(diagnostics, paths[["bridge_diagnostics"]])

  log_info("write_csv_outputs -- wrote %d files to %s", length(paths), out)
  invisible(paths)
}

#' Render the briefing to HTML via rmarkdown
#'
#' Calls `rmarkdown::render()` with explicit params so the briefing reads
#' from the configured `outputs/` and warehouse directories. HTML only;
#' the previous quarto-rendered PDF path was dropped because `{quarto}`
#' and the quarto CLI are not on the work-laptop allow-list.
#'
#' @param rmd_path Path to the `briefing.Rmd` source.
#' @param nowcast_current Dependency object (triggers rebuild).
#' @param csv_exports Dependency object.
#' @param cfg Config list.
#' @return Character vector of rendered output paths, invisibly.
#' @export
render_briefing <- function(rmd_path, nowcast_current, csv_exports, cfg) {
  params <- list(
    outputs_dir   = fs::path_abs(cfg$paths$outputs),
    warehouse_dir = fs::path_abs(cfg$paths$warehouse_dir %||% "data/warehouse")
  )

  html_path <- fs::path(fs::path_dir(rmd_path), "briefing.html")

  result <- tryCatch({
    rmarkdown::render(
      input         = rmd_path,
      output_file   = "briefing.html",
      output_format = "html_document",
      params        = params,
      quiet         = TRUE,
      envir         = new.env(parent = globalenv())
    )
    html_path
  },
  error = function(e) {
    log_warn("briefing render failed: %s", conditionMessage(e))
    rmd_path
  })

  log_info("render_briefing -- %d file(s)", length(result))
  invisible(result)
}
