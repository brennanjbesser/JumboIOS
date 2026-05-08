-- =====================================================================
-- supabase_game_room_lifecycle_helpers.sql
-- =====================================================================
-- Reusable SQL helpers for automatically deriving public.game_rooms.status
-- from the parent public.games row's lifecycle state (status, opens_at,
-- closes_at) plus the current wall clock.
--
-- Purpose:
--   These functions are the building blocks for a future game-room
--   lifecycle worker — typically a Supabase cron job or scheduled edge
--   function that runs every ~30s and ticks rooms forward through their
--   states without per-row triggers. Calling this from a cron is the
--   intended path; clients (iOS or otherwise) should NEVER invoke these
--   functions directly.
--
-- This file does NOT:
--   • create realtime triggers (intentionally deferred)
--   • ingest from any Sports API (intentionally deferred)
--   • alter games / game_rooms / posts schema in any way
--   • modify any existing RLS policies
--   • set up cron jobs (a separate migration will register
--     pg_cron / Supabase scheduled functions to call
--     public.refresh_all_game_room_statuses())
--
-- Replayable: every CREATE uses CREATE OR REPLACE. Safe to re-run
-- against an existing project; later migrations can adjust rules
-- by re-issuing the CREATE OR REPLACE.
--
-- Prerequisites:
--   supabase_migration_games_and_game_rooms.sql must have been run.
-- =====================================================================


-- ---------------------------------------------------------------------
-- public.compute_game_room_status
-- ---------------------------------------------------------------------
-- Pure function. Given the current room status, the parent game's
-- status, the room's opens_at / closes_at timestamps, and a reference
-- "now", returns the room status the lifecycle rules dictate.
--
-- Ordering of rules matters — they are checked top-to-bottom and the
-- first match wins:
--
--   1. Room is 'archived'                              → 'archived'
--      (Terminal state. archived is a manual flag —
--       this function never sets or unsets it.)
--
--   2. closes_at is set AND <= now                     → 'closed'
--      (closes_at reached overrides everything below
--       it. The lifecycle worker sets closes_at when
--       transitioning a game to final + grace-window
--       expired.)
--
--   3. Game.status = 'closed'                          → 'closed'
--      (Game explicitly closed by the worker —
--       upstream signal, not time-driven.)
--
--   4. Game.status = 'final'                           → 'final'
--      (Game over, scoreboard frozen. The room can
--       still be live — see below — but the room
--       semantically reflects the final state.)
--
--   5. Game.status IN ('pregame','live','halftime')    → 'live'
--      (All three "happening now" states map to a
--       single room status — the iOS LIVE NOW band
--       displays them uniformly.)
--
--   6. Game.status = 'scheduled' AND opens_at <= now   → 'open'
--   7. Game.status = 'scheduled' (otherwise)           → 'pending'
--      (Pre-game window. opens_at is typically
--       start_time - 15min so users can drop into
--       the room shortly before kickoff.)
--
--   8. Anything else                                   → unchanged
--      (Covers 'postponed' and 'cancelled' — the two
--       game statuses with no spec'd room mapping yet.
--       Leaves the room in whatever state the worker
--       last set, deferring the policy decision until
--       a follow-up migration spells out what should
--       happen — likely 'closed', but worth confirming
--       with product before encoding.)
--
-- Markers:
--   • IMMUTABLE — output depends purely on inputs. Postgres can cache
--     evaluations within a single query plan.
--   • LANGUAGE plpgsql for early-return control flow.

CREATE OR REPLACE FUNCTION public.compute_game_room_status(
    p_current_room_status TEXT,
    p_game_status         TEXT,
    p_opens_at            TIMESTAMPTZ,
    p_closes_at           TIMESTAMPTZ,
    p_now                 TIMESTAMPTZ DEFAULT NOW()
) RETURNS TEXT AS $$
BEGIN
    -- 1. archived is terminal and manual. Never overridden here.
    IF p_current_room_status = 'archived' THEN
        RETURN 'archived';
    END IF;

    -- 2. closes_at reached → closed. Overrides any active game state.
    IF p_closes_at IS NOT NULL AND p_closes_at <= p_now THEN
        RETURN 'closed';
    END IF;

    -- 3. Explicit upstream close signal.
    IF p_game_status = 'closed' THEN
        RETURN 'closed';
    END IF;

    -- 4. Final result locked.
    IF p_game_status = 'final' THEN
        RETURN 'final';
    END IF;

    -- 5. Pregame / live / halftime all collapse to 'live'.
    IF p_game_status IN ('pregame', 'live', 'halftime') THEN
        RETURN 'live';
    END IF;

    -- 6 & 7. Scheduled — split on whether opens_at has been reached.
    IF p_game_status = 'scheduled' THEN
        IF p_opens_at IS NOT NULL AND p_opens_at <= p_now THEN
            RETURN 'open';
        ELSE
            RETURN 'pending';
        END IF;
    END IF;

    -- 8. postponed / cancelled / unknown — leave the existing room
    -- status alone. Future migration may extend this branch once
    -- product confirms the intended behavior.
    RETURN p_current_room_status;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.compute_game_room_status(TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ)
    IS 'Pure lifecycle-rule evaluator. Given a room''s current status, its parent game''s status, the room''s opens_at/closes_at, and a reference now, returns the room status the lifecycle rules dictate. archived is preserved unchanged; postponed/cancelled fall through unchanged for now.';


-- ---------------------------------------------------------------------
-- public.refresh_all_game_room_statuses
-- ---------------------------------------------------------------------
-- Bulk pass over every public.game_rooms row. Joins to public.games to
-- pick up the parent game's status, evaluates compute_game_room_status
-- for each row, and updates only those whose computed status differs
-- from what's currently stored. Returns the number of rows updated.
--
-- Intended call site:
--   • Cron job / Supabase scheduled function (e.g. every 30s during
--     active periods, every 5min off-hours).
--   • Manual SQL editor invocation for debugging.
--
-- NOT intended to be called by clients — there is no RLS gating on
-- this function. Clients have read-only SELECT in production; writes
-- flow through the service-role key.
--
-- The UPDATE uses `IS DISTINCT FROM` so a row whose computed status
-- equals its stored status doesn't generate a no-op write (avoids
-- triggering the set_updated_at trigger pointlessly).

CREATE OR REPLACE FUNCTION public.refresh_all_game_room_statuses(
    p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS INTEGER AS $$
DECLARE
    v_updated_count INTEGER;
BEGIN
    WITH desired AS (
        SELECT
            gr.id AS room_pk,
            public.compute_game_room_status(
                gr.status,
                g.status,
                gr.opens_at,
                gr.closes_at,
                p_now
            ) AS new_status
        FROM public.game_rooms gr
        JOIN public.games      g ON g.id = gr.game_id
    )
    UPDATE public.game_rooms gr
       SET status = d.new_status
      FROM desired d
     WHERE gr.id     = d.room_pk
       AND gr.status IS DISTINCT FROM d.new_status;

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    RETURN v_updated_count;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION public.refresh_all_game_room_statuses(TIMESTAMPTZ)
    IS 'Cron-callable: ticks every game_rooms row to its computed status in one statement. Returns the count of rows actually changed (no-op writes are skipped via IS DISTINCT FROM). Service-role / scheduled-function use only.';
