#' Fetch the DISR Resources and Energy Quarterly historical-data workbook
#'
#' The Australian Department of Industry, Science & Resources (DISR)
#' publishes the **Resources and Energy Quarterly (REQ)** in March, June,
#' September and December. Each release ships a "historical data" xlsx
#' workbook whose **Sheet 16** contains quarterly commodity exports by
#' physical volume (kt / Mt / ML depending on commodity).
#'
#' URL pattern (as at 2026-04):
#' `https://www.industry.gov.au/sites/default/files/YYYY-MM/resources-and-energy-quarterly-MONTH-YYYY-historical-data.xlsx`
#' — where `YYYY-MM` and the `MONTH-YYYY` slug match the release date,
#' e.g. `2025-12` / `december-2025`.
#'
#' Because the URL changes quarterly, [disr_latest_url()] probes candidate
#' URLs in reverse-chronological order (starting with the current
#' quarter) and returns the newest that responds 200.
#'
#' The result is a long tibble: `commodity`, `quarter_end`, `tonnes_Mt`.
#' Iron ore (published in kt) is converted to Mt. Metallurgical + thermal
#' coal are summed into a single `coal` row.
#'
#' @param cfg Config list; uses `cfg$disr$sheet` (default `"16"`),
#'   `cfg$disr$rows` (named list mapping commodity -> row number or
#'   vector of rows), `cfg$disr$url_override` (optional).
#' @param db_ready Dependency handle (unused; kept for signature parity).
#' @return Long tibble: `quarter_end`, `commodity`, `tonnes_Mt`,
#'   `source_url`, `ingested_at`.
#' @export
fetch_disr_req <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"

  result <- tryCatch({
    url <- cfg$disr$url_override %||% disr_latest_url(max_look_back = 6L)
    if (is.null(url)) stop("disr_latest_url: no release found in last 6 quarters")

    df <- with_cache(cfg, "disr_req", basename(url), function() {
      tmp <- tempfile(fileext = ".xlsx")
      on.exit(unlink(tmp), add = TRUE)
      download_binary_url(url, tmp)
      parse_disr_table16(
        tmp,
        sheet = cfg$disr$sheet %||% "16",
        rows  = cfg$disr$rows  %||% default_disr_rows()
      ) |> dplyr::mutate(source_url = url)
    })
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "disr_req", started, 0L, "error", conditionMessage(e))
    stop(e)
  })

  result <- dplyr::mutate(result, ingested_at = Sys.time())
  wh_write("raw_disr_req_quarterly", result, cfg)

  log_ingest_run(cfg, "disr_req", started, nrow(result), status)
  log_info("fetch_disr_req -- %d rows (%s)", nrow(result), status)
  result
}

#' Default DISR T16 row mapping: commodity -> row number(s) to SUM.
#' @keywords internal
default_disr_rows <- function() {
  list(
    iron_ore = list(rows = 19L,           unit = "kt"),
    coal     = list(rows = c(47L, 48L),   unit = "Mt")
  )
}

