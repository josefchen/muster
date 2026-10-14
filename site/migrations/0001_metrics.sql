CREATE TABLE IF NOT EXISTS daily_events (
  day TEXT NOT NULL,
  channel TEXT NOT NULL,
  page TEXT NOT NULL,
  event TEXT NOT NULL,
  total INTEGER NOT NULL DEFAULT 0 CHECK(total >= 0),
  PRIMARY KEY (day, channel, page, event)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS public_stats (
  key TEXT PRIMARY KEY,
  value INTEGER NOT NULL,
  updated_at TEXT NOT NULL
) WITHOUT ROWID;
