-- ============================================================
-- One-time repair: backfill blank username / avatar_emoji /
-- avatar_color rows in public.users with deterministic values
-- derived from the user's id. Idempotent (safe to re-run).
-- ============================================================
--
-- Why:
--   Earlier versions of ensureCurrentUserExists could upsert a
--   user row with username = '' (or NULL) when UserPreferences
--   was uninitialized. iOS now backfills client-side, but
--   historical rows still have blanks — so the same authorId
--   resolves to "" on every device, falls into the in-app
--   deterministic fallback, and SHOULD render identically
--   everywhere. This SQL repair makes the server side agree
--   with what the client computes, so any non-iOS consumer
--   (admin SQL, BI exports) sees real values too.
--
-- Algorithm:
--   • username       → 'Fan_' || first 8 hex chars of id
--   • avatar_emoji   → '🦁' (a stable default; iOS overlays
--                       its own deterministic emoji at render
--                       time anyway, so any non-empty value
--                       satisfies the "not blank" invariant)
--   • avatar_color   → '#00D9FF' (matches UserPreferences default)
--
-- Note on alignment with iOS:
--   The iOS deterministic helpers (`Post.deterministicDisplayName`
--   etc.) use UUID byte indices to pick from longer palettes
--   ("RedFan_42", animal emojis, etc.). Replicating that exact
--   formula in SQL would be substantial — and unnecessary,
--   because iOS reads whatever the server stores and uses it
--   verbatim. The only invariant SQL must enforce is
--   non-empty strings; iOS handles cross-device consistency
--   from there.
-- ============================================================


UPDATE public.users
   SET username = 'Fan_' || substring(replace(id::text, '-', '') from 1 for 8)
 WHERE coalesce(trim(username), '') = '';

UPDATE public.users
   SET avatar_emoji = '🦁'
 WHERE coalesce(trim(avatar_emoji), '') = '';

UPDATE public.users
   SET avatar_color = '#00D9FF'
 WHERE coalesce(trim(avatar_color), '') = '';


-- Optional: enforce going forward that future inserts can't
-- store blanks for these fields. Apply only after the backfill
-- above has run successfully.
--
-- ALTER TABLE public.users
--     ADD CONSTRAINT users_username_nonblank
--         CHECK (length(trim(username)) > 0) NOT VALID;
-- ALTER TABLE public.users
--     VALIDATE CONSTRAINT users_username_nonblank;
