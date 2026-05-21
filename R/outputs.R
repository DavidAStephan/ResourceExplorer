#' Write per-commodity CSV exports to `outputs/`
#'
#' Four artefacts, all keyed by commodity:
#'
#' - `nowcast_current.csv` — one row per commodity: point + 80/95 bands
#' - `tonnage_daily.csv`   — raw PortWatch daily panel (filtered to named commodities)
#' - `tonnage_quarterly.csv` — aggregated quarterly tonnage per commodity
#' - `bridge_diagnostics.csv` — one row per commodity: R², DW, β_T, RMSEs
#'
#' @param nowcast_current Tibble from [run_nowcast()] (one row per commodity).
#' @param portwatch Daily tonnage tibble from [fetch_portwatch_tonnage()].
#' @param bridge_fits Output of [fit_bridge()].
#' @param backtest_results Tibble from [backtest_rmse()].
#' @param cfg Config list.
#' @param production_label Optional named character vector keyed by
#'   commodity (e.g. `c(iron_ore = "bojo", coal_met = "midas")`). When
#'   supplied, the matching `(commodity, spec)` row in
#'   `bridge_diagnostics.csv` is flagged `production_choice = TRUE`.
#' @param coverage Optional tibble from [backtest_coverage()] with
#'   `(commodity, spec, n_oos, coverage_80, coverage_95)`. Joined into
#'   `bridge_diagnostics.csv`.
#' @return Invisibly, a named character vector of file paths written.
#' @export
write_csv_outputs <- function(nowcast_current, portwatch, bridge_fits,
                              backtest_results, cfg,
                              production_label = NULL,
                              coverage         = NULL) {
  out <- cfg$paths$outputs
  fs::dir_create(out)

  paths <- c(
    nowcast_current    = fs::path(out, "nowcast_current.csv"),
    tonnage_daily      = fs::path(out, "tonnage_daily.csv"),
    tonnage_quarterly  = fs::path(out, "tonnage_quarterly.csv"),
    bridge_diagnostics = fs::path(out, "bridge_diagnostics.csv")
  )

  readr::write_csv(nowcast_current, paths[["nowcast_current"]])

  pw_named <- dplyr::filter(portwatch,
                            .data$commodity %in% cfg$commodities)
  readr::write_csv(pw_named, paths[["tonnage_daily"]])

  # Raw observed quarterly sum -- correct for all completed quarters,
  # misleading for the current partial quarter (cliff-drop on the
  # chart). We mark that quarter explicitly and attach the extrapolated
  # full-quarter estimate the bridge actually consumes.
  max_obs <- if (nrow(pw_named) > 0) max(pw_named$obs_date) else as.Date(NA)
  tonnage_quarterly_raw <- pw_named |>
    dplyr::mutate(
      quarter_end = lubridate::ceiling_date(.data$obs_date, "quarter") - 1
    ) |>
    dplyr::group_by(.data$quarter_end, .data$commodity) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop") |>
    # A quarter is "complete" if PortWatch coverage extends to or past
    # its end-date. The most-recent quarter is typically partial.
    dplyr::mutate(is_complete = !is.na(max_obs) &
                                .data$quarter_end <= max_obs)

  extrap_quarterly <- tibble::tibble(
    quarter_end          = as.Date(character()),
    commodity            = character(),
    tonnage_extrapolated = double()
  )
  if (!is.na(max_obs)) {
    cur_q_end <- quarter_end(max_obs)
    extrap_monthly <- extrapolate_quarter_tonnage(
      pw_named, ports_meta = NULL, cfg = cfg, as_of = max_obs
    )
    extrap_quarterly <- extrap_monthly |>
      dplyr::group_by(.data$commodity) |>
      dplyr::summarise(
        tonnage_extrapolated = sum(.data$tonnage_est, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(quarter_end = cur_q_end)
  }

  tonnage_quarterly <- tonnage_quarterly_raw |>
    dplyr::left_join(extrap_quarterly,
                     by = c("quarter_end", "commodity")) |>
    # Only the partial quarter carries an extrapolated total; null it out
    # for completed quarters where it would duplicate `tonnage`.
    dplyr::mutate(tonnage_extrapolated = dplyr::if_else(
      .data$is_complete, NA_real_, .data$tonnage_extrapolated
    )) |>
    dplyr::arrange(.data$commodity, .data$quarter_end)
  readr::write_csv(tonnage_quarterly, paths[["tonnage_quarterly"]])

  fit_diag <- purrr::map_dfr(bridge_fits, function(f) f$diagnostics)
  # Normalise empty fit_diag so the downstream join works.
  if (!"commodity" %in% names(fit_diag)) {
    fit_diag <- tibble::tibble(
      commodity            = character(),
      spec                 = character(),
      n_obs                = integer(),
      r_squared            = double(),
      rmse_train           = double(),
      dw_stat              = double(),
      beta_tonnage         = double(),
      beta_tonnage_se      = double(),
      beta_lag4            = double(),
      beta_lag4_eq_1_pval  = double()
    )
  }
  if (!"spec" %in% names(fit_diag)) {
    # Single-spec back-compat path: fit_bridge() was used instead of
    # fit_bridge_bench(). Assume aggregate.
    fit_diag$spec <- "aggregate"
  }

  oos <- oos_diagnostics(backtest_results)

  diagnostics <- fit_diag |>
    dplyr::full_join(oos, by = c("commodity", "spec")) |>
    dplyr::arrange(.data$commodity, .data$spec)

  if (!is.null(coverage) && nrow(coverage) > 0L) {
    diagnostics <- diagnostics |>
      dplyr::left_join(coverage, by = c("commodity", "spec"))
  } else {
    diagnostics$n_oos       <- NA_integer_
    diagnostics$coverage_80 <- NA_real_
    diagnostics$coverage_95 <- NA_real_
  }

  # `production_label` is a named character vector keyed by commodity
  # (e.g. `c(iron_ore = "midas", coal = "equal_avg")`). Mark the row that
  # matches as `production_choice = TRUE`; everything else FALSE.
  diagnostics$production_choice <- if (is.null(production_label)) {
    NA
  } else {
    mapply(function(com, spec) {
      isTRUE(production_label[[com]] == spec)
    }, diagnostics$commodity, diagnostics$spec)
  }

  readr::write_csv(diagnostics, paths[["bridge_diagnostics"]])

  log_info("write_csv_outputs -- wrote %d files to %s", length(paths), out)
  invisible(paths)
}

#' Render the briefing to HTML via rmarkdown
#'
#' Calls `rmarkdown::render()` with explicit params.
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
