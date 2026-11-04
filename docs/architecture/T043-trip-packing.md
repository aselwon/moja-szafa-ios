# T043: trip packing

Migration 021 and `api_v1_trips` persist destination, local dates/timezone, occasions, a unique-garment limit, owned outfit snapshots for each day and a packing checklist. Trips span 1–30 days and at most 100 unique garments; list pages contain at most 20 summaries. Server validation rejects foreign/stale outfits, duplicate/missing dates, unavailable garments and over-budget unions.

The native Outfits → Trips flow supports manual day selection, transparent local arrangement from loaded saved outfits, deliberate garment repeats, real garment collages, explicit missing top/bottom/shoes categories, availability-change warnings, checklist undo and retry. Dress/jumpsuit covers top+bottom. Deleted/unavailable garments become visible gaps on refresh. The arrangement makes no AI or weather claim; occasions and suitability remain user-reviewed.

Packing writes only trip state, never wear events or CPW. Exact-body operation replay and trip versions protect concurrent edits. Pending intents are persisted before sending, scoped to account/gateway, retained after ambiguous timeouts, removed on account deletion and blocked if corrupt. Owned data export includes the new travel fields. No new blob storage or external provider is introduced.

Validation: Debug build-for-testing passed (8 TripTests compiled); 42 harness tests passed; full disposable PostgreSQL 15 fresh/upgrade/security/recovery suite passed; focused four-client packing replay verifies one version increment and zero wear events. Simulator execution is pending the shared runtime window; no extra simulator was started. Trip planning does not record wear history and does not request a weather forecast.
