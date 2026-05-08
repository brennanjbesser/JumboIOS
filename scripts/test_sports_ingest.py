#!/usr/bin/env python3
"""
scripts/test_sports_ingest.py
=============================

Local development scaffolding for the Phase-5 sports ingest pipeline.
Generates synthetic 'test_ingest' provider data, resolves provider
team IDs via public.provider_team_mappings, and upserts canonical rows
into public.games + public.game_rooms.

This is NOT a production ingest worker. It exists to prove end-to-end
that:

    test provider data
        → public.provider_team_mappings resolution (or auto-bootstrap)
            → public.games upsert (deterministic UUIDs)
                → public.game_rooms upsert (deterministic room_id)
                    → realtime UPDATE fan-out to the iOS LIVE page

When the real ingest worker lands, the same shape applies — just with
a real Sports API call replacing the static `TEST_GAMES` list below
and a real provider name replacing 'test_ingest'.

────────────────────────────────────────────────────────────────────────
USAGE
────────────────────────────────────────────────────────────────────────

    export SUPABASE_URL='https://<project>.supabase.co'
    export SUPABASE_SERVICE_ROLE_KEY='<service-role-jwt>'   # preferred
        # OR (works while public.games / public.game_rooms have
        #     TEMP_ permissive INSERT/UPDATE policies for anon)
    export SUPABASE_ANON_KEY='<anon-jwt>'

    python3 scripts/test_sports_ingest.py

Re-run any time. The script is idempotent (ON CONFLICT upserts) and
deterministic (uuid_v5 derivation) — running twice in a row with
unchanged data updates `last_synced_at` + `updated_at` only. To
exercise realtime UPDATEs, edit `TEST_GAMES` below (e.g., bump
home_score on a live game) and re-run.

────────────────────────────────────────────────────────────────────────
WHAT IT WRITES
────────────────────────────────────────────────────────────────────────

    1. ~10 rows into public.provider_team_mappings
       (provider='test_ingest'). Auto-seeded from public.teams the
       first time the script runs; subsequent runs are no-ops.
    2. 5 rows into public.games (provider='test_ingest').
    3. 5 rows into public.game_rooms (one per game, room_id stable).

────────────────────────────────────────────────────────────────────────
WHAT IT DOES NOT DO
────────────────────────────────────────────────────────────────────────

    • read from any external Sports API (no network calls outside Supabase)
    • require any provider API keys
    • touch existing 'test' or production rows (different `provider` value)
    • delete anything
    • run on a schedule (one-shot; trigger via cron / launchd if desired)
    • write to Swift / iOS / UI

────────────────────────────────────────────────────────────────────────
DEPENDENCIES
────────────────────────────────────────────────────────────────────────

    Python 3.7+ standard library only (urllib, json, uuid, datetime,
    os, sys). No `pip install` required.

────────────────────────────────────────────────────────────────────────
SECURITY
────────────────────────────────────────────────────────────────────────

    No credentials are committed. URL + key come from env vars.
    The script intentionally tolerates either the service-role key
    (full RLS bypass) or the anon key (works while the games /
    game_rooms tables still carry their TEMP_ permissive INSERT/UPDATE
    policies). Once those policies tighten in a future migration, the
    anon key path will fail and the service-role key becomes required
    — matching how a real production ingest worker would run.
"""

import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

# ─────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = (
    os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    or os.environ.get("SUPABASE_ANON_KEY")
)

# This script's provider tag. Distinct from 'test' (used by the static
# seed scripts) so test-ingest data co-exists with hand-seeded data
# under (provider, provider_game_id) — the natural key on public.games.
PROVIDER = "test_ingest"

# Stable UUID namespace for uuid_v5 derivation. Same input string
# always yields the same UUID, every machine, every run. Mirrors the
# pattern used by supabase_seed_test_games.sql.
UUID_NAMESPACE = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")  # URL ns


# ─────────────────────────────────────────────────────────────────────
# Test fixtures — edit these to exercise realtime updates
# ─────────────────────────────────────────────────────────────────────
#
# Each row is a single game from the synthetic 'test_ingest' provider.
# `home_provider_team_id` / `away_provider_team_id` use the same
# `<league>_<abbreviation>` form as supabase_seed_test_provider_team_
# mappings.sql so the resolver pipeline matches the seeded mappings.
#
# `start_offset_minutes` is interpreted relative to NOW so the fixtures
# are always "fresh" without committing absolute timestamps.

NOW = datetime.now(timezone.utc)

