## Investigation: DISR physical tonnes → ABS chain-volume bridge
##
## Empirical test: how tight is the growth-rate mapping between
## DISR T16 physical tonnes and ABS chain-volume measures?
##
## Sources:
##   LHS: ABS 5302.0 Table 6 — BoP chain-volume by BoPCE commodity
##   RHS: DISR REQ Table 16 — physical export tonnes (Mt)

library(dplyr, warn.conflicts = FALSE)
library(tidyr)
library(lubridate, warn.conflicts = FALSE)
library(readabs)
library(ggplot2)

out_dir <- file.path(dirname(getwd()), "ResourceExplorer/analysis")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# ── 1. Load existing DISR physical tonnes ──────────────────────────

disr <- readRDS("data/warehouse/raw_disr_req_quarterly.rds") |>
  select(quarter_end, commodity, tonnes_Mt)

cat("=== DISR data ===\n")
cat("Date range:", as.character(min(disr$quarter_end)), "to",
    as.character(max(disr$quarter_end)), "\n")
cat("Commodities:", paste(unique(disr$commodity), collapse = ", "), "\n\n")

disr_total_coal <- disr |>
  filter(commodity %in% c("coal_met", "coal_thermal")) |>
  group_by(quarter_end) |>
  summarise(tonnes_Mt = sum(tonnes_Mt), .groups = "drop") |>
  mutate(commodity = "coal_total")

disr_wide <- bind_rows(
  disr |> filter(commodity == "iron_ore"),
  disr_total_coal
)


# ── 2. Fetch ABS 5302.0 Table 6 — chain-volume measures ───────────
#
# BoPCE commodities in Table 6 include:
#   "Metal ores and minerals" (SITC 27+28) — iron ore proxy
#   "Coal, coke and briquettes" (SITC 32)  — coal match

cat("Fetching ABS 5302.0 (Balance of Payments)...\n")

abs_raw <- tryCatch(
 read_abs(cat_no = "5302.0", tables = 6),
  error = function(e) {
    cat("readabs download failed:", conditionMessage(e), "\n")
    cat("Trying alternative table numbers...\n")
    tryCatch(
      read_abs(cat_no = "5302.0", tables = "6"),
      error = function(e2) {
        cat("Alternative also failed:", conditionMessage(e2), "\n")
        NULL
      }
    )
  }
)

if (is.null(abs_raw)) {
  cat("\nDirect readabs fetch failed. Trying read_abs_sdmx for BoP data...\n")
  stop("Could not fetch ABS 5302.0 Table 6. Check readabs configuration.")
}

cat("Fetched", nrow(abs_raw), "rows from ABS 5302.0\n")
cat("Unique series:", length(unique(abs_raw$series)), "\n")

# Inspect what series are available
cat("\n=== Available series in Table 6 ===\n")
series_list <- abs_raw |>
  distinct(series, series_id, unit) |>
  arrange(series)
print(series_list, n = 60)

# Filter for chain-volume series (seasonally adjusted preferred)
# Look for "Chain volume" in the series name
chain_vol <- abs_raw |>
  filter(grepl("[Cc]hain volume", series, ignore.case = TRUE))

cat("\n=== Chain volume series ===\n")
chain_vol_series <- chain_vol |>
  distinct(series, series_id, unit) |>
  arrange(series)
print(chain_vol_series, n = 40)

# Extract coal and metal ores
# Pattern matching for BoPCE commodity names
coal_cv <- chain_vol |>
  filter(grepl("[Cc]oal", series, ignore.case = TRUE)) |>
  filter(grepl("[Ss]easonally [Aa]djusted", series, ignore.case = TRUE) |
         !any(grepl("[Ss]easonally [Aa]djusted", series, ignore.case = TRUE)))

metal_ores_cv <- chain_vol |>
  filter(grepl("[Mm]etal.*ore|[Oo]re.*mineral|[Mm]ineral.*ore", series, ignore.case = TRUE)) |>
  filter(grepl("[Ss]easonally [Aa]djusted", series, ignore.case = TRUE) |
         !any(grepl("[Ss]easonally [Aa]djusted", series, ignore.case = TRUE)))

cat("\n=== Coal chain volume series ===\n")
print(coal_cv |> distinct(series, series_id))

