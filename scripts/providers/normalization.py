"""
scripts/providers/normalization.py
==================================

Provider-agnostic DTOs + canonical row builders. Every provider emits
``ProviderGameDTO`` / ``ProviderTeamDTO``; the worker passes those
through `to_canonical_game` / `to_canonical_game_room` (with team
UUIDs from `TeamResolver`) to produce `CanonicalGameRow` /
`CanonicalGameRoomRow` — the shapes that go into `public.games` and
`public.game_rooms` respectively.

UUID derivation mirrors `scripts/test_sports_ingest.py` so the
abstraction and the existing test runner produce identical IDs for
the same logical game.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Optional

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────
# Canonical status enum — matches games_status_check in
# supabase_migration_games_and_game_rooms.sql byte-for-byte.
# ─────────────────────────────────────────────────────────────────────


class GameStatus(str, Enum):
    SCHEDULED = "scheduled"
    PREGAME = "pregame"
    LIVE = "live"
    HALFTIME = "halftime"
    FINAL = "final"
    CLOSED = "closed"
    POSTPONED = "postponed"
    CANCELLED = "cancelled"


# ─────────────────────────────────────────────────────────────────────
# Provider DTOs (input from the provider implementation)
# ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class ProviderGameDTO:
    """
    A single game as the provider sees it. Team identity is still in
    provider-space (string IDs); resolution to canonical UUIDs is the
    next pipeline step (TeamResolver).
    """

    provider_game_id: str
    league: str  # lowercase: nfl/nba/mlb/nhl
    season: Optional[str]
    home_provider_team_id: str
    away_provider_team_id: str
    start_time: datetime  # UTC
    status: GameStatus
    period: Optional[str]
    clock: Optional[str]
    home_score: int
    away_score: int
    last_updated: Optional[datetime] = None  # UTC, provider's lastUpdated


@dataclass(frozen=True)
class ProviderTeamDTO:
    """
    A team as the provider sees it. Used for bootstrapping
    `public.provider_team_mappings` when onboarding a new provider.
    """

    provider_team_id: str
    league: str  # lowercase
    abbreviation: str
    name: str
    city: str = ""


# ─────────────────────────────────────────────────────────────────────
# Canonical rows (output to public.games / public.game_rooms)
# ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class CanonicalGameRow:
    """Final row shape for INSERT INTO public.games."""

    id: str  # UUID string — deterministic via derive_game_uuid
    provider: str
    provider_game_id: str
    league: str
    season: Optional[str]
    home_team_id: str  # UUID string from TeamResolver
    away_team_id: str
    start_time: datetime
    status: str  # GameStatus.value
    period: Optional[str]
    clock: Optional[str]
    home_score: int
    away_score: int
    last_synced_at: datetime
    final_at: Optional[datetime] = None


@dataclass(frozen=True)
class CanonicalGameRoomRow:
    """Final row shape for INSERT INTO public.game_rooms."""

    game_id: str
    room_id: str
    status: str
    opens_at: datetime
    closes_at: Optional[datetime] = None


# ─────────────────────────────────────────────────────────────────────
# Deterministic UUID derivation
# ─────────────────────────────────────────────────────────────────────
#
# Same RFC-4122 URL namespace + label format as
# scripts/test_sports_ingest.py and supabase_seed_test_games.sql, so
# game / room IDs match across the abstraction, the existing test
# runner, and the seeded SQL fixtures.

URL_NAMESPACE = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")


def derive_game_uuid(provider: str, provider_game_id: str) -> str:
    """Deterministic public.games.id for (provider, provider_game_id)."""
    return str(uuid.uuid5(URL_NAMESPACE, f"jumbo:game:{provider}:{provider_game_id}"))


def derive_room_uuid(provider: str, provider_game_id: str) -> str:
    """Deterministic public.game_rooms.room_id for (provider, provider_game_id)."""
    return str(uuid.uuid5(URL_NAMESPACE, f"jumbo:room:game:{provider}:{provider_game_id}"))


# ─────────────────────────────────────────────────────────────────────
# Canonical row builders
# ─────────────────────────────────────────────────────────────────────


def to_canonical_game(
    provider: str,
    dto: ProviderGameDTO,
    home_team_id: str,
    away_team_id: str,
    *,
    now: Optional[datetime] = None,
) -> CanonicalGameRow:
    """
    Convert a provider DTO + already-resolved team UUIDs into the
    row shape the worker upserts into `public.games`.

    `now` is the worker's reference clock — accept it as a parameter
    so the same NOW value can be used across a whole batch of rows
    in one ingest tick.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    final_at: Optional[datetime] = now if dto.status == GameStatus.FINAL else None

    return CanonicalGameRow(
        id=derive_game_uuid(provider, dto.provider_game_id),
        provider=provider,
        provider_game_id=dto.provider_game_id,
        league=dto.league,
        season=dto.season,
        home_team_id=home_team_id,
        away_team_id=away_team_id,
        start_time=dto.start_time,
        status=dto.status.value,
        period=dto.period,
        clock=dto.clock,
        home_score=dto.home_score,
        away_score=dto.away_score,
        last_synced_at=now,
        final_at=final_at,
    )


def to_canonical_game_room(
    provider: str,
    game_row: CanonicalGameRow,
    *,
    now: Optional[datetime] = None,
    pre_game_window_minutes: int = 15,
) -> CanonicalGameRoomRow:
    """
    Build the matching `public.game_rooms` row for a canonical game.
    Status mapping mirrors the SQL helper in
    supabase_game_room_lifecycle_helpers.sql so client + server agree.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    opens_at = game_row.start_time - timedelta(minutes=pre_game_window_minutes)

    if game_row.status in ("live", "halftime", "pregame"):
        room_status = "live"
    elif game_row.status == "scheduled":
        room_status = "open" if opens_at <= now else "pending"
    elif game_row.status == "final":
        room_status = "final"
    elif game_row.status == "closed":
        room_status = "closed"
    else:
        # postponed / cancelled / unknown — leave as pending; lifecycle
        # worker can refine this when product confirms behavior.
        room_status = "pending"

    return CanonicalGameRoomRow(
        game_id=game_row.id,
        room_id=derive_room_uuid(provider, game_row.provider_game_id),
        status=room_status,
        opens_at=opens_at,
        closes_at=None,
    )


# ─────────────────────────────────────────────────────────────────────
# Validation helper — reject suspicious payloads before they hit
# Supabase. Worker calls this on every DTO; failures get logged with
# the ❌ prefix and the row is skipped.
# ─────────────────────────────────────────────────────────────────────


def validate_provider_game(dto: ProviderGameDTO) -> Optional[str]:
    """
    Returns None if the DTO is valid for ingest, otherwise a short
    reason string. Reasons are stable enough to use as log keys.
    """
    if not dto.provider_game_id:
        return "empty provider_game_id"
    if dto.league not in ("nfl", "nba", "mlb", "nhl"):
        return f"unknown league '{dto.league}'"
    if not dto.home_provider_team_id or not dto.away_provider_team_id:
        return "missing home or away provider_team_id"
    if dto.home_provider_team_id == dto.away_provider_team_id:
        return "home and away are the same team"
    if dto.home_score < 0 or dto.away_score < 0:
        return f"negative score (home={dto.home_score} away={dto.away_score})"
    if dto.start_time.tzinfo is None:
        return "start_time is not timezone-aware (must be UTC)"
    return None
