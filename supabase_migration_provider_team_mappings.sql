-- =====================================================================
-- supabase_migration_provider_team_mappings.sql
-- =====================================================================
-- Canonical provider → team identity bridge. Maps every upstream
-- Sports-API team identifier (e.g., SportsDataIO's "KC", ESPN's "12",
-- Sportradar's GUID) to the canonical `public.teams.id` UUID. The
-- ingest worker resolves provider team strings to internal UUIDs by
-- looking up rows here BEFORE writing to `public.games`.
--
-- Why a dedicated table (not provider columns on `public.teams`)?
--   • One row per (provider, provider_team_id). Sparse columns
--     avoided.
--   • Adding a new provider = inserting rows, not migrating schema.
--   • The mapping is auditable (notes column, created_at).
--   • Hard FK to `public.teams(id)` with ON DELETE CASCADE, so
--     mapping rows never outlive the team they reference.
--
-- Anti-silent-mismatch contract:
--   The ingest worker MUST fail closed when a provider team can't be
--   resolved here — never silently fall back to a default UUID, never
--   skip the row without logging. A separate `unmatched` log table
--   (added in a follow-up migration) collects unrecognized provider
--   team IDs for human review before bringing on a new provider.
--
-- This migration intentionally:
--   • does NOT seed any mapping rows. Onboarding a new provider is a
--     deliberate manual step (fetch the provider's team roster,
--     review, INSERT). The migration is just the table.
--   • does NOT modify `public.games`. Wiring the FK
--     `public.games.home_team_id → public.teams(id)` is a separate
--     migration once the existing seeded games have been backfilled
--     against the canonical team UUIDs.
--   • does NOT create ingest workers. Server-side ingestion lives
--     outside this repo (Edge Function or dedicated service) — see
--     the Sports API ingestion plan.
--
-- Replayable:
--   CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, every
--   policy is DROP IF EXISTS + CREATE. Safe to run repeatedly.
--
-- Prerequisite:
--   supabase_migration_teams.sql must have been run first
--   (creates public.teams, the FK target).
-- =====================================================================


-- ---------------------------------------------------------------------
-- public.provider_team_mappings
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.provider_team_mappings (
    provider          TEXT          NOT NULL,
    provider_team_id  TEXT          NOT NULL,
    team_id           UUID          NOT NULL
                                    REFERENCES public.teams(id) ON DELETE CASCADE,
    notes             TEXT          NULL,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    -- Composite natural key: a single provider's view of one team.
    -- Across providers the same provider_team_id can collide (ESPN
    -- and SportsDataIO both use "12" for completely different teams),
    -- so the provider name is part of the key.
    CONSTRAINT provider_team_mappings_pk
        PRIMARY KEY (provider, provider_team_id)
);


-- ---------------------------------------------------------------------
-- Documentation (visible in Supabase Studio + psql \d+)
-- ---------------------------------------------------------------------

COMMENT ON TABLE  public.provider_team_mappings                  IS 'Canonical provider → public.teams.id bridge. Required for provider-agnostic Sports API ingestion: every upstream team identifier resolves to a JUMBO-canonical team UUID through this table. One row per (provider, provider_team_id). Adding a new provider = inserting rows, not migrating schema.';
COMMENT ON COLUMN public.provider_team_mappings.provider         IS 'Upstream API source identifier — must match values used in public.games.provider (e.g. ''sportsdataio'', ''sportradar'', ''thesportsdb'').';
COMMENT ON COLUMN public.provider_team_mappings.provider_team_id IS 'The provider''s native team identifier as a string. Stored verbatim from the provider — case-sensitive, no normalization. Combined with `provider` this is the natural key.';
COMMENT ON COLUMN public.provider_team_mappings.team_id          IS 'Canonical team UUID (public.teams.id). Must equal SportsTeam.stableID(league, shortName) on the iOS side, or the lowercase-derived equivalent currently seeded — see TeamData.swift and the canonical-resolver bridge.';
COMMENT ON COLUMN public.provider_team_mappings.notes            IS 'Free-form audit field — who created the mapping, why, when verified, edge cases (e.g. ''Raiders relocation 2020 → kept canonical UUID, only updated city''). Optional but encouraged.';
COMMENT ON COLUMN public.provider_team_mappings.created_at       IS 'Insertion timestamp. No updated_at — mapping rows are append-mostly; corrections are usually a DELETE + new INSERT, captured by created_at on the new row.';


-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
-- The PRIMARY KEY (provider, provider_team_id) auto-creates a btree
-- index that covers:
--   • (provider, provider_team_id) — the ingest worker's lookup pattern
--   • (provider) — leftmost-prefix scan for "all mappings for SDIO"
-- A standalone index on team_id covers the reverse direction:
-- "which provider IDs map to this canonical team?" — used for audit
-- and for cross-provider validation.

CREATE INDEX IF NOT EXISTS idx_provider_team_mappings_team_id
    ON public.provider_team_mappings (team_id);


-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
-- Production-shape from day one (matches public.teams):
--   • Public SELECT for anon + authenticated.
--   • NO INSERT/UPDATE/DELETE policies → no client writes possible.
-- The ingest worker writes via the service-role key, which bypasses
-- RLS by design. iOS clients can only read.

ALTER TABLE public.provider_team_mappings ENABLE ROW LEVEL SECURITY;

-- Drop pre-existing policies (under either the production name or
-- any TEMP_ name a future migration might draft) so this file is
-- fully replayable.
DROP POLICY IF EXISTS "Provider team mappings are viewable by everyone"
    ON public.provider_team_mappings;
DROP POLICY IF EXISTS "TEMP_select_all_provider_team_mappings"
    ON public.provider_team_mappings;
DROP POLICY IF EXISTS "TEMP_insert_all_provider_team_mappings"
    ON public.provider_team_mappings;
DROP POLICY IF EXISTS "TEMP_update_all_provider_team_mappings"
    ON public.provider_team_mappings;

CREATE POLICY "Provider team mappings are viewable by everyone"
ON public.provider_team_mappings
FOR SELECT
TO anon, authenticated
USING (true);

-- Note: NO INSERT / UPDATE / DELETE policies are created. Under RLS,
-- the absence of a policy means no access for non-superuser roles.
-- The service-role key (used by the ingest worker / admin tooling)
-- bypasses RLS unconditionally, so backfills and updates still work
-- through that path.