cat("\n=== Metal ores chain volume series ===\n")
print(metal_ores_cv |> distinct(series, series_id))

# If pattern matching didn't work, show all series for manual inspection
if (nrow(coal_cv) == 0 || nrow(metal_ores_cv) == 0) {
  cat("\n=== ALL series names (for debugging) ===\n")
  all_series <- abs_raw |> distinct(series) |> pull(series)
  cat(paste(all_series, collapse = "\n"), "\n")
}


# ── 3. Build quarterly chain-volume panel ──────────────────────────

build_abs_quarterly <- function(df, commodity_label) {
  df |>
    mutate(quarter_end = ceiling_date(date, "quarter") - days(1)) |>
    group_by(quarter_end) |>
    summarise(chain_vol_Am = mean(value, na.rm = TRUE), .groups = "drop") |>
    mutate(commodity = commodity_label)
}

abs_coal <- if (nrow(coal_cv) > 0) {
  # Use the first matching series (seasonally adjusted if available)
  sid <- coal_cv |> distinct(series_id) |> slice(1) |> pull()
  cat("\nUsing coal series:", sid, "\n")
  coal_cv |> filter(series_id == sid) |> build_abs_quarterly("coal_total")
} else {
  cat("\nWARNING: No coal chain-volume series found\n")
  tibble()
}

abs_iron <- if (nrow(metal_ores_cv) > 0) {
  sid <- metal_ores_cv |> distinct(series_id) |> slice(1) |> pull()
  cat("Using metal ores series:", sid, "\n")
  metal_ores_cv |> filter(series_id == sid) |> build_abs_quarterly("iron_ore")
} else {
  cat("\nWARNING: No metal ores chain-volume series found\n")
  tibble()
}

abs_panel <- bind_rows(abs_coal, abs_iron)

cat("\n=== ABS chain-volume panel ===\n")
cat("Date range:", as.character(min(abs_panel$quarter_end)), "to",
    as.character(max(abs_panel$quarter_end)), "\n")
cat("Obs per commodity:\n")
print(abs_panel |> count(commodity))


# ── 4. Merge and compute YoY growth rates ──────────────────────────

merged <- inner_join(disr_wide, abs_panel, by = c("quarter_end", "commodity"))

merged <- merged |>
  arrange(commodity, quarter_end) |>
  group_by(commodity) |>
  mutate(
    disr_yoy     = log(tonnes_Mt) - log(lag(tonnes_Mt, 4)),
    abs_cv_yoy   = log(chain_vol_Am) - log(lag(chain_vol_Am, 4)),
    disr_qoq     = log(tonnes_Mt) - log(lag(tonnes_Mt, 1)),
    abs_cv_qoq   = log(chain_vol_Am) - log(lag(chain_vol_Am, 1))
  ) |>
  ungroup()

cat("\n=== Merged panel ===\n")
cat("Total obs:", nrow(merged), "\n")
cat("Obs with YoY (non-NA):", sum(!is.na(merged$disr_yoy) & !is.na(merged$abs_cv_yoy)), "\n")


# ── 5. Growth-rate regressions ─────────────────────────────────────

cat("\n", strrep("=", 60), "\n")
cat("GROWTH-RATE BRIDGE REGRESSIONS\n")
cat(strrep("=", 60), "\n")

results <- list()

