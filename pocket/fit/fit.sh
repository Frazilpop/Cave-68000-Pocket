#!/bin/sh
# Cave 68000 for Analogue Pocket — the board alone through Quartus, for its
# fit and timing on the Pocket's part.
#
#   pocket/fit/fit.sh            compile pocket/fit/fit.qsf (every port a
#                                virtual pin) and print the fit and the worst
#                                slack per clock
#   pocket/fit/fit.sh --clean    empty the database first
#
# Runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1, linux/amd64),
# here under Colima with Rosetta, as pocket/build.sh will. The whole
# repository is mounted; the project reaches ../../rtl and ../../third_party.
# The database and reports land under build/pocket/fit/ (db/, incremental_db/
# and output_files/ here are symlinks into it). Takes the same lock as
# pocket/build.sh: one Quartus at a time in this repository.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
qb=$repo/build/pocket/fit
image=raetro/quartus:21.1

clean=0
for arg in "$@"; do
    case "$arg" in
        --clean) clean=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "fit.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

case "$repo" in
    "$HOME"/*) ;;
    *) echo "fit.sh: the repository must be under \$HOME ($HOME); Colima shares nothing else." >&2; exit 1 ;;
esac
[ -f "$repo/third_party/fx68k/hdl/fx68k.sv" ] || { echo "fit.sh: no third_party/fx68k (run tools/bootstrap.sh)" >&2; exit 1; }

lock=$repo/build/pocket/build.lock
mkdir -p "$repo/build/pocket"
if ! mkdir "$lock" 2>/dev/null; then
    other=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "fit.sh: another Quartus run is going (pid $other); not starting a second." >&2
        exit 1
    fi
    rm -rf "$lock"; mkdir "$lock"
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM

mkdir -p "$qb/db" "$qb/incremental_db" "$qb/output_files"
for d in db incremental_db output_files; do
    if [ -L "$here/$d" ]; then
        :
    elif [ -e "$here/$d" ]; then
        echo "fit.sh: $here/$d is a real directory; move it aside so it can be a link into build/." >&2
        exit 1
    else
        ln -s "../../build/pocket/fit/$d" "$here/$d"
    fi
done
# fx68k's microcode, read relative to the project directory
for m in microrom.mem nanorom.mem; do
    [ -e "$here/$m" ] || ln -s "../../third_party/fx68k/hdl/$m" "$here/$m"
done
if [ "$clean" = 1 ]; then
    find "$qb/db" "$qb/incremental_db" -mindepth 1 -delete
fi

log=$qb/compile.log
echo "== Quartus 21.1 ($image): the board alone, virtual pins"
echo "   log: $log"
start=$(date +%s)
if ! docker run --rm --platform linux/amd64 \
        -v "$repo":/build -w /build/pocket/fit \
        "$image" quartus_sh --flow compile fit > "$log" 2>&1; then
    echo "== COMPILE FAILED"
    grep -E "^Error|^ *Error \(" "$log" | head -40
    exit 1
fi
echo "   compiled in $(( $(date +%s) - start )) s"

crit=$(grep -c "^Critical Warning" "$log" || true)
if [ "$crit" != "0" ]; then
    echo "== $crit critical warning(s):"
    grep "^Critical Warning" "$log" | sort -u | head -20
fi

python3 -I - "$qb/output_files" <<'PYEOF'
import os, re, sys
out = sys.argv[1]
fit = open(os.path.join(out, "fit.fit.summary")).read()
print("== fit (5CEBA4F23C8), the board alone")
for key in ("Logic utilization (in ALMs)", "Total registers", "Total block memory bits",
            "Total RAM Blocks", "Total DSP Blocks", "Total PLLs"):
    m = re.search(re.escape(key) + r"\s*:\s*(.+)", fit)
    if m:
        print(f"   {key:<28} {m.group(1).strip()}")

sta = open(os.path.join(out, "fit.sta.summary")).read()
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
print("== timing: worst slack per clock over all corners (ns)")
fail = False
def label(clk):
    for k, v in (("pll_a|general[0]", "clk 96"), ("pll_a|general[1]", "clk_cpu 32"), ("pll_b|general[0]", "clk_vid 28")):
        if k in clk and "OUTPUT_COUNTER" in clk:
            return v
    return clk
for clk in sorted({c for c, _ in worst if (c, "Setup") in worst}, key=label):
    row = []
    for kind in ("Setup", "Hold", "Recovery", "Removal"):
        if (clk, kind) in worst:
            s, corner = worst[(clk, kind)]
            row.append(f"{kind.lower()} {s:+.3f}")
            if s < 0:
                fail = True
    print(f"   {label(clk):<12} " + "  ".join(row))
print("== NEGATIVE SLACK: timing is not met" if fail else "== timing met")
PYEOF
