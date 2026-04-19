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

  logger::log_info("write_csv_outputs -- wrote {length(paths)} files to {out}",
                   namespace = "resourcetracker")
  invisible(paths)
}

#' Render the Quarto briefing to HTML + PDF
#'
#' Calls `quarto::quarto_render()` with explicit parameters so the
#' briefing reads from the configured `outputs/` and `warehouse`. Both
#' HTML and PDF are rendered into the briefing directory next to the
#' source `.qmd`. If Quarto isn't installed, logs a warning and returns
#' the `.qmd` path -- the pipeline doesn't fail just because of a local
#' Quarto gap.
#'
#' @param qmd_path Path to the `briefing.qmd` source.
#' @param nowcast_current Dependency object (triggers rebuild).
#' @param csv_exports Dependency object.
#' @param cfg Config list.
#' @return Character vector of rendered output paths, invisibly.
#' @export
render_briefing <- function(qmd_path, nowcast_current, csv_exports, cfg) {
  if (!nzchar(Sys.which("quarto"))) {
    logger::log_warn("quarto binary not found on PATH -- skipping render",
                     namespace = "resourcetracker")
    return(invisible(qmd_path))
  }

  params <- list(
    outputs_dir = fs::path_abs(cfg$paths$outputs),
    warehouse   = fs::path_abs(cfg$paths$warehouse)
  )

  html_path <- fs::path(fs::path_dir(qmd_path), "briefing.html")
  pdf_path  <- fs::path(fs::path_dir(qmd_path), "briefing.pdf")

  result <- tryCatch({
    quarto::quarto_render(
      input          = qmd_path,
      execute_params = params,
      quiet          = TRUE
    )
    c(html_path, pdf_path)
  },
  error = function(e) {
    logger::log_warn("quarto render failed: {conditionMessage(e)}",
                     namespace = "resourcetracker")
    qmd_path
  })

  logger::log_info("render_briefing -- {length(result)} file(s)",
                   namespace = "resourcetracker")
  invisible(result)
}
