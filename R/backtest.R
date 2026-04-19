#' Walk-forward backtest of the bridge ensemble vs ABS 5302.0 actuals
#'
#' **Scheme.** Expanding-window refit. For each quarter `Q` from
#' `cfg$sample$valid_start` to the last quarter for which 5302.0 has
#' landed, we:
#'
#' 1. Cut the feature panel to `month_end <= (start_of_Q - 1 month)` --
#'    i.e. the last observation is the month immediately preceding Q.
#' 2. Refit all commodity bridges via [fit_bridge()] on that window.
#' 3. Build the Q prediction feature frame (the three months of Q from
#'    `features`). Feed it to [predict_bridge()], which recursively
#'    uses its own predictions as lags from month 2 onward.
#' 4. Sum monthly predictions across commodities to a quarterly
#'    current-price total; chain-volume convert via
#'    [apply_chain_volume()].
#' 5. Record actual (from 5302.0), point estimate, and the
#'    seasonal-random-walk benchmark `actual_{Q-4}`.
#'
#' **Benchmark.** Seasonal random walk at quarterly frequency:
#' `y_hat_Q = actual_{Q-4}`. This is the "no-skill" anchor the brief
#' mandates. The success target is RMSE >= 30% below the benchmark.
#'
#' **Window choice.** Expanding (not rolling). The brief names a
#' 2019-2023 train sample and the economic regime is better captured
#' by more data than by a fixed-width window -- particularly important
#' for LNG given the 2022 shock. Switch to rolling in Phase 4 if
#' structural breaks become a concern.
#'
#' @param features Long feature tibble from [build_features()].
#' @param abs_5302 Quarterly ABS tibble from [fetch_abs_5302()].
#' @param cfg Config list.
#' @return Tibble: `quarter_end`, `actual`, `point_estimate`,
#'   `naive_srw`, `err`, `err_naive`.
#' @export
backtest_rmse <- function(features, abs_5302, cfg) {
  deflators <- implicit_deflator(abs_5302)

  actuals <- abs_5302 |>
    dplyr::filter(!is.na(.data$value_chainvol_aud_m),
                  .data$value_chainvol_aud_m > 0) |>
    dplyr::group_by(.data$quarter_end) |>
    dplyr::summarise(actual = sum(.data$value_chainvol_aud_m, na.rm = TRUE),
                     .groups = "drop")

  valid_start <- as.Date(cfg$sample$valid_start %||% "2024-01-01")
  valid_quarters <- actuals$quarter_end[actuals$quarter_end >= valid_start]

  if (length(valid_quarters) == 0) {
    logger::log_warn("backtest_rmse: no validation quarters available",
                     namespace = "resourcetracker")
    return(tibble::tibble(
      quarter_end    = as.Date(character()),
      actual         = double(),
      point_estimate = double(),
      naive_srw      = double(),
      err            = double(),
      err_naive      = double()
    ))
  }

  out <- purrr::map_dfr(valid_quarters, function(q) {
    backtest_one_quarter(q, features, actuals, deflators, cfg)
  })

  logger::log_info(
    "backtest_rmse: {nrow(out)} quarters; ",
    "RMSE={round(sqrt(mean(out$err^2, na.rm=TRUE)), 2)} ",
    "naive={round(sqrt(mean(out$err_naive^2, na.rm=TRUE)), 2)}",
    namespace = "resourcetracker"
  )
  out
}

#' Backtest a single quarter -- isolated for unit testing
#' @keywords internal
backtest_one_quarter <- function(q, features, actuals, deflators, cfg) {
  train_end_m <- lubridate::floor_date(q, "quarter") - 1

  train_features <- dplyr::filter(features, .data$month_end <= train_end_m)
  train_cfg <- cfg
  train_cfg$sample$train_end <- as.character(train_end_m)
  fits <- fit_bridge(train_features, train_cfg)
  fits <- fits[!vapply(fits, is.null, logical(1))]
  if (length(fits) == 0) {
    return(empty_backtest_row(q, actuals))
  }

  pred_months <- seq(lubridate::floor_date(q, "quarter"), q, by = "month") |>
    lubridate::ceiling_date("month") - 1
  pred_frame <- features |>
    dplyr::filter(.data$month_end %in% pred_months,
                  .data$commodity %in% names(fits))

  if (nrow(pred_frame) == 0) return(empty_backtest_row(q, actuals))

  preds_monthly <- predict_bridge(fits, pred_frame)

  pred_curr <- preds_monthly |>
    dplyr::group_by(quarter_end = q) |>
    dplyr::summarise(value_current_aud_m = sum(.data$yhat_aud_m, na.rm = TRUE),
                     .groups = "drop")

  pred_cv <- apply_chain_volume(pred_curr, deflators, lookback = 4L)

  actual_q <- dplyr::filter(actuals, .data$quarter_end == q)$actual
  if (length(actual_q) == 0) actual_q <- NA_real_
  actual_q_minus4 <- dplyr::filter(actuals,
                                   .data$quarter_end == q - months(12))$actual
  if (length(actual_q_minus4) == 0) actual_q_minus4 <- NA_real_

  point <- pred_cv$value_chainvol_aud_m[1]
  tibble::tibble(
    quarter_end    = q,
    actual         = actual_q,
    point_estimate = point,
    naive_srw      = actual_q_minus4,
    err            = point - actual_q,
    err_naive      = actual_q_minus4 - actual_q
  )
}

#' @keywords internal
empty_backtest_row <- function(q, actuals) {
  actual_q <- dplyr::filter(actuals, .data$quarter_end == q)$actual
  if (length(actual_q) == 0) actual_q <- NA_real_
  actual_q_minus4 <- dplyr::filter(actuals,
                                   .data$quarter_end == q - months(12))$actual
  if (length(actual_q_minus4) == 0) actual_q_minus4 <- NA_real_
  tibble::tibble(
    quarter_end    = q,
    actual         = actual_q,
    point_estimate = NA_real_,
    naive_srw      = actual_q_minus4,
    err            = NA_real_,
    err_naive      = actual_q_minus4 - actual_q
  )
}
