#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
# Adapted for Cave 68000 on the Analogue Pocket: the dependencies and the
# MAME files are this board's.
#
# Bootstrap upstream dependencies for the Cave 68000 core.
#
#   tools/bootstrap.sh              read-only clones into third_party/
#   tools/bootstrap.sh --fork       fork to your GitHub account first (needs gh)
#   tools/bootstrap.sh --no-mame    skip the MAME sparse checkout
#   tools/bootstrap.sh --update     re-pin deps.lock to current upstream HEADs
#
# Everything lands in third_party/, which is gitignored and never committed.
# Nothing is copied into rtl/ automatically: licence terms differ per
# dependency. Read the licence report this prints before lifting any code.
#
# A dependency added here must ALSO be added to git.ignoredRepositories in
# .vscode/settings.json, in the same change.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
LOCK="$ROOT/deps.lock"

DO_FORK=0
DO_MAME=1
DO_UPDATE=0

for a in "$@"; do
  case "$a" in
    --fork)    DO_FORK=1 ;;
    --no-mame) DO_MAME=0 ;;
    --update)  DO_UPDATE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------- dependencies
#
# name | repo | branch | role | licence | forkable
#
# fx68k: jtfpga/fx68k rather than upstream ijor/fx68k, deliberately.
#
# Its hdl/fx68k.sv is BYTE-IDENTICAL to ijor's apart from line endings — it is a
# repackaging, not a fork — but it additionally ships hdl/verilator/, a variant
# that flattens the s_nanod struct into individual wires. Upstream's version
# cannot be linted or simulated by Verilator at all:
#
#   %Error-BLKANDNBLK: Unsupported: Blocking and non-blocking assignments to
#                      same non-packed variable: 'Nanod'
#
# So synthesis takes hdl/ (which is upstream's code) and simulation takes
# hdl/verilator/. Using ijor's directly would mean the 68000 is the one block in
# this project with no simulation harness.

DEPS=(
  "fx68k|jtfpga/fx68k|master|68000 main CPU|GPL-3.0-only|yes"
  "pocket-utils|agg23/analogue-pocket-utils|master|Pocket shell IP: data loader, PSRAM, I2S audio, sync FIFO|MIT|yes"
  "jt51|jotego/jt51|master|sim/ym2151's tb_jt51 only: the YM2151 first tried, held against ymfm (nothing that ships uses it)|GPL-3.0-or-later|yes"
)

# --------------------------------------------------------------------- helpers

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

pin() { # repo dir -> sha
  git -C "$1" rev-parse HEAD 2>/dev/null || echo "UNKNOWN"
}

pinned_sha() { # name -> sha recorded in the existing deps.lock, empty if none
  [ -f "$LOCK" ] || return 0
  awk -v n="$1" '$1 == n { print $3 }' "$LOCK"
}

# Move a fresh clone back onto its recorded pin.
#
# Without this the lock is decorative: every clone takes branch HEAD and then
# deps.lock is overwritten with whatever arrived, so the file records what you
# happened to get instead of constraining what you got. MAME is the oracle this
# project verifies against — it silently moving between two machines, or between
# two runs on the same machine, undermines every comparison made against it.
#
# GitHub permits fetching a reachable SHA directly, so this stays a shallow
# fetch rather than deepening the clone.
#
# Written with explicit if/return rather than `test && return 0` guards: this
# script runs under `set -e`, where a bare failing test as the final command of
# a && list is a well-known way to abort the whole run.
checkout_pin() { # name dir -> checks out the pinned sha if one is recorded
  local name="$1" dir="$2" want have
  if [ "$DO_UPDATE" = 1 ]; then return 0; fi
  want="$(pinned_sha "$name")"
  if [ -z "$want" ] || [ "$want" = "UNKNOWN" ]; then return 0; fi
  have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$have" = "$want" ]; then return 0; fi
  if git -C "$dir" fetch --depth 1 -q origin "$want" 2>/dev/null; then
    git -C "$dir" checkout -q FETCH_HEAD
    echo "  $name: pinned to $want"
  else
    warn "  $name: pinned $want not fetchable, left at branch HEAD ($(pin "$dir"))"
    warn "  $name: rerun with --update to re-pin deliberately"
  fi
}

# ------------------------------------------------------------------ toolchain

say "== toolchain"
need git
for t in verilator yosys; do
  if have "$t"; then echo "  $t        $(command -v $t)"
  else warn "  $t        MISSING — 'make test' and 'make area' will not run"; fi
done
# pocket/build.sh runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1,
# linux/amd64; Colima on a Mac), so no Quartus install is needed here.
if have docker && docker info >/dev/null 2>&1; then
  echo "  docker     $(command -v docker) (pocket/build.sh: Quartus 21.1 in raetro/quartus:21.1)"
else
  warn "  docker     MISSING or not running — pocket/build.sh runs Quartus in Docker."
fi
if have mame; then echo "  mame       $(command -v mame)"
else warn "  mame       MISSING — the oracle. Every open question here is answered by running it."; fi
if [ "$DO_FORK" = 1 ]; then
  need gh
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"
  echo "  gh         $(gh api user --jq .login) (fork mode)"
