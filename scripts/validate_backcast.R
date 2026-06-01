#!/usr/bin/env Rscript
## Validate the chain-volume backcast for the latest unpublished quarter
## against newly-released ABS Balance of Payments data.
##
## Compares the deployed backcast (the chain-volume estimate we made before
## ABS published Q-1) against the actual published value, reports point
## error, percentage error, and in-band coverage for the 80% and 95% bands.
##
## Usage:
##   Rscript scripts/validate_backcast.R
##     [--backcast-url URL]         (default: Pages deploy URL)
##     [--backcast-file PATH]       (local CSV override)
##     [--save-results PATH]        (write comparison to CSV)
##
## Defaults to fetching the locked snapshot under validation/ if it
## exists, otherwise pulls the live deployed CSV from GitHub Pages.

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
})

parse_args <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  out <- list(
    backcast_url  = "https://davidastephan.github.io/ResourceExplorer/data/nowcast_chain_vol.csv",
    backcast_file = NULL,
    save_results  = NULL
  )
  i <- 1
  while (i <= length(argv)) {
    key <- gsub("-", "_", sub("^--", "", argv[i]))
    val <- argv[i + 1]
    out[[key]] <- val
    i <- i + 2
  }
  out
}

args <- parse_args()

# Prefer locked snapshot if present and no explicit override.
locked_snapshots <- sort(
  list.files("validation", pattern = "^backcast_.*\\.csv$", full.names = TRUE),
  decreasing = TRUE
)
if (is.null(args$backcast_file) && length(locked_snapshots) > 0) {
  args$backcast_file <- locked_snapshots[1]
}

# 1. Load the backcast we're validating.
cat("=== Loading backcast ===\n")
if (!is.null(args$backcast_file)) {
  cat("Source: locked snapshot at", args$backcast_file, "\n")
  backcast <- read.csv(args$backcast_file, stringsAsFactors = FALSE)
} else {
  cat("Source: live deploy at", args$backcast_url, "\n")
  backcast <- tryCatch(
    read.csv(args$backcast_url, stringsAsFactors = FALSE),
    error = function(e) {
      stop("Failed to fetch backcast CSV: ", conditionMessage(e))
    }
  )
}

backcast_q <- backcast |>
  dplyr::filter(horizon < 0) |>
  dplyr::mutate(quarter_end = as.Date(quarter_end))

if (nrow(backcast_q) == 0L) {
  cat("\nNo backcast rows (horizon < 0). Nothing to validate.\n")
  quit(status = 0)
}

target_quarter <- backcast_q$quarter_end[1]
cat("Backcast quarter:", as.character(target_quarter), "\n")
cat("Commodities:", paste(backcast_q$commodity, collapse = ", "), "\n\n")

# 2. Re-fetch ABS 5302.0 Table 6 (should contain the newly-published Q1).
if (!requireNamespace("readabs", quietly = TRUE)) {
  stop("readabs package required: install.packages('readabs')")
}

cat("=== Fetching ABS 5302.0 Table 6 ===\n")
abs_raw <- readabs::read_abs(cat_no = "5302.0", tables = 6)

series_map <- c(
  iron_ore   = "A3535047K",
  coal_total = "A3535048L"
)

abs_cv <- abs_raw |>
  dplyr::filter(series_id %in% series_map) |>
  dplyr::mutate(
    quarter_end = lubridate::ceiling_date(date, "quarter") - 1,
    commodity   = names(series_map)[match(series_id, series_map)]
  ) |>
  dplyr::group_by(quarter_end, commodity) |>
  dplyr::summarise(actual_Am = mean(value, na.rm = TRUE), .groups = "drop")

latest_abs <- max(abs_cv$quarter_end)
cat("Latest ABS quarter available:", as.character(latest_abs), "\n\n")

if (latest_abs < target_quarter) {
  cat("ABS has NOT yet published", as.character(target_quarter), "data.\n")
  cat("(Latest available: ", as.character(latest_abs), ".)\n", sep = "")
  cat("Try again after the BoP release.\n")
  quit(status = 0)
}

# 3. Build comparison table.
comparison <- backcast_q |>
  dplyr::inner_join(
    dplyr::filter(abs_cv, quarter_end == target_quarter),
    by = c("quarter_end", "commodity")
  ) |>
  dplyr::transmute(
    commodity,
    quarter_end,
    backcast_Am = point_estimate_Am,
    actual_Am,
    error_Am    = actual_Am - backcast_Am,
    error_pct   = 100 * (actual_Am - backcast_Am) / backcast_Am,
    lower_80_Am, upper_80_Am,
    lower_95_Am, upper_95_Am,
    in_band_80  = actual_Am >= lower_80_Am & actual_Am <= upper_80_Am,
    in_band_95  = actual_Am >= lower_95_Am & actual_Am <= upper_95_Am
  )

# 4. Print results.
fmt <- function(x) format(round(x), big.mark = ",")

cat(strrep("=", 72), "\n", sep = "")
cat("BACKCAST VALIDATION  ", as.character(target_quarter), "\n", sep = "")
cat(strrep("=", 72), "\n\n", sep = "")

for (i in seq_len(nrow(comparison))) {
  r <- comparison[i, ]
  cat(toupper(r$commodity), "\n")
  cat(sprintf("  Backcast:   %10s A$m\n",  fmt(r$backcast_Am)))
  cat(sprintf("  Actual:     %10s A$m\n",  fmt(r$actual_Am)))
  cat(sprintf("  Error:      %+10s A$m  (%+.1f%%)\n",
              fmt(r$error_Am), r$error_pct))
  cat(sprintf("  80%% band:   %s -- %s  %s\n",
              fmt(r$lower_80_Am), fmt(r$upper_80_Am),
              if (r$in_band_80) "[in band]" else "[OUT OF BAND]"))
  cat(sprintf("  95%% band:   %s -- %s  %s\n",
              fmt(r$lower_95_Am), fmt(r$upper_95_Am),
              if (r$in_band_95) "[in band]" else "[OUT OF BAND]"))
  cat("\n")
}

cat(strrep("=", 72), "\n", sep = "")
cat(sprintf("80%% coverage: %d/%d  (%.0f%%)\n",
            sum(comparison$in_band_80), nrow(comparison),
            100 * mean(comparison$in_band_80)))
cat(sprintf("95%% coverage: %d/%d  (%.0f%%)\n",
            sum(comparison$in_band_95), nrow(comparison),
            100 * mean(comparison$in_band_95)))
cat(sprintf("Mean abs error:  %.1f%%\n",
            mean(abs(comparison$error_pct))))

# 5. Optionally save results.
if (!is.null(args$save_results)) {
  fs::dir_create(dirname(args$save_results))
  write.csv(comparison, args$save_results, row.names = FALSE)
  cat("\nSaved results to:", args$save_results, "\n")
}
