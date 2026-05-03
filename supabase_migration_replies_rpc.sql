-- ============================================================
-- Migration: thread-reply support.
--   • Update get_room_posts to filter top-level posts only
--     (parent_id IS NULL) so the room feed doesn't include replies.
--   • Add get_post_replies(parent_post_id_input) — same active-vote
--     aggregation shape as get_room_posts, but scoped to a single
--     parent and ordered chronologically (replies grow over time
--     in the order they were sent, like a chat thread).
-- ============================================================
--
-- Run this once in the Supabase SQL editor. Both statements are
-- idempotent — CREATE OR REPLACE on each function and matching
-- GRANTs make this safe to re-run.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Update get_room_posts to exclude replies from the feed.
--    Identical body to the existing version, with `WHERE
--    p.parent_id IS NULL` added inside the post_metrics CTE.
-- ------------------------------------------------------------

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
          -- Top-level posts only. Replies are fetched per-thread via
          -- get_post_replies(parent_post_id_input).
          AND p.parent_id IS NULL
    )
    SELECT
        id, user_id, content, room_id, room_type, team_id, parent_id,
        reply_count, report_count, is_hidden, created_at,
        active_upvotes, active_downvotes, score, hot_score
    FROM post_metrics
    ORDER BY
        CASE WHEN sort_mode = 'top' THEN score     END DESC NULLS LAST,
        CASE WHEN sort_mode = 'hot' THEN hot_score END DESC NULLS LAST,
        created_at DESC
$$;


-- ------------------------------------------------------------
-- 2. New RPC: get_post_replies(parent_post_id_input).
--    Returns every reply for a parent post with active vote
--    aggregates, ordered created_at ASC (oldest reply first —
--    same as MockChatService.fetchReplies and matches the
--    chronological "thread" expectation from the UI).
--
--    No sort_mode parameter — replies are always chronological.
--    No hot_score — reply ordering doesn't use the decay formula.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_post_replies(
    parent_post_id_input uuid
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
    score int
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
    )
    SELECT
        p.id,
        p.user_id,
        p.content,
        p.room_id,
        p.room_type,
        p.team_id,
        p.parent_id,
        COALESCE(p.reply_count,  0)::int,
        COALESCE(p.report_count, 0)::int,
        COALESCE(p.is_hidden,    false),
        p.created_at,
        COALESCE(vc.active_upvotes,   0),
        COALESCE(vc.active_downvotes, 0),
        (COALESCE(vc.active_upvotes, 0)
         - COALESCE(vc.active_downvotes, 0))::int
    FROM public.posts p
    LEFT JOIN vote_counts vc ON vc.post_id = p.id
    WHERE p.parent_id = parent_post_id_input
    ORDER BY p.created_at ASC
$$;

GRANT EXECUTE ON FUNCTION public.get_post_replies(uuid) TO anon, authenticated;
