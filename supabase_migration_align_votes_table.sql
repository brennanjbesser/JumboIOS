-- ============================================================
-- Migration: align public.votes with the deployed shape iOS expects.
-- ============================================================
--
-- Run this once in the Supabase SQL editor on any environment that
-- was bootstrapped from the original supabase_schema.sql before the
-- room-scoped + soft-delete model existed. Idempotent — every
-- statement is safe to re-run.
--
-- Brings the votes table in line with what RemoteChatService now
-- requires:
--
--   • room_id uuid NOT NULL — the realtime votes channel filters
--     server-side via `room_id=eq.<uuid>`. Without this column the
--     filter never matches and other devices receive nothing.
--
--   • vote_type CHECK ('up', 'down') — iOS sends the short forms
--     ('up' / 'down'); the original schema accepted only the long
--     forms ('upvote' / 'downvote'), which would reject every
--     insert from the current iOS app.
--
-- The is_active column is added by `supabase_migration_soft_delete_votes.sql`
-- — run that one too if you haven't already.
--
-- Production environments where these columns / constraints were
-- added manually via the SQL editor will see this run as a no-op.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Add room_id (nullable initially so the backfill can run).
-- ------------------------------------------------------------

ALTER TABLE public.votes
    ADD COLUMN IF NOT EXISTS room_id uuid;


-- ------------------------------------------------------------
-- 2. Backfill room_id from the parent post. Every vote belongs to
--    a post; every post (post-room-migration) has a room_id.
-- ------------------------------------------------------------

UPDATE public.votes v
   SET room_id = p.room_id
  FROM public.posts p
 WHERE v.post_id = p.id
   AND v.room_id IS NULL
   AND p.room_id IS NOT NULL;


-- ------------------------------------------------------------
-- 3. Promote room_id to NOT NULL once backfilled. Wrapped in a
--    DO block so failure (any leftover NULL rows) surfaces with a
--    readable message instead of an opaque ALTER TABLE error.
-- ------------------------------------------------------------

DO $$
DECLARE
    null_count integer;
BEGIN
    SELECT count(*) INTO null_count
      FROM public.votes
     WHERE room_id IS NULL;

    IF null_count > 0 THEN
        RAISE NOTICE
            'Cannot promote votes.room_id to NOT NULL: % row(s) still have NULL room_id (orphaned vote with no parent post?). Resolve manually before re-running.',
            null_count;
    ELSE
        ALTER TABLE public.votes
            ALTER COLUMN room_id SET NOT NULL;
    END IF;
END;
$$;


-- ------------------------------------------------------------
-- 4. Replace the vote_type CHECK constraint with the short-form
--    version iOS actually sends. Drop the old one if present
--    (Postgres auto-names CHECK constraints `<table>_<col>_check`).
-- ------------------------------------------------------------

ALTER TABLE public.votes
    DROP CONSTRAINT IF EXISTS votes_vote_type_check;

ALTER TABLE public.votes
    ADD CONSTRAINT votes_vote_type_check
        CHECK (vote_type IN ('up', 'down'));


-- ------------------------------------------------------------
-- 5. Index supporting the realtime filter join + per-room queries.
-- ------------------------------------------------------------

CREATE INDEX IF NOT EXISTS votes_room_id_idx
    ON public.votes (room_id);
