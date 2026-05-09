"""
scripts/providers/resolver.py
=============================

Provider team-identity bridge. Translates a (provider,
provider_team_id) pair into the canonical `public.teams.id` UUID the
worker stores in `public.games.home_team_id` / `away_team_id`.

Resolution order (first match wins):

    1. `public.provider_team_mappings` lookup
       (the canonical bridge — populated by manual seeds and ingest
        worker bootstrap from `provider.fetch_teams(league)`).

    2. Fallback: parse `<league>_<abbreviation>` style provider IDs
       (the convention used by the test ingest pipeline and the
        synthetic 'test_ingest' / 'test' seeds) and look up
        `public.teams` by `(league, abbreviation)`. Logs ⚠️ when this
        path saves an otherwise-unmapped row so the operator can
        backfill the missing mapping.

    3. Give up — log ❌, return None. The worker rejects the row.

Design choices:
    • Pure data class — no Supabase client built in. Callers inject
      `db_lookup` and `teams_table_lookup` callables. Keeps the
      resolver testable in isolation and reusable across runners
      (one-off scripts, edge functions, dedicated workers).
    • In-process cache (per-instance) so repeat lookups for the same
      team across a single ingest tick don't round-trip the DB.
    • All logs go through `logging.getLogger(__name__)` — the runner
      configures handlers / formatting / level.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Callable, Dict, Optional, Tuple

logger = logging.getLogger(__name__)

# Type aliases for the injected lookup callables.
ProviderMappingLookup = Callable[[str, str], Optional[str]]
"""(provider, provider_team_id) -> team_id UUID string or None"""

TeamsTableLookup = Callable[[str, str], Optional[str]]
"""(league, abbreviation) -> team_id UUID string or None"""


@dataclass
class TeamResolver:
    """
    Provider team UUID resolver. Inject lookup callables at
    construction; call `.resolve(provider, provider_team_id)` per
    needed team. Misses are logged once per (provider, team_id) so
    log volume scales with number of *unique* misses, not total
    invocations.
    """

    db_lookup: Optional[ProviderMappingLookup] = None
    teams_table_lookup: Optional[TeamsTableLookup] = None

    # Internal cache — (provider, provider_team_id) → resolved UUID
    # or None for known-unresolvable. The `_unmapped_logged` set
    # tracks which misses have already been warning-logged so we
    # don't spam the log on every retry.
    _cache: Dict[Tuple[str, str], Optional[str]] = field(default_factory=dict)
    _unmapped_logged: set = field(default_factory=set)

    def resolve(self, provider: str, provider_team_id: str) -> Optional[str]:
        """
        Return the canonical team UUID string, or None if neither the
        primary mapping nor the fallback succeeded.
        """
        key = (provider, provider_team_id)
        if key in self._cache:
            return self._cache[key]

        # 1. Canonical mapping table.
        team_id: Optional[str] = None
        if self.db_lookup is not None:
            team_id = self.db_lookup(provider, provider_team_id)

        # 2. Fallback for `<league>_<abbreviation>` provider IDs.
        if team_id is None and "_" in provider_team_id:
            league, abbreviation = provider_team_id.split("_", 1)
            if league in ("nfl", "nba", "mlb", "nhl") and self.teams_table_lookup is not None:
                fallback_team_id = self.teams_table_lookup(league, abbreviation)
                if fallback_team_id is not None:
                    if key not in self._unmapped_logged:
                        logger.warning(
                            "⚠️ Missing provider_team_mapping — fallback resolved via "
                            "public.teams (provider=%s, provider_team_id=%s, "
                            "league=%s, abbreviation=%s, team_id=%s). "
                            "Add a row to public.provider_team_mappings to silence.",
                            provider,
                            provider_team_id,
                            league,
                            abbreviation,
                            fallback_team_id,
                        )
                        self._unmapped_logged.add(key)
                    team_id = fallback_team_id

        # 3. Unresolvable — log once, cache the negative result.
        if team_id is None and key not in self._unmapped_logged:
            logger.error(
                "❌ Provider payload rejected — could not resolve team "
                "(provider=%s, provider_team_id=%s)",
                provider,
                provider_team_id,
            )
            self._unmapped_logged.add(key)

        self._cache[key] = team_id
        return team_id

    # -----------------------------------------------------------------
    # Cache control
    # -----------------------------------------------------------------

    def invalidate(self) -> None:
        """Clear the in-process cache. Call when the runner expects
        the underlying mappings may have changed (e.g., after a
        bootstrap insert). Cheap; rebuilds lazily on the next
        resolve() call."""
        self._cache.clear()
        self._unmapped_logged.clear()

    def stats(self) -> Dict[str, int]:
        """Inspection helper — count of cached hits / misses for
        observability dashboards."""
        hits = sum(1 for v in self._cache.values() if v is not None)
        misses = sum(1 for v in self._cache.values() if v is None)
        return {"hits": hits, "misses": misses, "unique_misses_logged": len(self._unmapped_logged)}
