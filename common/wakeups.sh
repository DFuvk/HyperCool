#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - wakeup sources (read-only, runs only when the WebUI asks)
#   wakeups.sh         counters since boot, or since the last mark
#   wakeups.sh mark    remember the counters now (a reboot drops the mark)
#   wakeups.sh clear   forget the mark
#   wakeups.sh apps    which apps held Android wake locks (what "PowerManagerService.WakeLocks" is made of)
#   wakeups.sh offmark       app wake locks now, for the screen-off keeper (own file: Mark start is not touched)
#   wakeups.sh offtop <ms> <s>  user apps with at least <ms> of wake locks since offmark, most first (at most 3):
#                            T|<uid>|<package or ->|<ms>|<tag that held the most>; C|charger when the charger was
#                            in for part of the <s> seconds; nothing when the stats were reset in between
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

# partial wake locks per app since the last full charge, from the text dump of battery stats.
# "--charged" prints only the since-charge section, without the battery history ("-c" adds the whole
# history, megabytes late in the day; "--checkin" would be a real checkin and delete the file Google's
# checkin service reads). Uid sections: "  u0a123:" then "    Wake lock <tag>: 1m 2s 3ms partial (4 times) ...".
# Lines: L|uid|tag|ms|times   BT|<ms on battery since the stats were last reset>
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 40"
# A dump that failed or was cut by the timeout gives nothing (a part of it would be a wrong mark).
apps_now() {
  { $TMO dumpsys batterystats --charged > "$W/bs"; } 2>/dev/null || { rm -f "$W/bs"; return 1; }
  tr -d '\r' < "$W/bs" | awk '
    # "1d 2h 3m 4s 5ms" -> ms
    function tms(s,   n, i, v, u, t) {
      t = 0; n = split(s, q, " ")
      for (i = 1; i <= n; i++) { v = q[i] + 0; u = q[i]; sub(/^[0-9]+/, "", u)
        if (u == "d") t += v * 86400000; else if (u == "h") t += v * 3600000; else if (u == "m") t += v * 60000
        else if (u == "s") t += v * 1000; else if (u == "ms") t += v }
      return t
    }
    # UserHandle.formatUid: 1000, u0a123 (app), u10s1000 (system uid of user 10), u0i5 / u0ai5 (isolated)
    function touid(x,   us, k, n) {
      if (x ~ /^[0-9]+$/) return x
      us = x; sub(/^u/, "", us); k = us; sub(/^[0-9]+/, "", k); us = substr(us, 1, length(us) - length(k))
      n = k; sub(/^[a-z]+/, "", n); k = substr(k, 1, length(k) - length(n))
      if (k == "a") return us * 100000 + 10000 + n
      if (k == "s") return us * 100000 + n
      if (k == "i") return us * 100000 + 99000 + n
      if (k == "ai") return us * 100000 + 90000 + n
      return ""
    }
    !bt && /^  Time on battery: / { x = $0; sub(/^  Time on battery: /, "", x); sub(/\(.*/, "", x); printf "BT|%.0f\n", tms(x); bt = 1; next }
    /^  (u[0-9]+[a-z]+[0-9]+|[0-9]+):$/ { uid = touid(substr($0, 3, length($0) - 3)); next }
    /^  [^ ]/ { uid = ""; next }
    uid != "" && /^    Wake lock / {
      x = substr($0, 15)
      # the first time field ends the tag; "background partial" is a part of "partial", not counted twice
      if (!match(x, /: ([0-9]+d )?([0-9]+h )?([0-9]+m )?([0-9]+s )?[0-9]+ms (full|partial|background partial|window|draw) \(/)) next
      tag = substr(x, 1, RSTART - 1); gsub(/\|/, "/", tag)
      if (!match(x, /(: |, )([0-9]+d )?([0-9]+h )?([0-9]+m )?([0-9]+s )?[0-9]+ms partial \([0-9]+ times\)/)) next
      seg = substr(x, RSTART + 2, RLENGTH - 2)
      c = seg; sub(/^.* partial \(/, "", c); sub(/ times\)$/, "", c)
      sub(/ partial \(.*$/, "", seg)
      ms = tms(seg)
      if (ms > 0) printf "L|%s|%s|%.0f|%d\n", uid, tag, ms, c
    }'
  rm -f "$W/bs"
}
# package of each app id (uid % 100000), only when something has to be named: P|<app id>|<package>
pkg_map() {
  { $TMO cmd package list packages -U; } 2>/dev/null | tr -d '\r' |
    sed -n 's/^package:\([^ ]*\) uid:\([0-9][0-9]*\).*/\2 \1/p' | awk '{ a = $1 % 100000; if (!(a in P)) { P[a] = $2; print "P|" a "|" $2 } }'
}

# the screen-off keeper: app wake locks over one screen-off period (needs no kernel wakeup statistics)
OFF=$D/wk.off
if [ "$1" = offmark ]; then
  mkdir -p "$D" 2>/dev/null
  # written in this run's own folder first: two runs (screen off, on, off again) never share a file
  if apps_now > "$W/mark" 2>/dev/null && grep -q '^BT|' "$W/mark"; then mv -f "$W/mark" "$OFF"; else rm -f "$OFF"; fi
  exit 0
fi
if [ "$1" = offtop ]; then
  MIN=${2:-600000}; case "$MIN" in ''|*[!0-9]*) MIN=600000 ;; esac
  [ -s "$OFF" ] || exit 0
  mv -f "$OFF" "$W/off" 2>/dev/null || exit 0
  apps_now > "$W/an" || exit 0
  # time on battery went back: Android reset its stats (full charge) in between, nothing to compare.
  # <s> (3rd argument, the length of the screen-off period): time on battery more than 10% short of it
  # means the charger was in for a while, and wake locks while charging are no drain: C|charger
  SEC=${3:-0}; case "$SEC" in ''|*[!0-9]*) SEC=0 ;; esac
  _bv=$(awk -F'|' -v sec="$SEC" 'FILENAME == A { if ($1 == "BT" && b0 == "") b0 = $2; next } $1 == "BT" && b1 == "" { b1 = $2 }
    END { if (b0 == "" || b1 == "" || b1 + 0 < b0 + 0) print "reset"; else if (sec > 0 && b1 - b0 < sec * 900) print "charger"; else print "ok" }' A="$W/off" "$W/off" "$W/an")
  case "$_bv" in
    ok) ;;
    charger) echo "C|charger"; exit 0 ;;
    *) exit 0 ;;
  esac
  # user apps only (uid 10000-19999 in any user): Android's own uids cannot be restricted
  # a wake lock cannot have held more than the whole period (+10%): such a value is no real change
  awk -F'|' -v MIN="$MIN" -v sec="$SEC" '
    FILENAME == A { if ($1 == "L") o[$2 "|" $3] = $4; next }
    $1 == "L" { u = $2; a = u % 100000; if (a < 10000 || a > 19999) next
      d = $4 - o[u "|" $3]; if (d <= 0 || (sec > 0 && d > sec * 1100)) next
      S[u] += d; if (d > T[u]) { T[u] = d; G[u] = $3 } }
    END { for (u in S) if (S[u] >= MIN + 0) printf "T|%s|-|%.0f|%s\n", u, S[u], G[u] }' A="$W/off" "$W/off" "$W/an" |
    sort -t'|' -k4,4nr | head -n 3 > "$W/top"
  [ -s "$W/top" ] || exit 0
  # package names only now that there is something to name
  pkg_map > "$W/pk"
  awk -F'|' 'FILENAME == K { P[$2] = $3; next } { a = $2 % 100000; $3 = (a in P ? P[a] : "-"); print }' OFS='|' K="$W/pk" "$W/pk" "$W/top"
  exit 0
fi

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
  if apps_now > "$W/mark" 2>/dev/null && grep -q '^BT|' "$W/mark"; then mv -f "$W/mark" "$APPS"; else rm -f "$APPS"; fi
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
  grep -q '^BT|' "$W/an" 2>/dev/null || { echo "src=none"; exit 0; }
  pkg_map >> "$W/an"
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
    END { for (k in L) { split(k, a, "|"); u = a[1]; t = substr(k, length(u) + 2); ap = u % 100000
      printf "A|%s|%s|%s|%.0f|%.0f\n", u, ((ap in P) ? P[ap] : "-"), t, L[k], C[k] } }' MF="$APPS" "$( [ "$AB" = mark ] && echo "$APPS" || echo /dev/null )" "$W/an" | sort -t'|' -k5,5nr | head -n 200
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
