"""
scripts/providers/mock.py
=========================

Reference `SportsProvider` implementation. Returns deterministic
synthetic data — no network, no API keys, no Supabase — so the
abstraction can be exercised end-to-end in unit tests, dev
scripts, and CI pipelines.

Fixture set is intentionally aligned with `scripts/test_sports_ingest.py`
(same provider_game_ids, same teams, same scoreboards) so the
abstraction's output matches the existing proven-working pipeline
byte-for-byte. The two implementations stay in sync at the data
level; the next milestone can refactor the runner script to drive
through this provider, or replace `MockSportsProvider` entirely with
e.g. `SportsDataIOProvider` without touching the worker.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import List, Optional

from .base import SportsProvider
from .normalization import GameStatus, ProviderGameDTO, ProviderTeamDTO

logger = logging.getLogger(__name__)


class MockSportsProvider(SportsProvider):
    """
    Pure in-memory provider for testing the abstraction pipeline.
    Every call returns rows derived from the static `_FIXTURES` list
    relative to the current wall clock — so a "live" game is always
    "live" regardless of when the test runs.
    """

    name: str = "mock"

    # -----------------------------------------------------------------
    # Public API (SportsProvider conformance)
    # -----------------------------------------------------------------

    def fetch_live_games(self) -> List[ProviderGameDTO]:
        all_games = self._materialize_games()
        live = [
            g for g in all_games
            if g.status in (GameStatus.PREGAME, GameStatus.LIVE, GameStatus.HALFTIME)
        ]
        logger.info(
            "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_live_games rows=%d",
            self.name,
            len(live),
        )
        return live

    def fetch_scheduled_games(self, window_hours: int = 168) -> List[ProviderGameDTO]:
        now = datetime.now(timezone.utc)
        cutoff = now + timedelta(hours=window_hours)
        scheduled = [
            g for g in self._materialize_games()
            if g.status == GameStatus.SCHEDULED
            and now <= g.start_time <= cutoff
        ]
        logger.info(
            "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_scheduled_games "
            "window=%dh rows=%d",
            self.name,
            window_hours,
            len(scheduled),
        )
        return scheduled

    def fetch_game_details(self, provider_game_id: str) -> Optional[ProviderGameDTO]:
        for g in self._materialize_games():
            if g.provider_game_id == provider_game_id:
                logger.info(
                    "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_game_details "
                    "provider_game_id=%s status=%s",
                    self.name,
                    provider_game_id,
                    g.status.value,
                )
                return g
        logger.info(
            "ℹ️ Provider fetch — provider=%s endpoint=fetch_game_details "
            "provider_game_id=%s rows=0",
            self.name,
            provider_game_id,
        )
        return None

    def fetch_teams(self, league: str) -> List[ProviderTeamDTO]:
        league = league.lower()
        teams = [t for t in self._materialize_teams() if t.league == league]
        logger.info(
            "🟢 Provider fetch succeeded — provider=%s endpoint=fetch_teams league=%s rows=%d",
            self.name,
            league,
            len(teams),
        )
        return teams

    # -----------------------------------------------------------------
    # Fixture materialization
    # -----------------------------------------------------------------
    # Resolved relative to "now" so a test run at any clock time gets
    # game states that line up with the iOS LIVE NOW / COMING UP
    # bands.

    def _materialize_games(self) -> List[ProviderGameDTO]:
        now = datetime.now(timezone.utc)

        return [
            # 1. Live NFL — KC @ BAL, ~30 min in
            ProviderGameDTO(
                provider_game_id="ti-nfl-001",
                league="nfl",
                season="2025-26",
                home_provider_team_id="nfl_BAL",
                away_provider_team_id="nfl_KC",
                start_time=now - timedelta(minutes=30),
                status=GameStatus.LIVE,
                period="Q2",
                clock="8:14",
                home_score=14,
                away_score=17,
                last_updated=now,
            ),
            # 2. Halftime NFL — CHI @ GB
            ProviderGameDTO(
                provider_game_id="ti-nfl-002",
                league="nfl",
                season="2025-26",
                home_provider_team_id="nfl_GB",
                away_provider_team_id="nfl_CHI",
                start_time=now - timedelta(hours=1),
                status=GameStatus.HALFTIME,
                period="Half",
                clock="0:00",
                home_score=17,
                away_score=13,
                last_updated=now,
            ),
            # 3. Live NBA — BOS @ LAL, ~45 min in
            ProviderGameDTO(
                provider_game_id="ti-nba-001",
                league="nba",
                season="2025-26",
                home_provider_team_id="nba_LAL",
                away_provider_team_id="nba_BOS",
                start_time=now - timedelta(minutes=45),
                status=GameStatus.LIVE,
                period="Q3",
                clock="4:32",
                home_score=78,
                away_score=81,
                last_updated=now,
            ),
            # 4. Scheduled NFL — PHI @ DAL, ~3h out
            ProviderGameDTO(
                provider_game_id="ti-nfl-003",
                league="nfl",
                season="2025-26",
                home_provider_team_id="nfl_DAL",
                away_provider_team_id="nfl_PHI",
                start_time=now + timedelta(hours=3),
                status=GameStatus.SCHEDULED,
                period=None,
                clock=None,
                home_score=0,
                away_score=0,
                last_updated=now,
            ),
            # 5. Scheduled NBA — MIL @ GSW, ~6h out
            ProviderGameDTO(
                provider_game_id="ti-nba-002",
                league="nba",
                season="2025-26",
                home_provider_team_id="nba_GSW",
                away_provider_team_id="nba_MIL",
                start_time=now + timedelta(hours=6),
                status=GameStatus.SCHEDULED,
                period=None,
                clock=None,
                home_score=0,
                away_score=0,
                last_updated=now,
            ),
        ]

    def _materialize_teams(self) -> List[ProviderTeamDTO]:
        # Mock teams — only the franchises referenced by `_materialize_games`.
        # A real provider's `fetch_teams("nfl")` would return all 32
        # NFL teams with full city/name; mock returns the subset
        # actually exercised by the fixture games to keep the surface
        # tight.
        return [
            ProviderTeamDTO("nfl_BAL", "nfl", "BAL", "Ravens", "Baltimore"),
            ProviderTeamDTO("nfl_KC",  "nfl", "KC",  "Chiefs", "Kansas City"),
            ProviderTeamDTO("nfl_GB",  "nfl", "GB",  "Packers", "Green Bay"),
            ProviderTeamDTO("nfl_CHI", "nfl", "CHI", "Bears", "Chicago"),
            ProviderTeamDTO("nfl_DAL", "nfl", "DAL", "Cowboys", "Dallas"),
            ProviderTeamDTO("nfl_PHI", "nfl", "PHI", "Eagles", "Philadelphia"),
            ProviderTeamDTO("nba_LAL", "nba", "LAL", "Lakers", "Los Angeles"),
            ProviderTeamDTO("nba_BOS", "nba", "BOS", "Celtics", "Boston"),
            ProviderTeamDTO("nba_GSW", "nba", "GSW", "Warriors", "Golden State"),
            ProviderTeamDTO("nba_MIL", "nba", "MIL", "Bucks", "Milwaukee"),
        ]
