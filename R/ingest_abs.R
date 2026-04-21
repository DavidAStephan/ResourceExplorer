#' Fetch ABS 5368.0 monthly goods-trade values (SITC 3-digit, FOB)
#'
#' Pulls the configured tables via `readabs::read_abs()`, isolates the
#' SITC 3-digit FOB export series for the commodities listed in
#' `cfg$abs$commodity_sitc`, and writes the long tibble to
#' `raw.abs_5368_monthly`.
#'
#' The IMF PortWatch bridge RHS uses the **primary** SITC per commodity
#' (from `mart.crosswalk_sitc`); coal aggregates 321 + 322 into one
#' monthly series at load time. Splitting is reversible via the crosswalk.
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle from [warehouse_init_schema()].
#' @return Tibble matching `raw.abs_5368_monthly`.
#' @export
fetch_abs_5368 <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  raw <- tryCatch({
    df <- with_cache(cfg, "abs_5368", "tables_12ab", function() {
      readabs::read_abs(
        cat_no = cfg$abs$cat_5368,
        tables = cfg$abs$tables_5368,
        retain_files = FALSE
      )
    })
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "abs_5368", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- parse_abs_5368(raw, cfg)

  wh_write("raw_abs_5368_monthly", result, cfg)

  log_ingest_run(cfg, "abs_5368", started, nrow(result), status)
  log_info("fetch_abs_5368 -- %d rows (%s)", nrow(result), status)
  result
}

#' Parse a raw `readabs::read_abs()` tibble down to our SITC-filtered schema
#'
#' Extracted for testability. Expects the standard `{readabs}` long output
#' with `series`, `series_id`, `date`, `value` columns.
#'
#' @keywords internal
parse_abs_5368 <- function(raw, cfg) {
  wanted_sitc <- unique(unlist(cfg$abs$commodity_sitc))
  # readabs uses "date" (first-of-month convention); we store month_end.
  sitc_regex <- paste0("\\b(", paste(wanted_sitc, collapse = "|"), ")\\b")

  raw |>
    dplyr::filter(grepl(sitc_regex, .data$series)) |>
    dplyr::mutate(
      month_end   = lubridate::ceiling_date(as.Date(.data$date), "month") - 1,
      sitc        = stringr::str_extract(.data$series, sitc_regex),
      value_aud_m = as.numeric(.data$value),
      ingested_at = Sys.time()
    ) |>
    dplyr::transmute(
      month_end,
      series_id   = as.character(.data$series_id),
      sitc,
      value_aud_m,
      ingested_at
    ) |>
    dplyr::filter(!is.na(.data$month_end), !is.na(.data$value_aud_m))
}

#' Fetch ABS 5302.0 quarterly BoP goods credits (current + chain-volume)
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle from [warehouse_init_schema()].
#' @return Tibble matching `raw.abs_5302_quarterly`.
#' @export
fetch_abs_5302 <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  raw <- tryCatch({
    df <- with_cache(cfg, "abs_5302", "tables_1_2", function() {
      readabs::read_abs(
        cat_no = cfg$abs$cat_5302,
        tables = cfg$abs$tables_5302,
        retain_files = FALSE
      )
    })
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "abs_5302", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- parse_abs_5302(raw)

  wh_write("raw_abs_5302_quarterly", result, cfg)

  log_ingest_run(cfg, "abs_5302", started, nrow(result), status)
  log_info("fetch_abs_5302 -- %d rows (%s)", nrow(result), status)
  result
}

#' Parse 5302.0 output into quarterly goods-credits rows
#'
#' Keeps both current-price (`value_current_aud_m`) and chain-volume
#' (`value_chainvol_aud_m`) series, pivoted so each quarter_end has one
#' row per series_id. The chain-volume series is the nowcast target;
#' current-price is kept for the implicit-deflator calc in Phase 4.
#'
#' @keywords internal
parse_abs_5302 <- function(raw) {
  goods_regex <- "(?i)goods credits|exports of goods"

  parsed <- raw |>
    dplyr::filter(grepl(goods_regex, .data$series, perl = TRUE)) |>
    dplyr::mutate(
      quarter_end = lubridate::ceiling_date(as.Date(.data$date), "quarter") - 1,
      is_chainvol = grepl("(?i)chain volume|chain-linked volume|reference", .data$series),
      value       = as.numeric(.data$value)
    ) |>
    dplyr::filter(!is.na(.data$quarter_end), !is.na(.data$value))

  parsed |>
    dplyr::group_by(.data$quarter_end, .data$series_id) |>
    dplyr::summarise(
      value_current_aud_m  = sum(ifelse(!.data$is_chainvol, .data$value, NA), na.rm = TRUE),
      value_chainvol_aud_m = sum(ifelse( .data$is_chainvol, .data$value, NA), na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      value_current_aud_m  = dplyr::na_if(.data$value_current_aud_m, 0),
      value_chainvol_aud_m = dplyr::na_if(.data$value_chainvol_aud_m, 0),
      ingested_at          = Sys.time()
    ) |>
    dplyr::transmute(quarter_end, series_id,
                     value_current_aud_m, value_chainvol_aud_m, ingested_at)
}
