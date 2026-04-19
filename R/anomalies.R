#' Detect >threshold-sigma departures from the seasonal daily norm
#'
#' For each (port, commodity), build a seasonal norm by pooling
#' observations from the training window (2019-`cfg$sample$train_end`)
#' across a +/-`window_days`-day window around each day-of-year. Z-score
#' each observation in the last `lookback_days` against its seasonal
#' mean and SD; return rows with `|z| > threshold` sorted by `|z|` desc.
#'
#' @param portwatch Daily tonnage tibble.
#' @param cfg Config list.
#' @param as_of Reference date.
#' @param lookback_days How many recent days to inspect.
#' @param window_days Half-width of the seasonal-norm smoothing window.
#' @param threshold `|z|` flag threshold.
#' Also overwrites `mart.latest_anomalies` with the detected rows so
#' the briefing and dashboard can query them without re-running the
#' detection.
#'
#' @return Tibble: `obs_date`, `port_id`, `commodity`, `tonnage`,
#'   `expected`, `sd`, `z_score`, sorted descending by `|z_score|`.
#' @export
detect_anomalies <- function(portwatch, cfg,
                             as_of         = Sys.Date(),
                             lookback_days = 28L,
                             window_days   = 7L,
                             threshold     = 2) {
  if (nrow(portwatch) == 0) {
    return(tibble::tibble(
      obs_date = as.Date(character()), port_id = character(),
      commodity = character(), tonnage = double(),
      expected = double(), sd = double(), z_score = double()
    ))
  }

  train_end <- as.Date(cfg$sample$train_end %||% "2023-12-31")
  train <- dplyr::filter(portwatch, .data$obs_date <= train_end) |>
    dplyr::mutate(doy = lubridate::yday(.data$obs_date))

  # Seasonal norm via +/-window-day pooling -- vectorise by expanding each
  # training row to its +/-W neighbours.
  offsets <- seq(-window_days, window_days)
  pooled <- purrr::map_dfr(offsets, function(o) {
    dplyr::mutate(train,
                  doy_centre = ((.data$doy + o - 1L) %% 366L) + 1L)
  })
  norm <- pooled |>
    dplyr::group_by(.data$port_id, .data$commodity, .data$doy_centre) |>
    dplyr::summarise(
      expected = mean(.data$tonnage, na.rm = TRUE),
      sd       = stats::sd(.data$tonnage, na.rm = TRUE),
      .groups  = "drop"
    )

  recent <- portwatch |>
    dplyr::filter(.data$obs_date >= as_of - lookback_days,
                  .data$obs_date <= as_of) |>
    dplyr::mutate(doy_centre = lubridate::yday(.data$obs_date))

  out <- recent |>
    dplyr::inner_join(norm,
                      by = c("port_id", "commodity", "doy_centre")) |>
    dplyr::mutate(
      z_score = dplyr::if_else(
        .data$sd > 0,
        (.data$tonnage - .data$expected) / .data$sd,
        NA_real_
      )
    ) |>
    dplyr::filter(!is.na(.data$z_score),
                  abs(.data$z_score) > threshold) |>
    dplyr::arrange(dplyr::desc(abs(.data$z_score))) |>
    dplyr::transmute(obs_date    = .data$obs_date,
                     port_id     = .data$port_id,
                     commodity   = .data$commodity,
                     tonnage     = .data$tonnage,
                     expected    = .data$expected,
                     sd          = .data$sd,
                     z_score     = .data$z_score)

  tryCatch({
    con <- warehouse_connect(cfg)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(con, "DELETE FROM mart.latest_anomalies")
    if (nrow(out) > 0) {
      out_db <- dplyr::mutate(out, detected_at = Sys.time())
      DBI::dbWriteTable(
        con, DBI::Id(schema = "mart", table = "latest_anomalies"),
        out_db, append = TRUE
      )
    }
  }, error = function(e) {
    logger::log_warn("anomaly warehouse write failed: {conditionMessage(e)}",
                     namespace = "resourcetracker")
  })

  out
}
