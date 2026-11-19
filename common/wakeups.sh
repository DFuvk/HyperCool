#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - wakeup sources (read-only, runs only when the WebUI asks)
#   wakeups.sh         counters since boot, or since the last mark
#   wakeups.sh mark    remember the counters now (a reboot drops the mark)
#   wakeups.sh clear   forget the mark
#   wakeups.sh apps    which apps held Android wake locks (what "PowerManagerService.WakeLocks" is made of)
# Reads the kernel's wakeup statistics: /sys/class/wakeup/wakeup*/{name,active_count,wakeup_count,total_time_ms,prevent_suspend_time_ms}
# (total_time_ms is the awake time since boot; active_time_ms would only be the activation running right now)
# Sources with the same name are added up. Nothing in the system is changed; only the mark file is written.
# Output:
#   src=none                                   no wakeup statistics on this kernel
#   src=wakeup  base=boot|mark  age=<s>  awake=<ms the CPU was awake in that time, if known>  n=<rows>
#   W|<name>|<awake ms>|<times active>|<wakeup_count: activations while the phone was suspending or waking>|<prevented sleep ms>
# apps output (Android battery stats, partial wake locks):
#   src=bstats|none  base=mark|charge  reset=1 (stats were reset after a full charge since the mark)  age=<s>
#   A|<uid>|<package or ->|<wake lock tag>|<ms>|<times>
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"

WK=${HC_WK:-/sys/class/wakeup}
D=${HC_DATA:-/data/adb/hypercool}
BASE=$D/wk.base
APPS=$D/wk.apps
TMPD=${HC_TMP:-/data/local/tmp}
[ -d "$TMPD" ] && [ -w "$TMPD" ] || TMPD=${TMPDIR:-/tmp}
W=$TMPD/hc_wakeups.$$
mkdir -p "$W" 2>/dev/null || exit 1
trap 'rm -rf "$W"' EXIT
trap 'exit 1' INT TERM HUP PIPE

[ "$1" = clear ] && { rm -f "$BASE" "$APPS"; exit 0; }

# partial wake locks per app since the last full charge, from the checkin format of battery stats.
# "-c" only prints that format; "--checkin" would be a real checkin and delete the file Google's checkin service reads.
# Lines: P|uid|package   L|uid|tag|ms|times   BT|<ms on battery since the stats were last reset>
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 40"
apps_now() {
  { $TMO dumpsys batterystats -c; } 2>/dev/null | tr -d '\r' | awk -F, '
    $3 == "i" && $4 == "uid" { if (!($5 in P)) P[$5] = $6; next }
    $3 == "l" && $4 == "bt" { print "BT|" $6; next }
    $3 == "l" && $4 == "wl" {
      ms = ""; c = 0
      for (i = 6; i < NF; i++) if ($i == "p") { ms = $(i - 1); c = $(i + 1); break }
      if (ms + 0 > 0) { n = $5; gsub(/\|/, "/", n); print "L|" $2 "|" n "|" ms "|" c }
      next
    }
    END { for (u in P) print "P|" u "|" P[u] }'
}

ls -d "$WK"/wakeup[0-9]* >/dev/null 2>&1 || { echo "src=none"; exit 0; }

# one grep per attribute (not one cat per source); "<id> <attribute> <value>"
for a in name active_count wakeup_count total_time_ms prevent_suspend_time_ms; do
  grep -H '' "$WK"/wakeup[0-9]*/$a 2>/dev/null | sed -n "s#^.*/wakeup\([0-9][0-9]*\)/$a:#\1 $a #p"
done | tr -d '\r' > "$W/raw"
[ -s "$W/raw" ] || { echo "src=none"; exit 0; }

# add up the sources of one name: name|awake ms|active|wakeups|prevent ms (awk doubles: no 32-bit overflow)
awk '
  { id = $1; a = $2; v = $0; sub(/^[0-9]+ [a-z_]+ ?/, "", v) }
  a == "name" { nm[id] = v; next }
  a == "active_count" { ac[id] = v + 0; next }
  a == "wakeup_count" { wc[id] = v + 0; next }
  a == "total_time_ms" { at[id] = v + 0; next }
  a == "prevent_suspend_time_ms" { ps[id] = v + 0; next }
  END {
    for (id in nm) {
      n = nm[id]; gsub(/\|/, "/", n); if (n == "") n = "(no name) " id
      A[n] += at[id]; C[n] += ac[id]; K[n] += wc[id]; P[n] += ps[id]
    }
    for (n in A) printf "%s|%.0f|%.0f|%.0f|%.0f\n", n, A[n], C[n], K[n], P[n]
  }' "$W/raw" > "$W/cur"

UP=$(cut -d. -f1 "${HC_UPTIME:-/proc/uptime}" 2>/dev/null)
case "$UP" in ''|*[!0-9]*) UP=0 ;; esac
# awake time: the monotonic clock stops in deep sleep, /proc/uptime does not (empty when unknown)
mono() { { grep -m 1 '^now at ' "${HC_TIMERLIST:-/proc/timer_list}"; } 2>/dev/null | sed -n 's/^now at \([0-9][0-9]*\)[0-9]\{6\} nsecs.*/\1/p'; }
MONO=$(mono)
# ms values pass 2^31 after 24.8 days, and Android's sh (mksh) counts in 32 bits: compare and subtract them in awk
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
# changes on every boot: a mark from an earlier boot is never mixed with new counters
BID=$( { tr -cd '0-9a-f-' < "${HC_BOOTID:-/proc/sys/kernel/random/boot_id}"; } 2>/dev/null )

