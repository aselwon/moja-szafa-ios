# T031 follow-up: start outfit generation

The Today screen sends the frozen `api_v1_generate_outfits` request and polls
`api_v1_job_result` for that exact job. Users choose 1–10 proposals. This initial
entry point sends no pin, empty color/season preferences, and null formality;
profile palette groups are not silently translated into different API enums.

Before admission, the app atomically saves the operation UUID and complete
request to a protected, gateway/account-scoped local journal. A timeout, view
exit or relaunch retains that intent; retries reuse its payload or poll its
known job without enqueueing another. The screen polls at two-second intervals
for up to 60 observations, then offers an explicit status retry. Terminal
server failures allow a new user intent. No AI result is synthesized locally.

Queued/running, offline, consent-required, quota, disabled AI and expired-account
states are explicit. The existing privacy view fetches the real disclosure and
records the user's choice. Generation never grants consent implicitly. Account
view teardown cancels polling; authenticated clients remain bound to their
original account. Deletion removes its generation journal. Corrupt journals
fail closed rather than creating an unknown duplicate.

A terminal successful job with garments that are now missing or unavailable
clears its finished intent and offers explicit fresh generation with a stale-result
message. A transient wardrobe fetch failure retains the same job for safe retry.

Successful results pass existing membership/availability validation before
appearing in T031 collages, save, wear and manual replacement flows. The client
also checks returned job identity, kind, terminal/result consistency and count.

Local integration includes PR72, PR68 and PR74 solely to validate dependencies.
Publish only the follow-up implementation commit after those dependencies merge.
