-- ============================================================
-- Migration: in-app notifications table.
--   • Per-user feed of notifications (replies, upvotes for now).
--   • RLS is ON, but with temporary permissive policies — see
--     the ⚠️ TODOs below for what to replace once Supabase Auth
--     is wired in.
--
-- Run this once in the Supabase SQL editor. Idempotent.
-- ============================================================
--
-- ⚠️ AUTH-NOT-YET-WIRED — TIGHTEN RLS WHEN AUTH LANDS:
--
--   The original version of this migration referenced auth.users(id)
--   and used auth.uid()-keyed RLS policies. Both are broken under the
--   current iOS flow because:
--
--     • The app upserts into public.users (not auth.users) — FK
--       violations on every insert.
--     • The app uses the Supabase anon key with no Supabase Auth
--       sign-in — auth.uid() is NULL, so auth.uid() = user_id
--       never matches and every SELECT / INSERT / UPDATE is denied.
--
--   This version targets public.users for the FKs and replaces the
--   auth.uid() policies with TEMP_ permissive policies that allow
--   both anon and authenticated roles to do everything. Once
--   Supabase Auth is connected:
--
--     1. Replace TEMP_select_all_notifications →
--          USING (auth.uid() = user_id)
--     2. Replace TEMP_insert_all_notifications →
--          WITH CHECK (auth.uid() = source_user_id
--                      AND auth.uid() <> user_id)
--        plus restrict TO authenticated.
--     3. Replace TEMP_update_all_notifications →
--          USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id)
--
--   The DROP POLICY statements below clean up BOTH the old
--   auth.uid() policy names AND the TEMP_ ones, so re-running this
--   migration is safe regardless of which version was applied last.
--
-- room_id note:
--   `room_id` is TEXT here even though `posts.room_id` is UUID
--   elsewhere — kept as TEXT to mirror the spec exactly (and to
--   leave room for non-UUID room identifiers later). Callers
--   passing the post's UUID-typed room id should `.uuidString` it
--   at the call site.
-- ============================================================


CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- ⚠️ TODO: re-point to auth.users(id) once Supabase Auth is wired
  -- (and migrate / dual-write user identities).
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('reply', 'upvote')),
  -- ⚠️ TODO: re-point to auth.users(id) once auth is wired.
  source_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  post_id UUID,
  room_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  read BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS notifications_user_id_created_at_idx
ON notifications(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS notifications_user_id_read_idx
ON notifications(user_id, read);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- DROP every prior policy name we might have created on this
-- table — both the original auth.uid() versions and the new
-- TEMP_ versions — so this migration is fully replayable.
-- ------------------------------------------------------------

DROP POLICY IF EXISTS "Users can view their own notifications"        ON notifications;
DROP POLICY IF EXISTS "Users can update their own notifications"      ON notifications;
DROP POLICY IF EXISTS "Authenticated users can create notifications"  ON notifications;
DROP POLICY IF EXISTS "TEMP_select_all_notifications"                 ON notifications;
DROP POLICY IF EXISTS "TEMP_insert_all_notifications"                 ON notifications;
DROP POLICY IF EXISTS "TEMP_update_all_notifications"                 ON notifications;


-- ------------------------------------------------------------
-- TEMP permissive policies — work with anon + authenticated
-- so the current iOS app (anon key, no Supabase Auth) can read
-- / insert / update freely. Replace these with auth.uid()-
-- keyed policies once Supabase Auth lands. See the ⚠️ TODO
-- header at the top of this file for the exact replacement
-- bodies.
--
-- Naming convention `TEMP_*` is deliberate — anyone reviewing
-- this table's policies in the Supabase dashboard will see at
-- a glance that they're not the final form.
-- ------------------------------------------------------------

CREATE POLICY "TEMP_select_all_notifications"
ON notifications
FOR SELECT
TO anon, authenticated
USING (true);

CREATE POLICY "TEMP_insert_all_notifications"
ON notifications
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

CREATE POLICY "TEMP_update_all_notifications"
ON notifications
FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (true);
