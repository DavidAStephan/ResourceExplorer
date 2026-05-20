#' Forecast combination + production-model selection
#'
#' Given the long-format backtest output from [backtest_rmse()] (one row
#' per commodity × spec × validation quarter), compute combination
#' forecasts (equal-weighted, inverse-MSE-weighted) and report each
#' candidate's out-of-sample RMSE in a single tidy diagnostics tibble.
#'
#' The "production choice" per commodity is whichever of {best single
#' spec, equal-weighted combination, inverse-MSE-weighted combination}
#' has the lowest backtest RMSE. With our sample size (~10 validation
#' quarters), equal-weighted combinations often beat inverse-MSE
#' weights -- Stock & Watson (2004) call this the "forecast combination
#' puzzle" and Aiolfi & Timmermann (2006) document it directly. Both are
#' computed so the report can show the gap.

#' Augment the per-spec backtest with combination forecasts.
#'
#' For each (commodity, quarter), produce two extra rows:
#'   - `equal_avg`: arithmetic mean of available candidate point
#'     estimates for that (commodity, quarter)
#'   - `inv_mse`:   weighted mean, weights proportional to
#'     `1 / RMSE_oos^2` over the full backtest (per-commodity, per-spec)
#'
#' The resulting tibble has the same schema as the input plus those two
#' extra `spec` values, so downstream summarisers (e.g. CSV writers) can
#' treat them uniformly.
#'
#' @param backtest Long tibble from [backtest_rmse()].
#' @return Same shape tibble, with two extra spec rows per
#'   (commodity, quarter_end).
#' @export
augment_with_combinations <- function(backtest) {
  if (nrow(backtest) == 0L) return(backtest)

  # Per-spec RMSE (full backtest) -- weights for inv_mse.
  rmse_by_spec <- backtest |>
    dplyr::filter(!is.na(.data$err)) |>
    dplyr::group_by(.data$commodity, .data$spec) |>
    dplyr::summarise(rmse = sqrt(mean(.data$err^2, na.rm = TRUE)),
                     .groups = "drop")
  weights_inv_mse <- rmse_by_spec |>
    dplyr::group_by(.data$commodity) |>
    dplyr::mutate(w = (1 / .data$rmse^2) / sum(1 / .data$rmse^2)) |>
    dplyr::ungroup() |>
    dplyr::select(dplyr::all_of(c("commodity", "spec", "w")))

  rows_with_predictions <- backtest |>
    dplyr::filter(!is.na(.data$point_estimate))

  equal_avg <- rows_with_predictions |>
    dplyr::group_by(.data$commodity, .data$quarter_end) |>
    dplyr::summarise(
      actual         = dplyr::first(.data$actual),
      naive_srw      = dplyr::first(.data$naive_srw),
      point_estimate = mean(.data$point_estimate, na.rm = TRUE),
      .groups        = "drop"
    ) |>
    dplyr::mutate(
      spec      = "equal_avg",
      err       = .data$point_estimate - .data$actual,
      err_naive = .data$naive_srw      - .data$actual
    )

  inv_mse <- rows_with_predictions |>
    dplyr::left_join(weights_inv_mse, by = c("commodity", "spec")) |>
    # Re-normalise weights across the specs that have a prediction
    # *this* quarter (some spec might be missing for some quarter).
    dplyr::group_by(.data$commodity, .data$quarter_end) |>
    dplyr::mutate(w = .data$w / sum(.data$w, na.rm = TRUE)) |>
    dplyr::summarise(
      actual         = dplyr::first(.data$actual),
      naive_srw      = dplyr::first(.data$naive_srw),
      point_estimate = sum(.data$w * .data$point_estimate, na.rm = TRUE),
      .groups        = "drop"
    ) |>
    dplyr::mutate(
      spec      = "inv_mse",
      err       = .data$point_estimate - .data$actual,
      err_naive = .data$naive_srw      - .data$actual
    )

  cols <- names(backtest)
  dplyr::bind_rows(
    backtest,
    dplyr::select(equal_avg, dplyr::all_of(cols)),
    dplyr::select(inv_mse,   dplyr::all_of(cols))
  )
}

