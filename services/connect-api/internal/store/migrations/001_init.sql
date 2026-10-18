-- MyBuddy Connect schema v1. Metadata only: no screen, audio, clipboard, files,
-- notifications, transcripts or AI content is ever stored.

CREATE TABLE devices (
    id           TEXT PRIMARY KEY CHECK (id ~ '^[0-9a-f]{32}$'),
    public_key   BYTEA NOT NULL CHECK (length(public_key) BETWEEN 60 AND 200),
    platform     TEXT NOT NULL CHECK (platform IN ('android', 'macos')),
    created_at   TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE auth_challenges (
    id         TEXT PRIMARY KEY,
    device_id  TEXT NOT NULL,
    nonce      BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX auth_challenges_expires_idx ON auth_challenges (expires_at);

CREATE TABLE auth_tokens (
    token_hash BYTEA PRIMARY KEY CHECK (length(token_hash) = 32),
    device_id  TEXT NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX auth_tokens_expires_idx ON auth_tokens (expires_at);

CREATE TABLE pairings (
    id                   TEXT PRIMARY KEY,
    host_device_id       TEXT NOT NULL REFERENCES devices (id),
    client_device_id     TEXT NOT NULL REFERENCES devices (id),
    statement_created_at TEXT NOT NULL,
    registered_at        TIMESTAMPTZ NOT NULL,
    revoked_at           TIMESTAMPTZ,
    revoked_by           TEXT,
    CHECK (host_device_id <> client_device_id)
);
CREATE UNIQUE INDEX pairings_active_unique ON pairings (host_device_id, client_device_id) WHERE revoked_at IS NULL;
CREATE INDEX pairings_client_idx ON pairings (client_device_id);

CREATE TABLE audit_events (
    id             BIGSERIAL PRIMARY KEY,
    at             TIMESTAMPTZ NOT NULL,
    kind           TEXT NOT NULL,
    device_id      TEXT NOT NULL,
    peer_device_id TEXT NOT NULL DEFAULT ''
);
CREATE INDEX audit_events_device_idx ON audit_events (device_id, at DESC);
CREATE INDEX audit_events_at_idx ON audit_events (at);
