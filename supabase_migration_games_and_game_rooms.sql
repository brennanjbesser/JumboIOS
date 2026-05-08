-- =====================================================================
-- supabase_migration_games_and_game_rooms.sql
-- =====================================================================
-- Phase 5 backend foundation. Adds the canonical schema for real
-- scheduled sporting events and the per-game chat rooms that hang off
-- them. After this migration:
--
--   • public.games       — one row per real scheduled game instance,
--                          keyed off the upstream provider's game id.
--                          Drives LIVE NOW / COMING UP on the LIVE page
--                          once the iOS client is rewired to read from
--                          Supabase instead of the in-memory mock
--                          provider (LiveScoreProvider.swift).
--
--   • public.game_rooms  — 1:1 with games. Holds the chat-room id that
--                          posts.room_id will eventually reference, plus
--                          lifecycle timestamps (opens_at / closes_at).
--                          Replaces today's team-pair-keyed
--                          ChatRoom.game(home, away) UUIDs, which
--                          collapse every meeting between the same two
--                          teams across a season into a single chat —
--                          fine for mocks, broken for a real schedule.
--
-- This migration intentionally:
--   • does NOT alter public.posts or any existing ChatRoom logic
--   • does NOT FK home_team_id / away_team_id to public.teams (no such
--     table exists yet — teams still live in TeamData.swift)
--   • does NOT seed any games (no Sports API connection yet)
--   • does NOT change client-side enums or models
--
-- ⚠️ AUTH-NOT-YET-WIRED — TIGHTEN RLS WHEN AUTH LANDS:
-- Both tables ship with TEMP_ permissive policies for dev (SELECT for
-- anon + authenticated; INSERT/UPDATE for the same so SQL-editor
-- seeding works without the service-role key). Production must replace
-- these with read-only policies for clients (writes flow through the
-- ingest worker using the service-role key, which bypasses RLS).
-- See the "RLS POLICIES" section near the bottom for replacement
-- instructions and policy names to drop.
--
-- Replayable: every CREATE uses IF NOT EXISTS where supported, every
-- DROP POLICY uses IF EXISTS, and every CREATE POLICY runs after its
-- DROP. The migration can be run repeatedly without error.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Reusable updated_at trigger function
-- ---------------------------------------------------------------------
-- The existing schema (supabase_schema.sql) sets updated_at to NOW()
-- only on INSERT via the column DEFAULT. Nothing keeps it fresh on
-- UPDATE. This shared trigger function does that for any table whose
-- rows we want to track. Idempotent — CREATE OR REPLACE is safe to
-- re-run, and existing tables/triggers using set_updated_at() will
-- pick up the latest version automatically.

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =====================================================================
-- public.games
-- =====================================================================
-- One row per scheduled real-world game instance. The (provider,
-- provider_game_id) pair is the natural key — the same physical game
-- always upserts to the same row regardless of how many times the
-- ingest worker re-fetches it.
--
-- id is intentionally UUID with NO default. The ingest worker is
-- expected to compute this deterministically from
-- (provider, provider_game_id) — typically via uuid_generate_v5(...) —
-- so a given upstream game always produces the same Supabase id, which
-- means downstream FKs (game_rooms.game_id, posts.room_id derivations)
-- stay stable across re-syncs and across devices.

CREATE TABLE IF NOT EXISTS public.games (
    id                  UUID            PRIMARY KEY,
    provider            TEXT            NOT NULL,
    provider_game_id    TEXT            NOT NULL,
    league              TEXT            NOT NULL,
    season              TEXT            NULL,
    home_team_id        UUID            NOT NULL,
    away_team_id        UUID            NOT NULL,
    start_time          TIMESTAMPTZ     NOT NULL,
    status              TEXT            NOT NULL,
    period              TEXT            NULL,
    clock               TEXT            NULL,
    home_score          INTEGER         NOT NULL DEFAULT 0,
    away_score          INTEGER         NOT NULL DEFAULT 0,
    last_synced_at      TIMESTAMPTZ     NULL,
    final_at            TIMESTAMPTZ     NULL,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- The same physical game must never appear twice. Re-syncs upsert
    -- on this pair. Includes provider so we can ingest from multiple
    -- sources without colliding ids in the wild.
    CONSTRAINT games_provider_game_id_unique
        UNIQUE (provider, provider_game_id),

    -- Status state machine. Worth keeping aligned with iOS
    -- LiveGameStatus once the client lands a unified enum (today the
    -- client also has a duplicate `GameStatus` in Models.swift — pick
    -- one before client wiring). The eight states cover the full life
    -- of a fixture from schedule announcement to archive.
    CONSTRAINT games_status_check
        CHECK (status IN (
            'scheduled',  -- on the schedule, kickoff in the future
            'pregame',    -- ~15min window before tip-off
            'live',       -- in progress
            'halftime',   -- mid-game intermission
            'final',      -- result is final, scores frozen
            'closed',     -- chat room closed but row retained
            'postponed',  -- moved to a later date
            'cancelled'   -- not happening
        ))
);

