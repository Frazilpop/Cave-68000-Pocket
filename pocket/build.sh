#!/bin/sh
# Cave 68000 for Analogue Pocket — build the bitstream.
#
#   pocket/build.sh            compile pocket/src/fpga/ap_core.qpf
#   pocket/build.sh --clean    empty db/ and incremental_db/ first, so smart
#                              recompilation cannot skip a stage
#   pocket/build.sh --oki      DonPachi's bitstream: the board with its two
#                              OKI M6295s in place of the YMZ280B (CAVE_OKI),
#                              as the revision ap_core_oki – ap_core.qsf with
#                              the macro added, written here each time
#
# Runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1, linux/amd64),
# here under Colima with Rosetta. The WHOLE repository is mounted, because the
# project in pocket/src/fpga reaches ../../../rtl and ../../../third_party.
# Colima shares $HOME only — a checkout under /tmp would mount as empty.
#
# Generated files stay under build/ (the repo's rule): db/, incremental_db/
# and output_files/ in the project directory are symlinks into
# build/pocket/quartus/, made here on first use. The one exception is Analogue's
# own pre-flow script, which rewrites apf/build_id.mif with the build date.
#
# Afterwards: the fit and the worst slack per clock are printed, and only if
# every clock meets timing is the bit-reversed bitstream the Pocket loads
# written to pocket/dist/Cores/frazilpop.Cave 68000/bitstream.rbf_r (with
# --oki, donpachi.rbf_r, which DonPachi's instance JSONs select). On negative
# slack the script fails and leaves dist alone; the bitstream it made is kept
# as build/pocket/quartus/<name>.failed for a look. A bitstream that met
# timing is recorded in build/pocket/bitstreams.txt (SHA-256, name, the
# commit its sources came from, when), and tools/pocket/deploy.sh puts only a
# recorded bitstream on the card. Takes the same lock as
# pocket/fit/fit.sh: one Quartus at a time in this repository.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
fpga=$repo/pocket/src/fpga
qb=$repo/build/pocket/quartus
dist="$repo/pocket/dist/Cores/frazilpop.Cave 68000"
image=raetro/quartus:21.1

clean=0 rev=ap_core out_name=bitstream.rbf_r
for arg in "$@"; do
    case "$arg" in
        --clean) clean=1 ;;
        --oki) rev=ap_core_oki out_name=donpachi.rbf_r ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

