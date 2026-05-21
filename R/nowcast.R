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
                        as_of      = Sys.Date(),
                        horizon    = 0L) {

  B     <- cfg$nowcast$bootstrap_reps %||% 1000
  seed  <- cfg$nowcast$seed %||% 20260419

  prod_models <- coerce_to_production_models(bridge_fits)
  prod_models <- prod_models[!vapply(prod_models, is.null, logical(1))]
  if (length(prod_models) == 0L || is.null(portwatch)) {
    return(empty_nowcast_rows(cfg$commodities,
                              quarter_end(as_of),
                              quarter_share_observed(as_of)))
  }

  set.seed(seed)

  # One pass per requested horizon. For `h = 0` the target quarter is
  # the one containing `as_of`; for `h = 1` we look one quarter ahead
  # (the bridge's `log_volume_lag4` for Q+1 is Q-3's observed value, so
  # no recursion is needed). PortWatch coverage of Q+1 is typically
  # zero, so all three months of Q+1 land in the "future" branch of
  # `extrapolate_quarter_tonnage` and use `seasonal_norm * pace`.
  per_horizon <- lapply(horizon, function(h) {
    target_as_of <- if (h == 0L) as_of else
      lubridate::ceiling_date(as_of, "quarter") - 1L + h * 92L  # rough; corrected below
    # Snap to the correct quarter-end for h > 0:
    if (h != 0L) {
      target_as_of <- quarter_end(lubridate::floor_date(as_of, "quarter") +
                                    months(3L * h))
    }
    q_end <- quarter_end(target_as_of)
    share <- if (h == 0L) quarter_share_observed(as_of) else 0
    scale_boot <- sqrt(max(1 - share, 0))

    first_components <- purrr::map(prod_models, function(pm) pm$components[[1]])
    pred_frame <- build_nowcast_pred_frame(
      features  = features,
      portwatch = portwatch,
      cfg       = cfg,
      as_of     = target_as_of,
      fits      = first_components
    )
    if (nrow(pred_frame) == 0L) {
      return(empty_nowcast_rows(cfg$commodities, q_end, share) |>
               dplyr::mutate(horizon = h))
    }

    rows <- purrr::imap_dfr(prod_models, function(pm, com) {
      com_frame <- dplyr::filter(pred_frame, .data$commodity == com)
      if (nrow(com_frame) == 0L) return(one_empty_nowcast_row(com, q_end, share))

      component_log <- purrr::map_dbl(names(pm$components), function(spec_name) {
        entry <- pm$components[[spec_name]]
        info <- spec_info(spec_name)
        raw  <- as.numeric(stats::predict(entry$fit, newdata = com_frame))[1]
        info$to_log_volume(raw, com_frame[1, , drop = FALSE])
      })
      point_log <- sum(component_log * pm$weights[names(pm$components)])

      res <- if (length(pm$components) == 1L) {
        as.numeric(pm$components[[1]]$residuals)
      } else {
        combined_log_residuals(pm)
      }
      if (length(res) < 2L) {
        log_warn("run_nowcast[%s/h=%d]: too few residuals to bootstrap (n=%d)",
                 com, h, length(res))
        res <- if (length(res) == 0L) 0 else res
      }

      draws <- replicate(B, {
        eps <- sample(res, 1L, replace = TRUE) * scale_boot
        exp(point_log + eps)
      })

      tibble::tibble(
        commodity         = com,
        quarter_end       = q_end,
        point_estimate_Mt = exp(point_log),
        lower_80          = unname(stats::quantile(draws, 0.10,  na.rm = TRUE)),
        upper_80          = unname(stats::quantile(draws, 0.90,  na.rm = TRUE)),
        lower_95          = unname(stats::quantile(draws, 0.025, na.rm = TRUE)),
        upper_95          = unname(stats::quantile(draws, 0.975, na.rm = TRUE)),
        share_observed    = share,
        run_timestamp     = Sys.time()
      )
    })

    missing_coms <- setdiff(cfg$commodities, rows$commodity)
    if (length(missing_coms)) {
      rows <- dplyr::bind_rows(
        rows,
        purrr::map_dfr(missing_coms, one_empty_nowcast_row, q_end, share)
      )
    }
    rows |>
      dplyr::mutate(horizon = h) |>
      dplyr::arrange(match(.data$commodity, cfg$commodities))
  })

  dplyr::bind_rows(per_horizon)
}

