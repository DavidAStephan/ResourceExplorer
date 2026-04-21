#' Fetch FRED commodity-price series
#'
#' Pulls each series listed in `cfg$fred$series_ids` via `{fredr}`,
#' binds long, writes to `raw.fred_prices_daily`. Requires
#' `FRED_API_KEY` in the environment (from `.Renviron`). If the key is
#' missing *or* the network call fails, falls back to the RDS cache.
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle from [warehouse_init_schema()].
#' @return Tibble matching `raw.fred_prices_daily`.
#' @export
fetch_fred_prices <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  key <- Sys.getenv("FRED_API_KEY", unset = "")
  fetcher <- if (!nzchar(key)) {
    function() {
      log_warn("FRED_API_KEY not set -- returning NULL to trigger cache fallback")
      NULL
    }
  } else {
    function() {
      fredr::fredr_set_key(key)
      purrr::map_dfr(cfg$fred$series_ids, function(sid) {
        fredr::fredr(series_id = sid) |>
          dplyr::transmute(
            obs_date  = as.Date(.data$date),
            series_id = .data$series_id,
            value     = as.numeric(.data$value)
          )
      })
    }
  }

  result <- tryCatch({
    df <- with_cache(cfg, "fred", "commodity_prices", fetcher)
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "fred", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- dplyr::mutate(result, ingested_at = Sys.time())

  wh_write("raw_fred_prices_daily", result, cfg)

  log_ingest_run(cfg, "fred", started, nrow(result), status)
  log_info("fetch_fred_prices -- %d rows (%s)", nrow(result), status)
  result
}
