#!/usr/bin/env Rscript
## Build the GitHub Pages landing page for resourcetracker.
##
## Reads the latest nowcast values + the per-spec OOS leaderboard from
## the freshly-deployed site dir and emits a polished index.html that
## doesn't look like raw rmarkdown.
##
## Usage:
##   Rscript scripts/build_index.R --site <dir> --today <yyyy-mm-dd> --repo <owner/name>

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(fs)
})

# ---- arg parsing ----
parse_args <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  out  <- list(site = NULL, today = NULL, repo = NULL, history = NULL)
  i <- 1
  while (i <= length(argv)) {
    key <- sub("^--", "", argv[i])
    val <- argv[i + 1]
    out[[key]] <- val
    i <- i + 2
  }
  if (is.null(out$site) || is.null(out$today) || is.null(out$repo)) {
    stop("usage: build_index.R --site <dir> --today <yyyy-mm-dd> --repo <owner/name> [--history <history.rds>]")
  }
  out
}
args <- parse_args()
site_dir <- args$site
today    <- args$today
repo     <- args$repo
history_rds <- args$history  # optional; path to mart_nowcast_history.rds

# ---- helpers ----
fmt_signed <- function(x, digits = 1) {
  if (!is.finite(x)) return("—")
  sign <- if (x >= 0) "+" else "−"
  paste0(sign, formatC(abs(x), digits = digits, format = "f"))
}
escape_html <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  x
}

# ---- data load ----
nc_path  <- path(site_dir, "data", "nowcast_current.csv")
cv_path  <- path(site_dir, "data", "nowcast_chain_vol.csv")
bd_path  <- path(site_dir, "data", "bridge_diagnostics.csv")
hist_dir <- path(site_dir, "history")

nc <- if (file_exists(nc_path)) {
  read_csv(nc_path, show_col_types = FALSE)
} else tibble::tibble()
cv <- if (file_exists(cv_path)) {
  read_csv(cv_path, show_col_types = FALSE)
} else tibble::tibble()
bd <- if (file_exists(bd_path)) {
  read_csv(bd_path, show_col_types = FALSE)
} else tibble::tibble()
history <- if (!is.null(history_rds) && file_exists(history_rds)) {
  tibble::as_tibble(readRDS(history_rds))
} else tibble::tibble()
csv_files <- if (dir_exists(path(site_dir, "data"))) {
  sort(path_file(dir_ls(path(site_dir, "data"), regexp = "\\.csv$")))
} else character()
hist_files <- if (dir_exists(hist_dir)) {
  sort(path_file(dir_ls(hist_dir, regexp = "\\.html$")), decreasing = TRUE)
} else character()

# ---- card HTML ----
commodity_label <- function(x) {
  switch(x,
         iron_ore     = "Iron ore",
         coal         = "Coal",
         coal_met     = "Metallurgical coal",
         coal_thermal = "Thermal coal",
         tools::toTitleCase(gsub("_", " ", x)))
}
# For each commodity in `nc`, find the most-recent prior run in
# `history` for the same quarter (strictly before this run) and return
# the delta (Mt + %). NA when no prior exists.
wow_delta <- function(nc_row, history) {
  if (nrow(history) == 0) {
    return(list(d_mt = NA_real_, d_pct = NA_real_, hours = NA_real_))
  }
  cur_ts <- as.POSIXct(nc_row$run_timestamp)
  prior <- history |>
    dplyr::mutate(
      run_timestamp = as.POSIXct(run_timestamp),
      quarter_end   = as.Date(quarter_end)
    ) |>
    dplyr::filter(commodity == nc_row$commodity,
                  quarter_end == as.Date(nc_row$quarter_end),
                  run_timestamp < cur_ts) |>
    dplyr::arrange(dplyr::desc(run_timestamp)) |>
    dplyr::slice(1)
  if (nrow(prior) == 0) {
    return(list(d_mt = NA_real_, d_pct = NA_real_, hours = NA_real_))
  }
  d  <- nc_row$point_estimate_Mt - prior$point_estimate
  list(
    d_mt  = d,
    d_pct = 100 * d / prior$point_estimate,
    hours = as.numeric(difftime(cur_ts, prior$run_timestamp, units = "hours"))
  )
}

