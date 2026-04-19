#' Produce the running current-quarter nowcast
#'
#' Combines: (1) observed PortWatch tonnage through `as_of`,
#' (2) [extrapolate_quarter_tonnage()] for partial/future months,
#' (3) recursive bridge prediction per commodity, (4) quarterly
#' aggregation, (5) chain-volume conversion via
#' [apply_chain_volume()], (6) residual bootstrap for 80/95 bands with
#' variance shrinkage proportional to `sqrt(1 - share_observed)`.
#'
#' The bootstrap is **recursive**: each draw resamples three monthly
#' residuals per commodity and propagates the perturbed log-y forward
#' through the AR(1) lag. Per-commodity draws are independent (the
#' "independent residual" spec; joint-across-commodities is a Phase 5
#' polish item).
#'
#' @param bridge_fits Output of [fit_bridge()].
#' @param features Long feature tibble from [build_features()].
#' @param deflators Output of [implicit_deflator()].
#' @param cfg Config list; `cfg$nowcast$bootstrap_reps` and
#'   `cfg$nowcast$seed` control the draw count and reproducibility.
#' @param portwatch Daily tonnage tibble (for within-quarter extrapolation).
#' @param ports_meta Port metadata.
#' @param fred FRED prices (for forward-looking price rows).
#' @param as_of Reference date; defaults to `Sys.Date()`.
#' @return One-row tibble: `quarter_end`, `point_estimate`, `lower_80`,
#'   `upper_80`, `lower_95`, `upper_95`, `share_observed`,
#'   `run_timestamp`.
#' @export
run_nowcast <- function(bridge_fits, features, deflators, cfg,
                        portwatch  = NULL,
                        ports_meta = NULL,
                        fred       = NULL,
                        as_of      = Sys.Date()) {

  q_end <- quarter_end(as_of)
  share <- quarter_share_observed(as_of)

  active_fits <- bridge_fits[!vapply(bridge_fits, is.null, logical(1))]
  if (length(active_fits) == 0) {
    return(empty_nowcast_row(q_end, share))
  }

  pred_frame <- build_nowcast_pred_frame(
    features = features, portwatch = portwatch, ports_meta = ports_meta,
    fred = fred, cfg = cfg, as_of = as_of, fits = active_fits
  )

  if (nrow(pred_frame) == 0) {
    return(empty_nowcast_row(q_end, share))
  }

  # Point estimate (deterministic recursion)
  preds_monthly <- predict_bridge(active_fits, pred_frame)
  pred_curr_q <- sum(preds_monthly$yhat_aud_m, na.rm = TRUE)
  pred_real_q <- apply_chain_volume(
    tibble::tibble(quarter_end = q_end,
                   value_current_aud_m = pred_curr_q),
    deflators, lookback = 4L
  )$value_chainvol_aud_m

  # Bootstrap
  B <- cfg$nowcast$bootstrap_reps %||% 1000
  seed <- cfg$nowcast$seed %||% 20260419
  boot_reals <- bootstrap_nowcast(active_fits, pred_frame, deflators,
                                  share_observed = share,
                                  B = B, seed = seed)

  tibble::tibble(
    quarter_end    = q_end,
    point_estimate = pred_real_q,
    lower_80       = stats::quantile(boot_reals, 0.10, na.rm = TRUE),
    upper_80       = stats::quantile(boot_reals, 0.90, na.rm = TRUE),
    lower_95       = stats::quantile(boot_reals, 0.025, na.rm = TRUE),
    upper_95       = stats::quantile(boot_reals, 0.975, na.rm = TRUE),
    share_observed = share,
    run_timestamp  = Sys.time()
  )
}