fi
echo

# -------------------------------------------------------------------- vendors

mkdir -p "$VENDOR"
: > "$LOCK.tmp"
echo "# Pinned upstream revisions. Regenerate with tools/bootstrap.sh --update" >> "$LOCK.tmp"
echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOCK.tmp"

say "== dependencies"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo branch role lic forkable <<< "$entry"
  dest="$VENDOR/$name"
  url="https://github.com/$repo.git"

  if [ "$DO_FORK" = 1 ] && [ "$forkable" = "yes" ]; then
    user="$(gh api user --jq .login)"
    if gh repo view "$user/$(basename "$repo")" >/dev/null 2>&1; then
      echo "  $name: fork already exists at $user/$(basename "$repo")"
    else
      echo "  $name: forking $repo -> $user"
      gh repo fork "$repo" --clone=false --remote=false >/dev/null
    fi
    url="https://github.com/$user/$(basename "$repo").git"
  elif [ "$DO_FORK" = 1 ]; then
    warn "  $name: not forked ($lic licence — see licence report below)"
  fi

  if [ -d "$dest/.git" ]; then
    if [ "$DO_UPDATE" = 1 ]; then
      echo "  $name: updating"
      git -C "$dest" fetch --depth 1 origin "$branch" -q
      git -C "$dest" checkout -q FETCH_HEAD
    else
      echo "  $name: present, skipping (use --update to re-pin)"
      want="$(pinned_sha "$name")"
      if [ -n "$want" ] && [ "$want" != "UNKNOWN" ] \
         && [ "$(pin "$dest")" != "$want" ]; then
        warn "  $name: DRIFT — on disk $(pin "$dest"), lock says $want"
      fi
    fi
  else
    echo "  $name: cloning $repo"
    git clone --depth 1 --branch "$branch" -q "$url" "$dest"
    # Keep upstream reachable even when working from a fork.
    git -C "$dest" remote add upstream "https://github.com/$repo.git" 2>/dev/null || true
    checkout_pin "$name" "$dest"
  fi

  printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$dest")" >> "$LOCK.tmp"

  # Local patches: tools/patches/<name>-*.patch, made with `git -C
  # third_party/<name> diff`, applied on top of the pin. The clone stays
  # upstream's plus a diff that is committed here, so a fresh checkout builds
  # the same core. Already applied (reverse applies cleanly) is skipped; one
  # that no longer applies after --update is a warning to go and rebase it.
  for patch in "$ROOT"/tools/patches/"$name"-*.patch; do
    [ -f "$patch" ] || continue
    if git -C "$dest" apply --reverse --check "$patch" 2>/dev/null; then
      echo "  $name: $(basename "$patch") already applied"
    elif git -C "$dest" apply --check "$patch" 2>/dev/null; then
      git -C "$dest" apply "$patch"
      echo "  $name: applied $(basename "$patch")"
    else
      warn "  $name: $(basename "$patch") does not apply to $(pin "$dest") — rebase it"
    fi
  done
done

# ------------------------------------------------------------------ MAME
#
# MAME is enormous. Blobless partial clone plus a non-cone sparse checkout
# pulls only the reference sources this project reads, a few MB rather than
# several GB.
#
# src/mame/atlus/ holds the Cave driver: cave.cpp (the boards, their memory
# maps, inputs and ROM sets), cave.h, cave_v.cpp (the layer mixing) and
# sprite013 (the 013 sprite chip). The 038 tilemap chip is a device,
# src/devices/video/tmap038; the YMZ280B, the 93C46 and the 68000 are under
# src/devices/ too, and so are the Z80 board's: the YM2151 (ymopm, on
# 3rdparty/ymfm, which sim/ym2151 compiles in as the reference), the OKI
# M6295, the Z80 and the sound latch.

