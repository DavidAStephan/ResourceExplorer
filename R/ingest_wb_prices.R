#' Fetch the World Bank Pink Sheet monthly commodity-price workbook
#'
#' The Pink Sheet is the World Bank's monthly commodity-price publication,
#' covering ~70 series back to 1960. We pull:
#'
#'   - `Iron ore, cfr spot` (China CFR import benchmark) -> mapped to
#'     `iron_ore`.
#'   - `Coal, Australian` (Newcastle benchmark, thermal coal) -> mapped
#'     to both `coal_met` and `coal_thermal`. Newcastle is a *thermal*
#'     benchmark; met coal isn't in the Pink Sheet. Using it as the
#'     met-coal proxy is imperfect (the two commodities have different
#'     demand cycles); the bridge candidate-bench is what decides
#'     whether the price term actually helps each sub-commodity.
#'
#' The Pink Sheet's URL changes with each annual reorganisation. We
#' probe a small list of candidate URLs in reverse-chronological order
#' and use the first one that returns a 200; falls back to the on-disk
#' cache when offline.
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle (unused; kept for signature parity
#'   with the other ingest functions).
#' @return Long tibble: `quarter_end`, `commodity`, `price`, `log_price`,
#'   `ingested_at`. One row per (commodity, quarter).
#' @export
fetch_wb_prices <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  result <- tryCatch({
    url <- wb_pink_latest_url()
    if (is.null(url)) stop("wb_pink_latest_url: no candidate URL returned 200")

    df <- with_cache(cfg, "wb_pink", basename(url), function() {
      tmp <- tempfile(fileext = ".xlsx")
      on.exit(unlink(tmp), add = TRUE)
      download_binary_url(url, tmp)
      parse_wb_pink_workbook(tmp) |>
        dplyr::mutate(source_url = url)
    })
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "wb_pink", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- dplyr::mutate(result, ingested_at = Sys.time())
  wh_write("raw_wb_prices_quarterly", result, cfg)
  log_ingest_run(cfg, "wb_pink", started, nrow(result), status)
  log_info("fetch_wb_prices -- %d rows (%s)", nrow(result), status)
  result
}

#' Probe a list of candidate URLs for the latest Pink Sheet.
#'
#' The World Bank's CDN serves the file under a per-year doc-id. We try
#' the explicit known doc-ids in reverse order; both have so far been
#' served as the *current* file (the most recent one is updated in
#' place on each release).
#'
#' @keywords internal
wb_pink_latest_url <- function() {
  candidates <- c(
    "https://thedocs.worldbank.org/en/doc/74e8be41ceb20fa0da750cda2f6b9e4e-0050012026/related/CMO-Historical-Data-Monthly.xlsx",
    "https://thedocs.worldbank.org/en/doc/18675f1d1639c7a34d463f59263ba0a2-0050012025/related/CMO-Historical-Data-Monthly.xlsx"
  )
  for (u in candidates) {
    ok <- tryCatch({
      r <- httr2::request(u) |> httr2::req_method("HEAD") |> httr2::req_perform()
      httr2::resp_status(r) == 200
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(u)
  }
  NULL
}

#' Parse the Pink Sheet "Monthly Prices" sheet into a quarterly long tibble.
#'
#' Handles the two facts that complicate it:
#'   1. Header rows are non-rectangular (the first 4 rows are units +
#'      sub-headers); skip them.
#'   2. The date column has format `YYYYMmm` (e.g. `2026M04`) as text.
#'      Parse to a proper Date.
#'
#' @keywords internal
parse_wb_pink_workbook <- function(path) {
  raw <- readxl::read_excel(path, sheet = "Monthly Prices", skip = 4,
                             na = c("", "..", "n/a"))
  names(raw)[1L] <- "yyyymm"

  # Series of interest. Newcastle thermal coal stands in as the price
  # proxy for both coal sub-commodities; iron ore CFR spot is the iron
  # benchmark.
  series_map <- list(
    iron_ore     = "Iron ore, cfr spot",
    coal_met     = "Coal, Australian",
    coal_thermal = "Coal, Australian"
  )

  # Filter to the series we care about (deduped) + the date column.
  needed <- unique(unlist(series_map))
  keep   <- c("yyyymm", needed[needed %in% names(raw)])
  if (length(keep) <= 1L) {
    stop("parse_wb_pink_workbook: expected commodity columns not found")
  }
  raw <- raw[, keep, drop = FALSE]

  # Parse YYYYMmm -> Date (last day of that month) so the quarterly
  # aggregation downstream is clean.
  raw <- raw[grepl("^[0-9]{4}M[0-9]{2}$", raw$yyyymm), , drop = FALSE]
  yr  <- as.integer(substr(raw$yyyymm, 1, 4))
  mo  <- as.integer(substr(raw$yyyymm, 6, 7))
  raw$month_end <- lubridate::ceiling_date(as.Date(sprintf("%04d-%02d-01", yr, mo)),
                                           "month") - 1
  raw$yyyymm <- NULL

  # Cast numerics defensively (xlsx stores some as text under the WB's
  # template).
  for (nm in needed) {
    if (nm %in% names(raw)) raw[[nm]] <- suppressWarnings(as.numeric(raw[[nm]]))
  }

  # Aggregate monthly -> quarterly (mean of available months in the
  # quarter). At nowcast time for the current quarter this will average
  # whatever months have been published so far.
  long <- purrr::map_dfr(names(series_map), function(com) {
    col <- series_map[[com]]
    if (!col %in% names(raw)) return(NULL)
    tibble::tibble(
      commodity   = com,
      month_end   = raw$month_end,
      price_month = raw[[col]]
    )
  })
  long |>
    dplyr::filter(!is.na(.data$price_month)) |>
    dplyr::mutate(quarter_end = lubridate::ceiling_date(.data$month_end,
                                                        "quarter") - 1) |>
    dplyr::group_by(.data$commodity, .data$quarter_end) |>
    dplyr::summarise(price = mean(.data$price_month, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::mutate(log_price = log(pmax(.data$price, 1e-6)))
}