for (comm in unique(merged$commodity)) {
  d <- merged |>
    filter(commodity == comm, !is.na(disr_yoy), !is.na(abs_cv_yoy))

  if (nrow(d) < 10) {
    cat("\nSkipping", comm, "— only", nrow(d), "obs\n")
    next
  }

  # YoY regression: Δ%chain_vol = α + β·Δ%physical_tonnes + ε
  fit_yoy <- lm(abs_cv_yoy ~ disr_yoy, data = d)
  s_yoy   <- summary(fit_yoy)

  cat("\n──", toupper(comm), "── YoY log-differences ──\n")
  cat("N =", nrow(d), "\n")
  cat("R² =", round(s_yoy$r.squared, 4), "\n")
  cat("Adj R² =", round(s_yoy$adj.r.squared, 4), "\n")
  cat("Intercept:", round(coef(fit_yoy)[1], 4),
      " (SE", round(s_yoy$coefficients[1, 2], 4), ")\n")
  cat("Slope (β):", round(coef(fit_yoy)[2], 4),
      " (SE", round(s_yoy$coefficients[2, 2], 4), ")\n")
  cat("RMSE:", round(s_yoy$sigma, 4), "\n")

  # Test H0: β = 1 (slope = 1, pure pass-through)
  beta_hat <- coef(fit_yoy)[2]
  beta_se  <- s_yoy$coefficients[2, 2]
  t_stat   <- (beta_hat - 1) / beta_se
  p_val    <- 2 * pt(abs(t_stat), df = fit_yoy$df.residual, lower.tail = FALSE)
  cat("Test β=1: t =", round(t_stat, 3), ", p =", round(p_val, 4), "\n")

  # Test H0: α = 0 (no systematic bias)
  alpha_hat <- coef(fit_yoy)[1]
  alpha_se  <- s_yoy$coefficients[1, 2]
  t_alpha   <- alpha_hat / alpha_se
  p_alpha   <- 2 * pt(abs(t_alpha), df = fit_yoy$df.residual, lower.tail = FALSE)
  cat("Test α=0: t =", round(t_alpha, 3), ", p =", round(p_alpha, 4), "\n")

  # Correlation at levels
  cor_level <- cor(d$tonnes_Mt, d$chain_vol_Am, use = "complete.obs")
  cat("Level correlation (tonnes vs chain-vol):", round(cor_level, 4), "\n")

  results[[comm]] <- list(
    commodity = comm, n = nrow(d),
    r2 = s_yoy$r.squared, slope = beta_hat, slope_se = beta_se,
    intercept = alpha_hat, intercept_se = alpha_se,
    rmse = s_yoy$sigma,
    p_slope_eq_1 = p_val, p_intercept_eq_0 = p_alpha,
    cor_level = cor_level
  )
}


# ── 6. Level-on-level regressions (for comparison) ────────────────

cat("\n", strrep("=", 60), "\n")
cat("LEVEL REGRESSIONS (for reference)\n")
cat(strrep("=", 60), "\n")

for (comm in unique(merged$commodity)) {
  d <- merged |> filter(commodity == comm, !is.na(chain_vol_Am))

  if (nrow(d) < 10) next

  fit_lev <- lm(log(chain_vol_Am) ~ log(tonnes_Mt), data = d)
  s_lev   <- summary(fit_lev)

  cat("\n──", toupper(comm), "── log-levels ──\n")
  cat("N =", nrow(d), "\n")
  cat("R² =", round(s_lev$r.squared, 4), "\n")
  cat("Intercept:", round(coef(fit_lev)[1], 4), "\n")
  cat("Slope (elasticity):", round(coef(fit_lev)[2], 4),
      " (SE", round(s_lev$coefficients[2, 2], 4), ")\n")
  cat("RMSE:", round(s_lev$sigma, 4), "\n")
}


# ── 7. Time-varying relationship check ────────────────────────────
#
# Is the mapping stable over time, or is quality degradation
# / composition shift creating a drift?

cat("\n", strrep("=", 60), "\n")
cat("TIME-STABILITY CHECK (rolling 5-year window)\n")
cat(strrep("=", 60), "\n")

for (comm in unique(merged$commodity)) {
  d <- merged |>
    filter(commodity == comm, !is.na(disr_yoy), !is.na(abs_cv_yoy)) |>
    arrange(quarter_end)

  if (nrow(d) < 24) {
    cat("\nSkipping", comm, "— too few obs for rolling window\n")
    next
  }

  window <- 20  # 5 years of quarterly data
  rolling <- tibble()

  for (i in window:nrow(d)) {
    win_data <- d[(i - window + 1):i, ]
    fit_win  <- lm(abs_cv_yoy ~ disr_yoy, data = win_data)
    rolling <- bind_rows(rolling, tibble(
      quarter_end = d$quarter_end[i],
      slope       = coef(fit_win)[2],
      r2          = summary(fit_win)$r.squared
    ))
  }

  cat("\n──", toupper(comm), "── 5-year rolling window ──\n")
  cat("Slope range:", round(min(rolling$slope), 3), "to",
      round(max(rolling$slope), 3), "\n")
  cat("Slope mean:", round(mean(rolling$slope), 3),
      "± SD", round(sd(rolling$slope), 3), "\n")
  cat("R² range:", round(min(rolling$r2), 3), "to",
      round(max(rolling$r2), 3), "\n")
  cat("R² mean:", round(mean(rolling$r2), 3), "\n")

  # Check for trend in slope (quality degradation signal)
  rolling$t <- seq_len(nrow(rolling))
  trend_fit <- lm(slope ~ t, data = rolling)
  cat("Slope trend:", round(coef(trend_fit)[2], 5), "per quarter",
      "(p =", round(summary(trend_fit)$coefficients[2, 4], 4), ")\n")
}


