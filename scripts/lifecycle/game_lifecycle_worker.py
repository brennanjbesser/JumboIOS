#!/usr/bin/env python3
"""
scripts/lifecycle/game_lifecycle_worker.py
==========================================

Server-side game-room lifecycle orchestrator. Keeps
``public.game_rooms.status`` aligned with ``public.games.status`` +
clock time, schedules ``closes_at`` on freshly-finalized games, and
flags rooms that are candidates for archival.

THIS WORKER IS NOT A DEPLOYMENT.
We are *not* wiring cron / pg_cron / Docker / cloud infra here.
This is the architecture; future milestones plug it into a scheduler.

Pipeline (per tick)
-------------------

    1. Snapshot public.games + public.game_rooms.
    2. Detect newly-final games and log 🏁 (one-shot per session).
    3. Schedule closes_at = final_at + GRACE_HOURS for any final
       game whose room.closes_at is still NULL. Logs 🕒.
    4. Call SQL helper public.refresh_all_game_room_statuses(),
       which atomically ticks every room to its computed status
       (rules in supabase_game_room_lifecycle_helpers.sql).
    5. Re-snapshot public.game_rooms and diff against the before
       snapshot. Log per-room transitions with emoji prefixes:
           pending → open      🟢 Room opened
           any → live          🟣 Room went live
           any → final         🏁 Game finalized (room mirror)
           any → closed        🔴 Room closed
    6. Identify archive candidates (room.status='closed'). Log 📦.

Modes
-----

    (default) one-shot tick, then exit:
        python3 scripts/lifecycle/game_lifecycle_worker.py

    --watch           loop every 15s (or --interval N) until SIGINT:
        python3 scripts/lifecycle/game_lifecycle_worker.py --watch

    --dry-run         read-only — print intended changes, write nothing:
        python3 scripts/lifecycle/game_lifecycle_worker.py --dry-run
        python3 scripts/lifecycle/game_lifecycle_worker.py --watch --dry-run

Options
-------

    --interval N      override the default 15-second watch cadence
    --grace-hours N   override the default 24h closes_at grace window
    --verbose         debug-level logging

Environment
-----------

    SUPABASE_URL                 required
    SUPABASE_SERVICE_ROLE_KEY    preferred (bypass RLS)
    SUPABASE_ANON_KEY            fallback (works while TEMP_ permissive
                                 RLS policies allow anon writes — same
                                 caveat as scripts/test_sports_ingest.py)

Dependencies
------------

    Python 3.7+ standard library only. No external packages.

Safety protections
------------------

    • Dry-run is enforced at every write site — a single boolean
      `dry_run` flag passes through to mutate_*() helpers, which
      log "would …" and return without HTTP calls.
    • Watch loop catches every per-tick exception so a transient
      Supabase outage doesn't kill the worker — the next tick retries.
    • Tick coalescing: a single Python process runs one tick at a
      time (each tick is sequential async-free code).
    • SIGINT (Ctrl-C) breaks the watch loop cleanly.
    • Closes_at scheduling is idempotent — only fires when
      `final_at IS NOT NULL AND closes_at IS NULL`. A second tick
      after a successful schedule is a no-op for that game.
    • Final-game logging dedupes per session via
      `WorkerState.seen_final_game_ids`.

Future cron deployment path
---------------------------

    1. Wrap this script in a Supabase Edge Function and trigger via
       Supabase scheduled cron (every 30s during peak, 5min off-hours).
    2. OR run as a long-lived process (--watch) on Fly.io / Render /
       Cloudflare Workers behind a process supervisor.
    3. OR call from pg_cron via SECURITY DEFINER SQL wrapper that
       invokes refresh_all_game_room_statuses() — leaner but loses
       the closes_at scheduling logic that lives in Python here
       (would need to migrate that to SQL too).

How closes_at will eventually work
----------------------------------

    Game transitions to 'final' (status = 'final', final_at = NOW)
    via the ingest worker.  →  This lifecycle worker's next tick
    detects (final_at IS NOT NULL AND room.closes_at IS NULL) and
    PATCHes closes_at = final_at + GRACE_HOURS (default 24h).  →
    Subsequent SQL refreshes leave the room at status='final' until
    closes_at <= NOW, at which point compute_game_room_status flips
    it to 'closed'. The worker logs 🔴 on that transition. Once
    closed, the room shows up in the archive candidates list (📦),
    where a follow-up archival policy can decide when to flip it
    to 'archived' (terminal — never overridden by the SQL helper).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

logger = logging.getLogger("scripts.lifecycle")


# ─────────────────────────────────────────────────────────────────────
# Configuration / constants
# ─────────────────────────────────────────────────────────────────────

DEFAULT_INTERVAL_SECONDS = 15
DEFAULT_GRACE_HOURS = 24

# Environment vars resolved at module load. Validated in main() so
# --help still works without them set.
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = (
    os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    or os.environ.get("SUPABASE_ANON_KEY")
)


# ─────────────────────────────────────────────────────────────────────
# Worker session state — persists across ticks within a single process
# ─────────────────────────────────────────────────────────────────────


@dataclass
class WorkerState:
    """In-process memory used to dedupe one-shot logs across ticks
    (e.g., we only log 🏁 the first time we see a game flip to final).
    Resets on worker restart — by design, server-side state belongs
    in Postgres."""

    seen_final_game_ids: Set[str] = field(default_factory=set)
    seen_archive_candidate_ids: Set[str] = field(default_factory=set)


# ─────────────────────────────────────────────────────────────────────
# HTTP helpers (PostgREST)
# ─────────────────────────────────────────────────────────────────────


def _request(method: str, path: str, *, body: Any = None, prefer: Optional[str] = None) -> Any:
    """Single PostgREST call. Returns parsed JSON (or None for empty
    bodies). Raises urllib.error.HTTPError on non-2xx — callers
    decide whether to swallow or propagate."""
    if SUPABASE_URL is None or SUPABASE_KEY is None:
        raise RuntimeError("SUPABASE_URL / key env vars not configured")

    url = SUPABASE_URL.rstrip("/") + "/rest/v1" + path
    headers = {
        "apikey":        SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }
    if prefer:
        headers["Prefer"] = prefer

    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            text = resp.read().decode("utf-8")
            return json.loads(text) if text else None
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        logger.error("HTTP %d on %s %s: %s", e.code, method, path, body_text[:300])
        raise


def fetch_games() -> List[Dict[str, Any]]:
    """Pull every public.games row with the columns the worker needs.
    Includes archived/closed games so transitions out of those
    states are observable too."""
    rows = _request(
        "GET",
        "/games?select=id,provider,provider_game_id,league,status,final_at",
    ) or []
    return rows


def fetch_game_rooms() -> List[Dict[str, Any]]:
    """Pull every public.game_rooms row."""
    rows = _request(
        "GET",
        "/game_rooms?select=game_id,room_id,status,opens_at,closes_at",
    ) or []
    return rows


def call_refresh_all_game_room_statuses() -> int:
    """Invoke the SQL helper. PostgREST exposes the function under
    /rest/v1/rpc/<name>; the integer return value comes back as a
    scalar JSON number."""
    result = _request(
        "POST",
        "/rpc/refresh_all_game_room_statuses",
        body={},
    )
    if isinstance(result, int):
        return result
    if isinstance(result, list) and result and isinstance(result[0], int):
        return result[0]
    # Unknown shape — return 0 and log so we notice.
    logger.warning("⚠️ Unexpected RPC return shape: %r", result)
    return 0


def patch_game_room_closes_at(room_id: str, closes_at_iso: str) -> None:
    """Set game_rooms.closes_at for a single room. Idempotent — if
    closes_at was already set, this is just a no-op-style overwrite
    (we only call it when closes_at IS NULL anyway)."""
    _request(
        "PATCH",
        f"/game_rooms?room_id=eq.{urllib.parse.quote(room_id)}",
        body={"closes_at": closes_at_iso},
        prefer="return=minimal",
    )


# ─────────────────────────────────────────────────────────────────────
# Local replica of compute_game_room_status (for --dry-run only)
# ─────────────────────────────────────────────────────────────────────
#
# Mirrors the Postgres function in
# supabase_game_room_lifecycle_helpers.sql byte-for-byte. Used only
# in dry-run mode to predict what the SQL helper *would* do without
# actually calling it. Keep these branches in lockstep with the SQL.


def compute_room_status_local(
    current_room_status: Optional[str],
    game_status: Optional[str],
    opens_at: Optional[datetime],
    closes_at: Optional[datetime],
    now: datetime,
) -> Optional[str]:
    if current_room_status == "archived":
        return "archived"
    if closes_at is not None and closes_at <= now:
        return "closed"
    if game_status == "closed":
        return "closed"
    if game_status == "final":
        return "final"
    if game_status in ("pregame", "live", "halftime"):
        return "live"
    if game_status == "scheduled":
        if opens_at is not None and opens_at <= now:
            return "open"
        return "pending"
    # postponed / cancelled / unknown — pass through unchanged.
    return current_room_status


# ─────────────────────────────────────────────────────────────────────
# Time helpers
# ─────────────────────────────────────────────────────────────────────


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_ts(s: Optional[str]) -> Optional[datetime]:
    """PostgREST returns timestamps as ISO 8601 with timezone (e.g.,
    '2026-05-08T06:18:26.203686+00:00' or '2026-05-08T06:18:26+00:00').
    Python 3.7+ datetime.fromisoformat handles the common shapes."""
    if not s:
        return None
    # Replace 'Z' with explicit +00:00 for older Python compat.
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


# ─────────────────────────────────────────────────────────────────────
# Transition emoji mapping
# ─────────────────────────────────────────────────────────────────────


def transition_emoji(old_status: Optional[str], new_status: Optional[str]) -> str:
    """Pick the most informative emoji for a (old → new) transition."""
    if new_status == "live":
        return "🟣 Room went live"
    if new_status == "open":
        return "🟢 Room opened"
    if new_status == "final":
        return "🏁 Room marked final"
    if new_status == "closed":
        return "🔴 Room closed"
    if new_status == "archived":
        return "📦 Room archived"
    if new_status == "pending":
        return "⏳ Room pending"
    return f"➡️  Room → {new_status}"


# ─────────────────────────────────────────────────────────────────────
# Single tick
# ─────────────────────────────────────────────────────────────────────


def tick(state: WorkerState, *, dry_run: bool, grace_hours: int) -> None:
    """One pass through the lifecycle pipeline."""
    now = utcnow()
    logger.info("─── tick start (%s, %s) ───", "DRY-RUN" if dry_run else "LIVE", now.isoformat())

    # ── Step 1: Snapshot
    games = fetch_games()
    rooms_before = fetch_game_rooms()
    games_by_id = {g["id"]: g for g in games}
    rooms_by_game_id_before = {r["game_id"]: r for r in rooms_before}
    logger.debug("snapshot: %d games / %d rooms", len(games), len(rooms_before))

    # ── Step 2: Detect newly-final games (one-shot per session)
    final_games = [g for g in games if g.get("status") == "final"]
    for g in final_games:
        if g["id"] in state.seen_final_game_ids:
            continue
        state.seen_final_game_ids.add(g["id"])
        logger.info(
            "🏁 Game finalized — provider=%s/%s game_id=%s final_at=%s",
            g.get("provider"),
            g.get("provider_game_id"),
            g["id"][:8],
            g.get("final_at") or "(unset)",
        )

    # ── Step 3: Plan + apply closes_at scheduling
    closes_at_plans: List[Tuple[Dict[str, Any], Dict[str, Any], datetime]] = []
    for g in final_games:
        room = rooms_by_game_id_before.get(g["id"])
        if room is None:
            continue
        if room.get("closes_at") is not None:
            continue  # already scheduled
        final_at = parse_ts(g.get("final_at"))
        if final_at is None:
            # Defensive: the ingest worker should set final_at when
            # status flips to 'final', but if it didn't we use NOW
            # so the room still gets a reasonable close window. Log
            # ⚠️ so the operator can investigate ingest health.
            logger.warning(
                "⚠️ game_id=%s status=final but final_at=NULL — using NOW as best-effort baseline",
                g["id"][:8],
            )
            final_at = now
        scheduled_close = final_at + timedelta(hours=grace_hours)
        closes_at_plans.append((g, room, scheduled_close))

    if closes_at_plans:
        logger.info(
            "🕒 closes_at scheduling — %d room(s) need closes_at set (grace=%dh)",
            len(closes_at_plans),
            grace_hours,
        )
    for g, room, scheduled in closes_at_plans:
        verb = "WOULD set" if dry_run else "setting"
        logger.info(
            "   🕒 %s closes_at=%s — provider=%s/%s room_id=%s",
            verb,
            scheduled.isoformat(),
            g.get("provider"),
            g.get("provider_game_id"),
            room["room_id"][:8],
        )
        if not dry_run:
            try:
                patch_game_room_closes_at(room["room_id"], scheduled.isoformat())
            except urllib.error.HTTPError:
                # Logged inside _request; continue with next room.
                logger.warning("⚠️ closes_at PATCH failed for room_id=%s — will retry next tick", room["room_id"][:8])

    # ── Step 4: Apply lifecycle rules
    if dry_run:
        # Predict transitions locally so the operator sees what
        # would happen if they re-ran without --dry-run.
        planned: List[Tuple[Dict[str, Any], Dict[str, Any], str, str]] = []
        for g_id, room in rooms_by_game_id_before.items():
            g = games_by_id.get(g_id)
            if g is None:
                continue
            new_status = compute_room_status_local(
                room.get("status"),
                g.get("status"),
                parse_ts(room.get("opens_at")),
                parse_ts(room.get("closes_at")),
                now,
            )
            if new_status is not None and new_status != room.get("status"):
                planned.append((g, room, room.get("status"), new_status))

        logger.info(
            "🔄 DRY-RUN: %d room(s) would transition (refresh_all_game_room_statuses skipped)",
            len(planned),
        )
        for g, room, old_status, new_status in planned:
            logger.info(
                "   %s — provider=%s/%s %s → %s",
                transition_emoji(old_status, new_status),
                g.get("provider"),
                g.get("provider_game_id"),
                old_status,
                new_status,
            )
    else:
        # Real run: invoke the SQL helper, then snapshot game_rooms
        # again to identify what changed.
        try:
            updated = call_refresh_all_game_room_statuses()
        except urllib.error.HTTPError:
            logger.error("❌ refresh_all_game_room_statuses RPC failed — skipping diff this tick")
            return
        logger.info("🔄 refresh_all_game_room_statuses applied — %d row(s) changed", updated)

        if updated > 0:
            rooms_after = fetch_game_rooms()
            rooms_by_game_id_after = {r["game_id"]: r for r in rooms_after}
            for g_id, room_after in rooms_by_game_id_after.items():
                room_before = rooms_by_game_id_before.get(g_id)
                if room_before is None:
                    continue  # newly-inserted room — no transition to log
                old_status = room_before.get("status")
                new_status = room_after.get("status")
                if old_status == new_status:
                    continue
                g = games_by_id.get(g_id, {})
                logger.info(
                    "   %s — provider=%s/%s %s → %s",
                    transition_emoji(old_status, new_status),
                    g.get("provider"),
                    g.get("provider_game_id"),
                    old_status,
                    new_status,
                )

    # ── Step 5: Identify archive candidates
    # Use the post-refresh snapshot if we have one; otherwise the
    # before snapshot is good enough for a dry-run pass.
    rooms_for_archive_check = rooms_before
    if not dry_run:
        try:
            rooms_for_archive_check = fetch_game_rooms()
        except urllib.error.HTTPError:
            pass  # use the pre-refresh snapshot

    candidates = [r for r in rooms_for_archive_check if r.get("status") == "closed"]
    new_candidates = [r for r in candidates if r["room_id"] not in state.seen_archive_candidate_ids]
    for r in new_candidates:
        state.seen_archive_candidate_ids.add(r["room_id"])
    if candidates:
        logger.info(
            "📦 Archive candidates — %d room(s) closed (%d newly-detected this tick)",
            len(candidates),
            len(new_candidates),
        )
        for r in new_candidates:
            g = games_by_id.get(r["game_id"], {})
            logger.info(
                "   📦 archive candidate — provider=%s/%s room_id=%s closes_at=%s",
                g.get("provider"),
                g.get("provider_game_id"),
                r["room_id"][:8],
                r.get("closes_at") or "(unset)",
            )

    logger.info("✅ tick complete")


# ─────────────────────────────────────────────────────────────────────
# Watch mode
# ─────────────────────────────────────────────────────────────────────


_shutdown_requested = False


def _handle_signal(signum, frame):  # noqa: ARG001 — frame unused, signature fixed
    global _shutdown_requested
    _shutdown_requested = True
    logger.info("⏹️  signal %d received — finishing current tick then exiting", signum)


def watch_loop(state: WorkerState, *, interval: int, dry_run: bool, grace_hours: int) -> None:
    """Loop until SIGINT / SIGTERM. Catches every per-tick exception
    so the worker survives Supabase outages."""
    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    logger.info(
        "👁  watch mode started — interval=%ds dry-run=%s grace=%dh (Ctrl-C to stop)",
        interval, dry_run, grace_hours,
    )
    while not _shutdown_requested:
        try:
            tick(state, dry_run=dry_run, grace_hours=grace_hours)
        except Exception as e:  # noqa: BLE001 — survive any tick error
            logger.exception("❌ tick failed — continuing on next interval (%s)", e)

        # Sleep in 1-second slices so SIGINT shuts down within ≤1s.
        for _ in range(interval):
            if _shutdown_requested:
                break
            time.sleep(1)

    logger.info("👋 watch loop exited cleanly")


# ─────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="game_lifecycle_worker.py",
        description="Game-room lifecycle orchestrator (dry-run-safe, watch-capable).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--watch",
        action="store_true",
        help="Loop every --interval seconds until SIGINT (default: one-shot tick + exit).",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Read state, plan changes, log them — but make NO writes.",
    )
    p.add_argument(
        "--interval",
        type=int,
        default=DEFAULT_INTERVAL_SECONDS,
        help=f"Watch-mode tick cadence in seconds (default: {DEFAULT_INTERVAL_SECONDS}).",
    )
    p.add_argument(
        "--grace-hours",
        type=int,
        default=DEFAULT_GRACE_HOURS,
        help=f"closes_at grace window in hours (default: {DEFAULT_GRACE_HOURS}).",
    )
    p.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug-level logging.",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # Logging setup. Format mirrors the existing scripts so all
    # ingest + lifecycle output reads the same.
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    # Treat empty-string env vars the same as unset — easy mistake to
    # make in shell exports and the urllib error this would otherwise
    # produce is uninformative.
    if not SUPABASE_URL or not SUPABASE_KEY:
        sys.stderr.write(
            "ERROR: SUPABASE_URL and (SUPABASE_SERVICE_ROLE_KEY or "
            "SUPABASE_ANON_KEY) env vars are required.\n\n"
            "Example:\n"
            "  export SUPABASE_URL='https://<project>.supabase.co'\n"
            "  export SUPABASE_SERVICE_ROLE_KEY='<jwt>'\n"
            "  python3 scripts/lifecycle/game_lifecycle_worker.py\n"
        )
        return 1

    logger.info(
        "→ Supabase: %s  mode=%s  dry-run=%s  grace=%dh",
        SUPABASE_URL,
        "watch" if args.watch else "once",
        args.dry_run,
        args.grace_hours,
    )

    state = WorkerState()

    if args.watch:
        watch_loop(state, interval=args.interval, dry_run=args.dry_run, grace_hours=args.grace_hours)
    else:
        try:
            tick(state, dry_run=args.dry_run, grace_hours=args.grace_hours)
        except urllib.error.HTTPError:
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
