"""
scripts/lifecycle/
==================

Game-room lifecycle worker. Runs server-side (no iOS coupling) and
keeps `public.game_rooms.status` aligned with `public.games.status`
+ time using the SQL helpers in
`supabase_game_room_lifecycle_helpers.sql`.

Module layout:

    game_lifecycle_worker.py  — CLI entrypoint + state-diff loop +
                                 closes_at scheduler. The only file
                                 here today; future extensions
                                 (archival cron, notification webhook
                                 dispatch, etc.) can land alongside.

The worker is intentionally stateless across restarts (uses Postgres
as the source of truth) and additive — every transition is computed
by the existing SQL helpers; the worker just orchestrates calls,
schedules `closes_at`, and logs human-readable transition lines.

See `game_lifecycle_worker.py` module docstring for usage.
"""
