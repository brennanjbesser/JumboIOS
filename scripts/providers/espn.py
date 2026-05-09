"""
scripts/providers/espn.py
=========================

ESPN-backed `SportsProvider` implementation. Targets ESPN's public
"site" API (no API key, no auth) so it can run in dev / CI without
secret handling:

    https://site.api.espn.com/apis/site/v2/sports/<sport>/<league>/scoreboard
    https://site.api.espn.com/apis/site/v2/sports/<sport>/<league>/teams

This is the *development* provider for ESPN — production-grade
ingest will eventually move to a paid feed (SportsDataIO, Sportradar,
etc.) with stricter SLAs. The contract surface is identical, so the
worker swaps providers with a one-line change.

Design notes
------------
* Stateless. No caching, no rate-limiting, no API keys. The worker
  controls cadence; this class is a thin HTTP→DTO mapper.
* Stdlib `urllib` only — no new dependencies.
* Returns `[]` on "no live games right now" (NOT raises).
* Raises `RuntimeError` on transient errors (timeout, non-2xx,
  malformed JSON) so the worker's retry/backoff layer decides.
* Provider team IDs are ESPN's numeric `team.id` as a string
  (e.g. `"12"` for the Chiefs). This is the value that appears in
  game payloads and is therefore the right key for
  `public.provider_team_mappings (provider='espn', provider_team_id='12')`.
* All timestamps are normalized to UTC, timezone-aware.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Callable, Dict, Iterable, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .base import SportsProvider
from .normalization import GameStatus, ProviderGameDTO, ProviderTeamDTO

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────

DEFAULT_BASE_URL = "https://site.api.espn.com"
DEFAULT_TIMEOUT_SECONDS = 10.0

# Map canonical lowercase league → ESPN (sport, league) URL segments.
# ESPN uses sport/league pairs; canonical is single lowercase token.
_LEAGUE_TO_ESPN_PATH: Dict[str, Tuple[str, str]] = {
    "nfl": ("football", "nfl"),
    "nba": ("basketball", "nba"),
    "mlb": ("baseball", "mlb"),
    "nhl": ("hockey", "nhl"),
}

# ESPN status keys (event.status.type.name) → canonical GameStatus.
# Source: ESPN's competition status type taxonomy. Anything not in
# this table is treated as "unknown" and the row is skipped with a
# ⚠️ log so we surface new states for review before they leak into
# canonical.
_ESPN_STATUS_TO_CANONICAL: Dict[str, GameStatus] = {
    "STATUS_SCHEDULED":      GameStatus.SCHEDULED,
    "STATUS_PRE_GAME":       GameStatus.PREGAME,
    "STATUS_IN_PROGRESS":    GameStatus.LIVE,
    "STATUS_FIRST_HALF":     GameStatus.LIVE,
    "STATUS_SECOND_HALF":    GameStatus.LIVE,
    "STATUS_HALFTIME":       GameStatus.HALFTIME,
    "STATUS_END_PERIOD":     GameStatus.LIVE,
    "STATUS_END_OF_PERIOD":  GameStatus.LIVE,
    "STATUS_FULL_TIME":      GameStatus.FINAL,
    "STATUS_FINAL":          GameStatus.FINAL,
    "STATUS_FINAL_OT":       GameStatus.FINAL,
    "STATUS_FINAL_PEN":      GameStatus.FINAL,
    "STATUS_POSTPONED":      GameStatus.POSTPONED,
    "STATUS_SUSPENDED":      GameStatus.POSTPONED,
    "STATUS_DELAYED":        GameStatus.PREGAME,
    "STATUS_RAIN_DELAY":     GameStatus.LIVE,
    "STATUS_CANCELED":       GameStatus.CANCELLED,
    "STATUS_FORFEIT":        GameStatus.CANCELLED,
}


# Type alias for a pluggable HTTP getter — makes the class trivially
# unit-testable by injecting a fake that returns canned JSON.
HttpGet = Callable[[str, float], dict]


# ─────────────────────────────────────────────────────────────────────
# Default HTTP getter (stdlib urllib)
# ─────────────────────────────────────────────────────────────────────


def _default_http_get(url: str, timeout_seconds: float) -> dict:
    """
    Fetch `url` and return parsed JSON. Raises RuntimeError on any
    failure (timeout, non-2xx, malformed JSON) so callers can map it
    to retry/backoff cleanly.

    A User-Agent is set because some CDN edges 403 unidentified
    clients on the public ESPN site API.
    """
    req = Request(
        url,
        headers={
            "User-Agent": "Jumbo-Sports-Ingest/0.1 (+dev)",
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(req, timeout=timeout_seconds) as resp:
            charset = resp.headers.get_content_charset() or "utf-8"
            body = resp.read().decode(charset)
    except HTTPError as e:
        raise RuntimeError(
            f"ESPN HTTP {e.code} for {url}: {e.reason}"
        ) from e
    except URLError as e:
        raise RuntimeError(f"ESPN network error for {url}: {e.reason}") from e
    except TimeoutError as e:
        raise RuntimeError(f"ESPN timeout for {url}") from e

    try:
        return json.loads(body)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"ESPN malformed JSON for {url}: {e}") from e


# ─────────────────────────────────────────────────────────────────────
# Provider
# ─────────────────────────────────────────────────────────────────────


class ESPNProvider(SportsProvider):
    """
    Development provider that pulls scoreboard + teams data from
    ESPN's public site API. Implements the full `SportsProvider`
    contract; suitable for dev, CI, and early-stage production.
    """

    name: str = "espn"

    def __init__(
        self,
        *,
        base_url: str = DEFAULT_BASE_URL,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        leagues: Optional[Iterable[str]] = None,
        http_get: Optional[HttpGet] = None,
    ) -> None:
        """
        Args:
            base_url: ESPN site API root. Override for testing or
                edge mirrors.
            timeout_seconds: Per-request socket timeout.
            leagues: Iterable of canonical lowercase leagues this
                instance should query (default: all four supported).
                Limiting at construction time saves N HTTP calls per
                ingest tick.
            http_get: Optional injectable transport. Signature is
                ``(url, timeout) -> parsed_json_dict``. Defaults to
                stdlib urllib. Tests pass a fake to avoid network.
        """
        self._base_url = base_url.rstrip("/")
        self._timeout_seconds = timeout_seconds
        self._http_get: HttpGet = http_get or _default_http_get

        if leagues is None:
            leagues = _LEAGUE_TO_ESPN_PATH.keys()
        self._leagues: Tuple[str, ...] = tuple(
            league.lower() for league in leagues
        )
        for league in self._leagues:
            if league not in _LEAGUE_TO_ESPN_PATH:
                raise ValueError(
                    f"ESPNProvider: unsupported league '{league}'. "
                    f"Supported: {sorted(_LEAGUE_TO_ESPN_PATH)}."
                )

    # -----------------------------------------------------------------
    # SportsProvider conformance
    # -----------------------------------------------------------------

    def fetch_live_games(self) -> List[ProviderGameDTO]:
        out: List[ProviderGameDTO] = []
        for league in self._leagues:
            for dto in self._fetch_scoreboard(league):
                if dto.status in (
                    GameStatus.PREGAME,
                    GameStatus.LIVE,
                    GameStatus.HALFTIME,
                ):
                    out.append(dto)
        logger.info(
            "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_live_games rows=%d",
            self.name,
            len(out),
        )
        return out

    def fetch_scheduled_games(self, window_hours: int = 168) -> List[ProviderGameDTO]:
        now = datetime.now(timezone.utc)
        cutoff = now + timedelta(hours=window_hours)
        out: List[ProviderGameDTO] = []
        for league in self._leagues:
            for dto in self._fetch_scoreboard(league):
                if (
                    dto.status == GameStatus.SCHEDULED
                    and now <= dto.start_time <= cutoff
                ):
                    out.append(dto)
        logger.info(
            "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_scheduled_games "
            "window=%dh rows=%d",
            self.name,
            window_hours,
            len(out),
        )
        return out

    def fetch_game_details(self, provider_game_id: str) -> Optional[ProviderGameDTO]:
        # The site scoreboard endpoint does not key by event id, and
        # ESPN's per-event "summary" endpoint has a different schema.
        # Simplest correct implementation: scan the same scoreboards
        # we'd hit anyway and return the matching event. For dev
        # cadence (15s tick) this is fine; if the worker grows
        # webhook-driven targeted refresh we can add a dedicated
        # /summary?event=<id> path then.
        for league in self._leagues:
            for dto in self._fetch_scoreboard(league):
                if dto.provider_game_id == provider_game_id:
                    logger.info(
                        "🟢 Provider fetch succeeded — provider=%s "
                        "endpoint=fetch_game_details provider_game_id=%s status=%s",
                        self.name,
                        provider_game_id,
                        dto.status.value,
                    )
                    return dto
        logger.info(
            "ℹ️ Provider fetch — provider=%s endpoint=fetch_game_details "
            "provider_game_id=%s rows=0",
            self.name,
            provider_game_id,
        )
        return None

    def fetch_teams(self, league: str) -> List[ProviderTeamDTO]:
        league = league.lower()
        if league not in _LEAGUE_TO_ESPN_PATH:
            raise ValueError(
                f"ESPNProvider.fetch_teams: unsupported league '{league}'."
            )

        sport_path, league_path = _LEAGUE_TO_ESPN_PATH[league]
        url = (
            f"{self._base_url}/apis/site/v2/sports/"
            f"{sport_path}/{league_path}/teams"
        )
        payload = self._http_get(url, self._timeout_seconds)

        teams: List[ProviderTeamDTO] = []
        # ESPN shape: payload.sports[0].leagues[0].teams[*].team
        try:
            sports_block = payload.get("sports") or []
            leagues_block = (
                (sports_block[0].get("leagues") if sports_block else []) or []
            )
            team_entries = (
                (leagues_block[0].get("teams") if leagues_block else []) or []
            )
        except (AttributeError, IndexError, TypeError):
            team_entries = []

        for entry in team_entries:
            team = (entry or {}).get("team") or {}
            team_id = team.get("id")
            if team_id is None:
                continue
            abbrev = (team.get("abbreviation") or "").strip()
            name = (team.get("name") or team.get("shortDisplayName") or "").strip()
            location = (team.get("location") or "").strip()
            teams.append(
                ProviderTeamDTO(
                    provider_team_id=str(team_id),
                    league=league,
                    abbreviation=abbrev,
                    name=name,
                    city=location,
                )
            )

        logger.info(
            "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_teams league=%s rows=%d",
            self.name,
            league,
            len(teams),
        )
        return teams

    # -----------------------------------------------------------------
    # Internals
    # -----------------------------------------------------------------

    def _fetch_scoreboard(self, league: str) -> List[ProviderGameDTO]:
        """
        Hit ESPN's scoreboard endpoint for `league` and decode every
        event into a `ProviderGameDTO`. Events with unmappable status
        or malformed shape are skipped with ⚠️ logs (NOT raised) so
        one bad row does not poison the whole tick.
        """
        sport_path, league_path = _LEAGUE_TO_ESPN_PATH[league]
        url = (
            f"{self._base_url}/apis/site/v2/sports/"
            f"{sport_path}/{league_path}/scoreboard"
        )
        payload = self._http_get(url, self._timeout_seconds)

        season_label = self._extract_season_label(payload)
        events = payload.get("events") or []

        out: List[ProviderGameDTO] = []
        for event in events:
            dto = self._event_to_dto(event, league=league, season=season_label)
            if dto is not None:
                out.append(dto)
        return out

    @staticmethod
    def _extract_season_label(payload: dict) -> Optional[str]:
        """
        Build a canonical season string like ``"2025-26"`` from the
        scoreboard envelope. ESPN exposes `season.year` (the
        starting calendar year for the season) at the top level. For
        seasons that don't span calendar years (MLB) we collapse to
        the single year. Returns None if absent / malformed.
        """
        season_block = payload.get("season") or {}
        year = season_block.get("year")
        if not isinstance(year, int):
            return None
        # MLB seasons stay within one calendar year; the others span.
        league_obj = (payload.get("leagues") or [{}])[0]
        slug = (league_obj.get("slug") or "").lower()
        if slug == "mlb":
            return str(year)
        return f"{year}-{str(year + 1)[-2:]}"

    @staticmethod
    def _event_to_dto(
        event: dict, *, league: str, season: Optional[str]
    ) -> Optional[ProviderGameDTO]:
        event_id = event.get("id")
        if event_id is None:
            logger.warning(
                "⚠️ ESPN event missing id — provider=espn league=%s skipping",
                league,
            )
            return None

        competitions = event.get("competitions") or []
        if not competitions:
            logger.warning(
                "⚠️ ESPN event has no competitions — provider=espn league=%s event=%s",
                league,
                event_id,
            )
            return None
        comp = competitions[0]

        # Status
        status_block = (
            (comp.get("status") or event.get("status") or {}).get("type") or {}
        )
        espn_status_name = status_block.get("name")
        canonical_status = _ESPN_STATUS_TO_CANONICAL.get(espn_status_name)
        if canonical_status is None:
            logger.warning(
                "⚠️ ESPN unknown status — provider=espn league=%s event=%s status=%s",
                league,
                event_id,
                espn_status_name,
            )
            return None

        # Start time (UTC)
        start_raw = comp.get("date") or event.get("date")
        start_time = _parse_iso8601_utc(start_raw)
        if start_time is None:
            logger.warning(
                "⚠️ ESPN event missing/invalid date — provider=espn league=%s event=%s date=%r",
                league,
                event_id,
                start_raw,
            )
            return None

        # Teams + scores
        competitors = comp.get("competitors") or []
        if len(competitors) != 2:
            logger.warning(
                "⚠️ ESPN event competitor count != 2 — provider=espn league=%s "
                "event=%s count=%d",
                league,
                event_id,
                len(competitors),
            )
            return None

        home: Optional[dict] = None
        away: Optional[dict] = None
        for c in competitors:
            ha = (c or {}).get("homeAway")
            if ha == "home":
                home = c
            elif ha == "away":
                away = c
        if home is None or away is None:
            logger.warning(
                "⚠️ ESPN event missing home/away designation — "
                "provider=espn league=%s event=%s",
                league,
                event_id,
            )
            return None

        home_team_id = ((home.get("team") or {}).get("id"))
        away_team_id = ((away.get("team") or {}).get("id"))
        if home_team_id is None or away_team_id is None:
            logger.warning(
                "⚠️ ESPN event missing team id — provider=espn league=%s event=%s",
                league,
                event_id,
            )
            return None

        home_score = _parse_int(home.get("score"), default=0)
        away_score = _parse_int(away.get("score"), default=0)

        # Period / clock — only meaningful in-game.
        period_str: Optional[str] = None
        clock_str: Optional[str] = None
        if canonical_status in (
            GameStatus.LIVE,
            GameStatus.HALFTIME,
            GameStatus.PREGAME,
        ):
            period_num = (comp.get("status") or {}).get("period")
            if isinstance(period_num, int) and period_num > 0:
                period_str = _format_period(league, period_num, canonical_status)
            raw_clock = (comp.get("status") or {}).get("displayClock")
            if isinstance(raw_clock, str) and raw_clock:
                clock_str = raw_clock

        return ProviderGameDTO(
            provider_game_id=str(event_id),
            league=league,
            season=season,
            home_provider_team_id=str(home_team_id),
            away_provider_team_id=str(away_team_id),
            start_time=start_time,
            status=canonical_status,
            period=period_str,
            clock=clock_str,
            home_score=home_score,
            away_score=away_score,
            last_updated=datetime.now(timezone.utc),
        )


# ─────────────────────────────────────────────────────────────────────
# Small helpers
# ─────────────────────────────────────────────────────────────────────


def _parse_iso8601_utc(value: object) -> Optional[datetime]:
    """
    Parse ESPN's ISO-8601 timestamps (e.g. ``2025-09-08T00:20Z`` or
    ``2025-09-08T00:20:00Z``) into a UTC, timezone-aware datetime.
    """
    if not isinstance(value, str) or not value:
        return None
    s = value.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _parse_int(value: object, *, default: int = 0) -> int:
    """
    Coerce ESPN's score fields (sometimes string, sometimes int)
    into a non-negative int. Anything unparseable falls back to
    `default` rather than raising — scores never poison ingest.
    """
    if isinstance(value, bool):
        # bool is a subclass of int; reject explicitly.
        return default
    if isinstance(value, int):
        return max(value, 0)
    if isinstance(value, str):
        s = value.strip()
        if not s:
            return default
        try:
            return max(int(s), 0)
        except ValueError:
            return default
    return default


def _format_period(league: str, period: int, status: GameStatus) -> str:
    """
    Render a provider-shaped period label that matches what
    `MockSportsProvider` emits (e.g. ``Q2``, ``Half``). The canonical
    schema stores this verbatim — clients format for display.
    """
    if status == GameStatus.HALFTIME:
        return "Half"
    if league in ("nfl", "nba"):
        return f"Q{period}"
    if league == "nhl":
        return f"P{period}"
    if league == "mlb":
        return f"I{period}"
    return str(period)
