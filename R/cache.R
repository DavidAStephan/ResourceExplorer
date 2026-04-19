#' Resolve the on-disk cache path for a (source, key) pair
#'
#' @param cfg Config list from [load_config()].
#' @param source Short source identifier (`"portwatch"`, `"abs_5368"`, `"fred"` ...).
#' @param key Cache key within the source. Sanitised to filesystem-safe chars.
#' @return Absolute path to an `.rds` file under `cfg$paths$cache/<source>/`.
#' @keywords internal
cache_path <- function(cfg, source, key) {
  dir <- fs::path(cfg$paths$cache, source)
  fs::dir_create(dir)
  safe_key <- gsub("[^A-Za-z0-9._-]", "_", key)
  fs::path(dir, paste0(safe_key, ".rds"))
}

#' Write an object to the cache
#' @keywords internal
cache_write <- function(cfg, source, key, obj) {
  path <- cache_path(cfg, source, key)
  saveRDS(obj, path, compress = "xz")
  invisible(path)
}

#' Read a cached object; returns `NULL` if not present
#' @keywords internal
cache_read <- function(cfg, source, key) {
  path <- cache_path(cfg, source, key)
  if (!fs::file_exists(path)) return(NULL)
  readRDS(path)
}

#' Run `fetcher()` and cache its result; fall back to cache on failure.
#'
#' Contract for `fetcher`: returns a data frame (or NULL). If it errors,
#' or if it returns `NULL` and a cache exists, the cached value is used
#' and tagged with `attr(x, "cache_status") <- "stale"`. Fresh returns
#' are tagged `"fresh"`. Used by every external-data ingestion function.
#'
#' @param cfg Config list.
#' @param source Cache source (`"portwatch"`, `"abs_5368"`, ...).
#' @param key Cache key.
#' @param fetcher A zero-argument function that returns the data.
#' @return The fetched (or cached) object, tagged via `cache_status` attr.
#' @keywords internal
with_cache <- function(cfg, source, key, fetcher) {
  fresh <- tryCatch(
    fetcher(),
    error = function(e) {
      # Defensive: a stale file appender can itself error. Swallow so
      # the fallback path below still runs.
      tryCatch(
        logger::log_warn("[{source}/{key}] fetch failed: {conditionMessage(e)}",
                         namespace = "resourcetracker"),
        error = function(e2) NULL
      )
      NULL
    }
  )

  if (!is.null(fresh)) {
    cache_write(cfg, source, key, fresh)
    attr(fresh, "cache_status") <- "fresh"
    return(fresh)
  }

  cached <- cache_read(cfg, source, key)
  if (is.null(cached)) {
    stop(sprintf("[%s/%s] fetch failed and no cache available",
                 source, key), call. = FALSE)
  }
  tryCatch(
    logger::log_warn("[{source}/{key}] using STALE cache",
                     namespace = "resourcetracker"),
    error = function(e2) NULL
  )
  attr(cached, "cache_status") <- "stale"
  cached
}