# Cards show the current quarter (h = 0). When a Q+1 row exists for the
# same commodity, append its point estimate + Mt sub-line so the
# next-quarter outlook is visible without leaving the home page.
if (!"horizon" %in% names(nc)) nc$horizon <- 0L
nc_now <- dplyr::filter(nc, horizon == 0L)
nc_fwd <- dplyr::filter(nc, horizon == 1L)
history_h0 <- if (!is.null(history) && nrow(history) > 0 && "horizon" %in% names(history)) {
  dplyr::filter(history, horizon == 0L)
} else history

# ---- chain-volume cards (lead the page) ----
cv_label <- function(x) {
  x <- as.character(x)
  switch(x,
         iron_ore   = "Iron ore",
         coal_total = "Coal (total)",
         tools::toTitleCase(gsub("_", " ", x)))
}
fmt_am <- function(x) format(round(x), big.mark = ",")

cv_backcast_html <- if (nrow(cv) > 0) {
  bc <- dplyr::filter(cv, horizon < 0L) |>
    dplyr::mutate(commodity = factor(commodity,
                                     levels = c("iron_ore", "coal_total"))) |>
    dplyr::arrange(commodity, quarter_end)
  if (nrow(bc) > 0) {
    qtr_label <- format(as.Date(bc$quarter_end[1]), "%B %Y")
    cards <- vapply(seq_len(nrow(bc)), function(i) {
      r <- bc[i, ]
      g_pct <- 100 * (r$growth_factor - 1)
      g_class <- if (g_pct >  0.5) "up"
                 else if (g_pct < -0.5) "down"
                 else                   "flat"
      g_sign <- if (g_pct >= 0) "+" else "&minus;"
      sprintf(
        '<div class="headline-card"><span class="label">%s</span><div class="value-row"><span class="value">%s</span><span class="unit">A&#36;m</span></div><span class="ci">80%% CI &middot; %s &ndash; %s A&#36;m</span><span class="delta %s">%s%.1f%% YoY</span></div>',
        escape_html(cv_label(r$commodity)),
        fmt_am(r$point_estimate_Am),
        fmt_am(r$lower_80_Am), fmt_am(r$upper_80_Am),
        g_class, g_sign, abs(g_pct)
      )
    }, character(1))
    sprintf(
      paste0('<p class="kicker">Backcast for %s &mdash; ABS BoP not yet published</p>\n',
             '<div class="headline-grid">\n%s\n</div>\n'),
      qtr_label, paste(cards, collapse = "\n")
    )
  } else ""
} else ""

cv_forward_html <- if (nrow(cv) > 0) {
  fwd <- dplyr::filter(cv, horizon >= 0L) |>
    dplyr::mutate(commodity = factor(commodity,
                                     levels = c("iron_ore", "coal_total"))) |>
    dplyr::arrange(horizon, commodity)
  if (nrow(fwd) > 0) {
    cards <- vapply(seq_len(nrow(fwd)), function(i) {
      r <- fwd[i, ]
      type_lbl <- if (r$horizon == 0L) "nowcast" else "forecast"
      qlbl <- format(as.Date(r$quarter_end), "%b %Y")
      g_pct <- 100 * (r$growth_factor - 1)
      g_sign <- if (g_pct >= 0) "+" else "&minus;"
      sprintf(
        '<div class="headline-card"><span class="label">%s &middot; %s %s</span><div class="value-row"><span class="value">%s</span><span class="unit">A&#36;m</span></div><span class="ci">80%% CI &middot; %s &ndash; %s</span><span class="delta flat">%s%.1f%% YoY</span></div>',
        escape_html(cv_label(r$commodity)),
        qlbl, type_lbl,
        fmt_am(r$point_estimate_Am),
        fmt_am(r$lower_80_Am), fmt_am(r$upper_80_Am),
        g_sign, abs(g_pct)
      )
    }, character(1))
    paste0('<h2 style="margin-top:2.5rem">Looking ahead &mdash; chain-volume</h2>\n',
           '<div class="headline-grid">\n', paste(cards, collapse = "\n"),
           "\n</div>\n")
  } else ""
} else ""

