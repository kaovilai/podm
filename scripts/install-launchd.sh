#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Copyright © 2026 the podm authors.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy
# of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

# Installs the podm daemon (podmd) as a launchd LaunchAgent with an
# on-demand lifecycle: RunAtLoad + idle-exit (zero RAM when idle), woken by
# `launchctl kickstart` from the podm client shim.
#
# Usage:
#   scripts/install-launchd.sh [--bin /path/to/podmd]
#
# Binary resolution order: --bin flag, PODMD_BIN env, `command -v podmd`.

set -euo pipefail

label="io.github.podm.daemon"
uid="$(id -u)"
plist_dest="${HOME}/Library/LaunchAgents/${label}.plist"
template="${0:A:h}/../assets/launchd/${label}.plist.in"

die() {
  echo "install-launchd: $*" >&2
  exit 1
}

[[ -f "$template" ]] || die "template not found: $template"

# Resolve the podmd binary path.
podmd_bin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin)
      [[ $# -ge 2 ]] || die "--bin requires a path argument"
      podmd_bin="$2"
      shift 2
      ;;
    --bin=*)
      podmd_bin="${1#--bin=}"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--bin /path/to/podmd]"
      exit 0
      ;;
    *)
      die "unknown argument: $1 (usage: $0 [--bin /path/to/podmd])"
      ;;
  esac
done
[[ -n "$podmd_bin" ]] || podmd_bin="${PODMD_BIN:-}"
[[ -n "$podmd_bin" ]] || podmd_bin="$(command -v podmd || true)"
[[ -n "$podmd_bin" ]] || die "podmd binary not found; pass --bin /path/to/podmd or set PODMD_BIN"
[[ -x "$podmd_bin" ]] || die "not executable: $podmd_bin"
podmd_bin="${podmd_bin:A}"  # launchd needs an absolute path

# Render the template. __PODMD_BIN__ and __HOME__ are the only placeholders.
mkdir -p "${HOME}/Library/LaunchAgents"
sed \
  -e "s|__PODMD_BIN__|${podmd_bin}|g" \
  -e "s|__HOME__|${HOME}|g" \
  "$template" > "$plist_dest"
echo "wrote ${plist_dest}"

# Replace any previously installed job (idempotent reinstall).
launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
launchctl bootstrap "gui/${uid}" "$plist_dest"

echo "installed ${label} (RunAtLoad=true, KeepAlive=false; podmd exits when idle)"
echo "wake it on demand with:"
echo "  launchctl kickstart gui/${uid}/${label}"