-- Documentation visible in Supabase Studio + psql \d
COMMENT ON TABLE  public.games                 IS 'One row per real scheduled game instance. Keyed off (provider, provider_game_id).';
COMMENT ON COLUMN public.games.id              IS 'Stable Supabase UUID for this game instance. Ingest worker should derive deterministically (e.g. uuid_generate_v5) from (provider, provider_game_id) so re-syncs and cross-device reads agree.';
COMMENT ON COLUMN public.games.provider        IS 'Upstream API source identifier (e.g. ''espn'', ''sportsdataio'', ''sportradar'').';
COMMENT ON COLUMN public.games.provider_game_id IS 'The upstream API''s native game id. Combined with provider this is the natural key.';
COMMENT ON COLUMN public.games.league          IS 'League rawValue: nfl | nba | mlb | nhl. Mirrors iOS League enum.';
COMMENT ON COLUMN public.games.season          IS 'Free-form season label (e.g. ''2025-26'' or ''2026''). Nullable — populate when the upstream API exposes it.';
COMMENT ON COLUMN public.games.home_team_id    IS 'iOS-side deterministic team UUID (SportsTeam.stableID). NOT FK''d — public.teams does not yet exist; teams still live in TeamData.swift.';
COMMENT ON COLUMN public.games.away_team_id    IS 'iOS-side deterministic team UUID (SportsTeam.stableID). NOT FK''d — see home_team_id note.';
COMMENT ON COLUMN public.games.start_time      IS 'Kickoff / tip-off in UTC. Always normalize to UTC at ingest; venue-local formatting is iOS''s job.';
COMMENT ON COLUMN public.games.status          IS 'Lifecycle status. See games_status_check.';
COMMENT ON COLUMN public.games.period          IS 'Free-form period label (e.g. ''Q3'', ''2nd Pd'', ''Top 7''). Provider-shaped.';
COMMENT ON COLUMN public.games.clock           IS 'Free-form game clock (e.g. ''7:42'', ''0:00''). Empty when not applicable.';
COMMENT ON COLUMN public.games.last_synced_at  IS 'Set by the ingest worker on every upsert. Useful for sync debugging and stale detection.';
COMMENT ON COLUMN public.games.final_at        IS 'Set when status first transitions to ''final''. Drives the close/archive grace window for game_rooms.';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_games_league_status_start_time ON public.games (league, status, start_time);
CREATE INDEX IF NOT EXISTS idx_games_status_start_time        ON public.games (status, start_time);
CREATE INDEX IF NOT EXISTS idx_games_start_time               ON public.games (start_time);
CREATE INDEX IF NOT EXISTS idx_games_home_team_id_start_time  ON public.games (home_team_id, start_time);
CREATE INDEX IF NOT EXISTS idx_games_away_team_id_start_time  ON public.games (away_team_id, start_time);

-- updated_at trigger
DROP TRIGGER IF EXISTS trigger_games_set_updated_at ON public.games;
CREATE TRIGGER trigger_games_set_updated_at
    BEFORE UPDATE ON public.games
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();


-- =====================================================================
-- public.game_rooms
-- =====================================================================
-- 1:1 with public.games. Separates room lifecycle from game data so
-- the chat surface can have its own state machine (pending → open →
-- live → final → closed → archived) without polluting the game row.
--
-- room_id is the UUID that posts.room_id will reference. CRITICAL:
-- room_id MUST be game-specific (one per game instance), NOT
-- team-pair-based. The current iOS ChatRoom.game(homeTeamId, awayTeamId)
-- model derives the room id from the team pair, which collapses every
-- regular-season meeting into a single shared chat. That model must
-- be retired when the iOS client switches to reading rooms from this
-- table.
--
-- The room_id is unique on its own column (UNIQUE constraint) so
-- posts.room_id can be matched to a single room cheaply.

CREATE TABLE IF NOT EXISTS public.game_rooms (
    id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id     UUID            NOT NULL
                                REFERENCES public.games(id) ON DELETE CASCADE,
    room_id     UUID            NOT NULL,
    status      TEXT            NOT NULL,
    opens_at    TIMESTAMPTZ     NOT NULL,
    closes_at   TIMESTAMPTZ     NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- 1:1 with games — one chat room per game instance.
    CONSTRAINT game_rooms_game_id_unique UNIQUE (game_id),

    -- room_id is the chat-room identifier referenced by posts.room_id.
    -- Must be globally unique across the room namespace.
    CONSTRAINT game_rooms_room_id_unique UNIQUE (room_id),

    -- Lifecycle state machine. Distinct from games.status — a game
    -- can be 'final' while its room is still 'live' during the grace
    -- window where users discuss the result.
    CONSTRAINT game_rooms_status_check
        CHECK (status IN (
            'pending',   -- created, opens_at not yet reached
            'open',      -- room is joinable; pre-game discussion
            'live',      -- the game is in progress
            'final',     -- game is over, room still active
            'closed',    -- read-only, no new posts allowed
            'archived'   -- hidden from LIVE page, posts retained
        ))
);

