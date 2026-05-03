-- ============================================================
-- Migration: get_room_posts(room_id_input, sort_mode) RPC.
-- ============================================================
--
-- Run this once in the Supabase SQL editor. Idempotent —
-- CREATE OR REPLACE on the function and a single trailing
-- GRANT make it safe to re-run.
--
-- Why this exists:
--   The iOS feed pills (Hot / New / Top) used to sort the
--   client-side response by a duplicated formula. That worked
--   for a single-page fetch but quietly diverged from the SQL
--   model whenever someone tweaked the score formula in one
--   place and not the other. Moving the sort into a Postgres
--   RPC makes the database the single source of truth for
--   feed order. iOS keeps the result in arrival order and
--   only re-sorts locally to maintain order across realtime
--   deltas (using the same formula as this function).
--
-- Contract:
--   • room_id_input  uuid  — required. Posts are filtered by
--                            posts.room_id = room_id_input.
--   • sort_mode      text  — 'new' | 'top' | 'hot' (anything
--                            else falls through to 'new').
--
-- Returns one row per post in the room, with active vote
-- aggregates and a derived hot_score, ordered per sort_mode.
--
-- Score formulas:
--   active_upvotes   = COUNT(votes WHERE vote_type='up'   AND is_active=true)
--   active_downvotes = COUNT(votes WHERE vote_type='down' AND is_active=true)
--   score            = active_upvotes - active_downvotes
--   hot_score        = score / power(hours_old + 2, 1.5)
--                       (matches Reddit's hot-rank shape; older posts
--                        decay regardless of score, newer posts with
--                        any positive net score float to the top.)
--
-- Sort:
--   'new'  → created_at DESC
--   'top'  → score DESC, created_at DESC
--   'hot'  → hot_score DESC, created_at DESC
-- ============================================================


CREATE OR REPLACE FUNCTION public.get_room_posts(
    room_id_input uuid,
    sort_mode text DEFAULT 'new'
)
RETURNS TABLE (
    id uuid,
    user_id uuid,
    content text,
    room_id uuid,
    room_type text,
    team_id uuid,
    parent_id uuid,
    reply_count int,
    report_count int,
    is_hidden boolean,
    created_at timestamptz,
    active_upvotes int,
    active_downvotes int,
    score int,
    hot_score double precision
)
LANGUAGE sql
STABLE
AS $$
    WITH vote_counts AS (
        SELECT
            v.post_id,
            COUNT(*) FILTER (WHERE v.vote_type = 'up')   ::int AS active_upvotes,
            COUNT(*) FILTER (WHERE v.vote_type = 'down') ::int AS active_downvotes
        FROM public.votes v
        WHERE v.is_active = true
        GROUP BY v.post_id
    ),
    post_metrics AS (
        SELECT
            p.id,
            p.user_id,
            p.content,
            p.room_id,
            p.room_type,
            p.team_id,
            p.parent_id,
            COALESCE(p.reply_count,  0)::int   AS reply_count,
            COALESCE(p.report_count, 0)::int   AS report_count,
            COALESCE(p.is_hidden,    false)    AS is_hidden,
            p.created_at,
            COALESCE(vc.active_upvotes,   0)   AS active_upvotes,
            COALESCE(vc.active_downvotes, 0)   AS active_downvotes,
            (COALESCE(vc.active_upvotes, 0)
             - COALESCE(vc.active_downvotes, 0))::int AS score,
            (
                (COALESCE(vc.active_upvotes,   0)
                 - COALESCE(vc.active_downvotes, 0))::double precision
                / power(
                    EXTRACT(EPOCH FROM (now() - p.created_at)) / 3600.0 + 2.0,
                    1.5
                  )
            )::double precision AS hot_score
        FROM public.posts p
        LEFT JOIN vote_counts vc ON vc.post_id = p.id
        WHERE p.room_id = room_id_input
    )
    SELECT
        id, user_id, content, room_id, room_type, team_id, parent_id,
        reply_count, report_count, is_hidden, created_at,
        active_upvotes, active_downvotes, score, hot_score
    FROM post_metrics
    -- Trick: in the inactive sort modes, the CASE returns NULL for
    -- every row, leaving them all "tied" — `NULLS LAST` keeps them
    -- stable and the next ORDER BY clause is the real tiebreaker.
    -- This avoids three near-duplicate IF/RETURN-QUERY branches.
    ORDER BY
        CASE WHEN sort_mode = 'top' THEN score     END DESC NULLS LAST,
        CASE WHEN sort_mode = 'hot' THEN hot_score END DESC NULLS LAST,
        created_at DESC
$$;


-- Grant EXECUTE to both anon (unauthenticated, current iOS path) and
-- authenticated roles so the RPC is callable via PostgREST. Idempotent.
GRANT EXECUTE ON FUNCTION public.get_room_posts(uuid, text) TO anon, authenticated;
