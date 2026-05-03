-- ============================================================
-- Migration: enable realtime for public.users so profile edits
--            propagate live to every device viewing that user's
--            posts / replies / notifications.
--
-- Run this once in the Supabase SQL editor. Idempotent (the DO
-- block swallows the duplicate-publication error if the table is
-- already published).
-- ============================================================
--
-- iOS subscribes to UPDATE events on public.users. The newRecord
-- in each event carries the full row (id, username, avatar_emoji,
-- avatar_color), which the client uses to refresh its
-- authorProfiles + userProfiles caches and update visible rows.
--
-- REPLICA IDENTITY FULL is recommended (matches the public.votes
-- pattern) so future enhancements that need oldRecord on UPDATE
-- have it available — strictly, the current iOS path only reads
-- newRecord, so this is forward-looking, not required.
-- ============================================================


-- 1. Add public.users to the realtime publication. Wrapped in a
--    DO block so re-running the migration doesn't error out when
--    the table is already published.

DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.users;
EXCEPTION
    WHEN duplicate_object THEN
        RAISE NOTICE 'public.users already in publication supabase_realtime — skipping';
END;
$$;


-- 2. REPLICA IDENTITY FULL — recommended (see header).

ALTER TABLE public.users REPLICA IDENTITY FULL;
