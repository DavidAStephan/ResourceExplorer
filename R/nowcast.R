#' Per-commodity running quarterly volume nowcast
#'
#' For each named commodity: compute the current-quarter point estimate
#' (chain-volume A$m) and 80/95 bootstrap uncertainty bands. Returns one
#' row per commodity — no aggregation across commodities is performed.
#'
#' Steps:
#'  1. Extrapolate partial-quarter PortWatch tonnage to a full-quarter
#'     estimate (see [extrapolate_quarter_tonnage()]).
#'  2. Seasonally-adjust the quarterly tonnage using the STL fit's most
#'     recent seasonal factor (proxy — we don't refit STL each run).
#'  3. Predict `log volume` from the bridge regression.
#'  4. Residual bootstrap for 80/95 bands, variance scaled by
#'     `sqrt(1 - share_observed)`.
#'
#' @param bridge_fits Output of [fit_bridge()].
#' @param features Quarterly feature tibble from [build_features()].
#' @param cfg Config list; uses `cfg$nowcast$bootstrap_reps` and
#'   `cfg$nowcast$seed`.
#' @param portwatch Daily PortWatch tonnage tibble.
#' @param ports_meta Port metadata (passed through, currently unused by
#'   the quarterly pipeline -- the portwatch tibble is already
#'   commodity-labelled).
#' @param as_of Reference date; defaults to `Sys.Date()`.
#' @return Tibble with one row per commodity: `commodity`, `quarter_end`,
#'   `point_estimate_Mt`, `lower_80`, `upper_80`, `lower_95`,
#'   `upper_95`, `share_observed`, `run_timestamp`.
#' @export
run_nowcast <- function(bridge_fits, features, cfg,
                        portwatch  = NULL,
                        ports_meta = NULL,
                        as_of      = Sys.Date()) {

  q_end <- quarter_end(as_of)
  share <- quarter_share_observed(as_of)
  B     <- cfg$nowcast$bootstrap_reps %||% 1000
  seed  <- cfg$nowcast$seed %||% 20260419

  active_fits <- bridge_fits[!vapply(bridge_fits, is.null, logical(1))]
  if (length(active_fits) == 0L || is.null(portwatch)) {
    return(empty_nowcast_rows(cfg$commodities, q_end, share))
  }

  pred_frame <- build_nowcast_pred_frame(
    features  = features,
    portwatch = portwatch,
    cfg       = cfg,
    as_of     = as_of,
    fits      = active_fits
  )

  if (nrow(pred_frame) == 0L) {
    return(empty_nowcast_rows(cfg$commodities, q_end, share))
  }

  # Point estimate: deterministic one-quarter-ahead prediction per commodity.
  preds <- predict_bridge(active_fits, pred_frame)

  # Bootstrap bands per commodity.
  set.seed(seed)
  scale_boot <- sqrt(max(1 - share, 0))

  out <- purrr::imap_dfr(active_fits, function(entry, com) {
    com_frame <- dplyr::filter(pred_frame, .data$commodity == com)
    if (nrow(com_frame) == 0L) {
      return(one_empty_nowcast_row(com, q_end, share))
    }
    co <- stats::coef(entry$fit)
    res <- as.numeric(entry$residuals)

    # Use stats::predict() for the deterministic mean, then add a
    # bootstrapped residual. Cleaner than unrolling the formula.
    mean_log <- as.numeric(stats::predict(entry$fit, newdata = com_frame))[1]
    draws <- replicate(B, {
      eps <- sample(res, 1L, replace = TRUE) * scale_boot
      exp(mean_log + eps)
    })

    point <- dplyr::filter(preds, .data$commodity == com)$yhat_volume_Mt[1]

    tibble::tibble(
      commodity                    = com,
      quarter_end                  = q_end,
      point_estimate_Mt = point,
      lower_80                     = unname(stats::quantile(draws, 0.10, na.rm = TRUE)),
      upper_80                     = unname(stats::quantile(draws, 0.90, na.rm = TRUE)),
      lower_95                     = unname(stats::quantile(draws, 0.025, na.rm = TRUE)),
      upper_95                     = unname(stats::quantile(draws, 0.975, na.rm = TRUE)),
      share_observed               = share,
      run_timestamp                = Sys.time()
    )
  })

  # Fill in any fitted commodity we might have lost along the way.
  missing_coms <- setdiff(cfg$commodities, out$commodity)
  if (length(missing_coms)) {
    out <- dplyr::bind_rows(
      out,
      purrr::map_dfr(missing_coms, one_empty_nowcast_row, q_end, share)
    )
  }
  out |> dplyr::arrange(match(.data$commodity, cfg$commodities))
}

