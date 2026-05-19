#' Per-commodity walk-forward backtest, all candidate specs
#'
#' Expanding-window refit. For each validation quarter `Q` from
#' `cfg$sample$valid_start` to the last quarter with a DISR actual:
#'
#'  1. Cut features to `quarter_end <= (Q - one quarter)`.
#'  2. Refit every candidate spec from `cfg$bridge$candidates` (default:
#'     `c("aggregate", "midas", "bojo")`) via [fit_bridge_bench()].
#'  3. Predict quarter `Q` per spec via [predict_bridge()] using `Q`'s
#'     observed feature row.
#'  4. Record actual (DISR Mt), per-spec point estimate, and the
#'     seasonal-random-walk benchmark (`V_{Q-4}`).
#'
#' Output is long-format: one row per (commodity × spec × validation
#' quarter). Combination forecasts and the production-choice decision
#' are computed downstream in `R/combination.R` from this tibble.
#'
#' @param features Quarterly feature tibble from [build_features()].
#' @param cfg Config list.
#' @return Tibble: `commodity`, `spec`, `quarter_end`, `actual`,
#'   `point_estimate`, `naive_srw`, `err`, `err_naive`.
#' @export
backtest_rmse <- function(features, cfg) {
  commodities <- cfg$commodities %||% unique(features$commodity)
  candidates  <- cfg$bridge$candidates %||% c("aggregate", "midas", "bojo")
  valid_start <- as.Date(cfg$sample$valid_start %||% "2024-01-01")

  valid_quarters <- features |>
    dplyr::filter(.data$quarter_end >= valid_start,
                  !is.na(.data$volume_Mt)) |>
    dplyr::distinct(.data$quarter_end) |>
    dplyr::arrange(.data$quarter_end) |>
    dplyr::pull(.data$quarter_end)

  empty <- tibble::tibble(
    commodity      = character(),
    spec           = character(),
    quarter_end    = as.Date(character()),
    actual         = double(),
    point_estimate = double(),
    naive_srw      = double(),
    err            = double(),
    err_naive      = double()
  )
  if (length(valid_quarters) == 0L) {
    log_warn("backtest_rmse: no validation quarters available")
    return(empty)
  }

  out <- purrr::map_dfr(valid_quarters, function(q) {
    backtest_one_quarter(q, features, commodities, candidates, cfg)
  })

  # Per-(commodity, spec) RMSE logged for visibility.
  per <- out |>
    dplyr::group_by(.data$commodity, .data$spec) |>
    dplyr::summarise(
      rmse_model = sqrt(mean(.data$err^2,       na.rm = TRUE)),
      rmse_naive = sqrt(mean(.data$err_naive^2, na.rm = TRUE)),
      .groups    = "drop"
    )
  for (i in seq_len(nrow(per))) {
    log_info(
      "backtest_rmse[%s/%s]: RMSE_model=%.2f RMSE_naive=%.2f ratio=%.2f",
      per$commodity[i], per$spec[i], per$rmse_model[i],
      per$rmse_naive[i], per$rmse_model[i] / per$rmse_naive[i]
    )
  }
  out
}

#' Backtest a single quarter across all commodities × all candidate specs.
#' @keywords internal
backtest_one_quarter <- function(q, features, commodities, candidates, cfg) {
  train_end <- q - 1L
  train_cfg <- cfg
  train_cfg$sample$train_end <- as.character(train_end)
  train_cfg$bridge$candidates <- candidates

  train_features <- dplyr::filter(features, .data$quarter_end <= train_end)
  fits <- fit_bridge_bench(train_features, train_cfg)

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
    actual_q_minus4 <- if (length(actual_q_minus4) == 0L) NA_real_
                       else actual_q_minus4[1]

    pred_row <- dplyr::filter(features,
                              .data$commodity == com,
                              .data$quarter_end == q)

    purrr::map_dfr(candidates, function(spec) {
      key <- paste0(com, "__", spec)
      empty_row <- tibble::tibble(
        commodity = com, spec = spec, quarter_end = q,
        actual = actual, point_estimate = NA_real_,
        naive_srw = actual_q_minus4,
        err = NA_real_,
        err_naive = actual_q_minus4 - actual
      )
      if (is.null(fits[[key]]) || nrow(pred_row) == 0L) {
        return(empty_row)
      }
      info <- spec_info(spec)
      required <- c(info$rhs, info$predict_extra)
      if (any(is.na(pred_row[1, required]))) {
        return(empty_row)
      }
      point_log <- predict_bridge(fits[key], pred_row)$yhat_log[1]
      point <- exp(point_log)
      tibble::tibble(
        commodity      = com,
        spec           = spec,
        quarter_end    = q,
        actual         = actual,
        point_estimate = point,
        naive_srw      = actual_q_minus4,
        err            = point - actual,
        err_naive      = actual_q_minus4 - actual
      )
    })
  })
}