# ── 8. Scatter plots ──────────────────────────────────────────────

cat("\n=== Generating diagnostic plots ===\n")

for (comm in unique(merged$commodity)) {
  d <- merged |>
    filter(commodity == comm, !is.na(disr_yoy), !is.na(abs_cv_yoy))
  if (nrow(d) < 10) next

  p <- ggplot(d, aes(x = disr_yoy, y = abs_cv_yoy)) +
    geom_point(alpha = 0.6, size = 2) +
    geom_smooth(method = "lm", se = TRUE, colour = "steelblue") +
    geom_abline(intercept = 0, slope = 1, linetype = "dashed", colour = "red") +
    labs(
      title = paste0(comm, ": DISR physical tonnes vs ABS chain-volume (YoY growth)"),
      subtitle = "Dashed red = perfect pass-through (slope=1, intercept=0)",
      x = "YoY Δlog(DISR physical tonnes)",
      y = "YoY Δlog(ABS chain-volume A$m)"
    ) +
    theme_minimal(base_size = 13)

  fname <- file.path(out_dir, paste0("scatter_yoy_", comm, ".png"))
  ggsave(fname, p, width = 8, height = 6, dpi = 150)
  cat("Saved:", fname, "\n")
}

# Time series overlay
for (comm in unique(merged$commodity)) {
  d <- merged |>
    filter(commodity == comm, !is.na(disr_yoy), !is.na(abs_cv_yoy)) |>
    select(quarter_end, disr_yoy, abs_cv_yoy) |>
    pivot_longer(-quarter_end, names_to = "series", values_to = "yoy") |>
    mutate(series = recode(series,
      disr_yoy = "DISR physical tonnes",
      abs_cv_yoy = "ABS chain-volume"
    ))

  p <- ggplot(d, aes(x = quarter_end, y = yoy, colour = series)) +
    geom_line(linewidth = 0.8) +
    geom_hline(yintercept = 0, linetype = "dotted") +
    labs(
      title = paste0(comm, ": YoY growth comparison"),
      x = NULL, y = "YoY Δlog", colour = NULL
    ) +
    theme_minimal(base_size = 13) +
    theme(legend.position = "bottom")

  fname <- file.path(out_dir, paste0("ts_yoy_", comm, ".png"))
  ggsave(fname, p, width = 10, height = 5, dpi = 150)
  cat("Saved:", fname, "\n")
}


# ── 9. Summary assessment ─────────────────────────────────────────

cat("\n", strrep("=", 60), "\n")
cat("SUMMARY ASSESSMENT\n")
cat(strrep("=", 60), "\n\n")

for (r in results) {
  cat(toupper(r$commodity), ":\n")
  cat("  Growth-rate R² =", round(r$r2, 3), "\n")
  cat("  Slope =", round(r$slope, 3), "(SE", round(r$slope_se, 3), ")\n")
  cat("  Slope = 1? p =", round(r$p_slope_eq_1, 3), "\n")
  cat("  Intercept =", round(r$intercept, 4), "(SE", round(r$intercept_se, 4), ")\n")
  cat("  Intercept = 0? p =", round(r$p_intercept_eq_0, 3), "\n")
  cat("  RMSE =", round(r$rmse, 4), "\n")

  if (r$r2 > 0.85 && r$p_slope_eq_1 > 0.05) {
    cat("  → PASS-THROUGH VIABLE: high R², slope ≈ 1\n")
  } else if (r$r2 > 0.70) {
    cat("  → BRIDGE VIABLE with price correction term\n")
  } else {
    cat("  → WEAK: may need constructed chain-volume (SITC 281 approach)\n")
  }
  cat("\n")
}

cat("Done. Plots saved to:", out_dir, "\n")
