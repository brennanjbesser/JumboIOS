-- ============================================================
-- Migration: room-scoped post identity
-- ============================================================
-- Adds `room_id uuid` + `room_type text` to posts. `room_id` is a
-- deterministic UUID derived from a canonical key (e.g.
-- "team:<lowercase-uuid>", "game:<sortedA>:<sortedB>",
-- "trending:<lowercase-uuid>") via SHA-256 → UUID v5. The iOS
-- `ChatRoom` enum derives the same UUID from the same key, so
-- client and server agree without coordination.
--
-- Idempotent — every statement is safe to re-run. The constraint-
-- tightening section at the end is intentionally left as a STAGE 2
-- block so you can verify the backfill before promoting the columns
-- to NOT NULL + CHECK constrained.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Extensions
-- ------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ------------------------------------------------------------
-- 2. Deterministic-UUID helper
-- ------------------------------------------------------------
-- Mirrors `ChatRoom.roomId` on iOS:
--   • SHA-256 the input bytes
--   • Take the first 16 bytes
--   • Set version 5 bits on byte[6]   (0x?? & 0x0F | 0x50)
--   • Set RFC 4122 variant on byte[8] (0x?? & 0x3F | 0x80)
--   • Format as canonical UUID string and cast to uuid
--
-- IMPORTANT: the input string must use lowercase UUIDs — Postgres
-- `uuid::text` is lowercase by default, so always feed it through
-- `lower()` defensively. The iOS side lowercases too. Mismatched
-- case → different SHA → different UUID → broken backfill.

CREATE OR REPLACE FUNCTION public.deterministic_room_uuid(input text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    raw bytea;
    b6  int;
    b8  int;
    hex text;
BEGIN
    raw := substring(digest(input::bytea, 'sha256') from 1 for 16);
    b6  := (get_byte(raw, 6) & 15)  | 80;     -- version 5
    raw := set_byte(raw, 6, b6);
    b8  := (get_byte(raw, 8) & 63)  | 128;    -- RFC 4122 variant
    raw := set_byte(raw, 8, b8);
    hex := encode(raw, 'hex');
    RETURN (
        substring(hex from 1  for 8)  || '-' ||
        substring(hex from 9  for 4)  || '-' ||
        substring(hex from 13 for 4)  || '-' ||
        substring(hex from 17 for 4)  || '-' ||
        substring(hex from 21 for 12)
    )::uuid;
END;
$$;


-- ------------------------------------------------------------
-- 3. Schema additions
-- ------------------------------------------------------------

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS room_id uuid;

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS room_type text;


-- ------------------------------------------------------------
-- 4. Backfill
-- ------------------------------------------------------------
-- Pre-migration posts were all team-scoped (the V0 design overloaded
-- `team_id` for every chat surface, but only team chats persisted
-- meaningful data — game / trending used the same column with
-- ephemeral or colliding ids). Treat all existing rows as team
-- rooms.
--
-- The canonical key matches the iOS `ChatRoom.team(teamId)` form:
--   "team:<lowercase-uuid>"

UPDATE public.posts
   SET room_id   = deterministic_room_uuid('team:' || lower(team_id::text)),
       room_type = 'team'
 WHERE room_id IS NULL AND team_id IS NOT NULL;


-- ------------------------------------------------------------
-- 5. Index for room-scoped fetches
-- ------------------------------------------------------------

CREATE INDEX IF NOT EXISTS posts_room_id_created_idx
    ON public.posts (room_id, created_at DESC);


-- ------------------------------------------------------------
-- 6. STAGE 2 — constraint promotion
-- ------------------------------------------------------------
-- Run sections 1-5 first, then verify:
--
--   SELECT count(*) FROM public.posts WHERE room_id IS NULL;
--   -- expected: 0
--
--   SELECT room_type, count(*) FROM public.posts GROUP BY room_type;
--   -- expected: every row has 'team' (or whatever you've backfilled)
--
-- Once verified, uncomment the block below and re-run this file.
-- The full file remains idempotent.
--
-- ALTER TABLE public.posts
--     ALTER COLUMN room_id   SET NOT NULL;
--
-- ALTER TABLE public.posts
--     ALTER COLUMN room_type SET NOT NULL;
--
-- ALTER TABLE public.posts
--     DROP CONSTRAINT IF EXISTS posts_room_type_check;
--
-- ALTER TABLE public.posts
--     ADD CONSTRAINT posts_room_type_check
--     CHECK (room_type IN ('team', 'game', 'trending'));


-- ------------------------------------------------------------
-- 7. team_id stays as-is (now optional metadata)
-- ------------------------------------------------------------
-- It was already nullable in the original schema. New posts may set
-- it to a meaningful team for `.team` rooms; `.game` and `.trending`
-- rooms emit NULL. No constraint changes required.