TEST_GAMES = [
    # 1. Live NFL: KC @ BAL, ~30m in
    {
        "provider_game_id":      "ti-nfl-001",
        "league":                "nfl",
        "season":                "2025-26",
        "home_provider_team_id": "nfl_BAL",
        "away_provider_team_id": "nfl_KC",
        "start_offset_minutes":  -30,
        "status":                "live",
        "period":                "Q2",
        "clock":                 "8:14",
        "home_score":            14,
        "away_score":            47,
    },
    # 2. Halftime NFL: CHI @ GB
    {
        "provider_game_id":      "ti-nfl-002",
        "league":                "nfl",
        "season":                "2025-26",
        "home_provider_team_id": "nfl_GB",
        "away_provider_team_id": "nfl_CHI",
        "start_offset_minutes":  -60,
        "status":                "halftime",
        "period":                "Half",
        "clock":                 "0:00",
        "home_score":            19,
        "away_score":            23,
    },
    # 3. Live NBA: BOS @ LAL, ~45m in
    {
        "provider_game_id":      "ti-nba-001",
        "league":                "nba",
        "season":                "2025-26",
        "home_provider_team_id": "nba_LAL",
        "away_provider_team_id": "nba_BOS",
        "start_offset_minutes":  -45,
        "status":                "live",
        "period":                "Q3",
        "clock":                 "4:32",
        "home_score":            78,
        "away_score":            81,
    },
    # 4. Scheduled NFL: PHI @ DAL, kickoff in ~3h
    {
        "provider_game_id":      "ti-nfl-003",
        "league":                "nfl",
        "season":                "2025-26",
        "home_provider_team_id": "nfl_DAL",
        "away_provider_team_id": "nfl_PHI",
        "start_offset_minutes":  180,
        "status":                "scheduled",
        "period":                None,
        "clock":                 None,
        "home_score":            0,
        "away_score":            0,
    },
    # 5. Scheduled NBA: MIL @ GSW, tip-off in ~6h
    {
        "provider_game_id":      "ti-nba-002",
        "league":                "nba",
        "season":                "2025-26",
        "home_provider_team_id": "nba_GSW",
        "away_provider_team_id": "nba_MIL",
        "start_offset_minutes":  360,
        "status":                "scheduled",
        "period":                None,
        "clock":                 None,
        "home_score":            0,
        "away_score":            0,
    },
]


# ─────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────

def http(method, path, body=None, prefer=None):
    """PostgREST request with JWT + JSON body. Raises on non-2xx."""
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
        sys.stderr.write(
            f"❌ HTTP {e.code} on {method} {path}\n"
            f"   request body: {json.dumps(body)[:300] if body else '(none)'}\n"
            f"   response:     {body_text[:300]}\n"
        )
        raise


def stable_uuid(label: str) -> uuid.UUID:
    """Deterministic UUID v5 from a stable label."""
    return uuid.uuid5(UUID_NAMESPACE, label)


def parse_provider_team_id(ptid: str):
    """'nfl_BAL' → ('nfl', 'BAL')"""
    league, abbr = ptid.split("_", 1)
    return league, abbr


def iso(dt: datetime) -> str:
    """UTC ISO 8601 with fractional seconds — Postgres-friendly."""
    return dt.astimezone(timezone.utc).isoformat()


# ─────────────────────────────────────────────────────────────────────
# Pipeline
# ─────────────────────────────────────────────────────────────────────

def ensure_provider_team_mappings():
    """For every unique provider_team_id used by TEST_GAMES, ensure
    a row exists in public.provider_team_mappings for our provider.
    Resolves canonical team_id by querying public.teams.

    Returns: dict mapping provider_team_id → team_id (UUID string).
    """
    needed = sorted({
        ptid
        for g in TEST_GAMES
        for ptid in (g["home_provider_team_id"], g["away_provider_team_id"])
    })

    rows = []
    for ptid in needed:
        league, abbr = parse_provider_team_id(ptid)
        # PostgREST: GET /teams?select=id&league=eq.<league>&abbreviation=eq.<abbr>
        path = (
            "/teams"
            f"?select=id"
            f"&league=eq.{urllib_quote(league)}"
            f"&abbreviation=eq.{urllib_quote(abbr)}"
            "&limit=1"
        )
        teams = http("GET", path) or []
        if not teams:
            sys.stderr.write(
                f"⚠️  no public.teams row for league={league} "
                f"abbreviation={abbr} — provider_team_id {ptid} skipped\n"
            )
            continue
        rows.append({
            "provider":         PROVIDER,
            "provider_team_id": ptid,
            "team_id":          teams[0]["id"],
            "notes":            "Auto-seeded by scripts/test_sports_ingest.py",
        })

    if not rows:
        sys.stderr.write("❌ Couldn't resolve any teams. Is public.teams seeded?\n")
        return {}

    print(f"→ Upserting {len(rows)} provider_team_mappings (provider={PROVIDER})")
    http(
        "POST",
        "/provider_team_mappings?on_conflict=provider,provider_team_id",
        body=rows,
        prefer="resolution=merge-duplicates,return=minimal",
    )
    return {r["provider_team_id"]: r["team_id"] for r in rows}