-- Documentation
COMMENT ON TABLE  public.game_rooms            IS 'One chat room per scheduled game instance. 1:1 with public.games.';
COMMENT ON COLUMN public.game_rooms.id         IS 'Surrogate primary key. Random UUID — not used by the iOS client.';
COMMENT ON COLUMN public.game_rooms.game_id    IS 'FK to public.games(id). Cascade deletes the room if the game row is hard-deleted.';
COMMENT ON COLUMN public.game_rooms.room_id    IS 'Chat-room id used by posts.room_id. MUST be game-specific (one per game instance), not team-pair-based — the latter collapses every meeting between the same two teams into one chat.';
COMMENT ON COLUMN public.game_rooms.status     IS 'Room lifecycle status. See game_rooms_status_check.';
COMMENT ON COLUMN public.game_rooms.opens_at   IS 'When the room becomes joinable. Typical: start_time - 15min for pre-game chat.';
COMMENT ON COLUMN public.game_rooms.closes_at  IS 'When the room transitions to closed/archived. Set by lifecycle worker after final_at + grace window.';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_game_rooms_game_id          ON public.game_rooms (game_id);
CREATE INDEX IF NOT EXISTS idx_game_rooms_room_id          ON public.game_rooms (room_id);
CREATE INDEX IF NOT EXISTS idx_game_rooms_status_opens_at  ON public.game_rooms (status, opens_at);
CREATE INDEX IF NOT EXISTS idx_game_rooms_status_closes_at ON public.game_rooms (status, closes_at);

-- updated_at trigger
DROP TRIGGER IF EXISTS trigger_game_rooms_set_updated_at ON public.game_rooms;
CREATE TRIGGER trigger_game_rooms_set_updated_at
    BEFORE UPDATE ON public.game_rooms
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();


-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
-- Enable RLS on both tables. The TEMP_ policies below are explicitly
-- permissive for the dev phase while the iOS client still uses anon-
-- key access. Production deployment MUST replace these with the
-- tighter policies described in the auth-cutover comment block at the
-- bottom of this file.

ALTER TABLE public.games      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_rooms ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------
-- TEMP_ policies — DROP IF EXISTS for replayability, then CREATE
-- ---------------------------------------------------------------------

-- games: drop any pre-existing policies (TEMP_ or production names) so
-- this migration is fully replayable.
DROP POLICY IF EXISTS "TEMP_select_all_games"        ON public.games;
DROP POLICY IF EXISTS "TEMP_insert_all_games"        ON public.games;
DROP POLICY IF EXISTS "TEMP_update_all_games"        ON public.games;
DROP POLICY IF EXISTS "Games are viewable by everyone" ON public.games;

CREATE POLICY "TEMP_select_all_games"
ON public.games
FOR SELECT
TO anon, authenticated
USING (true);

CREATE POLICY "TEMP_insert_all_games"
ON public.games
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

CREATE POLICY "TEMP_update_all_games"
ON public.games
FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (true);


-- game_rooms: same shape.
DROP POLICY IF EXISTS "TEMP_select_all_game_rooms"        ON public.game_rooms;
DROP POLICY IF EXISTS "TEMP_insert_all_game_rooms"        ON public.game_rooms;
DROP POLICY IF EXISTS "TEMP_update_all_game_rooms"        ON public.game_rooms;
DROP POLICY IF EXISTS "Game rooms are viewable by everyone" ON public.game_rooms;

CREATE POLICY "TEMP_select_all_game_rooms"
ON public.game_rooms
FOR SELECT
TO anon, authenticated
USING (true);

CREATE POLICY "TEMP_insert_all_game_rooms"
ON public.game_rooms
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

CREATE POLICY "TEMP_update_all_game_rooms"
ON public.game_rooms
FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (true);


-- =====================================================================
-- AUTH CUTOVER — REPLACE TEMP_ POLICIES BEFORE PRODUCTION
-- =====================================================================
-- When auth lands and the ingest worker runs under a dedicated role:
--
-- 1. DROP every TEMP_*_games and TEMP_*_game_rooms policy (above).
--
-- 2. Both tables become read-only for clients. Replace SELECT
--    policies with:
--      CREATE POLICY "Games are viewable by everyone"
--        ON public.games FOR SELECT
--        TO anon, authenticated USING (true);
--      CREATE POLICY "Game rooms are viewable by everyone"
--        ON public.game_rooms FOR SELECT
--        TO anon, authenticated USING (true);
--
-- 3. Drop INSERT and UPDATE policies entirely. Writes happen only via
--    the service-role key (used by the ingest worker / lifecycle
--    cron), which bypasses RLS by design. iOS clients must NEVER
--    write to either table.
--
-- 4. Optional: if at any point you need a dedicated worker role
--    instead of the service-role key, GRANT INSERT, UPDATE on
--    public.games, public.game_rooms TO that role and add a policy
--    keyed on auth.uid() = <worker_uid>.
-- =====================================================================
