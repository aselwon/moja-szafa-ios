"""Validate public gateway origins before compiling an environment-specific app."""
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


def validate(endpoints, environment, backend, plist):
    if not isinstance(endpoints, dict) or set(endpoints) != {"dev", "staging", "prod"}:
        raise ValueError("invalid endpoint manifest")
    origins = []
    for value in endpoints.values():
        if not isinstance(value, str):
            raise ValueError("invalid endpoint")
        if not value:
            continue
        # Exact canonical origin only: no paths, credentials, ports or URL suffixes.
        if not re.fullmatch(r"https://[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?)+", value):
            raise ValueError("invalid gateway origin")
        host = urlsplit(value).hostname
        if host.endswith((".localhost", ".local", ".invalid")) or re.fullmatch(r"[0-9.]+", host):
            raise ValueError("gateway must be a deployed public hostname")
        origins.append(value)
    if len(origins) != len(set(origins)):
        raise ValueError("environments must use separate gateways")
    if environment not in endpoints or backend != plist or backend != endpoints[environment]:
        raise ValueError("gateway does not match environment")


if __name__ == "__main__":
    try:
        manifest = Path(__file__).resolve().parent.parent / "Configuration/BackendEndpoints.json"
        validate(json.loads(manifest.read_text()), os.environ.get("APP_ENVIRONMENT"),
                 os.environ.get("BACKEND_BASE_URL", ""), os.environ.get("INFOPLIST_KEY_BackendBaseURL", ""))
    except (ValueError, OSError, TypeError):
        # Never echo build values, which may contain accidentally pasted credentials.
        print("Invalid backend endpoint configuration", file=sys.stderr)
        sys.exit(1)
