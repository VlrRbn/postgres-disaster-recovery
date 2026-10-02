#!/usr/bin/env python3
"""Journal acknowledged orders and measure recovery after an archive outage."""

import argparse
import csv
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import subprocess
import time


def build_rpo_report(acknowledgments, recovered, fault, start, verified):
    if not acknowledgments:
        raise ValueError("Acknowledgment journal must not be empty")
    expected = [ack["row"] for ack in acknowledgments]
    if any(len(row) != 4 for row in expected):
        raise ValueError("Each acknowledged row must contain all four order fields")
    if len({row[1] for row in expected}) != len(expected):
        raise ValueError("Acknowledged references must be unique")
    clocks = [ack["monotonic_ns"] for ack in acknowledgments]
    if any(right <= left for left, right in zip(clocks, clocks[1:])):
        raise ValueError("Acknowledgments must be strictly ordered on one monotonic clock")
    if fault["monotonic_ns"] < clocks[-1]:
        raise ValueError("Fault trigger must follow every recorded acknowledgment")
    # A retained prefix gives a defined recovery frontier; gaps require investigation.
    if not recovered or recovered != expected[:len(recovered)]:
        raise ValueError("Recovered data must exactly match a nonempty acknowledged prefix")
    if not (fault["monotonic_ns"] <= start["monotonic_ns"] < verified["monotonic_ns"]):
        raise ValueError("Recovery must start after the fault and end after its start")
    retained = len(recovered)
    lost = acknowledgments[retained:]
    last = acknowledgments[retained - 1]
    window = (fault["monotonic_ns"] - last["monotonic_ns"]) / 1_000_000_000
    return {
        "schema_version": 1,
        "status": "verified",
        "scenario": "archive_outage_then_primary_crash",
        "acknowledged_transactions": len(acknowledgments),
        "recovered_transactions": retained,
        "lost_acknowledged_transactions": len(lost),
        "lost_references": [ack["row"][1] for ack in lost],
        "last_recovered_acknowledgment_utc": last["utc"],
        "fault_trigger_utc": fault["utc"],
        "last_recovered_ack_to_fault_seconds": round(window, 6),
        "observed_rpo_seconds": round(window, 6) if lost else 0.0,
        "first_lost_acknowledgment_utc": lost[0]["utc"] if lost else None,
        "last_lost_acknowledgment_utc": lost[-1]["utc"] if lost else None,
        "recovery_started_utc": start["utc"],
        "data_verified_utc": verified["utc"],
        "recovery_duration_seconds": round(
            (verified["monotonic_ns"] - start["monotonic_ns"]) / 1_000_000_000, 6),
        "duration_clock": "host_monotonic",
        "acknowledgment_boundary": "host observation after successful autocommit psql exit",
        "fault_boundary": "host stamp immediately before SIGKILL request; writes already quiesced",
        "recovery_boundary": "restore invocation through exact retained-prefix validation and new write readback",
        "rpo_interpretation": "Observed acknowledged-data gap in a controlled archive outage; not an RPO objective",
        "source_data_used_for_recovery": False,
    }


def record_orders(journal, first, count):
    if first < 1 or count < 1:
        raise ValueError("First sequence and count must be positive")
    root = Path(__file__).resolve().parent.parent
    compose = ["bash", str(root / "scripts/compose.sh")]
    # The host journal is outside all database volumes and retained after cleanup.
    journal.parent.mkdir(parents=True, exist_ok=True)
    with journal.open("a") as out:
        for sequence in range(first, first + count):
            reference = f"rpo-{sequence:03d}"
            statement = ("INSERT INTO orders (reference, amount_cents) "
                         f"VALUES ('{reference}', {sequence * 100}) "
                         "RETURNING id, reference, amount_cents, created_at;")
            completed = subprocess.run(
                compose + ["exec", "-T", "--user", "postgres", "postgres", "psql", "-X", "-q",
                           "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "orders",
                           "--csv", "--tuples-only", "-c", statement],
                check=True, capture_output=True, text=True)
            observed_ns = time.monotonic_ns()
            observed_utc = datetime.now(timezone.utc).isoformat()
            rows = list(csv.reader(io.StringIO(completed.stdout)))
            if len(rows) != 1 or len(rows[0]) != 4 or rows[0][1] != reference:
                raise ValueError("Successful INSERT returned an unexpected row")
            json.dump({"row": rows[0], "utc": observed_utc, "monotonic_ns": observed_ns}, out)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
            print(f"Acknowledged: {reference}")
            if sequence < first + count - 1:
                time.sleep(0.2)


def read_json(path):
    with path.open() as source:
        return json.load(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("record")
    record.add_argument("--journal", required=True, type=Path)
    record.add_argument("--first", required=True, type=int)
    record.add_argument("--count", required=True, type=int)
    report = commands.add_parser("report")
    for name in ("journal", "recovered", "fault", "start", "verified", "output"):
        report.add_argument(f"--{name}", required=True, type=Path)
    for name in ("backup", "project", "last-archived-wal"):
        report.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    try:
        if args.command == "record":
            record_orders(args.journal, args.first, args.count)
            return
        with args.journal.open() as source:
            acknowledgments = [json.loads(line) for line in source]
        with args.recovered.open(newline="") as source:
            recovered = list(csv.reader(source))
        result = build_rpo_report(acknowledgments, recovered, read_json(args.fault),
                                  read_json(args.start), read_json(args.verified))
        root = Path(__file__).resolve().parent.parent
        result["source_commit"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        result["worktree_dirty"] = bool(subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=root, text=True).strip())
        result["backup_label"] = args.backup
        result["project"] = args.project
        result["last_archived_wal"] = args.last_archived_wal
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x") as out:
            json.dump(result, out, indent=2)
            out.write("\n")
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"RPO measurement failed: {error}\n")
    print(f"RPO report: {args.output}")
    print(f"Acknowledged: {result['acknowledged_transactions']}; "
          f"recovered: {result['recovered_transactions']}; "
          f"lost: {result['lost_acknowledged_transactions']}; "
          f"observed RPO: {result['observed_rpo_seconds']:.3f}s; "
          f"verified restore duration: {result['recovery_duration_seconds']:.3f}s")


if __name__ == "__main__":
    main()
