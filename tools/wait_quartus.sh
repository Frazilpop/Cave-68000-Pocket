#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Wait for any Quartus compile already running on this machine (a core build,
# a seed sweep, another checkout's) before starting a simulation or a build.
# A compile takes most of the cores and memory Colima has for ten minutes or
# more; a Verilator run or a second compile beside it slows both badly.
#
#   tools/wait_quartus.sh           wait until none is running, then return
#   tools/wait_quartus.sh --check   say what is running; exit 1 if anything is
#
# A compile is a running container from a Quartus image (pocket/build.sh's
# raetro/quartus). With Colima or Docker down nothing can be compiling.

set -eu

running() {
    docker ps --format '{{.Image}}	{{.RunningFor}}	{{.Names}}' 2>/dev/null |
        grep -i 'quartus' || true
}

now=$(running)
if [ "${1:-}" = "--check" ]; then
    [ -z "$now" ] && exit 0
    n=$(printf '%s\n' "$now" | wc -l | tr -d ' ')
    echo "$n Quartus compile(s) running:"
    printf '%s\n' "$now" | sed 's/^/  /'
    exit 1
fi

[ -z "$now" ] && exit 0
start=$(date +%s)
while [ -n "$now" ]; do
    n=$(printf '%s\n' "$now" | wc -l | tr -d ' ')
    since=$(printf '%s\n' "$now" | head -1 | cut -f2)
    echo "waiting for $n Quartus compile(s) (started $since), $(( ($(date +%s) - start) / 60 )) min so far"
    sleep 30
    now=$(running)
done
echo "no Quartus compile running after $(( ($(date +%s) - start) / 60 )) min; going on"
