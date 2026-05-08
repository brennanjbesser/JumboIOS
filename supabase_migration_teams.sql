-- =====================================================================
-- supabase_migration_teams.sql
-- =====================================================================
-- Canonical backend team identity. After this migration, public.teams
-- becomes the server-side source of truth for the four leagues' rosters
-- (NFL, NBA, MLB, NHL). Until iOS is rewired to read teams from
-- Supabase, the bundled TeamData.swift TeamDatabase remains
-- authoritative on-device — but the deterministic UUID system already
-- shared by both sides means the IDs line up perfectly when the
-- bridge is built.
--
-- ⚠️ CRITICAL: public.teams.id values MUST be the deterministic UUIDs
-- produced by iOS's `SportsTeam.stableID(league:shortName:)`
-- (TeamData.swift:71–85). That function takes a SHA-256 of
-- "<league>_<shortName>", truncates to 16 bytes, then sets v5-shape
-- version + RFC 4122 variant bits. The seeded games (see
-- supabase_seed_test_games.sql) and any future ingest worker rely on
-- those exact UUIDs to JOIN games ↔ teams without translation.
--
-- This migration intentionally:
--   • does NOT backfill any team rows (the bundled TeamDatabase has
--     124 teams across 4 leagues; that backfill is a separate
--     migration to keep diffs reviewable).
--   • does NOT add foreign keys from public.games.home_team_id /
--     away_team_id to public.teams(id). Attaching those FKs is also
--     a separate migration so the DB doesn't reject existing seeded
--     games whose team UUIDs predate the teams table.
--   • does NOT create standings, schedules, or players tables.
--   • does NOT alter any existing schema or RLS.
--
-- Replayable: every CREATE uses IF NOT EXISTS where supported, every
-- DROP POLICY uses IF EXISTS, and every CREATE POLICY runs after its
-- DROP. Safe to run repeatedly.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Reusable updated_at trigger function
-- ---------------------------------------------------------------------
-- Defensive redefinition — supabase_migration_games_and_game_rooms.sql
-- creates this same function, but re-emitting it here means this
-- migration can be applied first or second without depending on
-- migration order. CREATE OR REPLACE is idempotent; the body is
-- byte-identical to the games/game_rooms version, so triggers using
-- it elsewhere are unaffected.

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =====================================================================
-- public.teams
-- =====================================================================
-- One row per real-world franchise. id is supplied by the inserter
-- (no DEFAULT) and MUST equal SportsTeam.stableID(league, shortName).
-- That deterministic derivation is what makes this table cross-device
-- coherent — the same Bills row has the same UUID on every iPhone,
-- in every Supabase project, and in every seeded game's
-- home_team_id / away_team_id reference.

CREATE TABLE IF NOT EXISTS public.teams (
    id              UUID            PRIMARY KEY,
    league          TEXT            NOT NULL,
    city            TEXT            NOT NULL,
    name            TEXT            NOT NULL,
    short_name      TEXT            NOT NULL,
    abbreviation    TEXT            NOT NULL,
    primary_color   TEXT            NULL,
    secondary_color TEXT            NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Within a league, abbreviations are unique. Across leagues
    -- collisions are fine ("MIA" exists in NFL and NBA).
    CONSTRAINT teams_league_abbreviation_unique
        UNIQUE (league, abbreviation),

    -- Mirrors the iOS League enum's rawValues. Keep this list in
    -- lock-step with TeamData.swift's `League` cases.
    CONSTRAINT teams_league_check
        CHECK (league IN ('nfl', 'nba', 'mlb', 'nhl'))
);

-- Documentation visible in Supabase Studio + psql \d
COMMENT ON TABLE  public.teams                 IS 'Canonical backend team identity. id values MUST equal SportsTeam.stableID(league, shortName) from TeamData.swift so server-side joins (games.home_team_id, games.away_team_id, future user_followed_teams.team_id) resolve cleanly against bundled iOS data.';
COMMENT ON COLUMN public.teams.id              IS 'Deterministic UUID derived from SHA-256("<league>_<shortName>") with v5-shape version + RFC 4122 variant bits set. Must match SportsTeam.stableID(league:shortName:) in TeamData.swift:71–85 byte-for-byte. The ingest worker / backfill script computes this; never use gen_random_uuid() here.';
COMMENT ON COLUMN public.teams.league          IS 'League rawValue: nfl | nba | mlb | nhl. Mirrors iOS League enum. Adding a league requires updating teams_league_check AND the iOS enum together.';
COMMENT ON COLUMN public.teams.city            IS 'Locality, e.g. ''Buffalo'' or ''Los Angeles''. iOS SportsTeam.city.';
COMMENT ON COLUMN public.teams.name            IS 'Franchise name without city, e.g. ''Bills'' or ''Lakers''. iOS SportsTeam.name.';
COMMENT ON COLUMN public.teams.short_name      IS 'Display-friendly short label. Today''s iOS uses the 3-letter code here too (e.g. ''BUF''); a future migration may differentiate (e.g. ''Bills'' vs abbreviation ''BUF''). Both columns are required so callers can pick the right surface without coupling.';
COMMENT ON COLUMN public.teams.abbreviation    IS 'Canonical 3-letter abbreviation (e.g. ''BUF'', ''LAL''). Used as the natural-key partner of league in the unique constraint and as the suffix of stableID inputs.';
COMMENT ON COLUMN public.teams.primary_color   IS 'Hex string with leading # (e.g. ''#00338D''). Nullable while the bundle has gaps; should be required eventually.';
COMMENT ON COLUMN public.teams.secondary_color IS 'Hex string with leading #. Nullable for the same reason as primary_color.';

-- Indexes
--
-- (league, abbreviation) is already indexed by the UNIQUE constraint
-- above — that index is enough for any "give me NFL teams" query
-- (leftmost-prefix scan) and for any "look up BUF in NFL" lookup.
-- A standalone index on `abbreviation` covers cross-league lookups
-- (e.g., "show me every team abbreviated MIA").
CREATE INDEX IF NOT EXISTS idx_teams_abbreviation ON public.teams (abbreviation);

-- updated_at trigger
DROP TRIGGER IF EXISTS trigger_teams_set_updated_at ON public.teams;
CREATE TRIGGER trigger_teams_set_updated_at
    BEFORE UPDATE ON public.teams
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();


-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
-- Production-shape from day one: public read access, no client-side
-- writes. The ingest worker / admin tooling writes via the
-- service-role key, which bypasses RLS by design. This is stricter
-- than the TEMP_ policies on public.games / public.game_rooms because
-- teams are slow-moving reference data — no client should ever need
-- to insert or update them.

ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;

-- Drop pre-existing policies (under either the production name or
-- any TEMP_ name future-me might land in a follow-up) so this
-- migration is fully replayable.
DROP POLICY IF EXISTS "Teams are viewable by everyone" ON public.teams;
DROP POLICY IF EXISTS "TEMP_select_all_teams"           ON public.teams;
DROP POLICY IF EXISTS "TEMP_insert_all_teams"           ON public.teams;
DROP POLICY IF EXISTS "TEMP_update_all_teams"           ON public.teams;

CREATE POLICY "Teams are viewable by everyone"
ON public.teams
FOR SELECT
TO anon, authenticated
USING (true);

-- Note: NO INSERT / UPDATE / DELETE policies are created. Under RLS,
-- the absence of a policy means no access for non-superuser roles.
-- The service-role key (used by the ingest worker / admin migrations)
-- bypasses RLS unconditionally, so backfills and updates still work
-- via that path. iOS clients (anon + authenticated) can read but
-- cannot mutate.
