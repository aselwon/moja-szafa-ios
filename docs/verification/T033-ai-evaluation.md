# T033 AI evaluation report

Dataset: wardrobe-contexts-v1; SHA-256: db778c95bf43c5c6fec4b6ab54fbffc8073f14ba0de6a7b9de7db8a1c18daeaa.

120 original synthetic text contexts; no photos, personal data or third-party assets.
Each of the 12 families contains 10 cases: small_wardrobe, missing_shoes, winter, preference_conflict, instruction_injection, foreign_owner, laundry, archived, pinned, missing_base, empty_wardrobe, large_wardrobe.
Cases vary requested count (1–10), clothing composition and occasion formality.
These are correlated regression fixtures, not 120 independent real-world observations.

## Local contract verification

120/120 cases pass selection, reference-label checks and invented/excluded-ID rejection probes (where selection succeeds).
These results exercise deterministic code, not model quality or prompt effectiveness.
10 empty-wardrobe cases stop before the provider; 110 cases can receive model responses.

## Paired prompt comparison

| Prompt | SHA-256 (version and text) | Valid responses | Rejected responses | Failed cases | Presented ID violations | Human usefulness |
| --- | --- | --- | --- | --- | --- | --- |
| outfit-generation-v2 | 839fb35f6ecff8efd3d4f515dcbf497e686014b9bc576ea56588866a3b4d9722 | Not run | Not run | Not run | Not measured | Not reviewed |
| outfit-generation-v3-eval | 2008c73018769c3b07fd13a955f07e42f7ecef6ad3cc3bd10c18d2c5dcaf657c | Not run | Not run | Not run | Not measured | Not reviewed |

The baseline is the production prompt. The candidate adds explicit preference-conflict and winter-layer guidance; it is not enabled in production. Both use the same dataset and server validation. No improvement is claimed without paired responses. Category accuracy is not measurable with this text-only suite.

No provider calls or human reviews were performed. Model quality, latency, cost and the >=80% usefulness gate remain unmeasured.

## Limitations and next verification

Run the paired protocol in README.md with an authorized model and budget, review all responses blind, and regenerate this report. Verify zero ownership/nonexistent-ID violations in presented results; inspect rejected responses separately. Recognition requires a separate rights-cleared labeled photo set and the >=90% category gate. No image-classification evidence is claimed here.

Notes are currently removed by production candidate selection. Injection cases verify this boundary; they do not demonstrate model resistance to instructions embedded in photos or future note-enabled prompts. Weather is represented by season metadata, not a live forecast.
