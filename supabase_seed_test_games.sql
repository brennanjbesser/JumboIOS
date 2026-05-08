-- =====================================================================
-- supabase_seed_test_games.sql
-- =====================================================================
-- Test seed for public.games + public.game_rooms so SportsGameService
-- can be exercised against a real Supabase project before any Sports
-- API ingest worker exists.
--
-- Five fixtures total:
--   • test-nfl-001  KC @ BAL    status = live      (~30m in)
--   • test-nfl-002  GB @ CHI    status = halftime  (mid-game break)
--   • test-nba-001  LAL @ BOS   status = live      (~45m in)
--   • test-nfl-003  DAL @ PHI   status = scheduled (kickoff in ~3h)
--   • test-nba-002  GSW @ MIL   status = scheduled (kickoff in ~6h)
--
-- Convention: "AWAY @ HOME" in the comment matches the column order
-- (home_team_id, away_team_id) in the VALUES tuples — home team is
-- always the second team named, away team is the first. e.g.
-- "KC @ BAL" means BAL is at home, KC is the visitor.
--
-- All rows are tagged provider = 'test' so a future production seed
-- can co-exist (the natural key is (provider, provider_game_id), not
-- provider_game_id alone). To purge the test rows later:
--
--     DELETE FROM public.games WHERE provider = 'test';
--
-- (game_rooms cascade-deletes via FK ON DELETE CASCADE.)
--
-- Determinism:
--   • home_team_id / away_team_id are precomputed from the iOS-side
--     SportsTeam.stableID(league:shortName:) algorithm
--     (TeamData.swift:71–85): a SHA-256 of "<league>_<shortName>"
--     truncated to 16 bytes with v5-shape version bits + RFC 4122
--     variant bits set. These UUIDs match what every iPhone running
--     the app computes for the same team — so once public.teams
--     exists later, attaching a FK won't require rewriting these
--     rows.
--   • games.id and game_rooms.room_id derive via uuid_generate_v5 on
--     a fixed namespace + provider_game_id, so re-running this seed
--     upserts the same rows rather than creating duplicates.
--   • Idempotent: ON CONFLICT (provider, provider_game_id) DO UPDATE
--     for games, ON CONFLICT (game_id) DO UPDATE for game_rooms.
--     No DELETEs anywhere.
--
-- Prerequisite: supabase_migration_games_and_game_rooms.sql must have
-- been run first. uuid-ossp must be enabled (uuid_generate_v5 lives
-- there); the existing schema already uses uuid_generate_v4, so on
-- Supabase this is normally pre-enabled. The CREATE EXTENSION below
-- is defensive.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- =====================================================================
-- public.games
-- =====================================================================
--
-- Team UUIDs (precomputed from SportsTeam.stableID):
--   nfl_KC   c112d5cd-de2f-5deb-83c0-436709075975
--   nfl_BAL  22780759-f816-5ee7-9559-65bbbbc21638
--   nfl_DAL  250d2fad-d7ab-5733-bc88-92f18002094e
--   nfl_PHI  21b63854-e92d-5364-9871-e0c65299083e
--   nfl_GB   cd8b1e34-d36c-5103-a828-b52a055b6410
--   nfl_CHI  88ce09dc-0da0-545e-ba29-aa82e71f654e
--   nba_LAL  caa3a5d4-9bc7-5e6d-b922-4a040fa569dc
--   nba_BOS  87b616fa-f2a0-5466-a7ea-a6a5d36f51b8
--   nba_GSW  874945b4-cf49-5905-b0c1-3696573117ca
--   nba_MIL  899af24b-0bd1-5b6c-9a72-94087aba78da