#' Discover the most recent DISR REQ historical-data xlsx
#'
#' Walks backwards from the current month trying canonical release months
#' (March, June, September, December) and returning the first URL that
#' responds 200 OK.
#'
#' @keywords internal
disr_latest_url <- function(max_look_back = 6L) {
  quarter_months <- c("march", "june", "september", "december")
  today <- Sys.Date()

  candidates <- character(0)
  for (k in 0:max_look_back) {
    d <- seq(today, length.out = 2, by = sprintf("-%d months", 3L * k))[2]
    y <- as.integer(format(d, "%Y"))
    m <- as.integer(format(d, "%m"))
    # Snap back to the most recent canonical release month <= m
    release_month <- dplyr::case_when(
      m >= 12L ~ "december",
      m >=  9L ~ "september",
      m >=  6L ~ "june",
      m >=  3L ~ "march",
      TRUE     ~ "december"
    )
    release_year <- if (release_month == "december" && m < 12L) y - 1L else y
    release_ym <- sprintf("%04d-%02d",
                           release_year,
                           switch(release_month,
                                  march = 3L, june = 6L,
                                  september = 9L, december = 12L))
    url <- sprintf(
      "https://www.industry.gov.au/sites/default/files/%s/resources-and-energy-quarterly-%s-%d-historical-data.xlsx",
      release_ym, release_month, release_year
    )
    candidates <- c(candidates, url)
  }
  candidates <- unique(candidates)

  # industry.gov.au misbehaves with httr2's default HTTP/2 handshake
  # (times out with 0 bytes). Use `{curl}` directly -- it negotiates
  # cleanly with the same server. Try each URL with `nobody = TRUE` for
  # a HEAD-equivalent that doesn't pull the 3MB body.
  for (url in candidates) {
    ok <- tryCatch({
      h <- curl::new_handle(nobody = TRUE, connecttimeout = 10L,
                             timeout = 15L, followlocation = TRUE)
      resp <- curl::curl_fetch_memory(url, handle = h)
      resp$status_code >= 200L && resp$status_code < 400L
    }, error = function(e) FALSE)
    if (isTRUE(ok)) {
      log_info("disr_latest_url: using %s", url)
      return(url)
    }
  }
  NULL
}

#' Download a binary URL to a local path.
#'
#' Uses `{httr2}` with a short retry, avoiding curl's download timeout
#' defaults that trip on slow responses. Keeps binary fidelity.
#' @keywords internal
download_binary_url <- function(url, dest) {
  # Use `{curl}` directly -- httr2 hangs on industry.gov.au's HTTP/2
  # handshake. curl_download handles it cleanly in <1 second.
  curl::curl_download(url, destfile = dest, quiet = TRUE)
  invisible(dest)
}

#' Parse DISR REQ Table 16 into a long tonnes-per-commodity-quarter tibble
#'
#' @param xlsx_path Path to a downloaded DISR REQ historical-data xlsx.
#' @param sheet Sheet name/index (default `"16"`).
#' @param rows Named list; keys are commodity labels, values are lists
#'   with fields `rows` (integer row numbers to sum) and `unit`
#'   (`"kt"`, `"Mt"`, or `"ML"`).
#' @return Long tibble: `quarter_end`, `commodity`, `tonnes_Mt`.
#' @export
parse_disr_table16 <- function(xlsx_path,
                               sheet = "16",
                               rows  = default_disr_rows()) {
  raw <- suppressWarnings(
    readxl::read_excel(xlsx_path, sheet = sheet,
                       col_names = FALSE, .name_repair = "unique_quiet")
  )

  # Row 7 (1-indexed) carries Excel date-serial numbers across columns.
  # Data starts at column 8.
  header_row <- 7L
  data_col_start <- 8L
  dates_raw <- suppressWarnings(as.numeric(unlist(raw[header_row,
                                                      data_col_start:ncol(raw)])))
  dates <- as.Date(dates_raw, origin = "1899-12-30")
  quarter_end <- lubridate::ceiling_date(dates, "quarter") - 1

  purrr::imap_dfr(rows, function(spec, com) {
    rvec <- spec$rows
    unit <- spec$unit %||% "Mt"
    mat <- vapply(rvec, function(r) {
      suppressWarnings(as.numeric(unlist(raw[r, data_col_start:ncol(raw)])))
    }, numeric(length(dates)))
    vals <- rowSums(mat, na.rm = FALSE)
    to_Mt <- switch(unit, kt = 1/1000, Mt = 1, ML = NA_real_)
    tibble::tibble(
      quarter_end = quarter_end,
      commodity   = com,
      tonnes_Mt   = vals * to_Mt
    )
  }) |>
    dplyr::filter(!is.na(.data$quarter_end), !is.na(.data$tonnes_Mt))
}