#' Build the per-(commodity, spec) OOS diagnostics tibble.
#'
#' Each spec gets one row with backtest RMSE, RMSE ratio vs the naive
#' seasonal-random-walk, and the OOS R-squared. OOS R^2 is computed in
#' Mt-level space:
#'   `1 - sum(err^2) / sum((actual - mean(actual))^2)`
#' which can go negative if the model underperforms a sample-mean
#' baseline (a stronger benchmark than naive SRW).
#'
#' @param backtest_augmented Long tibble from [augment_with_combinations()].
#' @return Tibble keyed by (commodity, spec) with `rmse_valid`,
#'   `rmse_naive`, `ratio_vs_naive`, `r_squared_oos`.
#' @export
oos_diagnostics <- function(backtest_augmented) {
  if (nrow(backtest_augmented) == 0L) {
    return(tibble::tibble(
      commodity      = character(),
      spec           = character(),
      rmse_valid     = double(),
      rmse_naive     = double(),
      ratio_vs_naive = double(),
      r_squared_oos  = double()
    ))
  }
  backtest_augmented |>
    dplyr::filter(!is.na(.data$err)) |>
    dplyr::group_by(.data$commodity, .data$spec) |>
    dplyr::summarise(
      rmse_valid     = sqrt(mean(.data$err^2,       na.rm = TRUE)),
      rmse_naive     = sqrt(mean(.data$err_naive^2, na.rm = TRUE)),
      sst            = sum((.data$actual - mean(.data$actual,
                                                  na.rm = TRUE))^2,
                            na.rm = TRUE),
      ssr            = sum(.data$err^2, na.rm = TRUE),
      .groups        = "drop"
    ) |>
    dplyr::mutate(
      ratio_vs_naive = .data$rmse_valid / .data$rmse_naive,
      r_squared_oos  = 1 - .data$ssr / pmax(.data$sst, 1e-12)
    ) |>
    dplyr::select(dplyr::all_of(c("commodity", "spec", "rmse_valid",
                                  "rmse_naive", "ratio_vs_naive",
                                  "r_squared_oos")))
}

