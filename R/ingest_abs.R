#' Fetch ABS 5302.0 Table 6 chain-volume measures for resource exports
#'
#' The Australian Bureau of Statistics publishes quarterly chain-volume
#' measures of goods exports by BoPCE commodity group in **Balance of
#' Payments** (cat. 5302.0), Table 6. Two series are relevant:
#'
#'   - "Coal, coke and briquettes" (SITC 32) — clean coal match.
#'   - "Metal ores and minerals" (SITC 27+28) — iron ore proxy.
#'     Iron ore is ~85-90% of this basket by value; the growth-rate
#'     pass-through (slope ≈ 1) is validated from 2015 onwards.
#'
#' The chain-volume series are used post-nowcast to convert physical-
#' tonnage growth rates into national-accounts chain-volume A$m.
#'
#' @param cfg Config list; uses `cfg$abs$series` for series_id mapping.
#' @param db_ready Dependency handle (unused; signature parity).
#' @return Long tibble: `quarter_end`, `commodity`, `chain_vol_Am`,
#'   `series_id`, `ingested_at`.
#' @export
fetch_abs_chain_volume <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  if (!requireNamespace("readabs", quietly = TRUE)) {
    log_warn("fetch_abs_chain_volume: readabs package not installed -- skipping")
    log_ingest_run(cfg, "abs_bop", started, 0L, "error", "readabs not installed")
    return(empty_abs_chain_vol())
  }

  series_map <- cfg$abs$series %||% default_abs_series()

  result <- tryCatch({
    df <- with_cache(cfg, "abs_bop", "5302_table6", function() {
      raw <- readabs::read_abs(cat_no = "5302.0", tables = 6)
      parse_abs_chain_volume(raw, series_map)
    })
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "abs_bop", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- dplyr::mutate(result, ingested_at = Sys.time())
  wh_write("raw_abs_chain_vol_quarterly", result, cfg)
  log_ingest_run(cfg, "abs_bop", started, nrow(result), status)
  log_info("fetch_abs_chain_volume -- %d rows (%s)", nrow(result), status)
  result
}

#' Default ABS series mapping: commodity -> series_id in Table 6
#' @keywords internal
default_abs_series <- function() {
  list(
    iron_ore   = list(series_id = "A3535047K",
                      label = "Metal ores and minerals"),
    coal_total = list(series_id = "A3535048L",
                      label = "Coal, coke and briquettes")
  )
}

#' Parse readabs output into a commodity-level chain-volume panel
#' @keywords internal
parse_abs_chain_volume <- function(raw, series_map) {
  wanted_ids <- vapply(series_map, function(s) s$series_id, character(1))

  filtered <- dplyr::filter(raw, .data$series_id %in% wanted_ids)
  if (nrow(filtered) == 0L) {
    stop("parse_abs_chain_volume: no matching series_id found in Table 6",
         call. = FALSE)
  }

  id_to_commodity <- stats::setNames(names(series_map), wanted_ids)

  filtered |>
    dplyr::mutate(
      quarter_end = lubridate::ceiling_date(.data$date, "quarter") - 1,
      commodity   = id_to_commodity[.data$series_id]
    ) |>
    dplyr::group_by(.data$quarter_end, .data$commodity, .data$series_id) |>
    dplyr::summarise(chain_vol_Am = mean(.data$value, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::filter(!is.na(.data$chain_vol_Am)) |>
    dplyr::arrange(.data$commodity, .data$quarter_end)
}

#' Empty fallback when readabs is not available
#' @keywords internal
empty_abs_chain_vol <- function() {
  tibble::tibble(
    quarter_end  = as.Date(character()),
    commodity    = character(),
    chain_vol_Am = double(),
    series_id    = character(),
    ingested_at  = as.POSIXct(character())
  )
}