INSERT INTO public.games (
    id, provider, provider_game_id, league, season,
    home_team_id, away_team_id, start_time, status,
    period, clock, home_score, away_score,
    last_synced_at, final_at
) VALUES
    -- 1. KC @ BAL — Ravens at home, Chiefs visiting; live, ~30m in.
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nfl-001'),
        'test', 'test-nfl-001', 'nfl', '2025-26',
        '22780759-f816-5ee7-9559-65bbbbc21638'::uuid, -- BAL home
        'c112d5cd-de2f-5deb-83c0-436709075975'::uuid, -- KC  away
        NOW() - INTERVAL '30 minutes',
        'live',
        'Q2', '8:14',
        14, 17,
        NOW(), NULL
    ),

    -- 2. CHI @ GB — Packers at home, Bears visiting; halftime.
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nfl-002'),
        'test', 'test-nfl-002', 'nfl', '2025-26',
        'cd8b1e34-d36c-5103-a828-b52a055b6410'::uuid, -- GB  home
        '88ce09dc-0da0-545e-ba29-aa82e71f654e'::uuid, -- CHI away
        NOW() - INTERVAL '1 hour',
        'halftime',
        'Half', '0:00',
        17, 13,
        NOW(), NULL
    ),

    -- 3. BOS @ LAL — Lakers at home, Celtics visiting; live, ~45m in.
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nba-001'),
        'test', 'test-nba-001', 'nba', '2025-26',
        'caa3a5d4-9bc7-5e6d-b922-4a040fa569dc'::uuid, -- LAL home
        '87b616fa-f2a0-5466-a7ea-a6a5d36f51b8'::uuid, -- BOS away
        NOW() - INTERVAL '45 minutes',
        'live',
        'Q3', '4:32',
        78, 81,
        NOW(), NULL
    ),

    -- 4. PHI @ DAL — Cowboys at home, Eagles visiting; scheduled, ~3h out.
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nfl-003'),
        'test', 'test-nfl-003', 'nfl', '2025-26',
        '250d2fad-d7ab-5733-bc88-92f18002094e'::uuid, -- DAL home
        '21b63854-e92d-5364-9871-e0c65299083e'::uuid, -- PHI away
        NOW() + INTERVAL '3 hours',
        'scheduled',
        NULL, NULL,
        0, 0,
        NOW(), NULL
    ),

    -- 5. MIL @ GSW — Warriors at home, Bucks visiting; scheduled, ~6h out.
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nba-002'),
        'test', 'test-nba-002', 'nba', '2025-26',
        '874945b4-cf49-5905-b0c1-3696573117ca'::uuid, -- GSW home
        '899af24b-0bd1-5b6c-9a72-94087aba78da'::uuid, -- MIL away
        NOW() + INTERVAL '6 hours',
        'scheduled',
        NULL, NULL,
        0, 0,
        NOW(), NULL
    )
ON CONFLICT (provider, provider_game_id) DO UPDATE SET
    league          = EXCLUDED.league,
    season          = EXCLUDED.season,
    home_team_id    = EXCLUDED.home_team_id,
    away_team_id    = EXCLUDED.away_team_id,
    start_time      = EXCLUDED.start_time,
    status          = EXCLUDED.status,
    period          = EXCLUDED.period,
    clock           = EXCLUDED.clock,
    home_score      = EXCLUDED.home_score,
    away_score      = EXCLUDED.away_score,
    last_synced_at  = EXCLUDED.last_synced_at,
    final_at        = EXCLUDED.final_at,
    updated_at      = NOW();


-- =====================================================================
-- public.game_rooms
-- =====================================================================
--
-- Status rules (per spec):
--   • live + halftime games  → 'live'  (chat is open + active)
--   • scheduled games        → 'open' if opens_at has passed,
--                              else 'pending'
--   • opens_at = start_time - 15 minutes
--   • closes_at = NULL (lifecycle worker fills this on transition
--     to closed/archived; not modeled in seed)
--
-- Both scheduled fixtures here have opens_at clearly in the future
-- (2h45m / 5h45m out), so they seed as 'pending'. A real lifecycle
-- worker would flip them to 'open' once opens_at <= NOW() and 'live'
-- when start_time is reached.

INSERT INTO public.game_rooms (
    game_id, room_id, status, opens_at, closes_at
) VALUES
    -- 1. KC @ BAL (live)
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nfl-001'),
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:room:game:test:test-nfl-001'),
        'live',
        (NOW() - INTERVAL '30 minutes') - INTERVAL '15 minutes',
        NULL
    ),
    -- 2. CHI @ GB (halftime)
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nfl-002'),
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:room:game:test:test-nfl-002'),
        'live',
        (NOW() - INTERVAL '1 hour') - INTERVAL '15 minutes',
        NULL
    ),
    -- 3. BOS @ LAL (live)
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nba-001'),
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:room:game:test:test-nba-001'),
        'live',
        (NOW() - INTERVAL '45 minutes') - INTERVAL '15 minutes',
        NULL
    ),
    -- 4. PHI @ DAL (scheduled, +3h)
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nfl-003'),
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:room:game:test:test-nfl-003'),
        'pending',
        (NOW() + INTERVAL '3 hours') - INTERVAL '15 minutes',
        NULL
    ),
    -- 5. MIL @ GSW (scheduled, +6h)
    (
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:game:test:test-nba-002'),
        uuid_generate_v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid, 'jumbo:room:game:test:test-nba-002'),
        'pending',
        (NOW() + INTERVAL '6 hours') - INTERVAL '15 minutes',
        NULL
    )
ON CONFLICT (game_id) DO UPDATE SET
    room_id    = EXCLUDED.room_id,
    status     = EXCLUDED.status,
    opens_at   = EXCLUDED.opens_at,
    closes_at  = EXCLUDED.closes_at,
    updated_at = NOW();
