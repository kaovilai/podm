#!/usr/bin/env python3
"""Extract the CLI's subcommand tree from --help output and diff it
against a checked-in baseline (commands-<cli>.json).

The recording battery only exercises commands we already know about —
a NEW subcommand added upstream would otherwise sail through unnoticed.
The tree compare catches it: a new path is surface drift (podm may need
routes; the battery may want an entry), a removed path means battery rot
or an upstream removal. Either way the job fails with the diff.

Usage:
  commands.py extract <cli> <binary> > tree.json
  commands.py compare BASELINE.json TREE.json
"""
import json
import re
import subprocess
import sys

# Any "* Commands:" section header: CLIs name them differently and the
# naming varies BY BINARY — homebrew docker prints "Commands:", the static
# bundle from download.docker.com prints "Common Commands:" and
# "Swarm Commands:" as separate sections. An exact allowlist silently
# dropped whole sections (docker run/info/secret/swarm were missing from
# the first CI-generated baseline).
SECTION_HEADER = re.compile(r"^(?:[A-Z][A-Za-z]* )*Commands:$")
ENTRY = re.compile(r"^  (\S+?)(\*)?\s{2,}")
MAX_DEPTH = 3
HELP_TIMEOUT = 30

# Unstarred top-level names that alias a PATH-installed plugin rather than
# the binary under test: docker's `builder` forwards to buildx (its help is
# the plugin's, and it only exists when a plugin is discoverable), so its
# subcommands vary with the runner, not the CLI version. Starred entries
# (buildx*, compose*) are already skipped by the star check.
PLUGIN_ALIASES = {"docker": {"builder"}}


def help_lines(binary, args):
    """--help output for a (sub)command; empty on timeout (a subcommand
    that hangs on help is not something we can record anyway)."""
    try:
        out = subprocess.run(
            [binary, *args, "--help"],
            capture_output=True,
            text=True,
            timeout=HELP_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return []
    return (out.stdout or "").splitlines()


def parse_subcommands(lines, cli=None):
    """Names in any Commands: section. Docker marks plugin-provided
    commands with a trailing * (buildx*, compose*) — those live outside
    the binary under test and vary with the runner's PATH, so they are
    skipped to keep the tree about the CLI itself."""
    names = []
    in_section = False
    for line in lines:
        stripped = line.strip()
        if SECTION_HEADER.match(stripped):
            in_section = True
            continue
        if not in_section:
            continue
        if not stripped:
            # Cobra pads sections with blank lines; a blank line ends the
            # section only when the next non-blank line is not an entry.
            continue
        match = ENTRY.match(line)
        if match and not match.group(2):
            name = match.group(1)
            if cli is None or name not in PLUGIN_ALIASES.get(cli, set()):
                names.append(name)
        elif not line.startswith("  "):
            in_section = False
    return names


def extract_tree(binary, prefix, cli=None):
    """Depth-first walk of the command tree; returns sorted full paths."""
    tree = set()
    frontier = [((), name, 1) for name in parse_subcommands(help_lines(binary, []), cli=cli)]
    while frontier:
        parent_args, name, depth = frontier.pop()
        args = (*parent_args, name)
        tree.add(" ".join((*prefix, *args)))
        if depth < MAX_DEPTH:
            for sub in parse_subcommands(help_lines(binary, list(args)), cli=cli):
                frontier.append((args, sub, depth + 1))
    return sorted(tree)


def cli_version(binary):
    out = subprocess.run(
        [binary, "--version"], capture_output=True, text=True, timeout=HELP_TIMEOUT
    )
    match = re.search(r"\d+\.\d+\.\d+", out.stdout or "")
    return match.group(0) if match else "unknown"


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    mode = sys.argv[1]
    if mode == "extract":
        cli, binary = sys.argv[2], sys.argv[3]
        print(
            json.dumps(
                {
                    "cli": cli,
                    "cli_version": cli_version(binary),
                    "commands": extract_tree(binary, [cli], cli=cli),
                },
                indent=2,
            )
        )
    elif mode == "compare":
        baseline_path, tree_path = sys.argv[2], sys.argv[3]
        baseline = json.load(open(baseline_path))
        tree = json.load(open(tree_path))
        print(f"baseline: {baseline['cli']} {baseline['cli_version']} "
              f"({len(baseline['commands'])} commands)")
        print(f"tested:   {tree['cli']} {tree['cli_version']} "
              f"({len(tree['commands'])} commands)")
        if baseline["cli"] != tree["cli"]:
            print("comparing different CLIs — wrong baseline file?")
            sys.exit(2)
        base = set(baseline["commands"])
        new = set(tree["commands"])
        drift = False
        for command in sorted(new - base):
            print(f"NEW COMMAND (upstream addition): {command}")
            print("  podm may need routes for it; add a battery entry in run.sh")
            print("  or consciously skip-list it, then refresh the tree baseline.")
            drift = True
        for command in sorted(base - new):
            print(f"REMOVED COMMAND (upstream removal / rename): {command}")
            print("  the recording battery may be silently recording nothing")
            print("  for it — update run.sh and refresh the tree baseline.")
            drift = True
        if drift:
            print("\nCLI command-surface drift detected.")
            sys.exit(1)
        print("No drift: the command surface matches the baseline.")
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
