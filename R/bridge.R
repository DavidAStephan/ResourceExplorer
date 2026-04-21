#' Fit per-commodity bridge regressions (per-commodity spec)
#'
#' **Two specifications, both with a year-ago LHS lag as the seasonal
#' anchor.** Choice per commodity via `cfg$bridge$spec` (default:
#' `"aggregate"` if unspecified).
#'
#' - **aggregate** (parsimonious, 3 params + intercept):
#'   \deqn{\log V_{c,Q} = \beta_0 + \beta_T \, \Delta_{Q,Q-4}\log T_{c,Q} + \beta_4 \log V_{c,Q-4} + \varepsilon_{c,Q}}
#'
#' - **midas** (flexible, 5 params + intercept):
#'   \deqn{\log V_{c,Q} = \beta_0 + \sum_{m=1}^{3} \beta_m \, \Delta_{Q,Q-4}\log T_{c,Q,m} + \beta_4 \log V_{c,Q-4} + \varepsilon_{c,Q}}
#'
#' Why per-commodity: MIDAS wins when within-quarter monthly betas
#' legitimately differ (iron_ore: β_m1 dominates — early-quarter
#' shipping is a leading indicator). Aggregate wins when the monthly
#' betas would be roughly equal (coal: all three near-equal, so the
#' extra params just inflate variance). 2026-04-21 backtest showed
#' iron_ore improves 5% under MIDAS and coal degrades 16%; split spec
#' is best-of-both.
#'
#' `V` is DISR REQ Table 16 physical quarterly tonnage (Mt); YoY
#' differencing on the RHS mechanically strips seasonality so no
#' X-13 / STL is applied. Newey-West HAC standard errors with
#' `lag = cfg$bridge$hac_lag`.
#'
#' **Why no log price.** The target is already a *volume* measure
#' (chain-volume, reference year 2022-23). Price effects are stripped
#' on the LHS by construction; adding `log P` on the RHS would fit a
#' coefficient the target has nothing to tie it to. Volume ~ tonnage is
#' the relationship the bridge identifies.
#'
#' **Guardrails.**
#' - Commodities with fewer than `cfg$bridge$min_n` training quarters
#'   are skipped.
#' - Any regressor (or LHS) with near-zero variance skips with a warning.
#' - `nw_vcov()` failures (rare — usually singular design) skip.
#'
#' @param features Quarterly feature tibble from [build_features()].
#' @param cfg Config list. Uses `cfg$sample$train_end`, `cfg$commodities`,
#'   `cfg$bridge$hac_lag`, `cfg$bridge$min_n`.
#' @return Named list keyed by commodity. Each element is a list with:
#'   - `fit`: the `lm` object
#'   - `vcov_hac`: Newey-West variance-covariance matrix
#'   - `residuals`: named numeric vector
#'   - `diagnostics`: one-row tibble (n_obs, r_squared, rmse_train,
#'     dw_stat, beta_tonnage, beta_tonnage_se)
#' @export
fit_bridge <- function(features, cfg) {
  train_end   <- as.Date(cfg$sample$train_end %||% "2023-12-31")
  commodities <- cfg$commodities %||% unique(features$commodity)
  hac_lag     <- as.integer(cfg$bridge$hac_lag %||% 1L)
  min_n       <- as.integer(cfg$bridge$min_n   %||% 12L)
  spec_map    <- cfg$bridge$spec %||% list()

  fits <- stats::setNames(vector("list", length(commodities)), commodities)

  for (com in commodities) {
    spec <- tolower(spec_map[[com]] %||% "aggregate")
    if (!spec %in% c("aggregate", "midas")) {
      log_warn("fit_bridge[%s]: unknown spec %q -- falling back to aggregate",
               com, spec)
      spec <- "aggregate"
    }

    required_cols <- switch(
      spec,
      aggregate = c("log_volume", "log_volume_lag4", "yoy_log_tonnage"),
      midas     = c("log_volume", "log_volume_lag4",
                    "yoy_log_tonnage_m1", "yoy_log_tonnage_m2",
                    "yoy_log_tonnage_m3")
    )

    dat <- features |>
      dplyr::filter(.data$commodity == com,
                    .data$quarter_end <= train_end) |>
      dplyr::arrange(.data$quarter_end)
    dat <- dat[stats::complete.cases(dat[, required_cols]), , drop = FALSE]

    if (nrow(dat) < min_n) {
      log_warn("fit_bridge[%s]: %d obs < min_n=%d -- skipping",
               com, nrow(dat), min_n)
      fits[[com]] <- NULL
      next
    }

    vs <- vapply(required_cols,
                 function(v) stats::sd(dat[[v]], na.rm = TRUE),
                 numeric(1))
    if (any(vs < 1e-8, na.rm = TRUE) || any(is.na(vs))) {
      log_warn("fit_bridge[%s]: degenerate regressor (sd<1e-8) -- skipping",
               com)
      fits[[com]] <- NULL
      next
    }

    formula_fit <- switch(
      spec,
      aggregate = log_volume ~ yoy_log_tonnage + log_volume_lag4,
      midas     = log_volume ~ yoy_log_tonnage_m1 + yoy_log_tonnage_m2 +
                               yoy_log_tonnage_m3 + log_volume_lag4
    )
    fit <- stats::lm(formula_fit, data = dat)
    vcov_hac <- tryCatch(
      nw_vcov(fit, lag = hac_lag, prewhite = FALSE),
      error = function(e) {
        log_warn("fit_bridge[%s]: nw_vcov failed (%s) -- skipping",
                 com, conditionMessage(e))
        NULL
      }
    )
    if (is.null(vcov_hac)) { fits[[com]] <- NULL; next }

    res  <- stats::residuals(fit)
    yhat <- stats::fitted(fit)

    co <- stats::coef(fit)
    if (spec == "midas") {
      idx <- c("yoy_log_tonnage_m1", "yoy_log_tonnage_m2",
               "yoy_log_tonnage_m3")
      beta_T    <- sum(co[idx])
      beta_T_se <- sqrt(max(sum(vcov_hac[idx, idx]), 0))
      beta_m1   <- unname(co["yoy_log_tonnage_m1"])
      beta_m2   <- unname(co["yoy_log_tonnage_m2"])
      beta_m3   <- unname(co["yoy_log_tonnage_m3"])
    } else {
      beta_T    <- unname(co["yoy_log_tonnage"])
      beta_T_se <- sqrt(max(vcov_hac["yoy_log_tonnage",
                                      "yoy_log_tonnage"], 0))
      beta_m1 <- beta_m2 <- beta_m3 <- NA_real_
    }

    diag <- tibble::tibble(
      commodity       = com,
      spec            = spec,
      n_obs           = nrow(dat),
      r_squared       = summary(fit)$r.squared,
      rmse_train      = sqrt(mean(res^2)),
      dw_stat         = durbin_watson(res),
      beta_tonnage    = unname(beta_T),
      beta_tonnage_se = beta_T_se,
      beta_lag4       = unname(co["log_volume_lag4"]),
      beta_m1         = beta_m1,
      beta_m2         = beta_m2,
      beta_m3         = beta_m3
    )

    if (spec == "midas") {
      log_info(
        "fit_bridge[%s/midas]: n=%d R^2=%.3f RMSE=%.3f betaT=%.3f lag4=%.3f (m1=%.2f m2=%.2f m3=%.2f)",
        com, nrow(dat), diag$r_squared, diag$rmse_train,
        diag$beta_tonnage, diag$beta_lag4,
        diag$beta_m1, diag$beta_m2, diag$beta_m3
      )
    } else {
      log_info(
        "fit_bridge[%s/aggregate]: n=%d R^2=%.3f RMSE=%.3f betaT=%.3f lag4=%.3f",
        com, nrow(dat), diag$r_squared, diag$rmse_train,
        diag$beta_tonnage, diag$beta_lag4
      )
    }

    fits[[com]] <- list(
      fit         = fit,
      vcov_hac    = vcov_hac,
      residuals   = res,
      diagnostics = diag
    )
  }

  fits
}

