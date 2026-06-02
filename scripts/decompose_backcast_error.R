#!/usr/bin/env Rscript
## Decompose the chain-volume backcast error once DISR publishes physical
## tonnes for the previously-backcast quarter.
##
## The backcast pipeline is two stages:
##   1. PortWatch + bridge model -> DISR physical tonnes (backcast)
##   2. tonnage growth rate * ABS lag-4 chain-volume -> chain-volume A$m
##
## Total error decomposes as:
##   backcast_Am - actual_Am  =  (backcast_Am - counterfactual_Am)
##                              + (counterfactual_Am - actual_Am)
## where counterfactual = ABS_lag4 * (DISR_actual / DISR_lag4).
##
## Step 1 (tonnage)  = backcast_Am - counterfactual_Am
##                     "what tonnage mis-prediction cost"
## Step 2 (bridge)   = counterfactual_Am - actual_Am
##                     "what the basket-and-quality wedge cost, given
##                     correct tonnage"
##
## Sign: positive = we over-predicted; negative = we under-predicted.
##
## Usage:
##   Rscript scripts/decompose_backcast_error.R
##     [--backcast-file PATH]      (default: latest validation/backcast_*.csv)
##     [--validation-file PATH]    (default: latest validation/results_*.csv)
##     [--save-results PATH]
##
## Requires: DISR REQ to have published Q-1 tonnes. The script fetches
## the latest REQ release and gracefully exits if the target quarter is
## still missing.

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
})

parse_args <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  out <- list(backcast_file = NULL, validation_file = NULL,
              save_results = NULL)
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

# ---- 1. Locked backcast --------------------------------------------------

if (is.null(args$backcast_file)) {
  candidates <- sort(list.files("validation", pattern = "^backcast_.*\\.csv$",
                                full.names = TRUE), decreasing = TRUE)
  if (length(candidates) == 0L) stop("No locked backcast found in validation/")
  args$backcast_file <- candidates[1]
}
cat("Backcast: ", args$backcast_file, "\n", sep = "")
backcast <- read.csv(args$backcast_file, stringsAsFactors = FALSE) |>
  dplyr::filter(horizon < 0L) |>
  dplyr::mutate(quarter_end = as.Date(quarter_end))

if (nrow(backcast) == 0L) stop("No backcast rows (horizon < 0).")

target_q <- backcast$quarter_end[1]
cat("Target quarter: ", as.character(target_q), "\n", sep = "")

# Recover the implied physical-tonnage backcast.
backcast <- backcast |>
  dplyr::mutate(backcast_tonnes_Mt = .data$disr_lag4_Mt * .data$growth_factor)

# ---- 2. ABS actual (from today's validation) -----------------------------

if (is.null(args$validation_file)) {
  candidates <- sort(list.files("validation", pattern = "^results_.*\\.csv$",
                                full.names = TRUE), decreasing = TRUE)
  if (length(candidates) == 0L) {
    stop("No validation results found. Run validate_backcast.R first.")
  }
  args$validation_file <- candidates[1]
}
cat("ABS actual: ", args$validation_file, "\n", sep = "")
validation <- read.csv(args$validation_file, stringsAsFactors = FALSE)
abs_actual <- validation |>
  dplyr::select(commodity, actual_Am)

# ---- 3. DISR actual -- fetch latest REQ release --------------------------

cat("\nLoading R sources (need fetch_disr_req)...\n")
suppressMessages({
  for (f in sort(list.files("R", pattern = "\\.R$", full.names = TRUE))) {
    source(f)
  }
})

cfg <- load_config("config.R")

cat("Fetching DISR REQ (looking for ", as.character(target_q), " data)\n",
    sep = "")
disr <- tryCatch(
  fetch_disr_req(cfg, cfg$paths$warehouse_dir),
  error = function(e) {
    message("fetch_disr_req failed: ", conditionMessage(e))
    NULL
  }
)
if (is.null(disr) || nrow(disr) == 0L) {
  stop("Could not load DISR REQ data.")
}

disr_target <- disr |>
  dplyr::filter(.data$quarter_end == target_q)

if (nrow(disr_target) == 0L) {
  cat("\nDISR has NOT yet published ", as.character(target_q),
      " physical tonnes.\n", sep = "")
  cat("(Latest DISR quarter: ",
      as.character(max(disr$quarter_end)), ")\n", sep = "")
  cat("Re-run once the next REQ release lands.\n")
  quit(status = 0)
}

