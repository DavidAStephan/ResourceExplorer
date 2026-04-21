#' RDS-backed warehouse
#'
#' Replaces the previous DuckDB warehouse (not on the work-laptop package
#' allow-list). Each "table" is a single `.rds` file under
#' `cfg$paths$warehouse_dir`. Data volumes are small (≤ tens of thousands
#' of rows), so `readRDS` / `saveRDS` are more than fast enough and add
#' zero compiled-package surface area.
#'
#' Public API:
#'
#' - `warehouse_init_schema(cfg)` — ensure the warehouse directory exists.
#'   Returns the directory path invisibly (target-compatible signature).
#' - `wh_write(name, tbl, cfg)` — overwrite the named table.
#' - `wh_append(name, tbl, cfg)` — append rows, deduping by any shared keys.
#' - `wh_read(name, cfg)` — read (or return `NULL` if absent).
#' - `wh_exists(name, cfg)` — path predicate.
#'
#' Table names should be short, filesystem-safe snake_case strings, e.g.
#' `"raw_portwatch_tonnage_daily"`, `"mart_nowcast_history"`.
#' @name warehouse
NULL

#' @rdname warehouse
#' @export
warehouse_init_schema <- function(cfg) {
  dir <- cfg$paths$warehouse_dir %||% "data/warehouse"
  fs::dir_create(dir)
  invisible(dir)
}

.wh_path <- function(name, cfg) {
  dir <- cfg$paths$warehouse_dir %||% "data/warehouse"
  fs::dir_create(dir)
  if (!grepl("^[A-Za-z0-9_]+$", name)) {
    stop("warehouse table name must be [A-Za-z0-9_]+, got: ", name,
         call. = FALSE)
  }
  fs::path(dir, paste0(name, ".rds"))
}

#' @rdname warehouse
#' @export
wh_path <- function(name, cfg) .wh_path(name, cfg)

#' @rdname warehouse
#' @export
wh_exists <- function(name, cfg) fs::file_exists(.wh_path(name, cfg))

#' @rdname warehouse
#' @export
wh_write <- function(name, tbl, cfg) {
  stopifnot(is.data.frame(tbl))
  path <- .wh_path(name, cfg)
  saveRDS(tibble::as_tibble(tbl), path, compress = "xz")
  invisible(path)
}

#' @rdname warehouse
#' @export
wh_read <- function(name, cfg) {
  path <- .wh_path(name, cfg)
  if (!fs::file_exists(path)) return(NULL)
  readRDS(path)
}

#' @rdname warehouse
#' @param keys Character vector of columns to dedupe on. If `NULL`, rows
#'   are concatenated without dedup.
#' @export
wh_append <- function(name, tbl, cfg, keys = NULL) {
  stopifnot(is.data.frame(tbl))
  existing <- wh_read(name, cfg)
  out <- if (is.null(existing)) {
    tibble::as_tibble(tbl)
  } else {
    dplyr::bind_rows(existing, tibble::as_tibble(tbl))
  }
  if (!is.null(keys) && length(keys) && nrow(out)) {
    # Keep the most recent row per key set.
    out <- out[!duplicated(out[, keys, drop = FALSE], fromLast = TRUE), , drop = FALSE]
  }
  wh_write(name, out, cfg)
}