#' Predict from fitted bridge models
#'
#' With a year-ago lag (`log_volume_lag4`), multi-step forecasts do NOT
#' need recursion: quarter Q's lag is Q-4's OBSERVED volume, which is
#' always known once it's landed. `newdata` must carry
#' `yoy_log_tonnage_sa` and `log_volume_lag4` columns.
#'
#' @param fits Output of [fit_bridge()].
#' @param newdata Long feature tibble for the horizon to predict.
#' @return Tibble: `quarter_end`, `commodity`, `yhat_log`, `yhat_volume_Mt`.
#' @export
predict_bridge <- function(fits, newdata) {
  out <- list()
  for (com in names(fits)) {
    entry <- fits[[com]]
    if (is.null(entry)) next
    dat <- newdata |>
      dplyr::filter(.data$commodity == com) |>
      dplyr::arrange(.data$quarter_end)
    if (nrow(dat) == 0) next

    yhat_log <- as.numeric(stats::predict(entry$fit, newdata = dat))

    out[[com]] <- tibble::tibble(
      quarter_end    = dat$quarter_end,
      commodity      = com,
      yhat_log       = yhat_log,
      yhat_volume_Mt = exp(yhat_log)
    )
  }
  dplyr::bind_rows(out)
}

#' Durbin-Watson stat for a residual vector (no regression required).
#' Values near 2 suggest no first-order autocorrelation; < 1 or > 3 is a red flag.
#' @keywords internal
durbin_watson <- function(res) {
  d <- diff(res)
  sum(d * d) / sum(res * res)
}
