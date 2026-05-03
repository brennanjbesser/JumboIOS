-- ============================================================
-- Migration: keep posts.upvotes / posts.downvotes in sync with
--            the votes table via triggers.
-- ============================================================
--
-- Run this once in the Supabase SQL editor. The whole file is
-- idempotent — every statement is safe to re-run, so re-pasting
-- it later (e.g. after schema tweaks) won't break anything.
--
-- After it runs:
--   • posts.upvotes / posts.downvotes auto-update on every vote
--     insert/update/delete.
--   • Existing posts get a one-time backfill so the columns reflect
--     the current state of the votes table immediately.
--
-- NOTE on iOS:
--   iOS does NOT read posts.upvotes / posts.downvotes — those columns
--   are cache/analytics only, maintained for non-iOS consumers (admin
--   SQL, future REST clients, BI exports). The iOS client derives
--   live counts directly from `votes` rows where is_active = true
--   (cold-start aggregation in fetchPostsForRoom + realtime delta in
--   handleVoteAction). The trigger and iOS path are independent — the
--   trigger drifting wouldn't affect iOS UI.
--
-- NOTE on is_active:
--   The trigger function defined here uses the original recompute
--   logic (count all rows). `supabase_migration_soft_delete_votes.sql`
--   replaces it with an is_active-aware version (count only active
--   rows). Run BOTH migrations — the soft-delete one supersedes the
--   trigger body but relies on the columns + indexes added here.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Ensure the count columns exist with safe defaults.
--    `IF NOT EXISTS` means this is a no-op if you've already
--    added them.
-- ------------------------------------------------------------

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS upvotes integer NOT NULL DEFAULT 0;

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS downvotes integer NOT NULL DEFAULT 0;


-- ------------------------------------------------------------
-- 2. Index on votes(post_id, vote_type).
--    Makes the per-post COUNT(*) inside the trigger O(log n)
--    instead of O(table). Safe to re-run.
-- ------------------------------------------------------------

CREATE INDEX IF NOT EXISTS votes_post_id_type_idx
    ON public.votes (post_id, vote_type);


-- ------------------------------------------------------------
-- 3. Recompute function.
--    Recalculates the affected post's upvote / downvote counts
--    from scratch. Simpler than delta math and impossible to
--    get out of sync.
--
--    `CREATE OR REPLACE` makes this safe to re-run.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.recalculate_post_vote_counts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_post UUID;
BEGIN
    -- The post that needs recalculating depends on which DML fired.
    IF TG_OP = 'DELETE' THEN
        affected_post := OLD.post_id;
    ELSE
        affected_post := NEW.post_id;
    END IF;

    UPDATE public.posts
       SET upvotes   = (SELECT COUNT(*)::int FROM public.votes
                         WHERE post_id = affected_post AND vote_type = 'up'),
           downvotes = (SELECT COUNT(*)::int FROM public.votes
                         WHERE post_id = affected_post AND vote_type = 'down')
     WHERE id = affected_post;

    -- Edge case: if an UPDATE moved the vote to a different post,
    -- the OLD post needs its counts refreshed too.
    IF TG_OP = 'UPDATE' AND OLD.post_id IS DISTINCT FROM NEW.post_id THEN
        UPDATE public.posts
           SET upvotes   = (SELECT COUNT(*)::int FROM public.votes
                             WHERE post_id = OLD.post_id AND vote_type = 'up'),
               downvotes = (SELECT COUNT(*)::int FROM public.votes
                             WHERE post_id = OLD.post_id AND vote_type = 'down')
         WHERE id = OLD.post_id;
    END IF;

    -- AFTER triggers ignore the return value; NULL is conventional.
    RETURN NULL;
END;
$$;


-- ------------------------------------------------------------
-- 4. Triggers — INSERT, UPDATE, DELETE.
--    DROP IF EXISTS + CREATE makes the file safe to re-run.
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS recalc_post_votes_after_insert ON public.votes;
CREATE TRIGGER recalc_post_votes_after_insert
    AFTER INSERT ON public.votes
    FOR EACH ROW
    EXECUTE FUNCTION public.recalculate_post_vote_counts();

DROP TRIGGER IF EXISTS recalc_post_votes_after_update ON public.votes;
CREATE TRIGGER recalc_post_votes_after_update
    AFTER UPDATE ON public.votes
    FOR EACH ROW
    EXECUTE FUNCTION public.recalculate_post_vote_counts();

DROP TRIGGER IF EXISTS recalc_post_votes_after_delete ON public.votes;
CREATE TRIGGER recalc_post_votes_after_delete
    AFTER DELETE ON public.votes
    FOR EACH ROW
    EXECUTE FUNCTION public.recalculate_post_vote_counts();


-- ------------------------------------------------------------
-- 5. One-time backfill.
--    Recomputes every post's counts from the current votes
--    table. After this runs, posts.upvotes / .downvotes match
--    reality. Safe to re-run (it just overwrites with the
--    same values on subsequent runs).
-- ------------------------------------------------------------

UPDATE public.posts p
   SET upvotes   = (SELECT COUNT(*)::int FROM public.votes
                     WHERE post_id = p.id AND vote_type = 'up'),
       downvotes = (SELECT COUNT(*)::int FROM public.votes
                     WHERE post_id = p.id AND vote_type = 'down');