# ---- physical-tonnage cards (secondary; existing behaviour) ----
cards_html <- if (nrow(nc_now) > 0) {
  cards <- vapply(seq_len(nrow(nc_now)), function(i) {
    r <- nc_now[i, ]
    d <- wow_delta(r, history_h0)
    delta_class <- if (is.na(d$d_mt))       "flat"
                   else if (d$d_mt >  0.05) "up"
                   else if (d$d_mt < -0.05) "down"
                   else                     "flat"
    delta_text <- if (is.na(d$d_mt)) {
      "First nowcast for this quarter"
    } else {
      sign_lbl  <- if (d$d_mt  >= 0) "+" else "−"
      sign_pct  <- if (d$d_pct >= 0) "+" else "−"
      hours_lbl <- if (d$hours < 36) sprintf("%.0fh ago", d$hours)
                   else sprintf("%.0f days ago", d$hours / 24)
      sprintf("%s%.1f Mt &middot; %s%.1f%% vs %s",
              sign_lbl, abs(d$d_mt), sign_pct, abs(d$d_pct), hours_lbl)
    }
    fwd_row <- dplyr::filter(nc_fwd, commodity == r$commodity)
    fwd_html <- if (nrow(fwd_row) == 1) {
      sprintf('<span class="ci" style="opacity:.7">Next quarter (%s): %.1f Mt &middot; 80%% CI %.1f &ndash; %.1f</span>',
              format(as.Date(fwd_row$quarter_end), "%b %Y"),
              fwd_row$point_estimate_Mt, fwd_row$lower_80, fwd_row$upper_80)
    } else ""
    sprintf(
      '<div class="headline-card"><span class="label">%s &middot; %s</span><div class="value-row"><span class="value">%.1f</span><span class="unit">Mt</span></div><span class="ci">80%% CI &middot; %.1f &ndash; %.1f Mt</span><span class="delta %s">%s</span><span class="ci" style="opacity:.7">%.0f%% of the quarter observed</span>%s</div>',
      escape_html(commodity_label(r$commodity)),
      format(as.Date(r$quarter_end), "%b %Y"),
      r$point_estimate_Mt, r$lower_80, r$upper_80,
      delta_class, delta_text,
      100 * r$share_observed,
      fwd_html
    )
  }, character(1))
  paste0('<div class="headline-grid">\n', paste(cards, collapse = "\n"),
         "\n</div>")
} else {
  '<div class="callout"><span class="label">Status</span> No nowcast produced this run.</div>'
}

# ---- production-pick summary ----
prod_summary <- if (nrow(bd) > 0 && "production_choice" %in% names(bd)) {
  rows <- bd |>
    mutate(production_choice = as.character(production_choice)) |>
    filter(production_choice %in% c("TRUE", "true")) |>
    transmute(
      commodity = vapply(commodity, commodity_label, character(1)),
      cell = sprintf(
        "<strong>%s</strong>: <code>%s</code> &middot; %.2f&times; naive RMSE",
        escape_html(commodity), escape_html(spec),
        as.numeric(ratio_vs_naive)
      )
    )
  if (nrow(rows) > 0) {
    paste0(
      '<div class="callout"><span class="label">Production model</span> ',
      paste(rows$cell, collapse = " &nbsp;·&nbsp; "),
      "</div>"
    )
  } else ""
} else ""

