#!/usr/bin/env python3
"""Smoke-test HERE Geocoding & Search v7 speed-limit attributes.

Usage:
    set HERE_API_KEY=your_key       # Windows
    export HERE_API_KEY=your_key    # macOS/Linux
    python3 test_here_revgeocode_speed_limits.py

The key is intentionally not stored in this file or printed in output.
"""

from __future__ import annotations

import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

LAT = "52.53086"
LNG = "13.38469"
ENDPOINT = "https://revgeocode.search.hereapi.com/v1/revgeocode"


def find_speed_limits(value):
    """Recursively find speed-limit-shaped values in HERE's response."""
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = key.lower().replace("_", "")
            if "speedlimit" in normalized or normalized in {"maxspeed", "fromrefspeedlimit"}:
                yield key, child
            yield from find_speed_limits(child)
    elif isinstance(value, list):
        for child in value:
            yield from find_speed_limits(child)


def main() -> int:
    api_key = os.environ.get("HERE_API_KEY", "").strip()
    if not api_key:
        print("[ERROR] HERE_API_KEY is not set.", file=sys.stderr)
        print("Set it in the shell, then rerun this test.", file=sys.stderr)
        return 2

    query = urlencode(
        {
            "at": f"{LAT},{LNG}",
            "showNavAttributes": "speedLimits",
            "lang": "en-US",
            "apiKey": api_key,
        }
    )
    request = Request(
        f"{ENDPOINT}?{query}",
        headers={"Accept": "application/json", "User-Agent": "Speedio-HERE-SmokeTest/1.0"},
        method="GET",
    )

    print(f"Requesting HERE reverse geocode speed limits at {LAT},{LNG} ...")
    try:
        with urlopen(request, timeout=15) as response:
            status = response.status
            body = response.read()
    except HTTPError as error:
        body = error.read(512).decode("utf-8", errors="replace")
        print(f"[FAIL] HERE returned HTTP {error.code}.")
        print(body)
        return 1
    except URLError as error:
        print(f"[FAIL] Network error: {error.reason}")
        return 1
    except TimeoutError:
        print("[FAIL] Request timed out.")
        return 1

    print(f"HTTP status: {status}")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        print("[FAIL] HERE returned non-JSON data:")
        print(body[:512].decode("utf-8", errors="replace"))
        return 1

    items = payload.get("items")
    if not isinstance(items, list):
        print("[FAIL] Response does not contain an 'items' array.")
        print(json.dumps(payload, indent=2)[:4000])
        return 1

    matches = list(find_speed_limits(payload))
    print(f"Reverse-geocode items: {len(items)}")
    print(f"Speed-limit fields found: {len(matches)}")

    if matches:
        print("[PASS] API key works and the response contains speed-limit data.")
        for key, value in matches[:10]:
            print(f"  {key}: {json.dumps(value, ensure_ascii=False)}")
        return 0

    print("[WARN] API key authenticated, but this response contains no speed-limit fields.")
    print("Possible causes: no HERE speed-limit coverage at this coordinate, premium access is not enabled, or the response schema differs.")
    print(json.dumps(payload, indent=2)[:4000])
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