#' Assemble a prediction frame for the current quarter
#'
#' For each commodity with a fit, we need three monthly rows in `Q`:
#' `log_tonnage_sa` from the extrapolated tonnage, `log_price` from the
#' latest FRED observation (carried forward), and `log_y_lag1` from the
#' most recent observed `log_y`. Subsequent months' lags are filled by
#' `predict_bridge()` recursively.
#' @keywords internal
build_nowcast_pred_frame <- function(features, portwatch, ports_meta,
                                     fred, cfg, as_of, fits) {
  q_start <- lubridate::floor_date(as_of, "quarter")
  q_end   <- quarter_end(as_of)
  months_in_q <- seq(q_start, q_end, by = "month") |>
    lubridate::ceiling_date("month") - 1

  if (is.null(portwatch) || is.null(ports_meta)) {
    # Fallback: use features as-is (for tests and offline).
    feat_q <- dplyr::filter(features, .data$month_end %in% months_in_q,
                            .data$commodity %in% names(fits))
    return(feat_q)
  }

  tonnage_q <- extrapolate_quarter_tonnage(portwatch, ports_meta, cfg, as_of)

  # Latest observed log_y per commodity (the seed for log_y_lag1)
  latest_y <- features |>
    dplyr::filter(.data$month_end < q_start) |>
    dplyr::group_by(.data$commodity) |>
    dplyr::arrange(.data$month_end) |>
    dplyr::slice_tail(n = 1) |>
    dplyr::ungroup() |>
    dplyr::transmute(.data$commodity, seed_log_y = .data$log_y)

  # Latest price per commodity, carried forward to all three months
  latest_price <- features |>
    dplyr::filter(.data$month_end < q_start) |>
    dplyr::group_by(.data$commodity) |>
    dplyr::arrange(.data$month_end) |>
    dplyr::slice_tail(n = 1) |>
    dplyr::ungroup() |>
    dplyr::transmute(.data$commodity, latest_log_price = .data$log_price)

  tonnage_q |>
    dplyr::filter(.data$commodity %in% names(fits)) |>
    dplyr::left_join(latest_y,     by = "commodity") |>
    dplyr::left_join(latest_price, by = "commodity") |>
    dplyr::mutate(
      tonnage        = .data$tonnage_est,
      tonnage_sa     = .data$tonnage_est,   # already "deseasonalised" by being a full-month estimate
      log_tonnage_sa = log(pmax(.data$tonnage_est, 1e-6)),
      log_price      = .data$latest_log_price,
      log_y_lag1     = .data$seed_log_y,    # overwritten recursively from month 2
      y_aud_m        = NA_real_,
      price          = exp(.data$log_price),
      log_y          = NA_real_
    ) |>
    dplyr::select(.data$commodity, .data$month_end, .data$y_aud_m,
                  .data$tonnage, .data$tonnage_sa, .data$price,
                  .data$log_y, .data$log_tonnage_sa, .data$log_price,
                  .data$log_y_lag1)
}

#' Bootstrap the real-terms quarterly total
#'
#' Per-commodity independent residual draws with variance scaled by
#' `sqrt(1 - share_observed)`. Each draw runs the full recursive
#' prediction -> sum across commodities -> chain-volume conversion.
#' @keywords internal
bootstrap_nowcast <- function(fits, pred_frame, deflators,
                              share_observed, B, seed) {
  if (B <= 0 || share_observed >= 1) {
    # Quarter is done; only deflator error remains -- return a tight dist.
    return(rep(NA_real_, 0))
  }
  set.seed(seed)
  scale <- sqrt(max(1 - share_observed, 0))

  resid_by_com <- purrr::map(fits, function(f) as.numeric(f$residuals))

  replicate(B, {
    # Recursive predict with injected residuals
    per_com <- purrr::imap_dfr(fits, function(entry, com) {
      dat <- pred_frame |>
        dplyr::filter(.data$commodity == com) |>
        dplyr::arrange(.data$month_end)
      if (nrow(dat) == 0) return(tibble::tibble(yhat_aud_m = double()))

      eps <- sample(resid_by_com[[com]], size = nrow(dat), replace = TRUE) * scale
      yhat_log <- numeric(nrow(dat))
      prev_lag <- dat$log_y_lag1[1]
      co <- stats::coef(entry$fit)
      for (i in seq_len(nrow(dat))) {
        yhat_log[i] <- co["(Intercept)"] +
          co["log_tonnage_sa"] * dat$log_tonnage_sa[i] +
          co["log_price"]      * dat$log_price[i] +
          co["log_y_lag1"]     * prev_lag +
          eps[i]
        prev_lag <- yhat_log[i]
      }
      tibble::tibble(yhat_aud_m = exp(yhat_log))
    })

    total_curr <- sum(per_com$yhat_aud_m, na.rm = TRUE)
    q_end <- max(pred_frame$month_end)
    cv <- apply_chain_volume(
      tibble::tibble(quarter_end = q_end, value_current_aud_m = total_curr),
      deflators, lookback = 4L
    )
    cv$value_chainvol_aud_m[1]
  })
}

#' @keywords internal
empty_nowcast_row <- function(q_end, share) {
  tibble::tibble(
    quarter_end    = q_end,
    point_estimate = NA_real_,
    lower_80       = NA_real_,
    upper_80       = NA_real_,
    lower_95       = NA_real_,
    upper_95       = NA_real_,
    share_observed = share,
    run_timestamp  = Sys.time()
  )
}
