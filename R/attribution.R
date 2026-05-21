#' Decompose each nowcast into additive contributions vs the seasonal-
#' random-walk baseline `V_{Q-4}`.
#'
#' For every published nowcast row (commodity × horizon), break the gap
#' between the point estimate and the year-ago value of the same quarter
#' into four mechanical components implied by the production model's
#' coefficients:
#'
#'   - **tonnage signal** — sum of `β × yoy_log_tonnage*` terms,
#'     converted to Mt via `V_{Q-4} × Δlog`.
#'   - **seasonal-anchor drift** — `(β_lag4 − 1) × log V_{Q-4}` for
#'     specs that fit `β_lag4` freely (aggregate, midas, lagged,
#'     price_aug). Zero for `bojo`, which imposes `β_lag4 = 1`.
#'   - **intercept** — `β_0`. Generally small.
#'   - **other regressors** — `yoy_log_price` and similar non-tonnage
#'     drivers (currently just `price_aug`).
#'
#' For combination production picks (`equal_avg`, `inv_mse`) the
#' contributions are the weighted sum of the constituent singletons'
#' contributions, matching the combination's point-forecast formula.
#'
#' The decomposition is a first-order linearisation:
#' `contribution_k_Mt ≈ V_{Q-4} × Δlog_k`. Sums to a tiny rounding error
#' against `point - V_{Q-4}` for typical `|Δlog| ≤ 0.05`.
#'
#' @param nowcast_current Tibble from [run_nowcast()] (one row per
#'   commodity × horizon).
#' @param prod_models Output of [select_production_models()].
#' @param features Quarterly feature tibble from [build_features()].
#' @param portwatch Daily PortWatch tonnage tibble.
#' @param cfg Config list.
#' @return Same shape as `nowcast_current` with five extra columns:
#'   `v_lag4_Mt`, `tonnage_signal_Mt`, `lag4_drift_Mt`, `intercept_Mt`,
#'   `other_Mt`.
#' @export
decompose_nowcast <- function(nowcast_current, prod_models, features,
                              portwatch, cfg) {
  empty_cols <- list(v_lag4_Mt = NA_real_, tonnage_signal_Mt = NA_real_,
                     lag4_drift_Mt = NA_real_, intercept_Mt = NA_real_,
                     other_Mt = NA_real_)
  if (nrow(nowcast_current) == 0L || length(prod_models) == 0L) {
    return(dplyr::bind_cols(nowcast_current, tibble::as_tibble(empty_cols)[0, ]))
  }

  horizons <- if ("horizon" %in% names(nowcast_current)) {
    sort(unique(nowcast_current$horizon))
  } else {
    0L
  }

  per_h <- purrr::map_dfr(horizons, function(h) {
    pred_as_of <- if (h == 0L) Sys.Date() else {
      qend_now <- quarter_end(Sys.Date())
      quarter_end(lubridate::floor_date(qend_now, "quarter") +
                  months(3L * h))
    }
    # Re-build the same prediction frame the bridge consumes -- using
    # first_components only is enough because the regressor values are
    # identical across specs of a given commodity.
    first_components <- purrr::map(prod_models, function(pm) pm$components[[1]])
    pred_frame <- build_nowcast_pred_frame(
      features  = features,
      portwatch = portwatch,
      cfg       = cfg,
      as_of     = pred_as_of,
      fits      = first_components
    )
    if (nrow(pred_frame) == 0L) return(tibble::tibble())

    purrr::imap_dfr(prod_models, function(pm, com) {
      row <- dplyr::filter(pred_frame, .data$commodity == com)
      if (nrow(row) == 0L) return(tibble::tibble())
      row <- row[1, , drop = FALSE]

      parts <- decompose_components(pm, row)

      v_lag4 <- exp(row$log_volume_lag4)
      tibble::tibble(
        commodity         = com,
        horizon           = h,
        v_lag4_Mt         = v_lag4,
        tonnage_signal_Mt = v_lag4 * parts$tonnage_log,
        lag4_drift_Mt     = v_lag4 * parts$lag4_drift_log,
        intercept_Mt      = v_lag4 * parts$intercept_log,
        other_Mt          = v_lag4 * parts$other_log
      )
    })
  })

  if (nrow(per_h) == 0L) {
    return(dplyr::bind_cols(nowcast_current,
                            tibble::as_tibble(empty_cols)[0, ]))
  }

  join_by <- intersect(c("commodity", "horizon"), names(nowcast_current))
  if (!"horizon" %in% names(nowcast_current)) {
    per_h <- dplyr::filter(per_h, .data$horizon == 0L)
    per_h$horizon <- NULL
  }
  dplyr::left_join(nowcast_current, per_h, by = join_by)
}

#' For one production model and a prediction-frame row, sum the log-
#' contribution of each input category to `log V_Q − log V_{Q−4}`.
#'
#' Handles every spec in `spec_info()` and combination weights.
#'
#' @keywords internal
decompose_components <- function(pm, pred_row) {
  comp_breakdown <- purrr::imap_dfr(pm$components, function(entry, spec_name) {
    co <- stats::coef(entry$fit)
    intercept_log <- unname(co[["(Intercept)"]] %||% 0)

    # Tonnage-related regressors: every coefficient whose predictor name
    # starts with yoy_log_tonnage (covers _m1/_m2/_m3/_lag1/'').
    tonnage_terms <- grep("^yoy_log_tonnage", names(co), value = TRUE)
    tonnage_log <- sum(vapply(tonnage_terms, function(t) {
      x <- pred_row[[t]]
      if (is.null(x) || is.na(x)) 0 else unname(co[[t]]) * x
    }, numeric(1)))

    # Non-tonnage external regressors: yoy_log_price for price_aug.
    other_terms <- setdiff(names(co),
                           c("(Intercept)", "log_volume_lag4", tonnage_terms))
    other_log <- sum(vapply(other_terms, function(t) {
      x <- pred_row[[t]]
      if (is.null(x) || is.na(x)) 0 else unname(co[[t]]) * x
    }, numeric(1)))

    # Seasonal-anchor drift: (β_lag4 - 1) * log V_{Q-4} for non-bojo;
    # for bojo β_lag4 is implicitly 1 (the spec fits Δ_4 log V), so the
    # drift component is exactly zero.
    lag4_drift_log <- if (tolower(spec_name) == "bojo") {
      0
    } else if ("log_volume_lag4" %in% names(co)) {
      (unname(co[["log_volume_lag4"]]) - 1) * pred_row$log_volume_lag4
    } else {
      0
    }

    tibble::tibble(
      spec           = spec_name,
      intercept_log  = intercept_log,
      tonnage_log    = tonnage_log,
      lag4_drift_log = lag4_drift_log,
      other_log      = other_log
    )
  })

  if (nrow(comp_breakdown) == 0L) {
    return(list(intercept_log = 0, tonnage_log = 0,
                lag4_drift_log = 0, other_log = 0))
  }

  weights <- pm$weights[comp_breakdown$spec]
  weights <- weights / sum(weights)
  list(
    intercept_log  = sum(weights * comp_breakdown$intercept_log),
    tonnage_log    = sum(weights * comp_breakdown$tonnage_log),
    lag4_drift_log = sum(weights * comp_breakdown$lag4_drift_log),
    other_log      = sum(weights * comp_breakdown$other_log)
  )
}
