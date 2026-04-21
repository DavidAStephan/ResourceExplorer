#' Per-commodity walk-forward backtest vs ABS 5302 T25 chain-volume actuals
#'
#' Expanding-window refit. For each validation quarter `Q` from
#' `cfg$sample$valid_start` to the last quarter with an ABS T25 actual,
#' for each commodity `c`:
#'
#'  1. Cut features to `quarter_end <= (Q - one quarter)`.
#'  2. Refit `fit_bridge` on that window.
#'  3. Predict quarter `Q` via `predict_bridge` using the `Q`'s feature
#'     row (observed quarterly tonnage).
#'  4. Record actual (ABS T25), point estimate, and naive seasonal
#'     random walk (`V_{Q-4}`) for the same commodity.
#'
#' Per-commodity errors are reported; no aggregation across commodities.
#' Ratio vs naive per commodity — the brief's 30%-better target becomes
#' a commodity-level check.
#'
#' @param features Quarterly feature tibble from [build_features()].
#' @param cfg Config list.
#' @return Tibble: `commodity`, `quarter_end`, `actual`,
#'   `point_estimate`, `naive_srw`, `err`, `err_naive`.
#' @export
backtest_rmse <- function(features, cfg) {
  commodities <- cfg$commodities %||% unique(features$commodity)
  valid_start <- as.Date(cfg$sample$valid_start %||% "2024-01-01")

  valid_quarters <- features |>
    dplyr::filter(.data$quarter_end >= valid_start,
                  !is.na(.data$volume_Mt)) |>
    dplyr::distinct(.data$quarter_end) |>
    dplyr::arrange(.data$quarter_end) |>
    dplyr::pull(.data$quarter_end)

  if (length(valid_quarters) == 0L) {
    log_warn("backtest_rmse: no validation quarters available")
    return(tibble::tibble(
      commodity      = character(),
      quarter_end    = as.Date(character()),
      actual         = double(),
      point_estimate = double(),
      naive_srw      = double(),
      err            = double(),
      err_naive      = double()
    ))
  }

  out <- purrr::map_dfr(valid_quarters, function(q) {
    backtest_one_quarter(q, features, commodities, cfg)
  })

  per_com <- out |>
    dplyr::group_by(.data$commodity) |>
    dplyr::summarise(
      rmse_model = sqrt(mean(.data$err^2,       na.rm = TRUE)),
      rmse_naive = sqrt(mean(.data$err_naive^2, na.rm = TRUE)),
      .groups    = "drop"
    )
  for (i in seq_len(nrow(per_com))) {
    log_info(
      "backtest_rmse[%s]: RMSE_model=%.1f RMSE_naive=%.1f ratio=%.2f",
      per_com$commodity[i], per_com$rmse_model[i], per_com$rmse_naive[i],
      per_com$rmse_model[i] / per_com$rmse_naive[i]
    )
  }

  out
}

#' Backtest a single quarter across all commodities -- exposed for testing
#' @keywords internal
backtest_one_quarter <- function(q, features, commodities, cfg) {
  train_end <- q - 1L
  train_cfg <- cfg
  train_cfg$sample$train_end <- as.character(train_end)

  train_features <- dplyr::filter(features, .data$quarter_end <= train_end)
  fits <- fit_bridge(train_features, train_cfg)
  fits <- fits[!vapply(fits, is.null, logical(1))]

  purrr::map_dfr(commodities, function(com) {
    actual <- features |>
      dplyr::filter(.data$commodity == com, .data$quarter_end == q) |>
      dplyr::pull(.data$volume_Mt)
    actual <- if (length(actual) == 0L) NA_real_ else actual[1]

    q_minus4 <- q - lubridate::years(1L)
    q_minus4 <- lubridate::ceiling_date(q_minus4, "quarter") - 1
    actual_q_minus4 <- features |>
      dplyr::filter(.data$commodity == com, .data$quarter_end == q_minus4) |>
      dplyr::pull(.data$volume_Mt)
    actual_q_minus4 <- if (length(actual_q_minus4) == 0L) NA_real_ else actual_q_minus4[1]

    if (is.null(fits[[com]])) {
      return(tibble::tibble(
        commodity      = com,
        quarter_end    = q,
        actual         = actual,
        point_estimate = NA_real_,
        naive_srw      = actual_q_minus4,
        err            = NA_real_,
        err_naive      = actual_q_minus4 - actual
      ))
    }

    pred_row <- dplyr::filter(features,
                              .data$commodity == com,
                              .data$quarter_end == q)
    if (nrow(pred_row) == 0L) {
      return(tibble::tibble(
        commodity = com, quarter_end = q, actual = actual,
        point_estimate = NA_real_, naive_srw = actual_q_minus4,
        err = NA_real_, err_naive = actual_q_minus4 - actual
      ))
    }

    # Feature row carries both aggregate and per-month YoY-ΔT. Require
    # log_volume_lag4 plus the RHS family for the chosen spec.
    spec <- tolower(cfg$bridge$spec[[com]] %||% "aggregate")
    rhs_cols <- if (spec == "midas") {
      c("yoy_log_tonnage_m1", "yoy_log_tonnage_m2", "yoy_log_tonnage_m3")
    } else {
      "yoy_log_tonnage"
    }
    if (is.na(pred_row$log_volume_lag4[1]) ||
        any(is.na(pred_row[1, rhs_cols]))) {
      return(tibble::tibble(
        commodity = com, quarter_end = q, actual = actual,
        point_estimate = NA_real_, naive_srw = actual_q_minus4,
        err = NA_real_, err_naive = actual_q_minus4 - actual
      ))
    }

    point_log <- predict_bridge(fits[com], pred_row)$yhat_log[1]
    point <- exp(point_log)

    tibble::tibble(
      commodity      = com,
      quarter_end    = q,
      actual         = actual,
      point_estimate = point,
      naive_srw      = actual_q_minus4,
      err            = point - actual,
      err_naive      = actual_q_minus4 - actual
    )
  })
}
