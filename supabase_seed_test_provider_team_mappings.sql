-- =====================================================================
-- supabase_seed_test_provider_team_mappings.sql
-- =====================================================================
-- Test-tier provider team mappings. 124 rows — one per team in
-- public.teams — for the synthetic 'test' provider.
--
-- Spec called for provider_team_id = "the team's abbreviation"
-- (e.g., KC → Chiefs, BAL → Ravens, LAL → Lakers). Pure abbreviations
-- can't be the PK leaf for the 'test' provider because they collide
-- across leagues — MIA exists in NFL (Dolphins), NBA (Heat), and
-- MLB (Marlins); same shape for ATL, BOS, CHI, DAL, DET, MIN, PHI,
-- PIT, SEA, TB, TOR, WAS. The composite primary key
-- (provider, provider_team_id) would reject a multi-row INSERT that
-- tries to set ('test', 'MIA') three times.
--
-- Resolution: prefix each abbreviation with its lowercase league
-- (`nfl_KC`, `nba_LAL`, `mlb_MIA`, etc.). Same shape as the
-- canonical-UUID derivation key in supabase_seed_test_games.sql /
-- supabase_seed_teams.sql, so the test provider's namespace lines
-- up with the rest of the test data.
--
-- Real providers use whatever string they natively emit:
--   • SportsDataIO uses bare abbreviations and namespaces by API
--     endpoint per league
--   • ESPN uses numeric IDs ("12")
--   • Sportradar uses GUIDs
-- This seed is purely for exercising the resolver pipeline; a future
-- provider-specific seed will use that provider's native ID format.
--
-- Idempotent:
--   ON CONFLICT (provider, provider_team_id) DO UPDATE
-- so re-running refreshes team_id and notes in place rather than
-- creating duplicates. No DELETEs.
--
-- Strategy:
--   INSERT … SELECT FROM public.teams. Lets the seed pick up future
--   roster updates automatically (e.g., if a new team is added to
--   public.teams via supabase_seed_teams.sql, re-running this seed
--   adds the corresponding test mapping).
--
-- Prerequisites:
--   • supabase_migration_provider_team_mappings.sql (the table)
--   • supabase_seed_teams.sql (the 124 team rows the SELECT pulls
--     from). If public.teams is empty when this runs, the INSERT is
--     a no-op — safe but useless.
-- =====================================================================

INSERT INTO public.provider_team_mappings (
    provider,
    provider_team_id,
    team_id,
    notes
)
SELECT
    'test'                                        AS provider,
    league || '_' || abbreviation                 AS provider_team_id,
    id                                            AS team_id,
    'Test provider mapping using <league>_<abbreviation> form '
    || '(e.g., nfl_KC, nba_LAL). Pure abbreviations collide across '
    || 'leagues, so the test provider qualifies them.'
                                                  AS notes
FROM public.teams
ON CONFLICT (provider, provider_team_id) DO UPDATE SET
    team_id = EXCLUDED.team_id,
    notes   = EXCLUDED.notes;
