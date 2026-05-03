-- ============================================================
-- Migration: soft-delete votes via is_active flag.
-- ============================================================
--
-- Run this once in the Supabase SQL editor. The whole file is
-- idempotent — every statement is safe to re-run.
--
-- Why:
--   Postgres realtime DELETE events only deliver the primary key
--   in oldRecord (even with REPLICA IDENTITY FULL — SDK behavior),
--   so iOS can't tell which post / user / vote_type the deleted
--   row belonged to. UPDATE events deliver the full old row, so
--   replacing hard-DELETE with UPDATE-is_active=false gives the
--   client what it needs to apply a -1 delta on the originating
--   user's count across other devices.
--
-- After this migration:
--   • A new is_active column defaults to true.
--   • RemoteChatService.removeVote(from:) issues UPDATE
--     is_active=false instead of DELETE.
--   • RemoteChatService.fetchVoteCounts / preloadVotes filter on
--     is_active = true.
--   • The iOS realtime handler reads is_active from event payloads
--     to compute deltas across is_active and vote_type transitions.
--
-- The recalculate_post_vote_counts trigger from the previous
-- migration is unchanged. iOS no longer reads posts.upvotes /
-- posts.downvotes (counts are derived from active vote rows), so
-- the trigger is now belt-and-suspenders only.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Add is_active column.
--    NOT NULL DEFAULT true means every existing row is treated
--    as an active vote, which matches the prior hard-delete
--    semantics (any row that exists counted as a vote).
-- ------------------------------------------------------------

ALTER TABLE public.votes
    ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;


-- ------------------------------------------------------------
-- 2. Index supporting the new "active votes for a post" query
--    pattern in fetchVoteCounts. Partial index keeps it small
--    by only covering active rows — the inactive ones are
--    dead weight from an aggregation perspective.
-- ------------------------------------------------------------

CREATE INDEX IF NOT EXISTS votes_post_id_active_idx
    ON public.votes (post_id, vote_type)
 WHERE is_active = true;


-- ------------------------------------------------------------
-- 3. Recalibrate the recalculate_post_vote_counts trigger so
--    counts reflect only active votes. iOS doesn't read these
--    columns anymore, but keeping them honest helps any other
--    consumer (admin SQL, future REST clients, BI exports).
--
--    CREATE OR REPLACE makes this safe to re-run.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.recalculate_post_vote_counts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_post UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        affected_post := OLD.post_id;
    ELSE
        affected_post := NEW.post_id;
    END IF;

    UPDATE public.posts
       SET upvotes   = (SELECT COUNT(*)::int FROM public.votes
                         WHERE post_id = affected_post
                           AND vote_type = 'up'
                           AND is_active = true),
           downvotes = (SELECT COUNT(*)::int FROM public.votes
                         WHERE post_id = affected_post
                           AND vote_type = 'down'
                           AND is_active = true)
     WHERE id = affected_post;

    IF TG_OP = 'UPDATE' AND OLD.post_id IS DISTINCT FROM NEW.post_id THEN
        UPDATE public.posts
           SET upvotes   = (SELECT COUNT(*)::int FROM public.votes
                             WHERE post_id = OLD.post_id
                               AND vote_type = 'up'
                               AND is_active = true),
               downvotes = (SELECT COUNT(*)::int FROM public.votes
                             WHERE post_id = OLD.post_id
                               AND vote_type = 'down'
                               AND is_active = true)
         WHERE id = OLD.post_id;
    END IF;

    RETURN NULL;
END;
$$;


-- ------------------------------------------------------------
-- 4. One-time backfill of posts.upvotes / posts.downvotes so
--    they only reflect active votes after the column lands.
--    Safe to re-run.
-- ------------------------------------------------------------

UPDATE public.posts p
   SET upvotes   = (SELECT COUNT(*)::int FROM public.votes
                     WHERE post_id = p.id
                       AND vote_type = 'up'
                       AND is_active = true),
       downvotes = (SELECT COUNT(*)::int FROM public.votes
                     WHERE post_id = p.id
                       AND vote_type = 'down'
                       AND is_active = true);