# ---- history rows ----
#
# Each archived report (under /history/YYYY-MM-DD.html) gets one row.
# When we have history data, we join in the iron-ore and coal nowcast
# values from the run closest to that date so the archive table is
# scan-able rather than a wall of "View report" links.
history_index <- if (nrow(history) > 0) {
  history |>
    dplyr::mutate(run_date = as.Date(as.POSIXct(run_timestamp))) |>
    dplyr::group_by(run_date, commodity) |>
    dplyr::summarise(point = dplyr::last(point_estimate),
                     .groups = "drop") |>
    tidyr::pivot_wider(names_from  = "commodity",
                       values_from = "point",
                       names_prefix = "v_")
} else tibble::tibble()

history_html <- if (length(hist_files) > 0) {
  header_cells <- paste(c(
    "<th>Date</th>",
    if ("v_iron_ore" %in% names(history_index)) "<th align=\"right\">Iron&nbsp;ore (Mt)</th>" else NULL,
    if ("v_coal"     %in% names(history_index)) "<th align=\"right\">Coal (Mt)</th>"          else NULL,
    "<th>Briefing</th>"
  ), collapse = "")
  rows <- vapply(hist_files, function(f) {
    dt_str <- sub("\\.html$", "", f)
    dt <- tryCatch(as.Date(dt_str), error = function(e) NA)
    label <- if (!is.na(dt)) format(dt, "%e %B %Y") else dt_str
    iron_cell <- ""
    coal_cell <- ""
    if (!is.na(dt) && nrow(history_index) > 0) {
      h <- dplyr::filter(history_index, run_date == dt)
      if (nrow(h) > 0) {
        if ("v_iron_ore" %in% names(history_index)) {
          v <- h$v_iron_ore[1]
          iron_cell <- sprintf('<td align="right">%s</td>',
                                if (is.finite(v)) sprintf("%.1f", v) else "—")
        }
        if ("v_coal" %in% names(history_index)) {
          v <- h$v_coal[1]
          coal_cell <- sprintf('<td align="right">%s</td>',
                                if (is.finite(v)) sprintf("%.1f", v) else "—")
        }
      } else {
        if ("v_iron_ore" %in% names(history_index)) iron_cell <- '<td align="right">—</td>'
        if ("v_coal"     %in% names(history_index)) coal_cell <- '<td align="right">—</td>'
      }
    }
    sprintf('<tr><td>%s</td>%s%s<td><a href="history/%s">View report &rarr;</a></td></tr>',
            escape_html(label), iron_cell, coal_cell, escape_html(f))
  }, character(1))
  paste0(
    '<table class="history-table"><thead><tr>',
    header_cells,
    '</tr></thead><tbody>',
    paste(rows, collapse = ""),
    "</tbody></table>"
  )
} else {
  "<p>No prior reports yet.</p>"
}

