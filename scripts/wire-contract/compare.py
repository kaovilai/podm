#!/usr/bin/env python3
"""Diff a normalized recording against the checked-in wire-contract
baseline. Any added / removed / changed request signature per command is
UPSTREAM DRIFT (or an intentional podm-side change that forgot to refresh
the baseline) — the job fails with the diff so it can be reacted to.

Usage: compare.py BASELINE.json RECORDING-normalized.json
"""
import json
import sys


def sig(request):
    return (
        request["method"],
        request["path"],
        tuple(request["query_keys"]),
        request["content_type"],
    )


def main():
    baseline_path, recording_path = sys.argv[1], sys.argv[2]
    baseline = json.load(open(baseline_path))
    recording = json.load(open(recording_path))

    base_cmds = {c["command"]: c for c in baseline["commands"]}
    new_cmds = {c["command"]: c for c in recording["commands"]}

    print(f"baseline podman: {baseline['podman_version']}")
    print(f"tested  podman: {recording['podman_version']}")
    drift = False

    for command in sorted(set(base_cmds) | set(new_cmds)):
        if command not in new_cmds:
            print(f"MISSING COMMAND (baseline only): {command}")
            drift = True
            continue
        if command not in base_cmds:
            print(f"NEW COMMAND (recording only): {command}")
            for r in new_cmds[command]["requests"]:
                print(f"  + {sig(r)}")
            drift = True
            continue
        base_sigs = [sig(r) for r in base_cmds[command]["requests"]]
        new_sigs = [sig(r) for r in new_cmds[command]["requests"]]
        if base_sigs == new_sigs:
            continue
        drift = True
        print(f"DRIFT: {command}")
        base_set = set(base_sigs)
        new_set = set(new_sigs)
        for s in base_sigs:
            if s not in new_set:
                print(f"  - {s}")
        for s in new_sigs:
            if s not in base_set:
                print(f"  + {s}")
        if set(base_sigs) == set(new_sigs):
            print("  (same signatures, different ORDER)")

    if drift:
        print("\nWire-contract drift detected. If the CLI changed upstream:")
        print("  1. Adapt podm's routes to the new call signatures.")
        print("  2. Refresh the baseline (workflow_dispatch mode=refresh,")
        print("     or locally: run.sh + normalize.py > baseline.json) and")
        print("     commit it together with the adaptation.")
        sys.exit(1)
    print("No drift: every command's request signatures match the baseline.")


if __name__ == "__main__":
    main()
