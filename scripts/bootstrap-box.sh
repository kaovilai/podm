#!/bin/zsh
#
# Copyright (C) 2025 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# bootstrap-box: idempotent bootstrap of a fresh macOS 26 (Tahoe) Apple silicon
# dev box for pacman (https://github.com/kaovilai/pacman).
#
# usage: zsh scripts/bootstrap-box.sh [--user-install] [--sudo-stdin] [--test] [REPO]
#   REPO         existing pacman checkout to build; default: clone
#                $PACMAN_REPO_URL (branch $PACMAN_BRANCH) into ~/pacman
#   --user-install  (default) install Apple container and podman from their
#                .pkg payloads into ~/.local (no sudo at all) and symlink the
#                CLIs into the bin dir instead of running `installer`
#                (also BOX_USER_INSTALL=1; set BOX_USER_INSTALL=0 for root installs)
#   --sudo-stdin   read the sudo password as the first line of stdin and feed it
#                to each sudo call with `sudo -S -k`. It stays in an unexported
#                shell variable, never on argv or in the environment. Fallback
#                for when a root install is wanted over ssh without a tty.
#   --test         also run scripts/lint-pipes.sh and `swift test` in the checkout
#
# Versions are pinned below and overridable from the environment, e.g.
# CONTAINER_VERSION=1.7.0. CONTAINER_VERSION defaults to the `container` pin in
# the checkout's Package.resolved (same source of truth as CI), then 1.6.0.
#
# Without --sudo-stdin, sudo steps use `sudo -n` and are reported as PENDING
# when no cached credential exists — the script never prompts. Run `sudo -v`
# in the same terminal, then re-run; finished steps are skipped. Over ssh
# without a tty, sudo's per-tty timestamp falls back to a per-parent-process
# record, so a credential cached by --sudo-stdin's first call would not reach
# later calls: every call gets the password instead.

set -euo pipefail

PODMAN_VERSION=${PODMAN_VERSION:-6.1.4}
DOCKER_VERSION=${DOCKER_VERSION:-27.3.1}
PACMAN_REPO_URL=${PACMAN_REPO_URL:-https://github.com/kaovilai/pacman.git}
PACMAN_BRANCH=${PACMAN_BRANCH:-main}
# empty = derive from the checkout's Package.resolved (fallback 1.6.0 below)
CONTAINER_VERSION=${CONTAINER_VERSION:-}

DL=$HOME/pacman-box-dl
export PATH=/usr/local/bin:/opt/podman/bin:$HOME/bin:$PATH

typeset -a DONE_STEPS PENDING
ok()   { DONE_STEPS+=("$1"); echo "ok       $1"; return 0; }
pend() { PENDING+=("$1: $2"); echo "PENDING  $1: $2"; return 0; }
step() { echo; echo "== $1"; }

SUDO_PW='' USER_INSTALL=${BOX_USER_INSTALL:-1} RUN_TESTS=0
while [[ ${1:-} == --* ]]; do
  case $1 in
    --sudo-stdin) IFS= read -r SUDO_PW || true; exec </dev/null ;;
    --user-install) USER_INSTALL=1 ;;
    --test) RUN_TESTS=1 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac; shift
done

# asroot CMD...: run CMD as root. -k makes sudo always read the password line,
# so it never leaks into CMD's stdin.
asroot() {
  if [[ -n $SUDO_PW ]]; then print -r -- "$SUDO_PW" | sudo -S -k -p '' "$@"; else sudo -n "$@"; fi
}
SUDO_OK=0; asroot true 2>/dev/null && SUDO_OK=1 || true
[[ -n $SUDO_PW ]] && (( ! SUDO_OK )) && echo "WARN     --sudo-stdin password rejected; sudo steps will be PENDING"
needsudo() {
  (( SUDO_OK )) && return 0
  pend "$1" "needs sudo (run 'sudo -v' or pass --sudo-stdin, or use --user-install where offered, then re-run)"
  return 1
}

# userpkg NAME PKG SUBDIR DEST: extract SUBDIR of PKG's payload into DEST
# without installer/sudo
userpkg() {
  local x=$DL/$1/x; rm -rf $x
  pkgutil --expand-full $2 $x >/dev/null && [[ -d $x/$3 ]] && rm -rf $4 && mkdir -p ${4:h} && mv $x/$3 $4
}

# fetch NAME URL: download into a fresh ~/pacman-box-dl/NAME/ and print the file path
fetch() {
  local d=$DL/$1; rm -rf $d; mkdir -p $d; local f=$d/${2:t}
  curl -fsSL --retry 3 -o $f "$2" || { echo "download failed: $2" >&2; return 1; }; echo $f
}

# bin dir for CLIs: /usr/local/bin when writable or via sudo, else ~/bin
BIN=$HOME/bin
if [[ -w /usr/local/bin ]]; then BIN=/usr/local/bin
elif (( SUDO_OK )); then asroot mkdir -p /usr/local/bin && asroot chown $USER /usr/local/bin && BIN=/usr/local/bin; fi
mkdir -p $BIN

