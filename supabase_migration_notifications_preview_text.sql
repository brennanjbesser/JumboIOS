-- ============================================================
-- Migration: add preview_text to public.notifications.
--
-- Why:
--   Reply / upvote notifications need to render a snippet of the
--   relevant post in the row ("NavyBull replied: 'I can't…'").
--   For replies, `post_id` points to the parent (so the iOS app
--   can open the thread on tap) — it doesn't reference the reply
--   itself. Rather than add a second post-id column (and the
--   batch-fetch complexity that brings), we denormalize a TEXT
--   snapshot of the relevant content at notification-creation
--   time. Display is then a free read off the row.
--
-- What goes in preview_text:
--   • reply notifications  → the reply's content (the new message
--                              the user just posted)
--   • upvote notifications → the upvoted post's content (what was
--                              upvoted)
--
-- Stale-risk: minimal — this app doesn't currently support post
-- editing, so the snapshot stays accurate for the lifetime of the
-- notification row.
-- ============================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS preview_text TEXT;
