CREATE TABLE IF NOT EXISTS foreman_events (
  event_id TEXT PRIMARY KEY,
  stream_id TEXT NOT NULL,
  stream_version BIGINT NOT NULL CHECK (stream_version > 0),
  event_type TEXT NOT NULL,
  schema_version INTEGER NOT NULL CHECK (schema_version > 0),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  correlation_id TEXT NOT NULL,
  causation_id TEXT,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (stream_id, stream_version)
);

CREATE INDEX IF NOT EXISTS foreman_events_stream_idx
  ON foreman_events (stream_id, stream_version);

CREATE INDEX IF NOT EXISTS foreman_events_type_idx
  ON foreman_events (event_type, occurred_at);

CREATE INDEX IF NOT EXISTS foreman_events_correlation_idx
  ON foreman_events (correlation_id);

CREATE UNIQUE INDEX IF NOT EXISTS foreman_events_idempotency_idx
  ON foreman_events (stream_id, (metadata ->> 'idempotency_key'))
  WHERE metadata ? 'idempotency_key';

CREATE TABLE IF NOT EXISTS foreman_projection_checkpoints (
  projection_name TEXT PRIMARY KEY,
  last_event_id TEXT REFERENCES foreman_events(event_id),
  last_stream_version BIGINT NOT NULL DEFAULT 0 CHECK (last_stream_version >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  rebuild_started_at TIMESTAMPTZ
);
