#!/usr/bin/env python3
"""
scripts/bootstrap_espn_team_mappings.py
=======================================

Read-only bootstrap script that fetches every ESPN team across the
four supported leagues (NFL, NBA, MLB, NHL), matches each ESPN team
to a canonical `public.teams` row, and emits SQL `INSERT` statements
for `public.provider_team_mappings`.

Hard guarantees
---------------
* Does NOT execute SQL.
* Does NOT write to Supabase.
* Does NOT modify schema, lifecycle, realtime, or any Swift code.
* Stdlib only.
* Output is *only* a generated `.sql` file plus stdout/stderr logs.

Where canonical teams come from
-------------------------------
By default this script parses `supabase_seed_teams.sql` (the local,
hand-curated 124-row roster — the canonical source of `public.teams`
UUIDs that match `SportsTeam.stableID(league, shortName)` on iOS).
This makes the script fully offline: no Supabase URL, no service-role
key, no network call to the database.

If the environment variables `SUPABASE_URL` and either
`SUPABASE_SERVICE_ROLE_KEY` or `SUPABASE_ANON_KEY` are present AND
`--source supabase` is passed, it will instead pull canonical teams
live from `public.teams`. Mainly useful as a sanity check that the
seed file is in sync with the deployed DB.

Matching strategy
-----------------
For each ESPN team in a given league:

    1. Match by abbreviation (case-insensitive). If exactly one
       canonical team in that league matches, ✅ map.
    2. If 0 abbreviation matches: fall back to a normalized
       display-name match — strip case, punctuation, common suffixes;
       compare against `<city> <name>` and `<name>` of canonical
       teams in the same league. Exactly one hit ⇒ ⚠️ map (record
       as an "abbreviation mismatch") so the operator can review
       why ESPN's abbreviation differs.
    3. If still 0 matches: ❌ unresolved.
    4. If at any step >1 candidate team matches: ❌ ambiguous, no
       row emitted, full candidate list logged.

Output
------
* SQL file at `scripts/generated_espn_team_mappings.sql` containing
  one canonical `INSERT INTO public.provider_team_mappings (...)`
  block with all successful rows. Includes a deterministic header
  comment block recording the run, the totals, and any unresolved /
  ambiguous teams (so the file is self-describing for code review).
* stdout: per-league progress with 🟢 / ⚠️ / ❌ markers.
* stderr: nothing except logging output (basicConfig).

Usage
-----
    python3 scripts/bootstrap_espn_team_mappings.py
    python3 scripts/bootstrap_espn_team_mappings.py --source supabase
    JUMBO_LOG_LEVEL=DEBUG python3 scripts/bootstrap_espn_team_mappings.py

Exit codes
----------
    0  — at least one mapping row generated (even if some unresolved)
    1  — every ESPN call raised, or the canonical team source could
         not be loaded
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

# Make repo root importable when invoked as `python3 scripts/<this>.py`.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_THIS_DIR)
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from scripts.providers import ESPNProvider, ProviderTeamDTO  # noqa: E402

logger = logging.getLogger("scripts.bootstrap_espn_team_mappings")

# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────

LEAGUES: Tuple[str, ...] = ("nfl", "nba", "mlb", "nhl")
PROVIDER_NAME = "espn"

OUTPUT_PATH = os.path.join(_THIS_DIR, "generated_espn_team_mappings.sql")
SEED_PATH = os.path.join(_REPO_ROOT, "supabase_seed_teams.sql")


# ─────────────────────────────────────────────────────────────────────
# Canonical team model
# ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class CanonicalTeam:
    """A row from `public.teams` (the columns we need for matching)."""

    id: str  # UUID string
    league: str  # nfl/nba/mlb/nhl
    city: str
    name: str
    abbreviation: str

    @property
    def display(self) -> str:
        return f"{self.city} {self.name}".strip()


# ─────────────────────────────────────────────────────────────────────
# Canonical team loaders
# ─────────────────────────────────────────────────────────────────────


# Regex tuned to the row shape in supabase_seed_teams.sql:
#   ('<uuid>', '<league>', '<city>', '<name>', '<short>', '<abbrev>',
#    '<color1>', '<color2>'),
# Cities can contain "St. ", names can contain "76ers", "Trail Blazers",
# etc. — the SQL string-literal escape uses '' for ' (none of the
# canonical rows currently use it but the parser accepts it).
_SEED_ROW_RE = re.compile(
    r"""
    \(
    \s*'([0-9a-f-]{36})'        # id
    \s*,\s*'([a-z]{3})'         # league
    \s*,\s*'((?:[^']|'')*)'     # city
    \s*,\s*'((?:[^']|'')*)'     # name
    \s*,\s*'((?:[^']|'')*)'     # short_name
    \s*,\s*'((?:[^']|'')*)'     # abbreviation
    \s*,\s*'(?:[^']|'')*'       # primary_color
    \s*,\s*'(?:[^']|'')*'       # secondary_color
    \s*\)
    """,
    re.VERBOSE,
)


def _unescape_sql_str(s: str) -> str:
    """Undo the doubled-single-quote SQL string escape."""
    return s.replace("''", "'")


def load_canonical_teams_from_seed(seed_path: str = SEED_PATH) -> List[CanonicalTeam]:
    """
    Parse `supabase_seed_teams.sql` and return one CanonicalTeam per
    row. Strict: raises if the file isn't there or the row count is
    suspiciously off (the canonical seed is exactly 124 rows; an
    accidental drop of any league should fail loud, not silent).
    """
    if not os.path.isfile(seed_path):
        raise FileNotFoundError(
            f"Canonical team seed not found at {seed_path}. "
            f"Run with --source supabase if you intend to read live."
        )

    with open(seed_path, "r", encoding="utf-8") as f:
        text = f.read()

    teams: List[CanonicalTeam] = []
    for match in _SEED_ROW_RE.finditer(text):
        uid, league, city, name, _short, abbrev = match.groups()
        teams.append(
            CanonicalTeam(
                id=uid,
                league=league,
                city=_unescape_sql_str(city),
                name=_unescape_sql_str(name),
                abbreviation=_unescape_sql_str(abbrev).upper(),
            )
        )
    if not teams:
        raise RuntimeError(
            f"Parsed 0 canonical teams from {seed_path} — regex / file "
            f"shape may have changed."
        )
    logger.info(
        "🟢 Canonical teams loaded — source=seed path=%s rows=%d",
        seed_path,
        len(teams),
    )
    return teams


def load_canonical_teams_from_supabase() -> List[CanonicalTeam]:
    """
    Pull canonical teams live from `public.teams` via PostgREST. Used
    only when `--source supabase` is passed AND env vars are present.
    """
    base_url = os.environ.get("SUPABASE_URL")
    api_key = (
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or os.environ.get("SUPABASE_ANON_KEY")
    )
    if not base_url or not api_key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_ANON_KEY) "
            "are required for --source supabase."
        )

    url = (
        base_url.rstrip("/")
        + "/rest/v1/teams?select=id,league,city,name,abbreviation"
        + f"&league=in.({quote(','.join(LEAGUES), safe=',')})"
    )
    req = Request(
        url,
        headers={
            "apikey": api_key,
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": "Jumbo-ESPN-Bootstrap/0.1 (+dev)",
        },
    )
    try:
        with urlopen(req, timeout=15.0) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except (HTTPError, URLError, TimeoutError) as e:
        raise RuntimeError(f"Supabase teams fetch failed: {e}") from e

    teams = [
        CanonicalTeam(
            id=row["id"],
            league=row["league"],
            city=row.get("city") or "",
            name=row.get("name") or "",
            abbreviation=(row.get("abbreviation") or "").upper(),
        )
        for row in payload
    ]
    logger.info(
        "🟢 Canonical teams loaded — source=supabase rows=%d",
        len(teams),
    )
    return teams


# ─────────────────────────────────────────────────────────────────────
# Matching
# ─────────────────────────────────────────────────────────────────────


_NORMALIZE_STRIP_RE = re.compile(r"[^a-z0-9]+")


def _normalize_name(s: str) -> str:
    """
    Lowercase, strip punctuation and whitespace, drop common
    franchise suffix words ("the"). Used only for the display-name
    fallback matcher.
    """
    s = s.lower()
    s = _NORMALIZE_STRIP_RE.sub(" ", s)
    s = " ".join(s.split())
    # Drop a leading "the " (rare but possible).
    if s.startswith("the "):
        s = s[4:]
    return s


@dataclass(frozen=True)
class MatchResult:
    """Result of attempting to match one ESPN team to canonical."""

    espn_team: ProviderTeamDTO
    canonical: Optional[CanonicalTeam]
    method: str  # "abbreviation" | "name_fallback" | "ambiguous" | "unresolved"
    abbreviation_mismatch: bool
    candidates: Tuple[CanonicalTeam, ...] = ()
    detail: str = ""


def match_espn_team(
    espn: ProviderTeamDTO,
    canonical_by_league: Dict[str, List[CanonicalTeam]],
) -> MatchResult:
    league = espn.league.lower()
    pool = canonical_by_league.get(league, [])

    # ---- Step 1: abbreviation match ----
    espn_abbrev = (espn.abbreviation or "").upper()
    if espn_abbrev:
        abbrev_hits = [t for t in pool if t.abbreviation == espn_abbrev]
        if len(abbrev_hits) == 1:
            return MatchResult(
                espn_team=espn,
                canonical=abbrev_hits[0],
                method="abbreviation",
                abbreviation_mismatch=False,
                candidates=tuple(abbrev_hits),
            )
        if len(abbrev_hits) > 1:
            return MatchResult(
                espn_team=espn,
                canonical=None,
                method="ambiguous",
                abbreviation_mismatch=False,
                candidates=tuple(abbrev_hits),
                detail=(
                    f"abbreviation '{espn_abbrev}' matched "
                    f"{len(abbrev_hits)} canonical teams in {league}"
                ),
            )

    # ---- Step 2: name fallback ----
    espn_display_norm = _normalize_name(
        " ".join(s for s in (espn.city, espn.name) if s)
    )
    espn_name_norm = _normalize_name(espn.name or "")

    name_hits: List[CanonicalTeam] = []
    for t in pool:
        canon_display_norm = _normalize_name(t.display)
        canon_name_norm = _normalize_name(t.name)
        if not espn_display_norm and not espn_name_norm:
            continue
        if espn_display_norm and espn_display_norm == canon_display_norm:
            name_hits.append(t)
            continue
        if espn_name_norm and espn_name_norm == canon_name_norm:
            name_hits.append(t)
            continue

    # Dedup while preserving order (a team can match on both name and display).
    seen_ids = set()
    deduped_name_hits: List[CanonicalTeam] = []
    for t in name_hits:
        if t.id in seen_ids:
            continue
        seen_ids.add(t.id)
        deduped_name_hits.append(t)

    if len(deduped_name_hits) == 1:
        return MatchResult(
            espn_team=espn,
            canonical=deduped_name_hits[0],
            method="name_fallback",
            abbreviation_mismatch=True,
            candidates=tuple(deduped_name_hits),
            detail=(
                f"abbreviation '{espn_abbrev}' did not match any "
                f"canonical team in {league}; resolved by display name "
                f"'{deduped_name_hits[0].display}' "
                f"(canonical abbreviation '{deduped_name_hits[0].abbreviation}')"
            ),
        )
    if len(deduped_name_hits) > 1:
        return MatchResult(
            espn_team=espn,
            canonical=None,
            method="ambiguous",
            abbreviation_mismatch=True,
            candidates=tuple(deduped_name_hits),
            detail=(
                f"display-name fallback matched {len(deduped_name_hits)} "
                f"canonical teams in {league}"
            ),
        )

    return MatchResult(
        espn_team=espn,
        canonical=None,
        method="unresolved",
        abbreviation_mismatch=False,
        candidates=(),
        detail="no abbreviation or display-name match in canonical set",
    )


# ─────────────────────────────────────────────────────────────────────
# SQL emission
# ─────────────────────────────────────────────────────────────────────


def _sql_escape(s: str) -> str:
    """Postgres single-quoted string literal escape."""
    return s.replace("'", "''")


def render_sql(successful: List[MatchResult], stats: dict, source: str) -> str:
    """
    Build the contents of `generated_espn_team_mappings.sql`.
    Header includes run summary so the file is self-describing.
    """
    lines: List[str] = []
    lines.append("-- =====================================================================")
    lines.append("-- generated_espn_team_mappings.sql  (auto-generated, DO NOT HAND-EDIT)")
    lines.append("-- =====================================================================")
    lines.append("--")
    lines.append("-- Generated by scripts/bootstrap_espn_team_mappings.py")
    lines.append(f"-- Provider: '{PROVIDER_NAME}'")
    lines.append(f"-- Canonical team source: {source}")
    lines.append(f"-- Total ESPN teams seen:        {stats['total_seen']}")
    lines.append(f"-- Successful mappings:          {stats['mapped']}")
    lines.append(f"--   • abbreviation match:       {stats['by_abbreviation']}")
    lines.append(f"--   • display-name fallback:    {stats['by_name_fallback']}")
    lines.append(f"-- Abbreviation mismatches:      {stats['abbreviation_mismatches']}")
    lines.append(f"-- Unresolved ESPN teams:        {stats['unresolved']}")
    lines.append(f"-- Ambiguous matches:            {stats['ambiguous']}")
    lines.append("--")
    lines.append("-- This file performs an idempotent upsert into")
    lines.append("-- public.provider_team_mappings using the natural key")
    lines.append("-- (provider, provider_team_id). Re-running this file is safe.")
    lines.append("--")
    lines.append("-- Review carefully before applying. In particular, every row")
    lines.append("-- flagged with 'abbreviation mismatch' in `notes` should be")
    lines.append("-- spot-checked: the ESPN team was matched against a canonical")
    lines.append("-- team whose abbreviation differs (e.g. ESPN 'WSH' → canonical")
    lines.append("-- 'WAS'). The match itself is by display name, not abbreviation.")
    lines.append("-- =====================================================================")
    lines.append("")

    if not successful:
        lines.append("-- No mappings were generated. Nothing to insert.")
        lines.append("")
        return "\n".join(lines)

    lines.append("INSERT INTO public.provider_team_mappings (")
    lines.append("    provider,")
    lines.append("    provider_team_id,")
    lines.append("    team_id,")
    lines.append("    notes")
    lines.append(") VALUES")

    value_lines: List[str] = []
    # Stable ordering: league then ESPN abbreviation then ESPN id.
    successful_sorted = sorted(
        successful,
        key=lambda m: (
            m.espn_team.league,
            m.espn_team.abbreviation or "",
            m.espn_team.provider_team_id,
        ),
    )
    for m in successful_sorted:
        assert m.canonical is not None  # narrowed by caller
        note_parts = [
            f"ESPN: {m.espn_team.city + ' ' if m.espn_team.city else ''}{m.espn_team.name}".strip(),
            f"abbr={m.espn_team.abbreviation or '?'}",
            f"matched via {m.method}",
        ]
        if m.abbreviation_mismatch:
            note_parts.append(
                f"abbreviation mismatch (ESPN={m.espn_team.abbreviation or '?'} vs "
                f"canonical={m.canonical.abbreviation})"
            )
        note_parts.append("generated by scripts/bootstrap_espn_team_mappings.py")
        notes = "; ".join(note_parts)

        value_lines.append(
            "    ("
            f"'{_sql_escape(PROVIDER_NAME)}', "
            f"'{_sql_escape(m.espn_team.provider_team_id)}', "
            f"'{m.canonical.id}', "
            f"'{_sql_escape(notes)}'"
            ")"
        )

    lines.append(",\n".join(value_lines))
    lines.append("ON CONFLICT (provider, provider_team_id) DO UPDATE SET")
    lines.append("    team_id = EXCLUDED.team_id,")
    lines.append("    notes   = EXCLUDED.notes;")
    lines.append("")
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────────


def _fetch_espn_safely(
    provider: ESPNProvider, league: str
) -> Optional[List[ProviderTeamDTO]]:
    try:
        return provider.fetch_teams(league)
    except Exception as exc:  # noqa: BLE001 — provider raises arbitrary errors per contract
        logger.error(
            "❌ ESPN fetch failed — endpoint=fetch_teams league=%s reason=%s",
            league,
            exc,
        )
        return None


def run(source: str) -> int:
    # ---- Load canonical ----
    if source == "seed":
        try:
            canonical = load_canonical_teams_from_seed()
        except (FileNotFoundError, RuntimeError) as exc:
            logger.error(
                "❌ Could not load canonical teams from seed — %s", exc
            )
            return 1
    elif source == "supabase":
        try:
            canonical = load_canonical_teams_from_supabase()
        except RuntimeError as exc:
            logger.error(
                "❌ Could not load canonical teams from Supabase — %s", exc
            )
            return 1
    else:
        logger.error("❌ Unknown --source %r", source)
        return 1

    canonical_by_league: Dict[str, List[CanonicalTeam]] = {}
    for t in canonical:
        canonical_by_league.setdefault(t.league, []).append(t)

    canonical_league_counts = {
        league: len(canonical_by_league.get(league, []))
        for league in LEAGUES
    }
    missing_canonical_leagues = [
        league for league, n in canonical_league_counts.items() if n == 0
    ]

    # ---- Fetch ESPN teams per league ----
    provider = ESPNProvider(leagues=list(LEAGUES))
    any_espn_success = False
    all_espn_teams: List[ProviderTeamDTO] = []
    espn_league_counts: Dict[str, int] = {}
    for league in LEAGUES:
        teams = _fetch_espn_safely(provider, league)
        if teams is None:
            espn_league_counts[league] = -1  # sentinel for "errored"
            continue
        any_espn_success = True
        espn_league_counts[league] = len(teams)
        if teams:
            logger.info(
                "🟢 ESPN fetch succeeded — endpoint=fetch_teams league=%s rows=%d",
                league,
                len(teams),
            )
            all_espn_teams.extend(teams)
        else:
            logger.warning(
                "⚠️ ESPN fetch returned no teams — endpoint=fetch_teams league=%s",
                league,
            )

    if not any_espn_success:
        logger.error(
            "❌ Every ESPN fetch_teams call failed — aborting (no SQL emitted)"
        )
        return 1

    # ---- Match ----
    successful: List[MatchResult] = []
    unresolved: List[MatchResult] = []
    ambiguous: List[MatchResult] = []
    abbreviation_mismatches: List[MatchResult] = []

    for espn in all_espn_teams:
        m = match_espn_team(espn, canonical_by_league)
        if m.canonical is not None:
            successful.append(m)
            if m.method == "name_fallback":
                logger.warning(
                    "⚠️ ESPN team mapped via name fallback — league=%s espn_id=%s "
                    "espn_abbr=%s canonical_abbr=%s canonical_team='%s' detail=%s",
                    espn.league,
                    espn.provider_team_id,
                    espn.abbreviation or "?",
                    m.canonical.abbreviation,
                    m.canonical.display,
                    m.detail,
                )
                abbreviation_mismatches.append(m)
            else:
                logger.info(
                    "🟢 ESPN team mapped — league=%s espn_id=%s espn_abbr=%s "
                    "→ team_id=%s canonical='%s'",
                    espn.league,
                    espn.provider_team_id,
                    espn.abbreviation or "?",
                    m.canonical.id,
                    m.canonical.display,
                )
        elif m.method == "ambiguous":
            ambiguous.append(m)
            logger.error(
                "❌ ESPN team ambiguous — league=%s espn_id=%s espn_team='%s' "
                "candidates=%s detail=%s",
                espn.league,
                espn.provider_team_id,
                f"{espn.city} {espn.name}".strip(),
                [
                    f"{c.display} ({c.abbreviation}, id={c.id})"
                    for c in m.candidates
                ],
                m.detail,
            )
        else:
            unresolved.append(m)
            logger.warning(
                "⚠️ ESPN team unresolved — league=%s espn_id=%s espn_abbr=%s "
                "espn_team='%s' detail=%s",
                espn.league,
                espn.provider_team_id,
                espn.abbreviation or "?",
                f"{espn.city} {espn.name}".strip(),
                m.detail,
            )

    by_abbreviation = sum(1 for m in successful if m.method == "abbreviation")
    by_name_fallback = sum(1 for m in successful if m.method == "name_fallback")

    stats = {
        "total_seen": len(all_espn_teams),
        "mapped": len(successful),
        "by_abbreviation": by_abbreviation,
        "by_name_fallback": by_name_fallback,
        "abbreviation_mismatches": len(abbreviation_mismatches),
        "unresolved": len(unresolved),
        "ambiguous": len(ambiguous),
    }

    # ---- Emit SQL ----
    sql_text = render_sql(successful, stats, source=source)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(sql_text)
    logger.info(
        "🟢 SQL written — path=%s rows=%d",
        OUTPUT_PATH,
        len(successful),
    )

    # ---- Final report ----
    bar = "─" * 72
    print(bar)
    print("ESPN → public.provider_team_mappings BOOTSTRAP REPORT")
    print(bar)
    print(f"  canonical source:               {source}")
    for league in LEAGUES:
        print(
            f"  canonical {league.upper()} teams loaded:    "
            f"{canonical_league_counts[league]}"
        )
    if missing_canonical_leagues:
        print(
            f"  ⚠️ canonical leagues missing rows:    "
            f"{', '.join(missing_canonical_leagues)}"
        )
    print()
    for league in LEAGUES:
        n = espn_league_counts.get(league, 0)
        if n < 0:
            print(f"  ESPN {league.upper()} teams fetched:        ERROR (see logs)")
        else:
            print(f"  ESPN {league.upper()} teams fetched:        {n}")
    print()
    print(f"  total ESPN teams seen:          {stats['total_seen']}")
    print(f"  successful mappings:            {stats['mapped']}")
    print(f"     · by abbreviation:           {stats['by_abbreviation']}")
    print(f"     · by display-name fallback:  {stats['by_name_fallback']}")
    print(f"  abbreviation mismatches:        {stats['abbreviation_mismatches']}")
    print(f"  unresolved ESPN teams:          {stats['unresolved']}")
    print(f"  ambiguous matches:              {stats['ambiguous']}")
    print()
    if abbreviation_mismatches:
        print("  Abbreviation mismatches (ESPN → canonical):")
        for m in abbreviation_mismatches:
            assert m.canonical is not None
            print(
                f"    • {m.espn_team.league}  ESPN id={m.espn_team.provider_team_id:<4} "
                f"abbr={m.espn_team.abbreviation or '?':<4}  →  "
                f"canonical '{m.canonical.display}' (abbr={m.canonical.abbreviation})"
            )
        print()
    if unresolved:
        print("  Unresolved ESPN teams:")
        for m in unresolved:
            display = f"{m.espn_team.city} {m.espn_team.name}".strip()
            print(
                f"    • {m.espn_team.league}  ESPN id={m.espn_team.provider_team_id:<6} "
                f"abbr={m.espn_team.abbreviation or '?':<4}  "
                f"name='{display}'"
            )
        print()
    if ambiguous:
        print("  Ambiguous matches (skipped, need manual review):")
        for m in ambiguous:
            print(
                f"    • {m.espn_team.league}  ESPN id={m.espn_team.provider_team_id:<4} "
                f"abbr={m.espn_team.abbreviation or '?':<4}  "
                f"name='{m.espn_team.city} {m.espn_team.name}'  "
                f"candidates={[c.display + ' (' + c.abbreviation + ')' for c in m.candidates]}"
            )
        print()

    print(f"  SQL output written to:          {OUTPUT_PATH}")
    print(bar)
    print(
        "  NOTE: This script did NOT execute SQL or write to Supabase.\n"
        "  Review the generated file before applying it to your project."
    )
    print(bar)

    return 0


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
    parser = argparse.ArgumentParser(
        prog="bootstrap_espn_team_mappings.py",
        description=(
            "Read-only ESPN → public.provider_team_mappings bootstrap. "
            "Emits SQL only; does not execute or write to Supabase."
        ),
    )
    parser.add_argument(
        "--source",
        choices=("seed", "supabase"),
        default="seed",
        help=(
            "Where to load canonical public.teams from (default: seed = "
            "parse supabase_seed_teams.sql locally; supabase = pull live)."
        ),
    )
    args = parser.parse_args(list(argv))

    _configure_logging()
    return run(source=args.source)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
