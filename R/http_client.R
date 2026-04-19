#' Build a retrying `{httr2}` request
#'
#' Adds a user-agent, a retry policy with exponential backoff, and a
#' timeout. Callers compose further with `httr2::req_url_query()`, etc.
#'
#' @param url Base URL.
#' @param max_attempts Integer, max tries including the first.
#' @param backoff_seconds Base for exponential backoff.
#' @param timeout_seconds Request timeout.
#' @return An `httr2_request` object.
#' @keywords internal
make_request <- function(url,
                         max_attempts    = 3,
                         backoff_seconds = 5,
                         timeout_seconds = 60) {
  httr2::request(url) |>
    httr2::req_user_agent("resourcetracker (https://github.com/dstephan/resourcetracker)") |>
    httr2::req_timeout(timeout_seconds) |>
    httr2::req_retry(
      max_tries = max_attempts,
      backoff   = function(i) backoff_seconds * (2 ^ (i - 1)),
      is_transient = function(resp) {
        httr2::resp_status(resp) %in% c(408, 425, 429, 500, 502, 503, 504)
      }
    )
}