# Build commodity-mapped DISR actuals: iron_ore stays, coal_met +
# coal_thermal sum to coal_total (matching the chain-vol panel).
disr_iron <- disr_target |>
  dplyr::filter(commodity == "iron_ore") |>
  dplyr::transmute(commodity, disr_actual_Mt = tonnes_Mt)

disr_coal <- disr_target |>
  dplyr::filter(commodity %in% c("coal_met", "coal_thermal")) |>
  dplyr::summarise(disr_actual_Mt = sum(tonnes_Mt, na.rm = TRUE)) |>
  dplyr::mutate(commodity = "coal_total") |>
  dplyr::select(commodity, disr_actual_Mt)

disr_actual <- dplyr::bind_rows(disr_iron, disr_coal)

# ---- 4. Decomposition ----------------------------------------------------

decomp <- backcast |>
  dplyr::inner_join(disr_actual, by = "commodity") |>
  dplyr::inner_join(abs_actual,  by = "commodity") |>
  dplyr::mutate(
    counterfactual_Am   = .data$abs_lag4_Am *
                          (.data$disr_actual_Mt / .data$disr_lag4_Mt),
    step1_tonnage_Am    = .data$point_estimate_Am - .data$counterfactual_Am,
    step2_bridge_Am     = .data$counterfactual_Am - .data$actual_Am,
    total_error_Am      = .data$point_estimate_Am - .data$actual_Am,
    tonnage_error_pct   = 100 * (.data$backcast_tonnes_Mt -
                                 .data$disr_actual_Mt) /
                                 .data$disr_actual_Mt
  )

# ---- 5. Print ------------------------------------------------------------

fmt_am  <- function(x) format(round(x), big.mark = ",")
fmt_pct <- function(x) sprintf("%+.1f%%", x)
fmt_mt  <- function(x) sprintf("%.1f", x)

cat("\n", strrep("=", 76), "\n", sep = "")
cat("BACKCAST ERROR DECOMPOSITION  ", as.character(target_q), "\n", sep = "")
cat(strrep("=", 76), "\n", sep = "")
cat("Sign: positive = over-predicted; negative = under-predicted.\n\n")

for (i in seq_len(nrow(decomp))) {
  r <- decomp[i, ]
  cat(toupper(r$commodity), "\n")
  cat(sprintf("  Physical tonnes  -- backcast %s Mt vs actual %s Mt  (%s)\n",
              fmt_mt(r$backcast_tonnes_Mt), fmt_mt(r$disr_actual_Mt),
              fmt_pct(r$tonnage_error_pct)))
  cat(sprintf("  Chain-volume     -- backcast %s vs actual %s A$m\n",
              fmt_am(r$point_estimate_Am), fmt_am(r$actual_Am)))
  cat(sprintf("    Step 1 tonnage error:   %+10s A$m\n",
              fmt_am(r$step1_tonnage_Am)))
  cat(sprintf("    Step 2 bridge wedge:    %+10s A$m\n",
              fmt_am(r$step2_bridge_Am)))
  cat(sprintf("    ---------------------------------\n"))
  cat(sprintf("    Total error:            %+10s A$m  (%s)\n",
              fmt_am(r$total_error_Am),
              fmt_pct(100 * r$total_error_Am / r$actual_Am)))

  # Which stage dominates?
  s1 <- abs(r$step1_tonnage_Am); s2 <- abs(r$step2_bridge_Am)
  if (s1 + s2 > 0) {
    s1_share <- 100 * s1 / (s1 + s2)
    cat(sprintf("    Attribution: tonnage %.0f%%, bridge %.0f%%\n",
                s1_share, 100 - s1_share))
  }
  cat("\n")
}

if (!is.null(args$save_results)) {
  out <- decomp |>
    dplyr::select(commodity, quarter_end,
                  backcast_tonnes_Mt, disr_actual_Mt, tonnage_error_pct,
                  point_estimate_Am, counterfactual_Am, actual_Am,
                  step1_tonnage_Am, step2_bridge_Am, total_error_Am)
  fs::dir_create(dirname(args$save_results))
  write.csv(out, args$save_results, row.names = FALSE)
  cat("Saved decomposition to: ", args$save_results, "\n", sep = "")
}
