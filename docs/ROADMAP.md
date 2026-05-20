# Roadmap

Living document of follow-up work, ordered by ROI. Tiers 1 and 2 from
the 2026-05-20 review have shipped (see commit history). Tiers 3 and 4
are open — pick what's interesting.

## Tier 3 — operational hardening

Worth doing before any production-critical reliance on the weekly cron.

### `renv` lockfile

Currently `r-lib/actions/setup-r-dependencies` resolves to whatever
versions are current on CRAN at run time. A transient package-side
change (a `dplyr` API rename, a `httr2` retry-behaviour fix that
changes our retry semantics) could break the Tuesday run with no
local-dev warning.

Fix: `renv::init()` in the repo, commit `renv.lock`, change the
workflow to use `r-lib/actions/setup-renv@v2` instead of
`setup-r-dependencies@v2`.

Effort: ~1 hour. Adds about 100 KB of lockfile to the repo.

### Graduated staleness warning

`Rscript run.R --ci` currently fails *only* when every external fetch
landed on stale cache. A more useful signal: open a *soft* "investigate"
issue when any one source has been stale for >7 days but the run still
completes. Catches degradation before a hard failure on Tuesday morning.

Implementation: extend the `--ci` block in `run.R` to inspect
`mart_ingest_runs` rows older than 7 days; if the latest `status` per
source is `"cached"` or `"error"` and we haven't seen `"ok"` in that
window, exit code 0 but write a structured `WARN` line that the
workflow picks up (separate label from `weekly-failure`).

Effort: ~2 hours.

### `R CMD check` in CI

Currently never run in the workflow. A package-level lint (NOTEs,
WARNINGs from `R CMD check`) might be lurking. Adding a check step
to the workflow gates regressions.

Pre-req: needs `renv.lock` so the check environment is stable.

Effort: ~1 hour after renv is in.

## Tier 4 — bigger / more interesting

Ordered by potential headline impact.

### External demand signal (highest expected payoff)

Forecast-combination gains are largest when candidate models use
*different information*. Our current bench has three candidates all
driven by the same PortWatch tonnage signal — averaging them just
denoises within the same information set. A genuinely external demand
indicator would diversify and start delivering Stock-Watson gains.

Candidates worth piloting:

- **China crude steel production** (monthly, lagged ~3 weeks): the
  dominant iron-ore demand signal. Available via NBS / S&P Platts.
- **Baltic Dry Index** (daily, real-time): a price-side indicator for
  bulk-carrier demand. Especially useful when shipping freight is
  pricing in commodity-demand shifts ahead of physical flow.
- **China power generation index** (monthly): the dominant thermal coal
  demand signal.

Architecture: new candidate spec slots into `cfg$bridge$candidates`,
no other plumbing changes. The existing bench + combination + production
selection handles the rest.

Effort: ~1 day per indicator (new ingest source, spec wiring,
backtest, deployment). Recommend piloting one (China steel for iron-
ore) before adding more.

### LNG re-scope

Currently dropped (2026-04-21) because PortWatch tanker tonnage has
near-zero correlation with ABS LNG volumes at quarterly grain.
Australian LNG is contract-dominated — vessels arrive on schedule
regardless of spot-price dynamics, so tonnage is an output of contracts
rather than an indicator of them.

But: AIS *destinations* encode the contract structure implicitly. A
spec that models LNG via destination-share (% of tanker tonnage to
Japan / Korea / China each quarter) might pick up signal the
aggregate-tonnage version missed.

Effort: ~2 days research. Could quickly turn into a multi-week project
if destinations require their own data-cleaning step.

### One-quarter-ahead forecast

The bridge regressions support multi-step forecasts without
recursion: Q+1's `log_volume_lag4` is Q-3's *observed* volume, which is
always known. Currently we only publish the current-quarter nowcast;
could also publish a next-quarter forecast.

Practical question: how informative is the Q+1 forecast vs. just
extrapolating the seasonal pattern? Easy backtest answer.

Effort: ~half day. Add a Q+1 column to the headline cards if it has
skill; drop if it's no better than the naive Q+1 = Q-3 seasonal.

### `outputs.json` endpoint

Currently consumers must parse the CSVs. A tiny JSON endpoint at the
deployed Pages site (`/outputs.json`) would let other dashboards / Slack
bots / personal scripts consume the nowcast programmatically.

Schema (suggested):
```json
{
  "as_of": "2026-05-20",
  "quarter_end": "2026-06-30",
  "share_observed": 0.54,
  "commodities": {
    "iron_ore": {"point_mt": 234.9, "lower_80": 231.2, "upper_80": 237.9,
                 "production_spec": "bojo", "rmse_vs_naive": 0.78},
    "coal":     {"point_mt": 87.9,  "lower_80": 86.5,  "upper_80": 89.9,
                 "production_spec": "aggregate", "rmse_vs_naive": 0.50}
  }
}
```

Add the JSON emission to `scripts/build_index.R` (it already has all
the source data in scope).

Effort: ~30 minutes.

## Anti-list — things I'd recommend NOT doing

Documenting these so they don't quietly bubble up as "we should also…"
items in the future:

- **Don't redesign the Pages site again.** It's done; the design
  system is the current source of truth for the look. Subsequent
  changes should fit *into* the existing tokens (colours, spacing,
  components), not invent new ones.
- **Don't add ML / neural-net candidates.** At N ≈ 23 training
  quarters, anything more complex than the current linear bench will
  overfit. The combination bench already gives us the diversity the
  data can support.
- **Don't migrate the warehouse to DuckDB / Postgres.** The rds +
  `data` branch pattern is genuinely well-suited to this dataset
  size. The constraint that originally pushed away from DuckDB (work-
  laptop allowlist) is still real.
- **Don't add more candidate specs unless they bring new
  information.** A fourth variant on the same PortWatch signal
  (e.g. an Almon-polynomial MIDAS) won't help; an indicator from a
  different data source (Tier 4 #1) will.

## Maintenance

This file is hand-maintained. Mark items as done by moving them under a
"Completed" section at the bottom with a date, or by deleting them and
adding a one-liner to the relevant commit message.