#' Pick the per-commodity production model from the OOS diagnostics.
#'
#' Picks the row with the lowest `rmse_valid` (ties broken in the
#' candidate order, then `equal_avg`, then `inv_mse`).
#'
#' @param oos Tibble from [oos_diagnostics()].
#' @return Tibble: `commodity`, `production_spec`.
#' @export
production_choice <- function(oos) {
  if (nrow(oos) == 0L) {
    return(tibble::tibble(commodity = character(),
                          production_spec = character()))
  }
  oos |>
    dplyr::group_by(.data$commodity) |>
    dplyr::slice_min(.data$rmse_valid, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::transmute(.data$commodity, production_spec = .data$spec)
}

#' Compute the production weight vector for one commodity.
#'
#' Returns a named numeric vector (weights summing to 1) keyed by spec
#' name in `cfg$bridge$candidates`. For a single-spec choice (e.g.
#' `"aggregate"`), the vector is all zeros except the chosen spec at 1.
#' For `"equal_avg"`, equal weights across all candidates. For
#' `"inv_mse"`, weights proportional to `1/RMSE^2` from `oos`.
#'
#' @keywords internal
production_weights <- function(production_spec, candidates, oos_for_commodity) {
  w <- stats::setNames(rep(0, length(candidates)), candidates)
  if (production_spec %in% candidates) {
    w[production_spec] <- 1
    return(w)
  }
  if (production_spec == "equal_avg") {
    w[] <- 1 / length(candidates)
    return(w)
  }
  if (production_spec == "inv_mse") {
    sub <- oos_for_commodity |>
      dplyr::filter(.data$spec %in% candidates) |>
      dplyr::mutate(inv = 1 / .data$rmse_valid^2)
    norm <- sum(sub$inv, na.rm = TRUE)
    for (i in seq_len(nrow(sub))) {
      w[[sub$spec[i]]] <- sub$inv[i] / norm
    }
    return(w)
  }
  stop("unknown production_spec: ", production_spec)
}

#' Build the per-commodity "production model" structure consumed by
#' [run_nowcast()].
#'
#' Each entry is:
#'   - `commodity`
#'   - `spec`       : the chosen production-spec label
#'   - `weights`    : named numeric vector summing to 1 over candidates
#'   - `components` : named list of fit objects keyed by spec name
#'                    (subset of `fits` for which weight > 0)
#'
#' @param fits_bench Output of [fit_bridge_bench()] (long-keyed by
#'   `<commodity>__<spec>`).
#' @param oos Tibble from [oos_diagnostics()].
#' @param choice Tibble from [production_choice()].
#' @param cfg Config list.
#' @return Named list keyed by commodity.
#' @export
select_production_models <- function(fits_bench, oos, choice, cfg) {
  commodities <- cfg$commodities %||% unique(oos$commodity)
  candidates  <- cfg$bridge$candidates %||% c("aggregate", "midas", "bojo")
  out <- list()
  for (com in commodities) {
    pchoice <- choice |> dplyr::filter(.data$commodity == com) |>
      dplyr::pull(.data$production_spec)
    if (length(pchoice) == 0L) next
    pchoice <- pchoice[1]

    oos_c <- dplyr::filter(oos, .data$commodity == com)
    w     <- production_weights(pchoice, candidates, oos_c)

    component_fits <- purrr::map(candidates, function(spec) {
      fits_bench[[paste0(com, "__", spec)]]
    }) |> stats::setNames(candidates)
    # Drop zero-weighted components (and any NULL fit objects).
    keep <- !vapply(component_fits, is.null, logical(1)) & w > 0
    if (!any(keep)) {
      log_warn("select_production_models[%s]: no usable components for %s",
               com, pchoice)
      next
    }
    component_fits <- component_fits[keep]
    w <- w[keep]
    w <- w / sum(w)

    out[[com]] <- list(
      commodity  = com,
      spec       = pchoice,
      weights    = w,
      components = component_fits
    )
    log_info("select_production_models[%s]: production=%s -> %s",
             com, pchoice,
             paste(sprintf("%s=%.2f", names(w), w), collapse = ", "))
  }
  out
}

#' Combine in-sample log V hat across components into a single residual
#' series, which the nowcast bootstrap samples from.
#'
#' For each commodity's production-model bundle:
#'   - For each component fit, compute fitted `log_volume` per training
#'     quarter (back-transforming `bojo` from the YoY-Δ scale).
#'   - Align on `quarter_end` across components; drop quarters where any
#'     active component lacks a fit.
#'   - Compute combined `yhat_log = Σ_i w_i * yhat_log_i`.
#'   - Residual = `log V_Q (observed) - yhat_log`.
#'
#' The returned vector preserves the existing log-space residual
#' bootstrap (no scale change); a single-spec production choice gives
#' exactly the same residuals as the previous per-spec code.
#'
#' @keywords internal
combined_log_residuals <- function(pm) {
  per_spec <- purrr::imap_dfr(pm$components, function(entry, spec_name) {
    raw <- stats::fitted(entry$fit)
    info <- spec_info(spec_name)
    yhat_log <- vapply(seq_along(raw), function(i) {
      info$to_log_volume(raw[i], entry$train_data[i, , drop = FALSE])
    }, numeric(1))
    tibble::tibble(
      quarter_end = entry$train_data$quarter_end,
      spec        = spec_name,
      yhat_log    = yhat_log,
      actual_log  = entry$train_data$log_volume
    )
  })
  if (nrow(per_spec) == 0L) return(numeric(0))

  wide <- per_spec |>
    tidyr::pivot_wider(names_from = "spec",
                       values_from = "yhat_log",
                       names_prefix = "yhat_")
  spec_cols <- paste0("yhat_", names(pm$weights))
  wide <- wide[stats::complete.cases(wide[, c("actual_log", spec_cols),
                                          drop = FALSE]), , drop = FALSE]
  if (nrow(wide) == 0L) return(numeric(0))

  yhat_mat   <- as.matrix(wide[, spec_cols, drop = FALSE])
  weights_v  <- pm$weights[names(pm$weights) %in%
                            sub("^yhat_", "", spec_cols)]
  weights_v  <- weights_v[sub("^yhat_", "", spec_cols)]
  combined_yhat <- as.numeric(yhat_mat %*% weights_v)
  as.numeric(wide$actual_log - combined_yhat)
}
