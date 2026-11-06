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

Historical VPS observations reported system Pillow 10.2.0 and gateway-private
Pillow 12.3.0 before the remediation deployment. A fresh read-only inspection on
2026-11-06 of the active staging gateway process found Python 3.12.3 with Pillow
13.0.0 in the service's private environment. This supersedes the earlier 12.3.0
runtime finding; the system interpreter is not the image decoder runtime.

Fresh audits on 2026-11-06 of the existing gateway, storage and operations npm
lockfiles, and `backend/images/requirements.txt`, reported zero known
vulnerabilities. These are point-in-time advisory results; they do not establish
that the application or dependencies are vulnerability-free.

The dependency remediation and these scans do not mark broader T056 security
acceptance complete. See the private T056 verification record for the current
runtime observation, test matrix and its coverage limits.