#' Coerce a possibly-old-shape `bridge_fits` argument into the
#' production-model-bundle shape that run_nowcast expects internally.
#'
#' Detects "old shape" by the absence of a `components` field; wraps
#' each commodity entry into a single-spec bundle with weight 1.
#' @keywords internal
coerce_to_production_models <- function(x) {
  if (length(x) == 0L) return(x)
  has_components <- vapply(x, function(e) {
    !is.null(e) && !is.null(e$components)
  }, logical(1))
  if (all(has_components | vapply(x, is.null, logical(1)))) return(x)
  out <- list()
  for (com in names(x)) {
    entry <- x[[com]]
    if (is.null(entry)) { out[[com]] <- NULL; next }
    spec_name <- entry$spec %||% "aggregate"
    w <- stats::setNames(1, spec_name)
    out[[com]] <- list(
      commodity  = com,
      spec       = spec_name,
      weights    = w,
      components = stats::setNames(list(entry), spec_name)
    )
  }
  out
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

  # The `lagged` spec wants Δ_4 log T from the *prior* quarter as a
  # regressor. The prior quarter is fully observed by now (it's already
  # in `features`), so we just look it up.
  q_prev <- lubridate::floor_date(q_end, "quarter") - 1
  prev <- features |>
    dplyr::filter(.data$quarter_end == q_prev) |>
    dplyr::transmute(.data$commodity,
                     yoy_log_tonnage_lag1 = .data$yoy_log_tonnage)

  # The `price_aug` spec wants Δ_4 log P for the current quarter. At
  # nowcast time we use the *latest available* log_price per commodity
  # from `features` (which averages whatever months of the current
  # quarter are published so far). Lag 4 is the same-quarter price one
  # year ago, looked up directly. Skip entirely when the feature panel
  # has no price column (e.g. price ingest disabled or a fixture in a
  # unit test) so the join sets `log_price_*` to NA naturally.
  q_minus4_date <- lubridate::ceiling_date(q_end - lubridate::years(1L),
                                           "quarter") - 1
  has_price <- "log_price" %in% names(features)
  cur_price <- if (has_price) {
    features |>
      dplyr::filter(!is.na(.data$log_price)) |>
      dplyr::group_by(.data$commodity) |>
      dplyr::slice_max(.data$quarter_end, n = 1L) |>
      dplyr::ungroup() |>
      dplyr::transmute(.data$commodity, log_price_now = .data$log_price)
  } else {
    tibble::tibble(commodity = character(), log_price_now = double())
  }
  lag4_price <- if (has_price) {
    features |>
      dplyr::filter(.data$quarter_end == q_minus4_date,
                    !is.na(.data$log_price)) |>
      dplyr::transmute(.data$commodity, log_price_lag4 = .data$log_price)
  } else {
    tibble::tibble(commodity = character(), log_price_lag4 = double())
  }

  # Same pattern for FRED demand indicators: latest observed value per
  # series → `log_demand_<series>_now`, year-ago value → `_lag4`. The
  # `yoy_log_demand_<series>` regressor materialises by subtraction in
  # the final mutate below. Columns absent from the feature panel
  # (offline / fork build with no FRED ingest) produce NAs naturally.
  demand_cols <- grep("^log_demand_", names(features), value = TRUE)
  cur_demand <- if (length(demand_cols) > 0L) {
    features |>
      dplyr::group_by(.data$commodity) |>
      dplyr::slice_max(.data$quarter_end, n = 1L) |>
      dplyr::ungroup() |>
      dplyr::select(dplyr::all_of(c("commodity", demand_cols))) |>
      stats::setNames(c("commodity",
                        sub("^log_demand_", "log_demand_now_", demand_cols)))
  } else {
    tibble::tibble(commodity = character())
  }
  lag4_demand <- if (length(demand_cols) > 0L) {
    features |>
      dplyr::filter(.data$quarter_end == q_minus4_date) |>
      dplyr::select(dplyr::all_of(c("commodity", demand_cols))) |>
      stats::setNames(c("commodity",
                        sub("^log_demand_", "log_demand_lag4_", demand_cols)))
  } else {
    tibble::tibble(commodity = character())
  }

  pred <- wide_mwq |>
    dplyr::left_join(lag4,         by = "commodity") |>
    dplyr::left_join(prev,         by = "commodity") |>
    dplyr::left_join(cur_price,    by = "commodity") |>
    dplyr::left_join(lag4_price,   by = "commodity") |>
    dplyr::left_join(cur_demand,   by = "commodity") |>
    dplyr::left_join(lag4_demand,  by = "commodity") |>
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
      yoy_log_tonnage_m3 = .data$log_tonnage_m3 - .data$log_tonnage_m3_lag4,
      yoy_log_price      = .data$log_price_now  - .data$log_price_lag4
    )

  # Materialise `yoy_log_demand_<series>` columns by subtracting the
  # lag-4 from the current value for each FRED series wired up. Skipped
  # cleanly when no demand columns exist.
  for (col in demand_cols) {
    nm   <- sub("^log_demand_", "", col)
    cur  <- paste0("log_demand_now_",  nm)
    lag4 <- paste0("log_demand_lag4_", nm)
    out  <- paste0("yoy_log_demand_",  nm)
    if (all(c(cur, lag4) %in% names(pred))) {
      pred[[out]] <- pred[[cur]] - pred[[lag4]]
    } else {
      pred[[out]] <- NA_real_
    }
  }

  keep_cols <- c(
    "commodity", "quarter_end", "tonnage",
    "tonnage_m1", "tonnage_m2", "tonnage_m3",
    "log_tonnage", "log_tonnage_m1", "log_tonnage_m2", "log_tonnage_m3",
    "yoy_log_tonnage",
    "yoy_log_tonnage_m1", "yoy_log_tonnage_m2", "yoy_log_tonnage_m3",
    "yoy_log_tonnage_lag1",
    "yoy_log_price",
    "log_volume_lag4",
    grep("^yoy_log_demand_", names(pred), value = TRUE)
  )
  pred[, intersect(keep_cols, names(pred)), drop = FALSE]
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
