#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# measure.sh LABEL CMD [ARGS...]
#
# Runs CMD while sampling memory, then prints wall time and peak RAM.
#   - `free -m` every 5 s into $MEASURE_DIR/LABEL.free.log (the LU-02 requirement)
#   - MemAvailable every 1 s into $MEASURE_DIR/LABEL.avail.log (catches short spikes
#     that a 5 s sample can miss)
# Peak RAM is reported two ways: max "used" from free -m minus the idle baseline,
# and the lowest MemAvailable seen. WSL sees the whole VM, so this includes every
# container, not just CMD.
#
# Run inside the WSL distro:  wsl.exe -d <distro> -u root -- /root/plane-work/fork/test/measure.sh web-build podman build ...
set -u

label=${1:?usage: measure.sh LABEL CMD [ARGS...]}
shift
dir=${MEASURE_DIR:-/root/plane-build/logs}
mkdir -p "$dir"
freelog="$dir/$label.free.log"
availlog="$dir/$label.avail.log"
: > "$freelog"
: > "$availlog"

( while :; do echo "--- $(date +%s)"; free -m; sleep 5; done ) >> "$freelog" 2>&1 &
s1=$!
( while :; do echo "$(date +%s) $(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)"; sleep 1; done ) >> "$availlog" 2>&1 &
s2=$!

start=$(date +%s)
"$@"
rc=$?
end=$(date +%s)

kill "$s1" "$s2" 2>/dev/null
wait "$s1" "$s2" 2>/dev/null

base_used=$(awk '/^Mem:/{print $3; exit}' "$freelog")
peak_used=$(awk '/^Mem:/{if ($3>m) m=$3} END{print m}' "$freelog")
peak_swap=$(awk '/^Swap:/{if ($3>m) m=$3} END{print m+0}' "$freelog")
min_avail=$(awk 'NR==1{m=$2} $2<m{m=$2} END{print m}' "$availlog")
max_avail=$(awk '$2>m{m=$2} END{print m}' "$availlog")
total=$(awk '/^Mem:/{print $2; exit}' "$freelog")

echo "MEASURE label=$label rc=$rc wall_s=$((end - start)) total_mb=$total base_used_mb=$base_used peak_used_mb=$peak_used peak_delta_mb=$((peak_used - base_used)) min_available_mb=$min_avail max_available_mb=$max_avail peak_swap_mb=$peak_swap"
exit "$rc"
