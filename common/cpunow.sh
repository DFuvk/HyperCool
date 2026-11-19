#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - CPU use right now (read-only, runs only when the WebUI asks)
#   cpunow.sh [S]   S = seconds to measure (default 3, 2 to 10)
# Reads /proc/<pid>/stat twice and prints the processes that used the CPU in between.
# Percent is of ONE core (a process on two cores can show 200). Nothing is written.
# The measurement itself is left out: this script, the shells that started it and the tools it runs.
# Output: win=<s>  ncpu=<n>  n=<rows>
#   R|<percent>|<pid>|<uid>|<name>
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"

PR=${HC_PROC:-/proc}
S=${1:-3}
case "$S" in ''|*[!0-9]*) S=3 ;; esac
[ "$S" -ge 2 ] && [ "$S" -le 10 ] || S=3
TMPD=${HC_TMP:-/data/local/tmp}
[ -d "$TMPD" ] && [ -w "$TMPD" ] || TMPD=${TMPDIR:-/tmp}
W=$TMPD/hc_cpunow.$$
mkdir -p "$W" 2>/dev/null || exit 1
trap 'rm -rf "$W"' EXIT
trap 'exit 1' INT TERM HUP PIPE

up() { cut -d' ' -f1 "$PR/uptime" 2>/dev/null; }
# "pid utime+stime ppid" per process; comm may hold spaces and brackets, so cut at the first "(" and the last ")"
snap() {
  cat "$PR"/[0-9]*/stat 2>/dev/null | awk '{
    a = index($0, "("); b = 0
    for (i = length($0); i > a; i--) if (substr($0, i, 1) == ")") { b = i; break }
    if (!a || !b) next
    pid = substr($0, 1, a - 2); n = split(substr($0, b + 2), f, " ")
    if (n >= 13) printf "%s %d %s\n", pid, f[12] + f[13], f[2]
  }'
}
# this script and every shell above it up to the root daemon that ran the WebUI command
# (shell builtins only: every fork here adds to the wait in the WebUI)
SELF=$$; EX=" $$ "; p=$$; i=0
while [ "$i" -lt 8 ]; do
  l=""; { read -r l < "$PR/$p/stat"; } 2>/dev/null
  # fields after the last ")": state ppid ...
  set -- ${l##*) }; p=$2
  case "$p" in ''|0|1|*[!0-9]*) break ;; esac
  EX="$EX$p "; i=$((i + 1))
  c=""; { read -d '' -r c < "$PR/$p/cmdline"; } 2>/dev/null
  case "$c" in *ksud*|*magiskd*|*/apd|apd|*/su|su) break ;; esac
done
snap > "$W/a"; T0=$(up)
sleep "$S"
snap > "$W/b"; T1=$(up)

NCPU=$(grep -c '^processor' "$PR/cpuinfo" 2>/dev/null)
case "$NCPU" in ''|0|*[!0-9]*) NCPU=8 ;; esac
TCK=100
command -v getconf >/dev/null 2>&1 && { x=$(getconf CLK_TCK 2>/dev/null); case "$x" in ''|*[!0-9]*) ;; *) TCK=$x ;; esac; }

# top 25 by tick delta, as percent of one core over the real window
awk -v T0="${T0:-0}" -v T1="${T1:-0}" -v S="$S" -v TCK="$TCK" -v EX="$EX" -v SELF="$SELF" '
  FILENAME == A { u[$1] = $2; next }
  index(EX, " " $1 " ") || $3 == SELF { next }
  {
    # a process that started after the first sample has used all of its CPU time inside the window
    b = ($1 in u) ? u[$1] : 0
    if ($2 > b) { dt = T1 - T0; if (dt <= 0) dt = S; printf "%d %.1f\n", $1, ($2 - b) * 100 / TCK / dt }
  }' A="$W/a" "$W/a" "$W/b" | sort -k2,2 -nr | head -n 25 > "$W/top"

NL='
'
echo "win=$S"; echo "ncpu=$NCPU"
c=0
while read -r pid pct; do
  [ -d "$PR/$pid" ] || continue
  # first argument of the command line (up to the first NUL), builtins only
  name=""; { read -d '' -r name < "$PR/$pid/cmdline"; } 2>/dev/null
  name=${name%%[ $NL]*}; name=${name:0:80}
  if [ -z "$name" ]; then
    # kernel thread: the name in brackets from stat
    l=""; { read -r l < "$PR/$pid/stat"; } 2>/dev/null
    l=${l#*\(}; name=${l%\)*}
  fi
  [ -n "$name" ] || name="pid $pid"
  uid=""
  { while read -r k v x; do [ "$k" = Uid: ] && { uid=$v; break; }; done < "$PR/$pid/status"; } 2>/dev/null
  echo "R|$pct|$pid|${uid:--}|${name//|/}"
  c=$((c + 1))
done < "$W/top"
echo "n=$c"
