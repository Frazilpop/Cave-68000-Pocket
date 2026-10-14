#!/bin/bash
# Cave 68000 for the Analogue Pocket — put the core and the ROM images on the card.
#
#   tools/pocket/deploy.sh [/Volumes/NAME] [--keep]   (--keep is accepted and changes nothing)
#   tools/pocket/deploy.sh --status                   is the current build on the card?
#   tools/pocket/deploy.sh --full                     compare every ROM image on the card byte for byte
#
# Copies pocket/dist ("Cores/frazilpop.Cave 68000" with the two bitstreams –
# bitstream.rbf_r for the YMZ280B games, donpachi.rbf_r for DonPachi's sets – the
# platform JSON and image, the instance JSONs under Assets/cave68000/) onto the
# Pocket's SD card, and each target set's build/pocket/<set>.rom (made by
# tools/pocket/build_rom.py) to Assets/cave68000/common/. A ROM image already on
# the card is left alone: build/pocket/deployed-roms.txt records, for each card
# (its volume UUID), each image's SHA-256 and the size and time of its copy on
# the card, and an image whose record still matches is skipped unread. One
# without a record (a new card, a new build) is compared byte for byte, and
# copied only if it differs. The card is the volume with
# Analogue_Pocket.json at its root – in the Mac's reader, or the Pocket's own
# over USB. This installs the core itself: nothing has to be on the card first.
#
# The Pocket's card is shared with the other cores' deploy scripts (and
# DCMSX's buttons, which run them all): one copies at a time under
# /tmp/pocket-card.lock. Nothing ejects the card; that is done by hand.
# Each verified copy is recorded in build/pocket/deployed.txt (the bitstream's
# SHA-256, when it was built, the commit, when it was copied).

set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="frazilpop.Cave 68000"
PLATFORM="cave68000"
DIST="$REPO/pocket/dist"
BIN="$DIST/Cores/$CORE/bitstream.rbf_r"
BIN_OKI="$DIST/Cores/$CORE/donpachi.rbf_r"     # pocket/build.sh --oki
ROMS="$REPO/build/pocket"
RECORD="$ROMS/deployed.txt"
ROMREC="$ROMS/deployed-roms.txt"
SETS="ddonpach ddonpachj esprade espradej espradejo guwange guwanges feversos dfeveron uopoko uopokoj gaia theroes theroesa
      donpachi donpachij donpachijs donpachikr donpachihk"      # the target sets
[ -f "$BIN" ] || { echo "no $BIN - run pocket/build.sh first"; exit 1; }
[ -f "$BIN_OKI" ] || echo "Warning: no $BIN_OKI - DonPachi's sets will not start (pocket/build.sh --oki)"

VOL="" STATUS=0 FULL=0
for a in "$@"; do
	case "$a" in --keep) ;; --status) STATUS=1 ;; --full) FULL=1 ;; *) VOL="$a" ;; esac
done

built() { stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
if [ $STATUS = 1 ]; then
	s=$(sha "$BIN")
	echo "Build:   $(built), SHA-256 ${s:0:12}"
	last=$(sed -n 's/^sha256 //p' "$RECORD" 2>/dev/null || true)
	if [ -z "$last" ]; then
		echo "Card:    no deploy recorded"
	else
		echo "Card:    got the build of $(sed -n 's/^built //p' "$RECORD") at $(sed -n 's/^deployed //p' "$RECORD"), SHA-256 ${last:0:12}"
	fi
	for v in /Volumes/*; do
		[ -f "$v/Analogue_Pocket.json" ] || continue
		f="$v/Cores/$CORE/bitstream.rbf_r"
		[ -f "$f" ] && last=$(sha "$f") || last=none
		echo "         (checked on the mounted card, $v: ${last:0:12})"
	done
	if [ "$last" = "$s" ]; then echo "UP TO DATE - the card has the current build"
	else echo "NOT ON THE CARD - the current build has not been deployed: tools/pocket/deploy.sh"; exit 1; fi
	exit 0
fi

# the ROM images to copy: every target set that has both an image and an instance JSON
roms=()
for s in $SETS; do
	[ -f "$ROMS/$s.rom" ] && [ -f "$DIST/Assets/$PLATFORM/$CORE/$s.json" ] && roms+=("$s")
done
[ ${#roms[@]} -gt 0 ] || echo "Warning: no ROM images in $ROMS - the core goes on without games (tools/pocket/build_rom.py all ~/Downloads build/pocket)"

# A card pulled without being ejected is checked by macOS before it mounts
# again (~2 minutes for a big card): wait for it rather than fail.
find_card() {
	local v
	for v in /Volumes/*; do
		[ -f "$v/Analogue_Pocket.json" ] && { VOL="$v"; return 0; }
	done
	return 1
}
card_being_checked() {
	local d
	for d in $(diskutil list physical | sed -n 's|^/dev/\(disk[0-9]*\) (.*physical.*|\1|p'); do
		[ "$d" = disk0 ] && continue
		diskutil info "${d}s1" 2>/dev/null | grep -qE 'Mounted: +No' && return 0
	done
	return 1
}
if [ -z "$VOL" ]; then
	waited=0
	until find_card; do
		card_being_checked && [ $waited -lt 300 ] || break
		[ $waited = 0 ] && echo "The card is attached but macOS is checking it before mounting it (it was not ejected last time) - about 2 minutes; leave it connected..."
		sleep 2; waited=$((waited + 2))
	done
fi
[ -n "$VOL" ] || { echo "No Analogue Pocket SD card found (no volume with Analogue_Pocket.json)"; exit 1; }

# The lock is taken only once a card is mounted: finding the card only reads
# /Volumes; the copy is what the lock protects. (Taken first, a deploy left
# retrying for a card not in the reader held it, and DCMSX greyed every
# core's Deploy button until the card appeared.)
LOCK=/tmp/pocket-card.lock
release() {
	[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
	return 0
}
trap release EXIT
until mkdir "$LOCK" 2>/dev/null; do
	holder=$(cat "$LOCK/pid" 2>/dev/null || true)
	if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
	[ -n "${told:-}" ] || { echo "Waiting for another deploy to the card (pid ${holder:-?})..."; told=1; }
	sleep 1
done
echo $$ >"$LOCK/pid"

[ -f "$VOL/Analogue_Pocket.json" ] || { echo "$VOL is not the Pocket's card"; exit 1; }

# the core, the platform and the instance JSONs
for d in Cores Platforms Assets; do
	[ -d "$DIST/$d" ] && cp -R "$DIST/$d" "$VOL/"
done
echo "Copied the core ($CORE), the platform and ${#roms[@]} instance JSON(s)"

# the ROM images: only those that differ
common="$VOL/Assets/$PLATFORM/common"
mkdir -p "$common"
card_id=$(diskutil info "$VOL" 2>/dev/null | sed -n 's/^ *Volume UUID: *//p' || true)
[ -n "$card_id" ] || card_id=$(basename "$VOL" | tr ' ' _)
romsha() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }
copied() { stat -f '%z %m' "$common/$1.rom"; }   # the copy on the card: size, time
recorded() {   # set, SHA-256: this card has had the image since it was copied
	[ -f "$common/$1.rom" ] && grep -qxF "$card_id $1 $2 $(copied "$1")" "$ROMREC" 2>/dev/null
}
remember() {   # set, SHA-256
	{ grep -v "^$card_id $1 " "$ROMREC" 2>/dev/null || true; echo "$card_id $1 $2 $(copied "$1")"; } >"$ROMREC.tmp"
	mv "$ROMREC.tmp" "$ROMREC"
}
for s in ${roms[@]+"${roms[@]}"}; do
	h=$(romsha "$ROMS/$s.rom")
	if [ $FULL = 0 ] && recorded "$s" "$h"; then
		echo "  $s.rom already on the card (recorded)"
		continue
	fi
	if cmp -s "$ROMS/$s.rom" "$common/$s.rom"; then
		echo "  $s.rom already on the card"
	else
		cp "$ROMS/$s.rom" "$common/$s.rom"
		cmp -s "$ROMS/$s.rom" "$common/$s.rom" || { echo "copy of $s.rom differs"; exit 1; }
		echo "  $s.rom copied"
	fi
	remember "$s" "$h"
done

# drop the ._ AppleDouble files macOS writes beside them on a FAT card
for d in "$VOL/Cores/$CORE" "$VOL/Platforms" "$VOL/Assets/$PLATFORM"; do
	dot_clean -m "$d" 2>/dev/null || true
done

a=$(sha "$BIN") b=$(sha "$VOL/Cores/$CORE/bitstream.rbf_r")
[ "$a" = "$b" ] || { echo "the bitstream on the card differs from the build"; exit 1; }
oki=none
if [ -f "$BIN_OKI" ]; then
	oki=$(sha "$BIN_OKI")
	[ "$oki" = "$(sha "$VOL/Cores/$CORE/donpachi.rbf_r")" ] || { echo "donpachi.rbf_r on the card differs from the build"; exit 1; }
	echo "DonPachi's bitstream SHA-256 verified on the card (built $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN_OKI"))"
fi
mkdir -p "$ROMS"
printf 'sha256 %s\nbuilt %s\ncommit %s\ndeployed %s\noki_sha256 %s\n' "$a" "$(built)" \
	"$(git -C "$REPO" log -1 --format=%h 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M')" "$oki" >"$RECORD"
echo "Bitstream SHA-256 verified on the card: the build of $(built) is on $VOL"
echo "Left $VOL mounted - eject it yourself, then back in the Pocket and launch: openFPGA > Arcade > Cave 68000"
