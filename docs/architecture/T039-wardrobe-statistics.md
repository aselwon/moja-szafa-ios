# T039 — Wardrobe statistics

The Statistics tab computes wardrobe value, missing-price counts, activity rankings, lifetime cost-per-wear rankings, never-worn items and items with evidence of at least 90 days of inactivity. Archived items are excluded by default and can be included explicitly.

One account snapshot supplies garment metadata and historical wear memberships. The managed account path reads the durable local store after synchronization; a network failure retains local data and pending writes, clearly labelled. No per-garment request or image download is needed. Account revocation must fail rather than expose a cached snapshot.

Activity counts distinct local date labels, deduplicating repeated same-day events, ignoring removed events and using historical garment IDs. The 30/90/365-day filter is inclusive of the current local day. It changes activity counts only. Value, lifetime CPW and inactivity lists keep their own documented scopes.

Value is the exact sum of known grosz values using Decimal; a zero price remains known and missing prices are counted separately. CPW reuses the initial-history boundary and estimate from T036/T037. Ranking compares unrounded ratios and rounds only the displayed currency. Unknown prices and zero wear counts are excluded from CPW ranking.

An estimate without an exact last-wear date cannot establish recent inactivity. Its boundary can prove inactivity only when it lies at or before the 90-day cutoff and no later dated wear exists. Newly added items with no history appear in the never-worn list; their age is not invented.

Verification covers date scope, same-day deduplication, deleted events, archive inclusion, missing/zero/large prices, estimated history, unrounded CPW order, durable offline reads and account-deletion fencing. No backend migration or paid service is introduced.
