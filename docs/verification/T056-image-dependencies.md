# T056 — Image dependency security remediation

The former `Pillow>=10.2,<13` constraint excluded the 13.0.0 security fixes.
Pin the decoder to 13.0.0 and provision it using Python 3.11 or newer in the
service's own virtual environment. CI already selects Python 3.12. Do not upgrade
the operating system's shared Python packages to deploy this application fix.

The normalizer now limits plugin selection to JPEG, PNG and WebP before opening
an image. Format validation after `Image.open` alone cannot prevent unsupported
plugins from parsing a crafted header. Existing byte/pixel/dimension, single-frame,
timeout and metadata-stripping limits remain in place.

Reference: https://pillow.readthedocs.io/en/stable/releasenotes/13.0.0.html

On 2026-11-04, an isolated Python 3.12 environment with Pillow 13.0.0 passed the
decoder tests and private image pipeline tests. The dependency advisory audit
reported zero known findings for Pillow 13.0.0. This is a point-in-time advisory
lookup, not a claim that the library or application is vulnerability-free.
The temporary audit tool environment's older pip findings are separate from the
application dependency result.

The VPS system interpreter reported Pillow 10.2.0, but inspection of the actual
gateway process showed its private interpreter uses 12.3.0. Runtime remediation
must target that service interpreter; changing system Python would not fix it.
Deployment of the new environment and post-restart checks remain separate evidence.
This document does not mark the broader T056 security acceptance complete.