if [ "$1" = mark ]; then
  mkdir -p "$D" 2>/dev/null
  # app wake locks too (a second or two); a failed read only leaves the app list without a mark
  apps_now > "$APPS.tmp" 2>/dev/null
  if grep -q '^BT|' "$APPS.tmp" 2>/dev/null; then mv "$APPS.tmp" "$APPS"; else rm -f "$APPS.tmp" "$APPS"; fi
  { echo "#$UP${BID:+ $BID}"; [ -n "$MONO" ] && echo "#mono=$MONO"; cat "$W/cur"; } > "$BASE.tmp" 2>/dev/null && mv "$BASE.tmp" "$BASE" || { rm -f "$BASE.tmp"; exit 1; }
  exit 0
fi

# the mark counts only if the phone was not restarted since (counters start at zero after a restart):
# same boot id; without a boot id on either side, the uptime must not have gone back
B=boot; AGE=$UP
if [ -s "$BASE" ]; then
  _h=$(sed -n '1s/^#//p' "$BASE")
  U0=${_h%% *}; B0=""; case "$_h" in *' '*) B0=${_h#* } ;; esac
  case "$U0" in ''|*[!0-9]*) U0=-1 ;; esac
  _ok=0
  if [ "$U0" -ge 0 ] && [ "$UP" -ge "$U0" ]; then
    if [ -n "$B0" ] && [ -n "$BID" ]; then [ "$B0" = "$BID" ] && _ok=1; else _ok=1; fi
  fi
  if [ "$_ok" = 1 ]; then B=mark; AGE=$((UP - U0)); else rm -f "$BASE" "$APPS"; fi
fi

if [ "$1" = apps ]; then
  apps_now > "$W/an"
  grep -q '^BT|' "$W/an" || { echo "src=none"; exit 0; }
  BT1=$(sed -n 's/^BT|\([0-9][0-9]*\).*/\1/p' "$W/an" | head -n 1)
  AB=charge; RS=0
  if [ "$B" = mark ] && [ -s "$APPS" ]; then
    BT0=$(sed -n 's/^BT|\([0-9][0-9]*\).*/\1/p' "$APPS" | head -n 1)
    if grep -q '^R|1' "$APPS"; then
      # a reset was already seen since the mark: the stats count from that reset, as Android's own totals do
      RS=1
    elif [ -n "$BT0" ] && [ -n "$BT1" ] && ge "$BT1" "$BT0"; then
      AB=mark
    else
      # time on battery went back: Android reset its stats (full charge) after the mark. The old app counters
      # are of no use any more; remember the reset so a later read never subtracts them again
      RS=1
      { echo "R|1"; echo "BT|0"; } > "$APPS.tmp" 2>/dev/null && mv "$APPS.tmp" "$APPS" || rm -f "$APPS.tmp"
    fi
  fi
  echo "src=bstats"; echo "base=$AB"; echo "reset=$RS"; echo "age=$AGE"
  awk -F'|' -v AB="$AB" '
    FILENAME == MF { if ($1 == "L") { o[$2 "|" $3] = $4; oc[$2 "|" $3] = $5 } next }
    $1 == "P" { P[$2] = $3; next }
    $1 == "L" { k = $2 "|" $3; ms = $4; c = $5
      if (AB == "mark") { ms -= o[k]; c -= oc[k]; if (ms < 0) ms = 0; if (c < 0) c = 0 }
      if (ms > 0) { L[k] = ms; C[k] = c } }
    END { for (k in L) { split(k, a, "|"); u = a[1]; t = substr(k, length(u) + 2)
      printf "A|%s|%s|%s|%.0f|%.0f\n", u, (u in P ? P[u] : "-"), t, L[k], C[k] } }' MF="$APPS" "$( [ "$AB" = mark ] && echo "$APPS" || echo /dev/null )" "$W/an" | sort -t'|' -k5,5nr | head -n 200
  exit 0
fi

echo "src=wakeup"; echo "base=$B"; echo "age=$AGE"
# awake ms in the counted time: since the mark, or since boot (monotonic time is awake time since boot)
AW=""
if [ -n "$MONO" ]; then
  if [ "$B" = mark ]; then
    M0=$(sed -n 's/^#mono=\([0-9][0-9]*\)$/\1/p' "$BASE" | head -n 1)
    [ -n "$M0" ] && ge "$MONO" "$M0" && AW=$(awk -v a="$MONO" -v b="$M0" 'BEGIN { printf "%.0f", a - b }')
  else
    AW=$MONO
  fi
fi
[ -n "$AW" ] && echo "awake=$AW"
if [ "$B" = mark ]; then
  awk -F'|' 'FILENAME == BF { if ($0 !~ /^#/) { a[$1] = $2; c[$1] = $3; k[$1] = $4; p[$1] = $5 } next }
    { da = $2 - a[$1]; dc = $3 - c[$1]; dk = $4 - k[$1]; dp = $5 - p[$1]
      # a name can lose counters when one of its sources is removed (eventpoll and the like): count that as no change, not as a reset
      if (da < 0) da = 0; if (dc < 0) dc = 0; if (dk < 0) dk = 0; if (dp < 0) dp = 0
      if (da > 0 || dc > 0 || dk > 0 || dp > 0) printf "W|%s|%.0f|%.0f|%.0f|%.0f\n", $1, da, dc, dk, dp }' BF="$BASE" "$BASE" "$W/cur"
else
  awk -F'|' '$2 > 0 || $3 > 0 || $4 > 0 || $5 > 0 { printf "W|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5 }' "$W/cur"
fi > "$W/out"
cat "$W/out"
echo "n=$(grep -c '^W|' "$W/out")"
