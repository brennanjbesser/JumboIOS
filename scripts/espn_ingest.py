#!/usr/bin/env python3
"""
scripts/espn_ingest.py
======================

Real ESPN ingest runner. Pulls live + scheduled games from ESPN's
public site API via ``ESPNProvider``, resolves teams through
``public.provider_team_mappings`` (provider='espn'), and upserts
canonical rows into ``public.games`` + ``public.game_rooms``.

ESPN is still treated as a *development* provider — production
launch will eventually move to a paid feed (SportsDataIO,
Sportradar, etc.) with stricter SLAs. The contract surface is
identical, so flipping providers is a one-line change in the runner
(swap ``ESPNProvider()`` for whatever lands next).

Hard guarantees
---------------

* ``--dry-run`` performs ZERO Supabase mutations. Every write site
  short-circuits on the dry_run flag and logs "would …" instead.
* Games whose teams cannot be resolved are SKIPPED — never written
  with placeholder UUIDs. The operator gets a ⚠️ log per unresolved
  (provider, provider_team_id) pair so missing mappings can be
  backfilled and the next tick picks them up automatically.
* All UUIDs are deterministic (uuid_v5 derivation in
  ``providers.normalization``) — re-running with unchanged ESPN
  data is a no-op modulo ``last_synced_at`` / ``updated_at``.
* Stdlib only. No external deps, no Supabase SDK.

Usage
-----

    # Read-only smoke test (recommended first run):
    python3 scripts/espn_ingest.py --dry-run

    # Real ingest — requires service-role key:
    export SUPABASE_URL='https://<project>.supabase.co'
    export SUPABASE_SERVICE_ROLE_KEY='<jwt>'
    python3 scripts/espn_ingest.py

    # Explicit league + lookahead window:
    python3 scripts/espn_ingest.py --league nfl --window-hours 168
    python3 scripts/espn_ingest.py --dry-run --league nba --window-hours 24

CLI flags
---------

    --dry-run            Print intended writes; perform no mutations.
    --league <code>      Single league to ingest (nfl/nba/mlb/nhl).
                         Default: nfl.
    --window-hours N     Scheduled-game lookahead window. Default 168 (7d).
    --verbose            Debug-level logging.

Environment
-----------

    SUPABASE_URL                 required (real run; recommended dry-run)
    SUPABASE_SERVICE_ROLE_KEY    required (real run)
    SUPABASE_ANON_KEY            accepted ONLY for dry-run reads
                                 (loading provider_team_mappings).
                                 Real run rejects anon — writes need
                                 service role.

Out of scope
------------

* Cron / Edge Function / pg_cron wiring (deferred to a deployment
  milestone).
* iOS, schema, RLS, or realtime changes.
* Removing or modifying ``scripts/test_sports_ingest.py``.

Logging legend
--------------

    🟢 ESPN fetch succeeded
    🔄 Canonical game upserted
    🏟️ Game room upserted
    ⚠️ unresolved team mapping (skip)
    ❌ ingest failed
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, replace
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple

# Make the repo root importable when the script is invoked directly.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_THIS_DIR)
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from scripts.providers import (  # noqa: E402  (import after sys.path tweak)
    CanonicalGameRoomRow,
    CanonicalGameRow,
    ESPNProvider,
    ProviderGameDTO,
    TeamResolver,
    to_canonical_game,
    to_canonical_game_room,
)
from scripts.providers.normalization import validate_provider_game  # noqa: E402

logger = logging.getLogger("scripts.espn_ingest")


# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────

PROVIDER_NAME = "espn"
SUPPORTED_LEAGUES = ("nfl", "nba", "mlb", "nhl")
HTTP_TIMEOUT_SECONDS = 20.0


# ─────────────────────────────────────────────────────────────────────
# PostgREST helpers
# ─────────────────────────────────────────────────────────────────────


class SupabaseClient:
    """
    Minimal stdlib PostgREST client. Two responsibilities:

    * read: GET arbitrary `/rest/v1/<table>?<query>` paths
    * write: POST upserts with on_conflict + Prefer headers

    Errors raise `RuntimeError` with the response body for visibility.
    """

    def __init__(self, base_url: str, api_key: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key

    def _headers(self, *, prefer: Optional[str] = None) -> Dict[str, str]:
        headers = {
            "apikey": self._api_key,
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Jumbo-ESPN-Ingest/0.1 (+dev)",
        }
        if prefer:
            headers["Prefer"] = prefer
        return headers

    def get(self, path: str) -> List[Dict[str, Any]]:
        url = self._base_url + "/rest/v1" + path
        req = urllib.request.Request(
            url, headers=self._headers(), method="GET"
        )
        return self._send(req)

    def post(
        self,
        path: str,
        body: List[Dict[str, Any]],
        *,
        prefer: str = "resolution=merge-duplicates,return=minimal",
    ) -> Optional[List[Dict[str, Any]]]:
        url = self._base_url + "/rest/v1" + path
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers=self._headers(prefer=prefer),
            method="POST",
        )
        return self._send(req)

    @staticmethod
    def _send(req: urllib.request.Request) -> Optional[List[Dict[str, Any]]]:
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
                text = resp.read().decode("utf-8")
                if not text:
                    return None
                return json.loads(text)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"PostgREST {e.code} on {req.method} {req.full_url}: "
                f"{e.reason} | {body[:500]}"
            ) from e
        except urllib.error.URLError as e:
            raise RuntimeError(
                f"PostgREST network error on {req.method} {req.full_url}: {e.reason}"
            ) from e
        except TimeoutError as e:
            raise RuntimeError(
                f"PostgREST timeout on {req.method} {req.full_url}"
            ) from e


# ─────────────────────────────────────────────────────────────────────
# Mapping prefetch — load every (espn, provider_team_id) → team_id
# row in one round-trip so the per-game resolver hits the in-memory
# cache instead of hammering Supabase.
# ─────────────────────────────────────────────────────────────────────


def load_provider_mappings(
    client: SupabaseClient, provider: str = PROVIDER_NAME
) -> Dict[str, str]:
    """
    Returns {provider_team_id: team_id} for every row of
    public.provider_team_mappings WHERE provider = <provider>.
    """
    path = (
        "/provider_team_mappings"
        "?select=provider_team_id,team_id"
        f"&provider=eq.{urllib.parse.quote(provider, safe='')}"
    )
    rows = client.get(path) or []
    return {r["provider_team_id"]: r["team_id"] for r in rows}


def load_teams_index(client: SupabaseClient) -> Dict[Tuple[str, str], str]:
    """
    Returns {(league, abbreviation_upper): team_id} for every public.teams
    row across the four supported leagues. Powers the resolver's
    `<league>_<abbrev>` fallback (unused by ESPN's numeric IDs but
    still wired so the abstraction stays consistent).
    """
    leagues_csv = ",".join(SUPPORTED_LEAGUES)
    path = (
        "/teams"
        "?select=id,league,abbreviation"
        f"&league=in.({urllib.parse.quote(leagues_csv, safe=',')})"
    )
    rows = client.get(path) or []
    out: Dict[Tuple[str, str], str] = {}
    for r in rows:
        league = (r.get("league") or "").lower()
        abbrev = (r.get("abbreviation") or "").upper()
        if league and abbrev and r.get("id"):
            out[(league, abbrev)] = r["id"]
    return out


# ─────────────────────────────────────────────────────────────────────
# Canonical row → JSON serialization
# ─────────────────────────────────────────────────────────────────────


def _jsonify_dt(value: Any) -> Any:
    """Convert datetime → ISO 8601 UTC string; leave everything else."""
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat()
    return value


def game_row_to_json(row: CanonicalGameRow) -> Dict[str, Any]:
    """`CanonicalGameRow` → dict ready for PostgREST POST body."""
    raw = asdict(row)
    return {k: _jsonify_dt(v) for k, v in raw.items()}


def game_room_row_to_json(row: CanonicalGameRoomRow) -> Dict[str, Any]:
    """`CanonicalGameRoomRow` → dict ready for PostgREST POST body."""
    raw = asdict(row)
    return {k: _jsonify_dt(v) for k, v in raw.items()}


# ─────────────────────────────────────────────────────────────────────
# Pipeline
# ─────────────────────────────────────────────────────────────────────


def fetch_dtos(provider: ESPNProvider, window_hours: int) -> List[ProviderGameDTO]:
    """
    Pull live + scheduled DTOs from ESPN. Provider already returns
    `[]` on no-data; raises on transient errors. The runner wraps
    its caller in try/except and surfaces ❌ on outright failure.
    """
    live = provider.fetch_live_games()
    sched = provider.fetch_scheduled_games(window_hours=window_hours)
    combined = list(live) + list(sched)
    logger.info(
        "🟢 ESPN fetch succeeded — provider=%s endpoint=combined "
        "live=%d scheduled=%d total=%d window_hours=%d",
        provider.name,
        len(live),
        len(sched),
        len(combined),
        window_hours,
    )
    return combined


def resolve_and_build_rows(
    dtos: Iterable[ProviderGameDTO],
    resolver: TeamResolver,
    *,
    now: Optional[datetime] = None,
) -> Tuple[List[CanonicalGameRow], List[CanonicalGameRoomRow], Dict[str, int]]:
    """
    Validate every DTO, resolve home/away teams, and build the
    canonical row pair (game + game_room). Skipped rows are counted
    by reason in `stats`. Returns (game_rows, room_rows, stats).
    """
    if now is None:
        now = datetime.now(timezone.utc)

    game_rows: List[CanonicalGameRow] = []
    room_rows: List[CanonicalGameRoomRow] = []
    stats = {
        "fetched": 0,
        "validation_failed": 0,
        "unresolved_team": 0,
        "built": 0,
    }

    # Track unique unresolved (provider, provider_team_id) pairs for
    # the final summary. The resolver itself dedupes log lines, but
    # the runner wants a count for the report.
    unresolved_seen: set = set()

    for dto in dtos:
        stats["fetched"] += 1

        err = validate_provider_game(dto)
        if err is not None:
            stats["validation_failed"] += 1
            logger.error(
                "❌ Provider payload rejected — provider=%s "
                "provider_game_id=%s reason=%s",
                PROVIDER_NAME,
                dto.provider_game_id,
                err,
            )
            continue

        home_team_id = resolver.resolve(PROVIDER_NAME, dto.home_provider_team_id)
        away_team_id = resolver.resolve(PROVIDER_NAME, dto.away_provider_team_id)

        missing = []
        if home_team_id is None:
            missing.append(("home", dto.home_provider_team_id))
            unresolved_seen.add((PROVIDER_NAME, dto.home_provider_team_id))
        if away_team_id is None:
            missing.append(("away", dto.away_provider_team_id))
            unresolved_seen.add((PROVIDER_NAME, dto.away_provider_team_id))

        if missing:
            stats["unresolved_team"] += 1
            logger.warning(
                "⚠️ unresolved team mapping — skipping game "
                "provider=%s provider_game_id=%s league=%s missing=%s",
                PROVIDER_NAME,
                dto.provider_game_id,
                dto.league,
                missing,
            )
            continue

        # Both teams resolved — build canonical rows.
        # mypy/type-checker note: we just narrowed both team IDs to non-None.
        game_row = to_canonical_game(
            PROVIDER_NAME,
            dto,
            home_team_id,  # type: ignore[arg-type]
            away_team_id,  # type: ignore[arg-type]
            now=now,
        )
        room_row = to_canonical_game_room(
            PROVIDER_NAME,
            game_row,
            now=now,
        )
        game_rows.append(game_row)
        room_rows.append(room_row)
        stats["built"] += 1

    stats["unique_unresolved_team_ids"] = len(unresolved_seen)
    return game_rows, room_rows, stats


def upsert_games(
    client: SupabaseClient, rows: List[CanonicalGameRow], *, dry_run: bool
) -> None:
    if not rows:
        logger.info("→ no games to upsert")
        return

    if dry_run:
        logger.info(
            "→ [dry-run] would upsert %d row(s) into public.games "
            "(on_conflict=provider,provider_game_id)",
            len(rows),
        )
        for row in rows:
            logger.info(
                "🔄 [dry-run] Canonical game upserted — provider=%s "
                "provider_game_id=%s league=%s status=%s home=%d away=%d "
                "kickoff=%s",
                row.provider,
                row.provider_game_id,
                row.league,
                row.status,
                row.home_score,
                row.away_score,
                _jsonify_dt(row.start_time),
            )
        return

    body = [game_row_to_json(r) for r in rows]
    client.post(
        "/games?on_conflict=provider,provider_game_id",
        body,
    )
    for row in rows:
        logger.info(
            "🔄 Canonical game upserted — provider=%s provider_game_id=%s "
            "league=%s status=%s home=%d away=%d kickoff=%s",
            row.provider,
            row.provider_game_id,
            row.league,
            row.status,
            row.home_score,
            row.away_score,
            _jsonify_dt(row.start_time),
        )


def upsert_game_rooms(
    client: SupabaseClient, rows: List[CanonicalGameRoomRow], *, dry_run: bool
) -> None:
    if not rows:
        logger.info("→ no game_rooms to upsert")
        return

    if dry_run:
        logger.info(
            "→ [dry-run] would upsert %d row(s) into public.game_rooms "
            "(on_conflict=game_id)",
            len(rows),
        )
        for row in rows:
            logger.info(
                "🏟️ [dry-run] Game room upserted — game_id=%s room_id=%s "
                "status=%s opens_at=%s",
                row.game_id,
                row.room_id,
                row.status,
                _jsonify_dt(row.opens_at),
            )
        return

    body = [game_room_row_to_json(r) for r in rows]
    client.post(
        "/game_rooms?on_conflict=game_id",
        body,
    )
    for row in rows:
        logger.info(
            "🏟️ Game room upserted — game_id=%s room_id=%s status=%s "
            "opens_at=%s",
            row.game_id,
            row.room_id,
            row.status,
            _jsonify_dt(row.opens_at),
        )


# ─────────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────────


def _build_resolver(client: Optional[SupabaseClient]) -> TeamResolver:
    """
    Wire the resolver's two injected callables to in-memory dicts
    pre-populated from Supabase. Falls back to empty dicts when no
    Supabase client is available (offline dry-run) — every team will
    then resolve to None and the caller will skip every game.
    """
    mapping: Dict[str, str] = {}
    teams_index: Dict[Tuple[str, str], str] = {}
    if client is not None:
        mapping = load_provider_mappings(client, provider=PROVIDER_NAME)
        teams_index = load_teams_index(client)
        logger.info(
            "🟢 Provider mappings loaded — provider=%s rows=%d "
            "(teams_index rows=%d)",
            PROVIDER_NAME,
            len(mapping),
            len(teams_index),
        )
    else:
        logger.warning(
            "⚠️ No Supabase client — resolver will report every team "
            "as unresolved (offline dry-run mode)"
        )

    def db_lookup(provider: str, provider_team_id: str) -> Optional[str]:
        if provider != PROVIDER_NAME:
            return None
        return mapping.get(provider_team_id)

    def teams_table_lookup(league: str, abbreviation: str) -> Optional[str]:
        return teams_index.get((league.lower(), abbreviation.upper()))

    return TeamResolver(
        db_lookup=db_lookup,
        teams_table_lookup=teams_table_lookup,
    )


def run(args: argparse.Namespace) -> int:
    league = args.league.lower()
    if league not in SUPPORTED_LEAGUES:
        logger.error(
            "❌ ingest failed — unsupported --league %r (allowed: %s)",
            league,
            ", ".join(SUPPORTED_LEAGUES),
        )
        return 1

    # ---- Credentials policy ----
    supabase_url = os.environ.get("SUPABASE_URL")
    service_role = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    anon_key = os.environ.get("SUPABASE_ANON_KEY")

    client: Optional[SupabaseClient] = None
    if args.dry_run:
        # Dry-run: prefer service role, accept anon (read-only), tolerate
        # neither (offline mode — every team will resolve to None).
        if supabase_url and (service_role or anon_key):
            key = service_role or anon_key
            client = SupabaseClient(supabase_url, key)  # type: ignore[arg-type]
        elif supabase_url:
            logger.warning(
                "⚠️ SUPABASE_URL set without a key — dry-run will run "
                "offline (no mappings loaded)"
            )
        else:
            logger.warning(
                "⚠️ SUPABASE_URL not set — dry-run will run offline "
                "(no mappings loaded; every team will report as unresolved)"
            )
    else:
        # Real run: require URL + service-role key. Anon is rejected
        # because writes need to bypass RLS.
        if not supabase_url:
            logger.error(
                "❌ ingest failed — SUPABASE_URL env var required for "
                "real run (use --dry-run for read-only mode)"
            )
            return 1
        if not service_role:
            logger.error(
                "❌ ingest failed — SUPABASE_SERVICE_ROLE_KEY env var "
                "required for real run; SUPABASE_ANON_KEY is NOT accepted "
                "(writes need to bypass RLS). Use --dry-run for read-only mode."
            )
            return 1
        client = SupabaseClient(supabase_url, service_role)

    mode = "DRY-RUN" if args.dry_run else "LIVE"
    bar = "─" * 72
    print(bar)
    print(f"ESPN INGEST — mode={mode}  league={league}  "
          f"window_hours={args.window_hours}")
    print(bar)

    # ---- Resolver ----
    try:
        resolver = _build_resolver(client)
    except Exception as exc:  # noqa: BLE001
        logger.error(
            "❌ ingest failed — could not load provider mappings (%s)", exc
        )
        return 1

    # ---- ESPN fetch ----
    provider = ESPNProvider(leagues=[league])
    try:
        dtos = fetch_dtos(provider, window_hours=args.window_hours)
    except Exception as exc:  # noqa: BLE001 — provider raises arbitrary errors
        logger.error(
            "❌ ingest failed — ESPN fetch error (%s)", exc
        )
        return 1

    # ---- Build canonical rows ----
    game_rows, room_rows, stats = resolve_and_build_rows(dtos, resolver)

    # ---- Upsert ----
    try:
        if client is None and not args.dry_run:
            # Defensive — should be impossible given the cred check above.
            logger.error("❌ ingest failed — no Supabase client in real-run mode")
            return 1

        # In offline dry-run there's no client; pass a sentinel that
        # never gets called because rows are short-circuited above.
        upsert_games(client or _OfflineSink(), game_rows, dry_run=args.dry_run)
        upsert_game_rooms(client or _OfflineSink(), room_rows, dry_run=args.dry_run)
    except Exception as exc:  # noqa: BLE001
        logger.error(
            "❌ ingest failed — Supabase upsert error (%s)", exc
        )
        return 1

    # ---- Final summary ----
    print(bar)
    print("ESPN INGEST RESULT")
    print(bar)
    print(f"  mode:                    {mode}")
    print(f"  league:                  {league}")
    print(f"  window_hours:            {args.window_hours}")
    print(f"  ESPN events fetched:     {stats['fetched']}")
    print(f"  validation failures:     {stats['validation_failed']}")
    print(f"  unresolved-team skips:   {stats['unresolved_team']}")
    print(
        f"  unique unresolved IDs:   "
        f"{stats.get('unique_unresolved_team_ids', 0)}"
    )
    print(f"  rows built:              {stats['built']}")
    print(f"  games upserted:          "
          f"{0 if args.dry_run else len(game_rows)}"
          f"  (dry_run={args.dry_run})")
    print(f"  game_rooms upserted:     "
          f"{0 if args.dry_run else len(room_rows)}"
          f"  (dry_run={args.dry_run})")
    print(bar)

    return 0


class _OfflineSink:
    """No-op stand-in for SupabaseClient in offline dry-run mode.

    Never invoked in practice — `upsert_*` short-circuits on
    `dry_run=True` before calling any client method. Exists so the
    type signatures stay clean without spreading `Optional[Client]`
    branches through the upsert helpers.
    """

    def post(self, *args: Any, **kwargs: Any) -> None:  # pragma: no cover
        raise RuntimeError(
            "Offline sink should never be called — "
            "this is a real-run code-path bug"
        )

    def get(self, *args: Any, **kwargs: Any) -> List[Dict[str, Any]]:  # pragma: no cover
        raise RuntimeError(
            "Offline sink should never be called — "
            "this is a real-run code-path bug"
        )


# ─────────────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────────────


def _configure_logging(verbose: bool) -> None:
    level_name = os.environ.get("JUMBO_LOG_LEVEL")
    if level_name:
        level = getattr(logging, level_name.upper(), logging.INFO)
    else:
        level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )


def main(argv: Iterable[str] = ()) -> int:
    parser = argparse.ArgumentParser(
        prog="espn_ingest.py",
        description=(
            "Real ESPN ingest runner. Fetches NFL live + scheduled "
            "games via ESPNProvider, resolves teams through "
            "public.provider_team_mappings, and upserts canonical "
            "rows into public.games + public.game_rooms."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print intended writes; perform no Supabase mutations.",
    )
    parser.add_argument(
        "--league",
        choices=SUPPORTED_LEAGUES,
        default="nfl",
        help="League to ingest (default: nfl). One league per invocation.",
    )
    parser.add_argument(
        "--window-hours",
        type=int,
        default=168,
        help="Scheduled-game lookahead window in hours (default: 168 = 7d).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Debug-level logging.",
    )
    args = parser.parse_args(list(argv))
    _configure_logging(args.verbose)
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