# --user-install roots; their CLIs are symlinked into $BIN. container derives
# its install root (plugins, apiserver) from the real path of the executable,
# so it runs from here unchanged.
UCONTAINER=$HOME/.local/container UPODMAN=$HOME/.local/podman
if (( USER_INSTALL )); then PODMAN=$UPODMAN/bin/podman CONTAINER=$UCONTAINER/bin/container
else PODMAN=/opt/podman/bin/podman CONTAINER=container; fi

# ulink NAME TARGET: symlink a --user-install CLI into $BIN, never over a
# root-installed file, then pend when NAME on PATH still resolves elsewhere
# (a root install earlier on PATH wins)
ulink() {
  [[ -x $2 ]] || return 0
  if [[ -e $BIN/$1 && ! -L $BIN/$1 ]]; then pend "$1 link" "$BIN/$1 is a root install; uninstall it to use $2"
  else ln -sf $2 $BIN/$1; fi
  [[ ${$(command -v $1):A} == ${2:A} ]] || pend "$1 PATH" "$(command -v $1) shadows $2"
  return 0
}

# ── pacman checkout ──────────────────────────────────────────────────────────
if [[ -n ${1:-} ]]; then
  REPO=$1
  [[ -d $REPO ]] || { echo "repo path not found: $REPO" >&2; exit 1; }
else
  REPO=$HOME/pacman
  if [[ -d $REPO/.git ]]; then
    if git -C $REPO fetch -q origin; then
      git -C $REPO checkout -q -B $PACMAN_BRANCH origin/$PACMAN_BRANCH \
        || pend "repo update" "branch $PACMAN_BRANCH not found on origin; keeping current checkout"
    else
      pend "repo update" "git fetch failed (offline?); keeping current checkout"
    fi
  else
    git clone -q --branch $PACMAN_BRANCH $PACMAN_REPO_URL $REPO
  fi
fi

# container version: env pin wins, else the Package.resolved pin (what CI
# installs), else a floor default
if [[ -z $CONTAINER_VERSION ]]; then
  CONTAINER_VERSION=$(python3 -c "import json; d=json.load(open('$REPO/Package.resolved')); print([p['state']['version'] for p in d['pins'] if p['identity']=='container'][0])" 2>/dev/null || echo 1.6.0)
fi

# ── Xcode / swift ────────────────────────────────────────────────────────────
step "Xcode / swift"
if xcode-select -p >/dev/null 2>&1 && swift --version >/dev/null 2>&1; then
  if xcodebuild -license check >/dev/null 2>&1; then ok "swift ($(swift --version 2>&1 | head -1))"
  elif needsudo "xcode license"; then asroot xcodebuild -license accept && ok "xcode license accepted"; fi
else pend "xcode" "install Xcode 26 from the App Store (or xcode-select --install), then re-run"; fi

# ── Rosetta (for pacman's amd64 builder containers) ──────────────────────────
step "Rosetta"
if arch -x86_64 /usr/bin/true 2>/dev/null; then ok "rosetta"
elif needsudo "rosetta"; then asroot softwareupdate --install-rosetta --agree-to-license && ok "rosetta installed"; fi

# ── Apple container ──────────────────────────────────────────────────────────
step "Apple container $CONTAINER_VERSION"
if [[ $($CONTAINER --version 2>/dev/null) == *"$CONTAINER_VERSION"* ]]; then ok "container $CONTAINER_VERSION present"
elif (( USER_INSTALL )) || needsudo "container install"; then
  base=https://github.com/apple/container/releases/download/$CONTAINER_VERSION
  pkg=$(fetch container $base/container-$CONTAINER_VERSION-installer-signed.pkg) \
    || pkg=$(fetch container $base/container-installer-signed.pkg) || pkg=''
  if (( USER_INSTALL )); then
    # running services exec from their install root (old user or root
    # install), so stop them first
    for c in $CONTAINER container; do command -v $c >/dev/null && { $c system stop >/dev/null 2>&1 || true; break; }; done
    if [[ -n $pkg ]] && userpkg container $pkg Payload $UCONTAINER; then ok "container $CONTAINER_VERSION -> $UCONTAINER"
    else pend "container install" "pkg extract failed (pkg: ${pkg:-none})"; fi
  elif [[ -n $pkg ]] && asroot installer -pkg $pkg -target /; then ok "container $CONTAINER_VERSION installed"
  else pend "container install" "installer failed (pkg: ${pkg:-none})"; fi
fi
(( USER_INSTALL )) && ulink container $CONTAINER

