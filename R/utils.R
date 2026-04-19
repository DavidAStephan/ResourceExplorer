#' Quarter end for a given date
#'
#' @param x A Date or vector of Dates.
#' @return Date(s) of the last calendar day of the containing quarter.
#' @keywords internal
quarter_end <- function(x) {
  q <- lubridate::quarter(x, with_year = TRUE)
  yr <- floor(q)
  qn <- round((q - yr) * 10)
  month_end <- c(3L, 6L, 9L, 12L)[qn]
  day_end   <- c(31L, 30L, 30L, 31L)[qn]
  as.Date(sprintf("%04d-%02d-%02d", yr, month_end, day_end))
}

#' Share of the current quarter observed through a given date
#'
#' Used by the nowcast to scale uncertainty bands.
#'
#' @param today Reference date; defaults to `Sys.Date()`.
#' @return Numeric in \[0, 1\].
#' @keywords internal
quarter_share_observed <- function(today = Sys.Date()) {
  qs <- lubridate::floor_date(today, "quarter")
  qe <- quarter_end(today)
  as.numeric(today - qs + 1) / as.numeric(qe - qs + 1)
}
