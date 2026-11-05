#!/bin/bash
set -euo pipefail
fail() { echo "error: Invalid environment configuration: $1" >&2; exit 1; }
case "${CONFIGURATION:-}" in
  Debug) expected_environment=dev; expected_bundle=pl.mojaszafa.app.dev; expected_signing=Automatic ;;
  Staging) expected_environment=staging; expected_bundle=pl.mojaszafa.app.staging; expected_signing=Automatic ;;
  Release) expected_environment=prod; expected_bundle=pl.mojaszafa.app; expected_signing=Manual ;;
  *) fail 'unknown build configuration' ;;
esac
[[ "${APP_ENVIRONMENT:-}" == "$expected_environment" ]] || fail 'environment does not match build configuration'
[[ "${PRODUCT_BUNDLE_IDENTIFIER:-}" == "$expected_bundle" ]] || fail 'bundle ID does not match environment'
[[ "${INFOPLIST_KEY_AppEnvironment:-}" == "$expected_environment" ]] || fail 'Info.plist environment mismatch'
[[ "${CODE_SIGN_STYLE:-}" == "$expected_signing" ]] || fail 'signing policy mismatch'
# The checked-in manifest binds each public gateway to exactly one environment.
# Both build values must agree; command-line overrides cannot select another host.
python3 "$(dirname "$0")/validate-backend-endpoint.py" || fail 'backend endpoint mismatch'
if [[ "${CONFIGURATION}" == Release && "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] || fail 'production signing team is required'
  [[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]] || fail 'explicit production provisioning profile is required'
fi