# ---- outputs.json (programmatic feed) -----------------------------------
#
# Compact JSON summary so other systems / dashboards / scripts can
# consume the nowcast without parsing CSVs. Stable schema, versioned via
# `schema` field so consumers can guard against future shape changes.
production_picks <- if (nrow(bd) > 0 && "production_choice" %in% names(bd)) {
  bd |>
    mutate(production_choice = as.character(production_choice)) |>
    filter(production_choice %in% c("TRUE", "true"))
} else tibble::tibble()
oj_row <- function(r) {
  pp <- dplyr::filter(production_picks, commodity == r$commodity)
  list(
    point_mt        = unname(r$point_estimate_Mt),
    lower_80        = unname(r$lower_80),
    upper_80        = unname(r$upper_80),
    lower_95        = unname(r$lower_95),
    upper_95        = unname(r$upper_95),
    share_observed  = unname(r$share_observed),
    production_spec = if (nrow(pp) == 1L) pp$spec[1] else NA_character_,
    rmse_vs_naive   = if (nrow(pp) == 1L) round(as.numeric(pp$ratio_vs_naive[1]), 3) else NA_real_
  )
}
horizons_json <- list()
if (nrow(nc_now) > 0) {
  horizons_json$current <- list(
    quarter_end = format(as.Date(nc_now$quarter_end[1]), "%Y-%m-%d"),
    commodities = stats::setNames(
      lapply(seq_len(nrow(nc_now)), function(i) oj_row(nc_now[i, ])),
      nc_now$commodity
    )
  )
}
if (nrow(nc_fwd) > 0) {
  horizons_json$next_quarter <- list(
    quarter_end = format(as.Date(nc_fwd$quarter_end[1]), "%Y-%m-%d"),
    commodities = stats::setNames(
      lapply(seq_len(nrow(nc_fwd)), function(i) oj_row(nc_fwd[i, ])),
      nc_fwd$commodity
    )
  )
}
outputs_json <- list(
  schema      = "resourcetracker.outputs.v1",
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  run_timestamp = if (nrow(nc) > 0) format(as.POSIXct(nc$run_timestamp[1]),
                                            "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
                   else NA_character_,
  horizons    = horizons_json
)
writeLines(jsonlite::toJSON(outputs_json, auto_unbox = TRUE, pretty = TRUE,
                             na = "null"),
           path(site_dir, "data", "outputs.json"))

# ---- CSV downloads ----
csv_list_html <- if (length(csv_files) > 0) {
  items <- vapply(csv_files, function(f) {
    sprintf('<li><a href="data/%s">%s</a></li>',
            escape_html(f), escape_html(f))
  }, character(1))
  paste0('<ul class="downloads">', paste(items, collapse = ""), "</ul>")
} else "<p>—</p>"

# ---- page ----
title <- "Australian Resource Export Volumes"
tagline <- "Weekly chain-volume backcast and physical-tonnage nowcast of Australian iron-ore and coal exports, built from IMF PortWatch AIS shipping data."
nice_date <- format(as.Date(today), "%e %B %Y")

html <- sprintf('<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>resourcetracker &middot; weekly nowcast</title>
<meta name="description" content="%s">
<link rel="stylesheet" href="style.css">
<link rel="canonical" href="https://%s.github.io/%s/">
</head>
<body>
<main>
  <header class="hero">
    <p class="kicker">resourcetracker &middot; updated %s</p>
    <h1>%s</h1>
    <p class="lede">%s</p>
    <p><a href="latest.html">Read the full briefing &rarr;</a></p>
  </header>

  %s

  %s

  <h2 style="margin-top:2.5rem">Physical tonnage nowcasts</h2>
  %s

  %s

  <h2>Report archive</h2>
  %s

  <h2>Raw data</h2>
  <p>Underlying series from this week\'s run, as CSV:</p>
  %s

  <h2>About</h2>
  <p>resourcetracker is a quarterly nowcast for Australian iron-ore and coal exports, built from IMF PortWatch AIS shipping data and the DISR Resources &amp; Energy Quarterly historical data release. Per-commodity bridge regressions are refit weekly against the most recent available data; uncertainty bands shrink as the current quarter is observed.</p>
  <p>Full methodology: <a href="https://github.com/%s/blob/main/docs/METHODOLOGY.md">METHODOLOGY.md</a>. Source code: <a href="https://github.com/%s">%s</a>. Live state branch: <a href="https://github.com/%s/tree/data">data</a>.</p>

  <footer class="site-footer">
    <span>Site rendered %s UTC by the weekly Actions workflow.</span>
    <span><a href="https://github.com/%s/actions/workflows/weekly.yml">View latest run</a></span>
  </footer>
</main>
</body>
</html>
',
  escape_html(tagline),
  tolower(strsplit(repo, "/", fixed = TRUE)[[1]][1]),
  strsplit(repo, "/", fixed = TRUE)[[1]][2],
  nice_date,
  escape_html(title),
  escape_html(tagline),
  cv_backcast_html,
  cv_forward_html,
  cards_html,
  prod_summary,
  history_html,
  csv_list_html,
  repo, repo, repo, repo,
  today, repo
)

writeLines(html, path(site_dir, "index.html"))
cat("wrote ", path(site_dir, "index.html"), "\n", sep = "")
