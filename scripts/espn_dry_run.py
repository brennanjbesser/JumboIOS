#!/usr/bin/env python3
"""
scripts/espn_dry_run.py
=======================

Read-only ESPN ingest probe. Uses `ESPNProvider` to hit ESPN's public
site API for NFL data and prints what *would* be upserted into
`public.games` / `public.game_rooms` / `public.provider_team_mappings`
— but does NOT touch Supabase, write any rows, or mutate any state.

Intent
------
Smoke-test the live provider before wiring it into the lifecycle
worker. Lets us eyeball:

* whether ESPN actually returns events for NFL right now
* whether status / score / clock decoding lines up with the canonical
  GameStatus enum
* what `provider_team_id` shape ESPN emits (so we can pre-seed
  `public.provider_team_mappings (provider='espn', ...)` rows by hand
  before flipping the worker over to ESPN)

Out of scope
------------
* Supabase writes
* Schema changes
* iOS / UI changes
* Lifecycle worker changes
* Other leagues (NBA/MLB/NHL) — limited to NFL for this milestone

Usage
-----
    python3 scripts/espn_dry_run.py

Or with a verbose log level:

    JUMBO_LOG_LEVEL=DEBUG python3 scripts/espn_dry_run.py

Exits non-zero only if every fetch raises (network down, ESPN 5xx).
A fetch that succeeds with zero events exits 0 with a ⚠️ log.
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Iterable, List

# Make the repo root importable when the script is invoked directly
# (`python3 scripts/espn_dry_run.py`) rather than via `-m`.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_THIS_DIR)
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from scripts.providers import (  # noqa: E402  (import after sys.path tweak)
    ESPNProvider,
    ProviderGameDTO,
    ProviderTeamDTO,
)

logger = logging.getLogger("scripts.espn_dry_run")


# ─────────────────────────────────────────────────────────────────────
# Pretty printers
# ─────────────────────────────────────────────────────────────────────


def _print_header(title: str) -> None:
    bar = "─" * 72
    print(bar)
    print(title)
    print(bar)


def _print_game(dto: ProviderGameDTO) -> None:
    """
    Print every field that would be written to `public.games` for
    this DTO (modulo the home/away UUIDs the resolver fills in).
    Field order intentionally mirrors `CanonicalGameRow` for easy
    cross-referencing.
    """
    print(
        "  • provider_game_id        = {pid}\n"
        "    league                  = {league}\n"
        "    home_provider_team_id   = {home}\n"
        "    away_provider_team_id   = {away}\n"
        "    status                  = {status}\n"
        "    period                  = {period}\n"
        "    clock                   = {clock}\n"
        "    home_score              = {hs}\n"
        "    away_score              = {as_}\n"
        "    start_time (UTC)        = {start}\n"
        "    season                  = {season}".format(
            pid=dto.provider_game_id,
            league=dto.league,
            home=dto.home_provider_team_id,
            away=dto.away_provider_team_id,
            status=dto.status.value,
            period=dto.period if dto.period is not None else "—",
            clock=dto.clock if dto.clock is not None else "—",
            hs=dto.home_score,
            as_=dto.away_score,
            start=dto.start_time.isoformat(),
            season=dto.season if dto.season is not None else "—",
        )
    )
    print()


def _print_team(team: ProviderTeamDTO) -> None:
    """
    Print every field needed to pre-seed
    `public.provider_team_mappings (provider='espn', ...)` for this
    team. The `provider_team_id` here is the exact string ESPN puts
    in game payloads' competitor `team.id`.
    """
    display = team.name or team.abbreviation or "?"
    if team.city:
        display = f"{team.city} {display}".strip()
    print(
        "  • provider_team_id  = {pid:<6}  abbreviation = {ab:<5}  "
        "name = {name}".format(
            pid=team.provider_team_id,
            ab=team.abbreviation or "—",
            name=display,
        )
    )


# ─────────────────────────────────────────────────────────────────────
# Section runners
# ─────────────────────────────────────────────────────────────────────


def _fetch_safely(label: str, fn) -> "List[ProviderGameDTO] | List[ProviderTeamDTO] | None":
    """
    Call `fn`, returning the list on success, None on failure.
    Logs are emoji-prefixed to match the rest of the providers
    package style.
    """
    try:
        rows = fn()
    except Exception as exc:  # noqa: BLE001 — provider raises arbitrary errors per contract
        logger.error("❌ ESPN fetch failed — endpoint=%s reason=%s", label, exc)
        return None
    return rows


def run_dry_run() -> int:
    """
    Returns a process exit code:
        0  — at least one ESPN call succeeded (even if zero rows)
        1  — every ESPN call raised (network down, all 5xx, etc.)
    """
    provider = ESPNProvider(leagues=["nfl"])

    # Track whether *any* call succeeded so we can surface a useful
    # exit code without hiding individual failures.
    any_success = False

    # ---- Live games ----
    _print_header("ESPN NFL — LIVE GAMES (would-write to public.games)")
    live = _fetch_safely("fetch_live_games", provider.fetch_live_games)
    if live is not None:
        any_success = True
        if live:
            logger.info(
                "🟢 ESPN fetch succeeded — endpoint=fetch_live_games rows=%d",
                len(live),
            )
            for dto in live:
                _print_game(dto)
        else:
            logger.warning(
                "⚠️ ESPN fetch returned no live games — endpoint=fetch_live_games"
            )

    # ---- Scheduled games ----
    _print_header(
        "ESPN NFL — SCHEDULED GAMES (next 7d, would-write to public.games)"
    )
    scheduled = _fetch_safely(
        "fetch_scheduled_games", lambda: provider.fetch_scheduled_games(window_hours=168)
    )
    if scheduled is not None:
        any_success = True
        if scheduled:
            logger.info(
                "🟢 ESPN fetch succeeded — endpoint=fetch_scheduled_games rows=%d",
                len(scheduled),
            )
            for dto in scheduled:
                _print_game(dto)
        else:
            logger.warning(
                "⚠️ ESPN fetch returned no scheduled games — "
                "endpoint=fetch_scheduled_games window=168h"
            )

    # ---- Teams (provider_team_mappings bootstrap data) ----
    _print_header(
        "ESPN NFL — TEAMS (would-seed public.provider_team_mappings rows)"
    )
    teams = _fetch_safely("fetch_teams(nfl)", lambda: provider.fetch_teams("nfl"))
    if teams is not None:
        any_success = True
        if teams:
            logger.info(
                "🟢 ESPN fetch succeeded — endpoint=fetch_teams league=nfl rows=%d",
                len(teams),
            )
            for team in teams:
                _print_team(team)
            print()
        else:
            logger.warning(
                "⚠️ ESPN fetch returned no teams — endpoint=fetch_teams league=nfl"
            )

    # ---- Footer ----
    _print_header("DRY RUN COMPLETE — no Supabase writes performed")

    return 0 if any_success else 1


# ─────────────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────────────


def _configure_logging() -> None:
    level_name = os.environ.get("JUMBO_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )


def main(argv: Iterable[str] = ()) -> int:
    _configure_logging()
    return run_dry_run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
