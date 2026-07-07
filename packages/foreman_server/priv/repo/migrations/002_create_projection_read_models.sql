CREATE TABLE IF NOT EXISTS foreman_project_projections (
  project_id TEXT PRIMARY KEY,
  status TEXT,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_event_id TEXT REFERENCES foreman_events(event_id)
);

CREATE TABLE IF NOT EXISTS foreman_task_projections (
  task_id TEXT PRIMARY KEY,
  project_id TEXT,
  status TEXT,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_event_id TEXT REFERENCES foreman_events(event_id)
);

CREATE TABLE IF NOT EXISTS foreman_run_projections (
  run_id TEXT PRIMARY KEY,
  task_id TEXT,
  status TEXT,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_event_id TEXT REFERENCES foreman_events(event_id)
);

CREATE TABLE IF NOT EXISTS foreman_inbox_message_projections (
  message_id TEXT PRIMARY KEY,
  run_id TEXT,
  task_id TEXT,
  project_id TEXT,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_event_id TEXT REFERENCES foreman_events(event_id)
);

CREATE INDEX IF NOT EXISTS foreman_project_projections_status_idx
  ON foreman_project_projections (status);
CREATE INDEX IF NOT EXISTS foreman_task_projections_project_status_idx
  ON foreman_task_projections (project_id, status);
CREATE INDEX IF NOT EXISTS foreman_run_projections_task_status_idx
  ON foreman_run_projections (task_id, status);
CREATE INDEX IF NOT EXISTS foreman_inbox_message_projections_run_idx
  ON foreman_inbox_message_projections (run_id);
CREATE INDEX IF NOT EXISTS foreman_inbox_message_projections_project_idx
  ON foreman_inbox_message_projections (project_id);