if [ "$DO_MAME" = 1 ]; then
  echo
  say "== mame (sparse reference checkout)"
  dest="$VENDOR/mame"
  if [ -d "$dest/.git" ]; then
    echo "  present, skipping"
  else
    git clone --filter=blob:none --no-checkout --depth 1 -q \
      https://github.com/mamedev/mame.git "$dest"
    git -C "$dest" sparse-checkout init --no-cone
    git -C "$dest" sparse-checkout set \
      '/src/mame/atlus/cave.*' \
      '/src/mame/atlus/cave_v.cpp' \
      '/src/mame/atlus/sprite013.*' \
      '/src/devices/video/tmap038.*' \
      '/src/devices/cpu/m68000/m68000.h' \
      '/src/devices/cpu/m68000/m68kcpu.*' \
      '/src/devices/cpu/m68000/m68kmusashi.*' \
      '/src/devices/cpu/m68000/m68kcommon.*' \
      '/src/devices/sound/ymz280b.*' \
      '/src/devices/sound/ymopm.*' \
      '/src/devices/sound/okim6295.*' \
      '/src/devices/cpu/z80/z80.*' \
      '/src/devices/machine/gen_latch.*' \
      '/3rdparty/ymfm/' \
      '/src/devices/machine/eepromser.*' \
      '/src/devices/machine/eeprom.*' \
      '/src/devices/machine/input_merger.*' \
      '/src/devices/machine/timer.*' \
      '/src/devices/machine/watchdog.*' \
      '/src/emu/tilemap.*' \
      '/src/emu/drawgfx.*' \
      '/src/emu/digfx.*' \
      '/src/emu/emupal.*' \
      '/src/emu/video/generic.*' \
      '/src/emu/video.*' \
      '/src/emu/screen.*' \
      '/src/frontend/mame/luaengine.cpp' \
      '/LICENSE.md'
    # Pin only AFTER sparse-checkout is configured. The clone is --no-checkout,
    # so checking out a ref before the sparse patterns exist would materialise
    # all ~31k tracked files and demand every blob — gigabytes, on a clone whose
    # entire purpose is to stay at a few MB.
    checkout_pin "mame" "$dest"
    git -C "$dest" checkout -q
    echo "  checked out $(find "$dest/src" -type f 2>/dev/null | wc -l) reference files"
  fi
  printf '%-14s %s %s\n' "mame" "mamedev/mame" "$(pin "$dest")" >> "$LOCK.tmp"
fi

# Preserve pins for anything vendored by hand rather than by this script — a
# local reference core copied in under hard rule 5, for instance. Without this
# the rewritten lock would silently drop them.
if [ -f "$LOCK" ]; then
  while read -r name repo sha; do
    case "$name" in \#*|"") continue ;; esac
    if ! awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$LOCK.tmp"; then
      if [ -d "$VENDOR/$name/.git" ]; then
        printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$VENDOR/$name")" >> "$LOCK.tmp"
      fi
    fi
  done < "$LOCK"
fi

mv "$LOCK.tmp" "$LOCK"

# --------------------------------------------------------------------- report

# fx68k reads its microcode with $readmemb at RUN time, relative to the working
# directory rather than to the source file. Symlinked into the root so a
# harness started from there finds them; without these fx68k elaborates and
# then executes an all-X microcode, which looks like a CPU that fetches once
# and stops.
if [ -f "$VENDOR/fx68k/hdl/microrom.mem" ]; then
    ln -sf third_party/fx68k/hdl/microrom.mem "$ROOT/microrom.mem"
    ln -sf third_party/fx68k/hdl/nanorom.mem  "$ROOT/nanorom.mem"
fi

cat <<'REPORT'

================================ LICENCE REPORT ================================

Read this before copying a single line out of third_party/.

  fx68k        GPL-3.0-ONLY — verified against the files, 2026-08-20.
               Earlier notes said "or-later". That is not what the
               repo grants. LICENSE is a bare GPLv3 text and fx68k.sv carries
               only "Copyright (c) 2018,2021 by Jorge Cwik" — no version
               clause, no or-later grant. The "any later version" strings in
               LICENSE are inside the licence's own how-to-apply appendix, not
               a statement by the author. Absent that grant, GPLv3 is
               version-only.
               Compatible here because nullobject's Cave core (rtl/cave/) and
               alphanu1's SDRAM controller are GPL-3.0-or-later, which GPL-3
               takes. CONSEQUENCE: taking fx68k makes this core GPL-3.0-only
               as a whole. If or-later matters, ask Jorge Cwik for the grant
               rather than assuming it.

  pocket-utils MIT — Adam Gastineau (agg23), 2022.
               The Pocket shell's data loader, PSRAM controller, I2S audio and
               sync FIFO, used in place from third_party/ by
               pocket/src/fpga/ap_core.qsf. Permissive; keep the notice.

  mame         Mixed. The atlus/cave files, sprite013 and tmap038 vendored
               here carry BSD-3-Clause headers (Luca Elia, Paul Priest, David
               Haywood). MAME as a whole is GPL-2.0. Check the header of every
               file you read, not the repo licence. BSD-3-Clause is readable
               AND adaptable — it is the reference of record for the two
               custom chips and the oracle every comparison runs against.

================================================================================
REPORT

cat <<'NEXT'
Useful paths now available:

  third_party/mame/src/mame/atlus/cave.cpp             boards, clocks, memory maps, ROM sets
  third_party/mame/src/mame/atlus/cave_v.cpp           the layers' mixing order
  third_party/mame/src/mame/atlus/sprite013.cpp        the 013 sprite chip
  third_party/mame/src/devices/video/tmap038.cpp       the 038 tilemap chip
  third_party/mame/src/devices/sound/ymz280b.cpp       the YMZ280B
  third_party/fx68k/hdl/fx68k.sv                       68000 (synthesis)
  third_party/fx68k/hdl/verilator/                     68000 (simulation)
  third_party/pocket-utils/ip/                         the Pocket shell's IP

Next: the board in Verilator (sim/ddonpach) against MAME, then
      sh pocket/build.sh   (the bitstream, into pocket/dist)
NEXT
