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
bd_path  <- path(site_dir, "data", "bridge_diagnostics.csv")
hist_dir <- path(site_dir, "history")

nc <- if (file_exists(nc_path)) {
  read_csv(nc_path, show_col_types = FALSE)
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

cards_html <- if (nrow(nc) > 0) {
  cards <- vapply(seq_len(nrow(nc)), function(i) {
    r <- nc[i, ]
    d <- wow_delta(r, history)
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
    sprintf(
      '<div class="headline-card"><span class="label">%s &middot; %s</span><div class="value-row"><span class="value">%.1f</span><span class="unit">Mt</span></div><span class="ci">80%% CI &middot; %.1f &ndash; %.1f Mt</span><span class="delta %s">%s</span><span class="ci" style="opacity:.7">%.0f%% of the quarter observed</span></div>',
      escape_html(commodity_label(r$commodity)),
      format(as.Date(r$quarter_end), "%b %Y"),
      r$point_estimate_Mt, r$lower_80, r$upper_80,
      delta_class, delta_text,
      100 * r$share_observed
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
tagline <- "Weekly nowcast of Australian iron-ore and coal physical-tonnage exports from IMF PortWatch AIS shipping data."
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
  cards_html,
  prod_summary,
  history_html,
  csv_list_html,
  repo, repo, repo, repo,
  today, repo
)

writeLines(html, path(site_dir, "index.html"))
cat("wrote ", path(site_dir, "index.html"), "\n", sep = "")