step "container system"
if ! command -v $CONTAINER >/dev/null; then pend "container system" "container CLI missing"
elif $CONTAINER system status >/dev/null 2>&1; then ok "container system running"
else
  # --enable-kernel-install answers the first-run kernel prompt non-interactively
  if ! $CONTAINER system start --enable-kernel-install; then
    # start writes the apiserver plist before its launchctl bootstrap; over
    # ssh that bootstrap can silently target the wrong domain, so bootstrap it
    # into this user's domain and start again
    plist=$(find $HOME/Library /var/root -maxdepth 6 -path '*/com.apple.container/apiserver/apiserver.plist' 2>/dev/null | head -1)
    [[ -n $plist ]] && launchctl bootstrap user/$(id -u) $plist 2>/dev/null || true
    $CONTAINER system start --enable-kernel-install || true
  fi
  if $CONTAINER system status >/dev/null 2>&1; then
    # kernel install from start can still be in flight; this blocks until the
    # kernel is set
    $CONTAINER system kernel set --recommended --force && ok "container system started + kernel set"
  else pend "container system" "'container system start --enable-kernel-install' failed (try it from a GUI/Screen Sharing session)"; fi
fi

# ── podman ───────────────────────────────────────────────────────────────────
step "podman $PODMAN_VERSION"
if [[ $($PODMAN --version 2>/dev/null) == *" $PODMAN_VERSION"* ]]; then ok "podman $PODMAN_VERSION present"
elif (( USER_INSTALL )) || needsudo "podman install"; then
  pkg=$(fetch podman https://github.com/containers/podman/releases/download/v$PODMAN_VERSION/podman-installer-macos-arm64.pkg) || pkg=''
  if (( USER_INSTALL )); then
    # only the CLI is needed: pacman is reached with --remote, so podman
    # machine helpers stay unused
    if [[ -n $pkg ]] && userpkg podman $pkg podman.pkg/Payload/podman $UPODMAN; then ok "podman $PODMAN_VERSION -> $UPODMAN"
    else pend "podman install" "pkg extract failed"; fi
  elif [[ -n $pkg ]] && asroot installer -pkg $pkg -target /; then ok "podman $PODMAN_VERSION installed"
  else pend "podman install" "installer failed"; fi
fi
(( USER_INSTALL )) && ulink podman $PODMAN

# ── docker CLI (static, no Docker Desktop) ───────────────────────────────────
step "docker CLI $DOCKER_VERSION"
if [[ $(docker --version 2>/dev/null) == *" $DOCKER_VERSION,"* ]]; then ok "docker $DOCKER_VERSION present ($(command -v docker))"
else
  tgz=$(fetch docker https://download.docker.com/mac/static/stable/aarch64/docker-$DOCKER_VERSION.tgz) || tgz=''
  if [[ -n $tgz ]] && tar -xzf $tgz -C ${tgz:h} && install -m 755 ${tgz:h}/docker/docker $BIN/docker; then
    ok "docker $DOCKER_VERSION -> $BIN/docker"
    [[ $(command -v docker) == $BIN/docker ]] || pend "docker PATH" "$(command -v docker) shadows $BIN/docker"
  else pend "docker install" "download/extract failed"; fi
fi

# ── build pacman ─────────────────────────────────────────────────────────────
step "build pacmand (release) in $REPO"
if (cd $REPO && swift build -c release --product pacmand 2>&1 | tail -5); then
  ok "pacmand built ($REPO/.build/arm64-apple-macosx/release/pacmand)"
  ln -sf $REPO/.build/arm64-apple-macosx/release/pacmand $BIN/pacmand
  ok "pacmand symlinked -> $BIN/pacmand"
else
  pend "build pacmand" "swift build -c release --product pacmand failed in $REPO"
fi

step "build pacman client shim (if present)"
# The `pacman` client shim target (Sources/pacman/) may not exist on every
# branch yet; never fail the bootstrap because of it.
if [[ -d $REPO/Sources/pacman ]]; then
  if (cd $REPO && swift build -c release --product pacman 2>&1 | tail -5); then
    ok "pacman shim built"
    ln -sf $REPO/.build/arm64-apple-macosx/release/pacman $BIN/pacman
    ok "pacman symlinked -> $BIN/pacman"
  else
    pend "build pacman shim" "swift build -c release --product pacman failed in $REPO"
  fi
else
  echo "Sources/pacman not present yet; skipping client shim build"
fi

if (( RUN_TESTS )); then
  step "lint-pipes + swift test in $REPO"
  if (cd $REPO && ./scripts/lint-pipes.sh); then ok "lint-pipes passed"
  else pend "lint-pipes" "scripts/lint-pipes.sh failed"; fi
  if (cd $REPO && swift test 2>&1 | tail -20); then ok "swift test passed"
  else pend "swift test" "swift test failed in $REPO"; fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
step "versions"
for c in "sw_vers -productVersion" "swift --version" "$CONTAINER --version" "$PODMAN --version" "docker --version"; do
  printf '%-42s %s\n' "$c" "$(eval $c 2>&1 | tail -1)"
done

echo
echo "next steps:"
echo "  $BIN/pacmand &              # daemon; socket at \$HOME/.pacman/container.sock"
echo "  docker ps                   # stock docker CLI, no setup (context 'pacman' is auto-installed)"
echo "  CONTAINER_HOST=unix://\$HOME/.pacman/container.sock podman ps"

echo
echo "${#DONE_STEPS} ok, ${#PENDING} pending"
for p in $PENDING; do echo "PENDING  $p"; done
(( ${#PENDING} == 0 ))