case "$repo" in
    "$HOME"/*) ;;
    *) echo "build.sh: the repository must be under \$HOME ($HOME); Colima shares nothing else." >&2
       exit 1 ;;
esac

for f in "$repo/third_party/pocket-utils/ip/data_loader.sv" "$repo/third_party/fx68k/hdl/fx68k.sv"; do
    [ -f "$f" ] || { echo "build.sh: missing $f (run tools/bootstrap.sh?)" >&2; exit 1; }
done

# ------------------------------------------------------------ one at a time
# Two Quartus runs in one project write the same db/ and the same log, and
# neither finishes cleanly; two at once in one repository also halve the
# Mac's memory. The DCMSX page and a chat can both start this script, so it
# takes a lock (mkdir is atomic) and refuses while another build holds it. A
# lock left by a killed build is cleared once its pid is gone.
lock=$repo/build/pocket/build.lock
mkdir -p "$repo/build/pocket"
if ! mkdir "$lock" 2>/dev/null; then
    other=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "build.sh: another build is running (pid $other); not starting a second." >&2
        exit 1
    fi
    rm -rf "$lock"; mkdir "$lock"
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM
# Compiles the lock does not see (a seed sweep, another checkout) are waited for.
"$repo/tools/wait_quartus.sh"

# ---------------------------------------------------- generated -> build/
mkdir -p "$qb/db" "$qb/incremental_db" "$qb/output_files"
for d in db incremental_db output_files; do
    if [ -L "$fpga/$d" ]; then
        :
    elif [ -e "$fpga/$d" ]; then
        echo "build.sh: $fpga/$d is a real directory; move it aside so it can be a link into build/." >&2
        exit 1
    else
        # Relative, so it resolves the same inside the container (/build/...).
        ln -s "../../../build/pocket/quartus/$d" "$fpga/$d"
    fi
done

# fx68k's microcode, read relative to the project directory
for m in microrom.mem nanorom.mem; do
    [ -e "$fpga/$m" ] || ln -s "../../../third_party/fx68k/hdl/$m" "$fpga/$m"
done

if [ "$rev" = ap_core_oki ]; then
    # Quartus adds the revision to ap_core.qpf, first, which would make it the
    # project's default; the file is put back as it was afterwards
    cp "$fpga/ap_core.qpf" "$qb/ap_core.qpf.keep"
    trap 'cp "$qb/ap_core.qpf.keep" "$fpga/ap_core.qpf"; rm -rf "$lock"' EXIT INT TERM
    { cat "$fpga/ap_core.qsf"
      echo
      echo "# DonPachi's bitstream (pocket/build.sh --oki writes this file from ap_core.qsf)"
      echo 'set_global_assignment -name VERILOG_MACRO "CAVE_OKI=1"'
    } > "$fpga/ap_core_oki.qsf"
fi

if [ "$clean" = 1 ]; then
    echo "== clean: emptying $qb/db and $qb/incremental_db"
    find "$qb/db" "$qb/incremental_db" -mindepth 1 -delete
fi

# The sources as the compile reads them: the commit, and "+changes" when the
# working tree differs from it (apf/build_id.mif aside, which every compile
# rewrites).
src=$(git -C "$repo" rev-parse --short HEAD)
[ -z "$(git -C "$repo" status --porcelain -- rtl pocket/src \
        ':(exclude)pocket/src/fpga/apf/build_id.mif')" ] || src=$src+changes

log=$qb/compile.log
[ "$rev" = ap_core ] || log=$qb/compile_$rev.log
echo "== Quartus 21.1 ($image), revision $rev"
echo "   log: $log"
start=$(date +%s)
if ! docker run --rm --platform linux/amd64 \
        -v "$repo":/build -w /build/pocket/src/fpga \
        "$image" quartus_sh --flow compile ap_core -c "$rev" > "$log" 2>&1; then
    echo "== COMPILE FAILED"
    grep -E "^Error|^ *Error \(" "$log" | head -40
    exit 1
fi
echo "   compiled in $(( $(date +%s) - start )) s"

# Critical warnings are worth a look every time; they are where a wrong pin or
# an ignored constraint shows up.
crit=$(grep -c "^Critical Warning" "$log" || true)
if [ "$crit" != "0" ]; then
    echo "== $crit critical warning(s):"
    grep "^Critical Warning" "$log" | sort -u | head -20
fi

# ------------------------------------------------------------- bitstream
rbf=$qb/output_files/$rev.rbf
[ -f "$rbf" ] || { echo "build.sh: no $rbf" >&2; exit 1; }
rbf_r=$qb/$out_name.new
python3 -I - "$rbf" "$rbf_r" <<'EOF'
import sys
# APF wants every byte of the .rbf bit-reversed (Analogue: Packaging a Core).
src, dst = sys.argv[1], sys.argv[2]
table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(src, "rb").read()
open(dst, "wb").write(data.translate(table))
print(f"== bitstream: {len(data)} bytes")
EOF

# ------------------------------------------------------------- reports
status=0
python3 -I - "$qb/output_files" "$rev" <<'EOF' || status=$?
import os, re, sys
out, rev = sys.argv[1], sys.argv[2]

fit = open(os.path.join(out, rev + ".fit.summary")).read()
print("== fit (5CEBA4F23C8)")
for key in ("Logic utilization (in ALMs)", "Total registers", "Total pins",
            "Total block memory bits", "Total RAM Blocks", "Total DSP Blocks",
            "Total PLLs"):
    m = re.search(re.escape(key) + r"\s*:\s*(.+)", fit)
    if m:
        print(f"   {key:<28} {m.group(1).strip()}")

sta = open(os.path.join(out, rev + ".sta.summary")).read()
worst = {}
for typ, slack in re.findall(r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?[\d.]+)", sta):
    m = re.match(r"(.+?) Model (Setup|Hold|Recovery|Removal|Minimum Pulse Width) '(.+)'", typ)
    if not m:
        continue
    corner, kind, clk = m.groups()
    k = (clk, kind)
    s = float(slack)
    if k not in worst or s < worst[k][0]:
        worst[k] = (s, corner)

names = {
    ("u_pll_core", "general[0]"):  "clk 96",
    ("u_pll_core", "general[1]"):  "clk_cpu 32",
    ("u_pll_core", "general[2]"):  "clk_sdram_ps 96/180",
    ("u_pll_video", "general[0]"): "clk_vid 28",
    ("u_pll_video", "general[1]"): "clk_pix 7",
    ("u_pll_video", "general[2]"): "clk_pix90 7/90",
}
def label(clk):
    for (pll, out), v in names.items():
        if pll in clk and out in clk:
            return v
    return clk

print("== timing: worst slack per clock over all corners (ns)")
fail = False
for clk in sorted({c for c, _ in worst}, key=label):
    row = []
    for kind in ("Setup", "Hold", "Recovery", "Removal"):
        if (clk, kind) in worst:
            s, corner = worst[(clk, kind)]
            row.append(f"{kind.lower()} {s:+.3f}")
            if s < 0:
                fail = True
    print(f"   {label(clk):<22} " + "  ".join(row))
if fail:
    print("== NEGATIVE SLACK: timing is not met")
    sys.exit(1)
print("== timing met")
EOF

# ------------------------------------------------------------- dist
# A bitstream that misses timing never reaches dist, so deploy.sh cannot put
# it on the card.
if [ "$status" != 0 ]; then
    mv "$rbf_r" "$qb/$out_name.failed"
    echo "== $out_name NOT written to dist; kept as $qb/$out_name.failed" >&2
    exit 1
fi
mkdir -p "$dist"
mv "$rbf_r" "$dist/$out_name"
sha=$(shasum -a 256 "$dist/$out_name" | cut -d' ' -f1)
echo "$sha $out_name $src $(date '+%Y-%m-%d %H:%M') timing met" >> "$repo/build/pocket/bitstreams.txt"
echo "== written: $dist/$out_name (sources $src, SHA-256 ${sha%"${sha#????????}"})"
