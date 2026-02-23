-- Plex PostgreSQL initialization
-- This runs automatically on first container start

-- Extension for UUID support (useful for future tooling)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- A simple health / metadata table so other services can verify DB is ready
CREATE TABLE IF NOT EXISTS plex_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO plex_meta (key, value)
VALUES ('schema_version', '1')
ON CONFLICT (key) DO NOTHING;

-- Grant full privileges to the application user
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO plexuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO plexuser;
