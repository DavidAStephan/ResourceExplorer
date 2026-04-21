#' Fit per-commodity bridge regressions
#'
#' **Specification.** For each commodity `c` we fit, on monthly data,
#'
#' \deqn{\log y_{c,m} = \beta_0 + \beta_1 \log T^{SA}_{c,m} + \beta_2 \log P_{c,m} + \beta_3 \log y_{c,m-1} + \varepsilon_{c,m}}
#'
#' **Why log-levels rather than first-differences.** Australian
#' commodity export values have persistent level shifts (the 2020-2022
#' iron-ore spike, the 2022 LNG shock) that carry economically
#' meaningful information. First-differencing throws those away. The
#' trade-off is serial correlation in the residuals, which we handle
#' two ways: (a) the AR(1) lag on `log_y` absorbs most of it at the
#' conditional-mean level, and (b) Newey-West (HAC) standard errors
#' with `lag = 3` keep inference honest on the remainder.
#'
#' **Why AR(1) and not richer dynamics.** With a ~60-month training
#' window per commodity, we have a single-digit parameter budget per
#' bridge. One lag captures the bulk of the persistence and doubles as
#' the "bridge" mechanism at nowcast time -- it lets partial-month
#' observations of `log T` update `log y` through its own lagged value.
#' Phase 4 can add further lags if residual diagnostics warrant.
#'
#' **Why log on both sides.** Exports value = price x quantity, so
#' taking logs makes the RHS additive in `log P` and `log T`. `beta_1`
#' then reads as an elasticity of value with respect to tonnage --
#' expected to be close to 1 for a commodity whose tonnage and value
#' move together. Large deviations from 1 flag either mix-shifts in the
#' commodity basket (coal 321 vs 322), measurement differences
#' (PortWatch coverage gaps), or genuine unit-value swings.
#'
#' **Zero and missing values** are filtered out upstream in
#' [build_features()] -- we don't have to handle them here.
#'
#' @param features Long tibble from [build_features()].
#' @param cfg Config list. Uses `cfg$sample$train_end` to restrict the
#'   estimation window (everything later is held out for Phase 4
#'   backtesting / nowcasting).
#' @return Named list keyed by commodity. Each element is a list with:
#'   - `fit`: the `lm` object
#'   - `vcov_hac`: Newey-West variance-covariance matrix
#'   - `residuals`: named numeric vector
#'   - `diagnostics`: one-row tibble (n_obs, r_squared, rmse_train,
#'     dw_stat, beta_tonnage, beta_tonnage_se)
#' @export
fit_bridge <- function(features, cfg) {
  train_end <- as.Date(cfg$sample$train_end %||% "2023-12-31")
  commodities <- cfg$commodities %||% unique(features$commodity)

  fits <- stats::setNames(vector("list", length(commodities)), commodities)

  for (com in commodities) {
    dat <- features |>
      dplyr::filter(.data$commodity == com, .data$month_end <= train_end) |>
      dplyr::filter(!is.na(.data$log_y_lag1)) |>
      dplyr::arrange(.data$month_end)

    if (nrow(dat) < 24) {
      log_warn("fit_bridge[%s]: %d obs < 24 -- skipping", com, nrow(dat))
      fits[[com]] <- NULL
      next
    }

    fit <- stats::lm(
      log_y ~ log_tonnage_sa + log_price + log_y_lag1,
      data = dat
    )
    vcov_hac <- nw_vcov(fit, lag = 3L, prewhite = FALSE)
    res <- stats::residuals(fit)
    yhat <- stats::fitted(fit)

    diag <- tibble::tibble(
      commodity       = com,
      n_obs           = nrow(dat),
      r_squared       = summary(fit)$r.squared,
      rmse_train      = sqrt(mean(res^2)),
      dw_stat         = durbin_watson(res),
      beta_tonnage    = unname(stats::coef(fit)["log_tonnage_sa"]),
      beta_tonnage_se = sqrt(vcov_hac["log_tonnage_sa", "log_tonnage_sa"])
    )

    log_info(
      "fit_bridge[%s]: n=%d R^2=%.3f RMSE_train=%.3f beta_T=%.3f",
      com, nrow(dat), diag$r_squared, diag$rmse_train, diag$beta_tonnage
    )

    fits[[com]] <- list(
      fit         = fit,
      vcov_hac    = vcov_hac,
      residuals   = res,
      diagnostics = diag
    )
  }

  fits
}

#' Predict from fitted bridge models, recursively for multi-step ahead.
#'
#' **Recursion matters.** Because `log_y_lag1` is on the RHS, a 3-month
#' ahead forecast needs the 1- and 2-month-ahead predictions fed back
#' in as lags. We iterate month-by-month, overwriting `log_y_lag1` in
#' each step with the previous step's prediction.
#'
#' @param fits Output of [fit_bridge()].
#' @param newdata Long feature tibble for the horizon to predict.
#'   Rows for each commodity must be sorted by `month_end` ascending
#'   and **must include a `log_y_lag1` value for the first month**
#'   (from the last observed actual).
#' @return Tibble: `month_end`, `commodity`, `yhat_log`, `yhat_aud_m`.
#' @export
predict_bridge <- function(fits, newdata) {
  out <- list()
  for (com in names(fits)) {
    entry <- fits[[com]]
    if (is.null(entry)) next
    dat <- newdata |>
      dplyr::filter(.data$commodity == com) |>
      dplyr::arrange(.data$month_end)
    if (nrow(dat) == 0) next

    yhat_log <- numeric(nrow(dat))
    prev_lag <- dat$log_y_lag1[1]
    for (i in seq_len(nrow(dat))) {
      row <- dat[i, , drop = FALSE]
      row$log_y_lag1 <- prev_lag
      yhat_log[i] <- as.numeric(stats::predict(entry$fit, newdata = row))
      prev_lag <- yhat_log[i]
    }

    out[[com]] <- tibble::tibble(
      month_end  = dat$month_end,
      commodity  = com,
      yhat_log   = yhat_log,
      yhat_aud_m = exp(yhat_log)
    )
  }
  dplyr::bind_rows(out)
}

#' Durbin-Watson stat for a residual vector (no regression required).
#'
#' Avoids dragging in `{lmtest}` just for this. Values near 2 suggest
#' no first-order autocorrelation; < 1 or > 3 is a red flag.
#' @keywords internal
durbin_watson <- function(res) {
  d <- diff(res)
  sum(d * d) / sum(res * res)
}
