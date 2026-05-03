-- ============================================================
-- Migration: thread-reply polish.
--   • get_room_posts now computes reply_count from actual reply
--     rows (COUNT posts WHERE parent_id = post.id) rather than
--     trusting the posts.reply_count column maintained by the
--     legacy update_reply_count trigger. The trigger has been
--     observed drifting (parent showing "0 replies" when there
--     are clearly several); aggregating from the rows is the
--     only formula that can't go stale.
--
--   • get_post_replies now returns oldest-last (created_at DESC)
--     so the freshest reply sits at the top of the thread list.
-- ============================================================
--
-- Run this once in the Supabase SQL editor. Both statements are
-- idempotent (CREATE OR REPLACE) and the function signatures
-- haven't changed, so re-running is safe and no GRANT redo is
-- needed.
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
    -- Compute reply_count by counting actual reply rows. Bypasses
    -- posts.reply_count which has been observed drifting.
    reply_counts AS (
        SELECT parent_id, COUNT(*)::int AS reply_count
        FROM public.posts
        WHERE parent_id IS NOT NULL
        GROUP BY parent_id
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
            COALESCE(rc.reply_count, 0)::int   AS reply_count,
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
        LEFT JOIN vote_counts  vc ON vc.post_id   = p.id
        LEFT JOIN reply_counts rc ON rc.parent_id = p.id
        WHERE p.room_id = room_id_input
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
    -- Newest reply first — matches iOS thread-VM local sort.
    ORDER BY p.created_at DESC
$$;
