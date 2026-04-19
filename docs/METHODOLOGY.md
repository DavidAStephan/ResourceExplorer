# Methodology

This document is the econometric writeup for `resourcetracker`. If
you're reading source to understand a modelling choice, start here.

## 1. Goal

Nowcast Australian **quarterly real goods exports** — specifically
the chain-volume *goods credits* series from ABS 5302.0 (Balance of
Payments) — using higher-frequency indicators that land before the
BoP release.

The headline success metric is RMSE ≥ 30% below a seasonal-random-walk
benchmark on 2024+ out-of-sample quarters.

## 2. Data

| Source | Series | Frequency | Role |
|---|---|---|---|
| IMF PortWatch | AUS port tonnage by commodity | Daily | RHS of bridge — leading indicator |
| ABS 5368.0 (ITG, Tables 12a/12b) | FOB exports by SITC 3-digit | Monthly | LHS of bridge |
| ABS 5302.0 (BoP, Tables 1–2) | Goods credits: current + chain-volume | Quarterly | **Nowcast target** |
| FRED | `PIORECRUSDM`, `PCOALAUUSDM`, `PNGASJPUSDM` | Monthly | RHS of bridge (price) |

The PortWatch daily panel is aggregated to monthly per commodity via
`ports_metadata.csv`, which maps port_id → commodity bucket. The SITC
crosswalk (`inst/extdata/sitc_crosswalk.csv`) maps the commodity
bucket to one or more 3-digit SITC codes used to slice 5368.0.

**Commodity scope (MVP):** iron_ore (SITC 281), coal (SITC 321+322),
lng (SITC 343 — caveat: includes non-LNG natural gas; LNG dominates
Australian 343 exports), and "other" as the residual.

## 3. Seasonal adjustment

- **LHS (ABS 5368.0).** Use ABS's own seasonally-adjusted series
  where published. Re-adjusting introduces unnecessary degrees of
  freedom variance.
- **RHS (PortWatch tonnage).** Raw daily panel aggregated to monthly
  then X-13-ARIMA-SEATS via `{seasonal}`. Falls back to the raw
  series when < 36 monthly observations are available, or when X-13
  errors (rare — logged as a warning).
- **RHS (FRED prices).** No seasonal adjustment — commodity prices
  don't carry a strong calendar-month pattern at this grain.

## 4. Bridge specification

For each commodity `c` in `{iron_ore, coal, lng}`, monthly frequency `m`:

$$
\log y_{c,m}
  \;=\; \beta_0
  \;+\; \beta_1 \log T^{\text{SA}}_{c,m}
  \;+\; \beta_2 \log P_{c,m}
  \;+\; \beta_3 \log y_{c,m-1}
  \;+\; \varepsilon_{c,m}
$$

