#!/usr/bin/env python3
"""Record PITR measurements only after the recovered dataset is verified."""

import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time


def load_json(path):
    with Path(path).open() as source:
        return json.load(source)


def load_rows(path):
    with Path(path).open(newline="") as source:
        return list(csv.reader(source))


def build_report(start, verified, expected, recovered, later, target, incident):
    elapsed_ns = verified["monotonic_ns"] - start["monotonic_ns"]
    if elapsed_ns <= 0:
        raise ValueError("Recovery interval must be positive on the same host monotonic clock")
    if not expected or expected != recovered:
        raise ValueError("Recovered rows do not exactly match the expected snapshot")
    if not later or any(row in recovered for row in later):
        raise ValueError("Post-target rows must be absent from the recovered snapshot")
    target_time = datetime.fromisoformat(target)
    incident_time = datetime.fromisoformat(incident)
    if target_time.utcoffset() is None or incident_time.utcoffset() is None:
        raise ValueError("Recovery target and incident observation require explicit time zones")
    rollback_window = (incident_time - target_time).total_seconds()
    if rollback_window < 0:
        raise ValueError("Incident observation must follow the recovery target")
    return {
        "schema_version": 1,
        "status": "verified",
        "scenario": "pitr_before_accidental_deletion",
        "recovery_target_utc": target,
        "incident_observed_utc": incident,
        "rollback_window_seconds": rollback_window,
        "recovery_started_utc": start["utc"],
        "data_verified_utc": verified["utc"],
        "recovery_duration_seconds": round(elapsed_ns / 1_000_000_000, 6),
        "duration_clock": "host_monotonic",
        "duration_start": "before successful restore command; empty target already prepared",
        "duration_end": "exact dataset and excluded rows checked; recovered-side write read back",
        "expected_rows": len(expected),
        "recovered_rows": len(recovered),
        "missing_expected_rows": 0,
        "excluded_post_target_rows": len(later),
        "rpo_seconds": None,
        "rpo_interpretation": "All expected rows recovered; selected rollback window is not a measured crash RPO",
        "rto_interpretation": "One verified restore duration; excludes detection, preparation, prior failed attempts and cutover",
    }


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stamp = commands.add_parser("stamp")
    stamp.add_argument("output", type=Path)
    report = commands.add_parser("report")
    for name in ("start", "verified", "expected", "recovered", "later", "output"):
        report.add_argument(f"--{name}", required=True, type=Path)
    for name in ("target", "incident", "backup", "project"):
        report.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    return parser, args


def create_report(args):
    result = build_report(load_json(args.start), load_json(args.verified),
                          load_rows(args.expected), load_rows(args.recovered),
                          load_rows(args.later), args.target, args.incident)
    root = Path(__file__).resolve().parent.parent
    result["source_commit"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    result["worktree_dirty"] = bool(subprocess.check_output(
        ["git", "status", "--porcelain"], cwd=root, text=True).strip())
    result["backup_label"] = args.backup
    result["project"] = args.project
    return result


def save_result(output, result):
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation preserves the result of an earlier successful run.
    with output.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")


def main():
    parser, args = parse_args()
    try:
        if args.command == "stamp":
            result = {"utc": datetime.now(timezone.utc).isoformat(),
                      "monotonic_ns": time.monotonic_ns()}
        else:
            result = create_report(args)
        save_result(args.output, result)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Recovery report failed: {error}\n")
    if args.command == "report":
        print(f"Recovery report: {args.output}")
        print(f"Verified restore duration: {result['recovery_duration_seconds']:.3f}s; "
              f"missing expected rows: {result['missing_expected_rows']}; "
              f"intentionally excluded rows: {result['excluded_post_target_rows']}")


if __name__ == "__main__":
    main()