#' Build the one-row-per-commodity prediction frame for the current quarter
#'
#' Computes quarterly tonnage via [extrapolate_quarter_tonnage()] (which
#' sums observed days + partial-month scale-up + future-month seasonal
#' extrapolation), then carries forward the commodity's latest seasonal
#' factor from the feature history to get `log_tonnage_sa`. Seeds
#' `log_volume_lag1` from the commodity's most recent observed `log_volume`.
#'
#' @keywords internal
build_nowcast_pred_frame <- function(features, portwatch, cfg, as_of, fits) {
  q_end   <- quarter_end(as_of)
  q_start <- lubridate::floor_date(as_of, "quarter")

  # Monthly extrapolation: returns (commodity, month_end, tonnage_est,
  # share_observed, status). Map month -> month-in-quarter (1/2/3).
  tq_monthly <- extrapolate_quarter_tonnage(portwatch, ports_meta = NULL,
                                            cfg = cfg, as_of = as_of) |>
    dplyr::mutate(mwq = ((lubridate::month(.data$month_end) - 1L) %% 3L) + 1L)

  # Overall share observed, weighted by tonnage
  share_by_com <- tq_monthly |>
    dplyr::group_by(.data$commodity) |>
    dplyr::summarise(
      total_tonnage  = sum(.data$tonnage_est, na.rm = TRUE),
      share_observed = sum(.data$tonnage_est * .data$share_observed,
                           na.rm = TRUE) /
                       pmax(sum(.data$tonnage_est, na.rm = TRUE), 1e-9),
      .groups = "drop"
    )

  # Pivot monthly tonnage to wide (m1/m2/m3)
  wide_mwq <- tq_monthly |>
    dplyr::transmute(.data$commodity, .data$mwq,
                     tonnage_m = .data$tonnage_est) |>
    tidyr::pivot_wider(names_from = "mwq", values_from = "tonnage_m",
                       names_prefix = "tonnage_m", values_fill = 0) |>
    dplyr::filter(.data$commodity %in% names(fits))
  for (k in 1:3) {
    col <- paste0("tonnage_m", k)
    if (!col %in% names(wide_mwq)) wide_mwq[[col]] <- 0
  }

  # Year-ago volume + year-ago monthly + aggregate quarterly tonnages.
  q_minus4 <- q_end - lubridate::years(1L)
  q_minus4 <- lubridate::ceiling_date(q_minus4, "quarter") - 1
  lag4 <- features |>
    dplyr::filter(.data$quarter_end == q_minus4) |>
    dplyr::transmute(.data$commodity,
                     log_volume_lag4     = .data$log_volume,
                     log_tonnage_lag4    = .data$log_tonnage,
                     log_tonnage_m1_lag4 = .data$log_tonnage_m1,
                     log_tonnage_m2_lag4 = .data$log_tonnage_m2,
                     log_tonnage_m3_lag4 = .data$log_tonnage_m3)

  wide_mwq |>
    dplyr::left_join(lag4,         by = "commodity") |>
    dplyr::left_join(share_by_com, by = "commodity") |>
    dplyr::mutate(
      quarter_end        = q_end,
      tonnage            = .data$tonnage_m1 + .data$tonnage_m2 +
                           .data$tonnage_m3,
      log_tonnage        = log(pmax(.data$tonnage,    1e-6)),
      log_tonnage_m1     = log(pmax(.data$tonnage_m1, 1e-6)),
      log_tonnage_m2     = log(pmax(.data$tonnage_m2, 1e-6)),
      log_tonnage_m3     = log(pmax(.data$tonnage_m3, 1e-6)),
      yoy_log_tonnage    = .data$log_tonnage    - .data$log_tonnage_lag4,
      yoy_log_tonnage_m1 = .data$log_tonnage_m1 - .data$log_tonnage_m1_lag4,
      yoy_log_tonnage_m2 = .data$log_tonnage_m2 - .data$log_tonnage_m2_lag4,
      yoy_log_tonnage_m3 = .data$log_tonnage_m3 - .data$log_tonnage_m3_lag4
    ) |>
    dplyr::select(.data$commodity, .data$quarter_end, .data$tonnage,
                  .data$tonnage_m1, .data$tonnage_m2, .data$tonnage_m3,
                  .data$log_tonnage, .data$log_tonnage_m1,
                  .data$log_tonnage_m2, .data$log_tonnage_m3,
                  .data$yoy_log_tonnage,
                  .data$yoy_log_tonnage_m1, .data$yoy_log_tonnage_m2,
                  .data$yoy_log_tonnage_m3,
                  .data$log_volume_lag4)
}

#' @keywords internal
empty_nowcast_rows <- function(commodities, q_end, share) {
  purrr::map_dfr(commodities, one_empty_nowcast_row, q_end, share)
}

#' @keywords internal
one_empty_nowcast_row <- function(com, q_end, share) {
  tibble::tibble(
    commodity                     = com,
    quarter_end                   = q_end,
    point_estimate_Mt = NA_real_,
    lower_80                      = NA_real_,
    upper_80                      = NA_real_,
    lower_95                      = NA_real_,
    upper_95                      = NA_real_,
    share_observed                = share,
    run_timestamp                 = Sys.time()
  )
}
