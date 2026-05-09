"""
scripts/providers/
==================

Production-shape Sports API provider abstraction. Keeps the JUMBO
ingest pipeline producer-agnostic so a future migration to a real
provider (Sportradar, SportsDataIO, ESPN-style, The Odds API, …) is
a drop-in: implement the `SportsProvider` ABC, register it, run the
worker.

Layered architecture
--------------------

    ┌───────────────────────────────────────────────────────────┐
    │ Provider layer (provider-specific HTTP / decoding)        │
    │   class SportsDataIOProvider(SportsProvider): …           │
    │   class SportradarProvider(SportsProvider):  …            │
    │   class MockSportsProvider(SportsProvider):  …            │
    │                                                           │
    │   each emits ProviderGameDTO + ProviderTeamDTO objects    │
    │   keyed by *provider* identifiers (string team IDs, etc.) │
    └───────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌───────────────────────────────────────────────────────────┐
    │ Normalization layer (provider-agnostic)                   │
    │   ProviderGameDTO         → CanonicalGameRow              │
    │   GameStatus enum         (canonical 8-state)             │
    │   derive_game_uuid / derive_room_uuid (deterministic v5)  │
    │   to_canonical_game / to_canonical_game_room              │
    └───────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌───────────────────────────────────────────────────────────┐
    │ Resolver (team identity bridge)                           │
    │   TeamResolver:                                           │
    │     1. public.provider_team_mappings lookup               │
    │     2. fallback: parse "<league>_<abbrev>" → public.teams │
    │     3. structured logging on miss                         │
    │     4. in-process cache                                   │
    └───────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌───────────────────────────────────────────────────────────┐
    │ Worker (your runner script — out of scope here)           │
    │   for game in provider.fetch_live_games():                │
    │       home_id = resolver.resolve(provider.name,           │
    │                                  game.home_provider_team_id)│
    │       away_id = resolver.resolve(provider.name,           │
    │                                  game.away_provider_team_id)│
    │       row     = to_canonical_game(provider.name, game,    │
    │                                   home_id, away_id)       │
    │       upsert public.games / public.game_rooms             │
    └───────────────────────────────────────────────────────────┘

The existing `scripts/test_sports_ingest.py` is the proven-working
runner. It does not yet use this abstraction (intentionally kept
untouched). The next milestone wires a runner that does — at which
point swapping `MockSportsProvider` for a real provider is a one-line
change.

Public API
----------

    from scripts.providers import (
        SportsProvider,             # abstract base
        ProviderGameDTO,
        ProviderTeamDTO,
        GameStatus,
        CanonicalGameRow,
        CanonicalGameRoomRow,
        TeamResolver,
        MockSportsProvider,
        derive_game_uuid,
        derive_room_uuid,
        to_canonical_game,
        to_canonical_game_room,
    )

Logging
-------

All modules log via `logging.getLogger("scripts.providers.<module>")`.
Standard emoji prefixes are used so tail -f output is scannable:

    🟢 Provider fetch succeeded — N rows returned
    ⚠️ Missing provider_team_mapping — resolved via fallback
    🔄 Canonical game updated (score / status / clock)
    ❌ Provider payload rejected (validation failure / unmapped team)

Configuration is left to the runner (basicConfig / structured logging
adapter). The provider modules don't add handlers themselves.
"""

from .base import SportsProvider
from .espn import ESPNProvider
from .mock import MockSportsProvider
from .normalization import (
    CanonicalGameRoomRow,
    CanonicalGameRow,
    GameStatus,
    ProviderGameDTO,
    ProviderTeamDTO,
    derive_game_uuid,
    derive_room_uuid,
    to_canonical_game,
    to_canonical_game_room,
)
from .resolver import TeamResolver

__all__ = [
    "CanonicalGameRoomRow",
    "CanonicalGameRow",
    "ESPNProvider",
    "GameStatus",
    "MockSportsProvider",
    "ProviderGameDTO",
    "ProviderTeamDTO",
    "SportsProvider",
    "TeamResolver",
    "derive_game_uuid",
    "derive_room_uuid",
    "to_canonical_game",
    "to_canonical_game_room",
]