def upsert_games(team_lookup):
    """Upsert canonical public.games rows. Returns dict
    provider_game_id → games.id (UUID string)."""
    rows = []
    game_id_for = {}
    for g in TEST_GAMES:
        home_team_id = team_lookup.get(g["home_provider_team_id"])
        away_team_id = team_lookup.get(g["away_provider_team_id"])
        if not home_team_id or not away_team_id:
            sys.stderr.write(
                f"⚠️  cannot resolve teams for {g['provider_game_id']} — skipping "
                f"(home={g['home_provider_team_id']}→{home_team_id}, "
                f"away={g['away_provider_team_id']}→{away_team_id})\n"
            )
            continue

        game_uuid = stable_uuid(
            f"jumbo:game:{PROVIDER}:{g['provider_game_id']}"
        )
        game_id_for[g["provider_game_id"]] = str(game_uuid)
        start = NOW + timedelta(minutes=g["start_offset_minutes"])

        rows.append({
            "id":               str(game_uuid),
            "provider":         PROVIDER,
            "provider_game_id": g["provider_game_id"],
            "league":           g["league"],
            "season":           g["season"],
            "home_team_id":     home_team_id,
            "away_team_id":     away_team_id,
            "start_time":       iso(start),
            "status":           g["status"],
            "period":           g["period"],
            "clock":            g["clock"],
            "home_score":       g["home_score"],
            "away_score":       g["away_score"],
            "last_synced_at":   iso(NOW),
            "final_at":         None,
        })

    if not rows:
        return {}

    print(f"→ Upserting {len(rows)} games (provider={PROVIDER})")
    http(
        "POST",
        "/games?on_conflict=provider,provider_game_id",
        body=rows,
        prefer="resolution=merge-duplicates,return=minimal",
    )
    return game_id_for


def upsert_game_rooms(game_id_for):
    """Upsert canonical public.game_rooms rows, one per game.
    room_id is a stable uuid_v5 keyed off provider_game_id so
    posts.room_id references stay valid across reruns."""
    rows = []
    for g in TEST_GAMES:
        gid = game_id_for.get(g["provider_game_id"])
        if not gid:
            continue

        room_uuid = stable_uuid(
            f"jumbo:room:game:{PROVIDER}:{g['provider_game_id']}"
        )
        start    = NOW + timedelta(minutes=g["start_offset_minutes"])
        opens_at = start - timedelta(minutes=15)

        # Mirrors the rules in supabase_game_room_lifecycle_helpers.sql.
        if g["status"] in ("live", "halftime", "pregame"):
            room_status = "live"
        elif g["status"] == "scheduled":
            room_status = "open" if opens_at <= NOW else "pending"
        elif g["status"] == "final":
            room_status = "final"
        else:
            room_status = "pending"

        rows.append({
            "game_id":   gid,
            "room_id":   str(room_uuid),
            "status":    room_status,
            "opens_at":  iso(opens_at),
            "closes_at": None,
        })

    if not rows:
        return

    print(f"→ Upserting {len(rows)} game_rooms")
    http(
        "POST",
        "/game_rooms?on_conflict=game_id",
        body=rows,
        prefer="resolution=merge-duplicates,return=minimal",
    )


def urllib_quote(s: str) -> str:
    """Minimal URL-encode for PostgREST filter values."""
    import urllib.parse
    return urllib.parse.quote(s, safe="")


# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────

def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        sys.stderr.write(
            "ERROR: SUPABASE_URL and (SUPABASE_SERVICE_ROLE_KEY or "
            "SUPABASE_ANON_KEY) env vars are required.\n"
            "\n"
            "Example:\n"
            "  export SUPABASE_URL='https://<project>.supabase.co'\n"
            "  export SUPABASE_SERVICE_ROLE_KEY='<jwt>'\n"
            "  python3 scripts/test_sports_ingest.py\n"
        )
        sys.exit(1)

    print(f"→ Supabase: {SUPABASE_URL}")
    print(f"→ Provider: {PROVIDER}")
    print(f"→ Now (UTC): {NOW.isoformat()}")
    print()

    team_lookup = ensure_provider_team_mappings()
    if not team_lookup:
        sys.exit(1)

    game_id_for = upsert_games(team_lookup)
    upsert_game_rooms(game_id_for)

    print()
    print("✅ Done.")
    print(f"   {len(team_lookup)} mappings · "
          f"{len(game_id_for)} games · "
          f"{len(game_id_for)} game_rooms")


if __name__ == "__main__":
    main()
