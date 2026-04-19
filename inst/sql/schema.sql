-- resourcetracker DuckDB schema (Phase 1)
-- Idempotent: re-running warehouse_init_schema() is safe.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS mart;

-- Raw layer: landing tables for each external source ----------------------

CREATE TABLE IF NOT EXISTS raw.portwatch_tonnage_daily (
  obs_date      DATE      NOT NULL,
  port_id       VARCHAR   NOT NULL,
  commodity     VARCHAR   NOT NULL,
  tonnage       DOUBLE,
  vessel_count  INTEGER,
  ingested_at   TIMESTAMP NOT NULL,
  PRIMARY KEY (obs_date, port_id, commodity)
);

CREATE TABLE IF NOT EXISTS raw.abs_5368_monthly (
  month_end     DATE      NOT NULL,
  series_id     VARCHAR   NOT NULL,
  sitc          VARCHAR,
  value_aud_m   DOUBLE,
  ingested_at   TIMESTAMP NOT NULL,
  PRIMARY KEY (month_end, series_id)
);

CREATE TABLE IF NOT EXISTS raw.abs_5302_quarterly (
  quarter_end              DATE      NOT NULL,
  series_id                VARCHAR   NOT NULL,
  value_current_aud_m      DOUBLE,
  value_chainvol_aud_m     DOUBLE,
  ingested_at              TIMESTAMP NOT NULL,
  PRIMARY KEY (quarter_end, series_id)
);

CREATE TABLE IF NOT EXISTS raw.fred_prices_daily (
  obs_date      DATE      NOT NULL,
  series_id     VARCHAR   NOT NULL,
  value         DOUBLE,
  ingested_at   TIMESTAMP NOT NULL,
  PRIMARY KEY (obs_date, series_id)
);

-- Mart layer: curated dimensions and metadata -----------------------------

CREATE TABLE IF NOT EXISTS mart.dim_port (
  port_id          VARCHAR PRIMARY KEY,
  port_name        VARCHAR,
  iso3             VARCHAR,
  lat              DOUBLE,
  lon              DOUBLE,
  commodity_class  VARCHAR,
  sitc_map         VARCHAR
);

CREATE TABLE IF NOT EXISTS mart.crosswalk_sitc (
  commodity    VARCHAR NOT NULL,
  sitc         VARCHAR NOT NULL,
  is_primary   BOOLEAN NOT NULL,  -- first-listed SITC per commodity
  notes        VARCHAR,
  PRIMARY KEY (commodity, sitc)
);

CREATE TABLE IF NOT EXISTS mart.latest_anomalies (
  obs_date    DATE      NOT NULL,
  port_id     VARCHAR   NOT NULL,
  commodity   VARCHAR   NOT NULL,
  tonnage     DOUBLE,
  expected    DOUBLE,
  sd          DOUBLE,
  z_score     DOUBLE,
  detected_at TIMESTAMP NOT NULL,
  PRIMARY KEY (obs_date, port_id, commodity)
);

CREATE TABLE IF NOT EXISTS mart.nowcast_history (
  run_timestamp   TIMESTAMP NOT NULL,
  quarter_end     DATE      NOT NULL,
  point_estimate  DOUBLE,
  lower_80        DOUBLE,
  upper_80        DOUBLE,
  lower_95        DOUBLE,
  upper_95        DOUBLE,
  share_observed  DOUBLE,
  PRIMARY KEY (run_timestamp, quarter_end)
);

CREATE TABLE IF NOT EXISTS mart.ingest_runs (
  run_id         VARCHAR PRIMARY KEY,
  source         VARCHAR   NOT NULL,
  started_at     TIMESTAMP NOT NULL,
  finished_at    TIMESTAMP,
  rows_written   INTEGER,
  status         VARCHAR   NOT NULL,  -- 'ok' | 'error' | 'cached'
  error_message  VARCHAR
);
