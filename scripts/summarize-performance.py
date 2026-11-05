#!/usr/bin/env python3
"""Validate and summarize the synthetic T059 database timing CSV."""
import argparse
import csv
import json
import math
from pathlib import Path


def summarize(path):
    expected = {"wardrobe_first_page", "wardrobe_last_page", "garment_detail", "sync_snapshot"}
    samples = {operation: {} for operation in expected}
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != ["operation", "iteration", "elapsed_ms", "response_bytes"]:
            raise ValueError("Unexpected CSV header")
        for row in reader:
            operation = row["operation"]
            if operation not in expected:
                raise ValueError("Unknown benchmark operation")
            iteration = int(row["iteration"])
            elapsed = float(row["elapsed_ms"])
            size = int(row["response_bytes"])
            if iteration not in range(1, 101) or iteration in samples[operation]:
                raise ValueError("Duplicate or invalid sample iteration")
            if not math.isfinite(elapsed) or elapsed < 0 or size <= 0:
                raise ValueError("Invalid timing or response size")
            samples[operation][iteration] = (elapsed, size)
    result = {}
    for operation in sorted(expected):
        rows = samples[operation]
        if set(rows) != set(range(1, 101)):
            raise ValueError(f"Missing samples for {operation}")
        timings = sorted(row[0] for row in rows.values())
        result[operation] = {
            "samples": 100, "p50_ms": timings[49], "p95_ms": timings[94],
            "max_ms": timings[-1], "max_response_bytes": max(row[1] for row in rows.values()),
        }
    return {"scope": "database_only", "percentile_method": "nearest_rank", "operations": result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(summarize(args.csv), indent=2, allow_nan=False))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"Invalid benchmark: {error}\n")
