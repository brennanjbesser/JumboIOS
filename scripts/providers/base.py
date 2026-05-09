"""
scripts/providers/base.py
=========================

Abstract base class every concrete Sports API provider implements.
Hides provider-specific HTTP, auth, decoding, retry, and rate-limit
handling behind a small async-free interface that emits canonical
DTOs (see normalization.py).

Concrete implementations live alongside this module:

    scripts/providers/mock.py            ← MockSportsProvider (this milestone)
    scripts/providers/sportsdataio.py    ← future
    scripts/providers/sportradar.py      ← future
    scripts/providers/the_odds_api.py    ← future

A provider is responsible for:
    • All HTTP / network I/O
    • All provider-specific decoding
    • Mapping provider status strings → `GameStatus` enum
    • Normalizing timestamps to UTC
    • Returning empty list (NOT raising) on "no data right now"
    • Raising on transient errors so the worker's retry/backoff layer
      can decide what to do

A provider is NOT responsible for:
    • Resolving team UUIDs (that's `TeamResolver`)
    • Deriving canonical game UUIDs (that's `derive_game_uuid`)
    • Talking to Supabase (that's the worker)
    • Computing game-room status / opens_at (that's `to_canonical_game_room`)

Why ABC, not typing.Protocol?
    typing.Protocol is structurally typed and would let any object
    that "looks like" a provider sneak through. ABC makes the
    contract explicit at the inheritance level and gives `isinstance`
    checks for runtime registration.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import List, Optional

from .normalization import ProviderGameDTO, ProviderTeamDTO


class SportsProvider(ABC):
    """Provider-agnostic interface for Sports API data ingestion."""

    # -----------------------------------------------------------------
    # Identity
    # -----------------------------------------------------------------

    @property
    @abstractmethod
    def name(self) -> str:
        """
        Stable provider identifier. Used as `public.games.provider`
        and `public.provider_team_mappings.provider`. Must be
        lowercase, hyphen / underscore safe, and unique across
        providers in the same Supabase project.

        Examples: ``"sportsdataio"``, ``"sportradar"``,
        ``"thesportsdb"``, ``"the_odds_api"``, ``"mock"``.
        """

    # -----------------------------------------------------------------
    # Live games
    # -----------------------------------------------------------------

    @abstractmethod
    def fetch_live_games(self) -> List[ProviderGameDTO]:
        """
        Return every game the provider currently considers in-play
        (status `pregame`, `live`, or `halftime` in canonical terms).

        Implementations:
            • return [] when no games are live (NOT raise)
            • raise on transient errors (network, 5xx, timeouts) so
              the worker can apply retry/backoff
            • normalize all timestamps to UTC before returning
        """

    # -----------------------------------------------------------------
    # Schedule
    # -----------------------------------------------------------------

    @abstractmethod
    def fetch_scheduled_games(self, window_hours: int = 168) -> List[ProviderGameDTO]:
        """
        Return scheduled games starting within the next
        ``window_hours`` (default 7 days). Used to populate
        `public.games` rows ahead of kickoff so the LIVE page's
        COMING UP section can show them.

        Implementations:
            • only return games with `status == GameStatus.SCHEDULED`
            • do NOT include past kickoffs
            • do NOT include postponed/cancelled rows (those flow
              through `fetch_live_games` or a separate hook later)
        """

    # -----------------------------------------------------------------
    # Single-game refresh
    # -----------------------------------------------------------------

    @abstractmethod
    def fetch_game_details(self, provider_game_id: str) -> Optional[ProviderGameDTO]:
        """
        Return the latest snapshot of a single game by its provider
        identifier, or ``None`` if the provider has no record of it.

        Used by the worker for targeted refreshes — e.g., after a
        webhook says "game X just changed" we hit this method
        instead of re-fetching the full live list.
        """

    # -----------------------------------------------------------------
    # Teams
    # -----------------------------------------------------------------

    @abstractmethod
    def fetch_teams(self, league: str) -> List[ProviderTeamDTO]:
        """
        Return every team the provider knows about in ``league``
        (canonical lowercase: nfl/nba/mlb/nhl). Used to bootstrap
        `public.provider_team_mappings` when onboarding a new
        provider:

            for team_dto in provider.fetch_teams("nfl"):
                # human-review team_dto + add a mapping row
                ...

        Implementations:
            • do NOT side-effect public.teams or
              public.provider_team_mappings — they're read-only.
            • return ProviderTeamDTOs whose ``provider_team_id`` is
              the exact string the provider would use in a game
              payload's ``home_team_id`` / ``away_team_id``.
        """