- $y_{c,m}$ — ABS 5368.0 monthly FOB exports for commodity `c`'s
  SITC basket (sum across the commodity's SITC rows).
- $T^{\text{SA}}_{c,m}$ — X-13-adjusted monthly tonnage from
  PortWatch, aggregated across the commodity's ports.
- $P_{c,m}$ — monthly FRED commodity price.
- $\varepsilon_{c,m}$ — i.i.d.-in-bootstrap residual.

**Why log-levels rather than first-differences.** Australian
commodity values carry persistent level shifts (the 2020–22 iron-ore
cycle, the 2022 LNG shock) that first-differencing throws away. Log
on both sides gives additive decomposition into price and quantity
contributions; `β₁` reads as a tonnage-to-value elasticity. We accept
the resulting serial correlation and handle it two ways:

1. The AR(1) lag on `log y` absorbs most persistence in the
   conditional-mean fit.
2. Standard errors are Newey-West / HAC with `lag = 3` via
   `sandwich::NeweyWest()`.

**Why AR(1) and not richer dynamics.** With ~60 monthly training
observations per commodity, the parameter budget is tight. One lag
captures the bulk of the persistence and doubles as the bridge
mechanism at nowcast time — partial-month tonnage observations
propagate forward through `log_y_lag1`. Adding more lags or
cross-commodity regressors is a flagged Phase-5+ extension.

**"Other" bucket.** Not fit as a structural bridge. Constructed as
the residual

$$y_\text{other} = y_\text{total} - (y_\text{iron\_ore} + y_\text{coal} + y_\text{lng})$$

and regressed on total AUS monthly tonnage plus a trade-weighted
commodity price index (2019–2023 value-share weights).

## 5. Chain-volume conversion

5302.0 publishes both current-price and chain-volume goods credits.
We define the quarterly implicit deflator

$$D_Q \;=\; \frac{\text{current}_Q}{\text{chainvol}_Q}$$

and apply it to bridge-based current-price predictions:

$$\hat y^{\text{real}}_Q \;=\; \hat y^{\text{curr}}_Q \;/\; \hat D_Q$$

At nowcast time `D_Q` for the current quarter is unobservable; we use
the trailing 4-quarter mean as the forecast deflator. This reflects
the production constraint (same-quarter deflator lands with the BoP
release) and is the dominant source of error left in the fully-
observed case.

## 6. Running nowcast — partial-quarter logic

Given current date $t$ in quarter $Q$ with months $m_1, m_2, m_3$:

- **Completed months within Q** (`month_end < t`): use observed
  PortWatch monthly tonnage directly.
- **Current month** (contains `t`): scale partial-month observed
  tonnage by the commodity's **2019–23 day-of-month cumulative
  share**. If through day `d` the training panel saw share `s(d)` of
  the typical month's tonnage, then $\hat T = T^{\text{obs}} / s(d)$.
  A floor of 0.05 avoids blow-up on day 1.
- **Future months within Q**: use `seasonal_avg × pace`, where
  `pace` is the last completed month's tonnage over its own seasonal
  avg. A pickup in recent pace carries forward.

The three monthly hatted tonnages enter `predict_bridge()` which
runs the AR(1) lag recursively — month 2's lag is month 1's
prediction, etc.

## 7. Uncertainty bands

Per-commodity residual bootstrap, $B = 1{,}000$ draws:

1. For each draw `b` and commodity `c`, sample three residuals
   $\hat\varepsilon^{(b)}_{c,m}$ from the in-sample residual vector
   (with replacement).
2. Scale each by $\sqrt{1 - s_Q}$ where $s_Q$ is the share of the
   quarter observed. When $s_Q = 1$, residual variance collapses —
   only chain-volume-deflator error remains.
3. Inject the perturbed residual into the recursive forecast: each
   month's prediction = deterministic mean + scaled residual, then
   that value becomes month+1's lag. This is the **correct**
   propagation of uncertainty through the AR(1) — not a static
   add-to-point-estimate.
4. Sum across commodities → quarterly current-price total.
5. Chain-volume convert to real quarterly.

The `B` real-terms draws form the empirical distribution; we report
the 10/90th percentiles as the 80% band and the 2.5/97.5th as 95%.

**Per-commodity independent** draws (MVP choice). Joint draws across
commodities would capture "iron ore + coal both up on China stimulus"
correlation and can tighten bands when cross-commodity correlation is
positive. Flagged as a post-MVP polish item.

## 8. Backtest

- **Train window start:** 2019-01-01.
- **Validation:** quarters from 2024-01-01 forward.
- **Scheme:** expanding window. At each validation quarter `Q`,
  refit all bridges on data through end-of-previous-quarter
  (`floor_date(Q, "quarter") - 1`), run the full nowcast pipeline
  treating `Q` as the current quarter, compare to 5302.0 actual.
- **Benchmark:** seasonal random walk at quarterly grain,
  $\hat y_Q = y_{Q-4}$, applied directly on the 5302.0 chain-volume
  series.

RMSE is computed both unconditionally and ratioed against the
benchmark. The "ratio vs naive" column in `bridge_diagnostics.csv` is
the headline skill metric; a value of 0.70 hits the brief's target.

## 9. Anomaly detection (briefing only)

For each (port, commodity): compute a seasonal daily norm by pooling
training-window observations over a ±7-day window around each day of
year. Z-score the last 28 observed days; flag `|z| > 2`. Surfaces in
the briefing as "departures from seasonal norm".

## 10. Limitations and known sources of error

1. **LNG = SITC 343 proxy.** SITC 343 includes non-LNG natural gas;
   LNG dominates the Australian share, but shifts in pipeline gas
   exports could bias the bridge. Phase-next: upgrade to HS 2711.11
   from the ABS Data Explorer.
2. **"Other" bucket uses total PortWatch tonnage as a proxy for the
   non-named commodity tonnage.** Fine when named commodities are
   well-identified, brittle when port-commodity mapping drifts.
3. **Coal thermal/metallurgical combined.** Different price drivers.
   Split if residuals warrant.
4. **Deflator forecast = trailing 4-quarter mean.** Adequate in
   stable regimes; mis-specifies during rapid terms-of-trade swings
   (e.g. H2-2022 LNG).
5. **Bootstrap independence assumption.** Conservative (wider bands)
   when cross-commodity residuals are correlated.
6. **Structural-break stability** not formally tested. A
   `strucchange::Fstats()` pass per commodity would highlight
   regime-sensitive β's; left for a follow-up.

## 11. Reproducibility

`cfg$nowcast$seed` (default `20260419`) controls bootstrap draws.
Fixed seed means identical bands across runs given identical inputs.
`renv.lock` pins all R package versions. The pipeline writes every
external fetch to `mart.ingest_runs` with `{run_id, started_at,
finished_at, rows_written, status}` for an after-the-fact audit
trail.
