#' Fetch China-demand indicator series from FRED
#'
#' For each `(commodity, series_id)` pair in `cfg$fred$series`, pulls the
#' monthly FRED series via the public API (key from
#' `Sys.getenv(cfg$fred$api_key_env)`), aggregates to quarterly mean,
#' and returns a long tibble keyed by `(commodity, quarter_end, series)`.
#'
#' Two series are wired by default (verified live 2026-05-21):
#'
#'   - `CHNLOLITOAASTSAM` — OECD Composite Leading Indicator
#'     (amplitude-adjusted) for China → `iron_ore`. Broad forward-
#'     looking activity index that proxies steel-demand expectations.
#'   - `XTEXVA01CNM667S` — China International Merchandise Exports
#'     (value, USD) → `coal_thermal`. Manufacturing throughput proxies
#'     electricity demand, which drives thermal-coal burn.
#'
#' `coal_met` deliberately has no series in this pass — the bridge will
#' skip its `demand_aug` row automatically via the existing min_n / NA
#' guardrails in [`fit_bridge_one`].
#'
#' **Graceful degradation.** When the API key is unset (offline dev,
#' fork build, missing GitHub secret) the function returns a zero-row
#' tibble with a `WARN`-level log message and the pipeline continues —
#' the `demand_aug` spec then has no inputs and is dropped per
#' commodity. This mirrors the absent-cache behaviour of the other
#' ingest functions.
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle (unused; kept for signature parity
#'   with the other ingest functions).
#' @return Long tibble:
#'   `quarter_end`, `commodity`, `series`, `value`, `log_value`,
#'   `ingested_at`. One row per `(commodity, series, quarter)`.
#' @export
fetch_fred_demand <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  empty <- tibble::tibble(
    quarter_end = as.Date(character()),
    commodity   = character(),
    series      = character(),
    value       = double(),
    log_value   = double(),
    ingested_at = as.POSIXct(character())
  )

  series_map <- cfg$fred$series %||% list()
  if (length(series_map) == 0L) {
    log_info("fetch_fred_demand: no series configured -- skipping")
    log_ingest_run(cfg, "fred", started, 0L, "ok", "no series configured")
    return(empty)
  }

  api_key_env <- cfg$fred$api_key_env %||% "FRED_API_KEY"
  api_key     <- Sys.getenv(api_key_env)
  if (!nzchar(api_key)) {
    log_warn("fetch_fred_demand: %s unset -- demand_aug spec will be skipped",
             api_key_env)
    log_ingest_run(cfg, "fred", started, 0L, "ok", "api key unset")
    return(empty)
  }

  if (!requireNamespace("fredr", quietly = TRUE)) {
    log_warn("fetch_fred_demand: fredr package not installed -- skipping")
    log_ingest_run(cfg, "fred", started, 0L, "error", "fredr not installed")
    return(empty)
  }

  fredr::fredr_set_key(api_key)
  obs_start <- as.Date(cfg$sample$train_start %||% "2019-01-01")

  result <- tryCatch({
    pairs <- expand_fred_series_map(series_map)
    rows <- purrr::pmap_dfr(pairs, function(commodity, label, series_id) {
      df <- with_cache(cfg, "fred", series_id, function() {
        out <- fredr::fredr(series_id, observation_start = obs_start)
        if (nrow(out) == 0L) {
          stop(sprintf("fredr returned 0 rows for %s", series_id),
               call. = FALSE)
        }
        out
      })
      if (identical(attr(df, "cache_status"), "stale")) {
        status <<- "cached"
      }
      tibble::tibble(
        commodity = commodity,
        series    = label,
        series_id = series_id,
        month_end = lubridate::ceiling_date(as.Date(df$date), "month") - 1,
        value     = as.numeric(df$value)
      )
    })
    aggregate_fred_quarterly(rows)
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "fred", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- dplyr::mutate(result, ingested_at = Sys.time())
  wh_write("raw_fred_demand_quarterly", result, cfg)
  log_ingest_run(cfg, "fred", started, nrow(result), status)
  log_info("fetch_fred_demand -- %d rows across %d series (%s)",
           nrow(result),
           length(unique(result$series)),
           status)
  result
}

#' Expand the nested `cfg$fred$series` config into a flat pairs tibble.
#'
#' Config format:
#'   `list(iron_ore = c(cli = "CHNLOLITOAASTSAM"), coal_thermal = c(...))`
#'
#' Each commodity may map to one or more series (named character vector
#' where the *name* is the friendly label and the *value* is the FRED
#' series ID). This flattens to `(commodity, label, series_id)` rows.
#' The label is what materialises as a feature column suffix; the ID
#' is what we send to FRED.
#' @keywords internal
expand_fred_series_map <- function(series_map) {
  rows <- purrr::imap_dfr(series_map, function(ids, commodity) {
    if (length(ids) == 0L) return(NULL)
    labels <- names(ids)
    if (is.null(labels) || any(!nzchar(labels))) {
      stop("cfg$fred$series entries must be named (label = \"SERIES_ID\")",
           call. = FALSE)
    }
    tibble::tibble(commodity = commodity,
                   label     = labels,
                   series_id = unname(ids))
  })
  if (nrow(rows) == 0L) {
    return(tibble::tibble(commodity = character(),
                          label     = character(),
                          series_id = character()))
  }
  rows
}

#' Average monthly observations within each quarter, drop NA months.
#'
#' Quarter-end is the last day of the quarter the month belongs to. For
#' the current (partial) quarter this averages whatever months have been
#' published so far — same behaviour as `R/ingest_wb_prices.R`.
#'
#' @keywords internal
aggregate_fred_quarterly <- function(monthly) {
  if (nrow(monthly) == 0L) {
    return(tibble::tibble(
      quarter_end = as.Date(character()),
      commodity   = character(),
      series      = character(),
      series_id   = character(),
      value       = double(),
      log_value   = double()
    ))
  }
  monthly |>
    dplyr::filter(!is.na(.data$value)) |>
    dplyr::mutate(quarter_end = lubridate::ceiling_date(.data$month_end,
                                                        "quarter") - 1) |>
    dplyr::group_by(.data$commodity, .data$series, .data$series_id,
                   .data$quarter_end) |>
    dplyr::summarise(value = mean(.data$value, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::mutate(log_value = log(pmax(abs(.data$value), 1e-6)) *
                              sign(.data$value)) |>
    dplyr::select(dplyr::all_of(c("quarter_end", "commodity", "series",
                                  "series_id", "value", "log_value")))
}
