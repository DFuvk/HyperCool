#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - top battery users (read-only, runs only when the WebUI asks)
#   topdrain.sh [N]   N = rows (default 25)
#   topdrain.sh raw   the power sections of the dump as printed (bug report)
# Reads `dumpsys batterystats`: "Estimated power use (mAh)" (user apps, system apps, system uids, hardware).
# No power section on this ROM: falls back to the partial wake lock times. Nothing is written.
# Output (one item per line):
#   src=power|wake|none    unit=mAh|s    since=<text>    total=<sum>    n=<rows>
#   R|<value>|<share %>|<app|system|core|hw>|<name>|<uid>
#   diag=<line>            only with src=none
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"

RAW=0; [ "$1" = raw ] && { RAW=1; set -- 25; }
N=${1:-25}
case "$N" in ''|*[!0-9]*) N=25 ;; esac
[ "$N" -ge 5 ] && [ "$N" -le 60 ] || N=25
TMPD=${HC_TMP:-/data/local/tmp}
[ -d "$TMPD" ] && [ -w "$TMPD" ] || TMPD=${TMPDIR:-/tmp}
W=$TMPD/hc_topdrain.$$
mkdir -p "$W" 2>/dev/null || exit 1
trap 'rm -rf "$W"' EXIT
trap 'exit 1' INT TERM HUP

TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 40"

# uid -> package map: "<uid> <package> <app|system>"
pkgmap() {
  { $TMO cmd package list packages -U -3 2>/dev/null || $TMO pm list packages -U -3 2>/dev/null; } |
    sed -n 's/^package:\([^ ]*\) uid:\([0-9][0-9]*\).*/\2 \1 app/p'
  { $TMO cmd package list packages -U -s 2>/dev/null || $TMO pm list packages -U -s 2>/dev/null; } |
    sed -n 's/^package:\([^ ]*\) uid:\([0-9][0-9]*\).*/\2 \1 system/p'
}
pkgmap | tr -d '\r' > "$W/map"

$TMO dumpsys batterystats 2>/dev/null | tr -d '\r' > "$W/dump"
[ -s "$W/dump" ] || { echo "src=none"; echo "diag=dumpsys batterystats printed nothing"; exit 0; }
# raw: the first lines of every power section as the ROM prints them (for the bug report)
if [ "$RAW" = 1 ]; then
  grep -n -A40 'Estimated power use' "$W/dump" | head -n 130
  exit 0
fi

# shared awk part: Android uid text -> numeric uid, then label / kind
cat > "$W/lib.awk" <<'EOF'
function numuid(s,   m, a, u) {
  if (s ~ /^[0-9]+$/) return s + 0
  if (match(s, /^u[0-9]+a[0-9]+$/)) {
    split(substr(s, 2), a, "a")
    return a[1] * 100000 + 10000 + a[2]
  }
  if (match(s, /^u[0-9]+i[0-9]+$/)) return -1
  if (match(s, /^u[0-9]+s[0-9]+$/)) return -1
  return -1
}
function usr(s,   a) {
  if (match(s, /^u[0-9]+a[0-9]+$/)) { split(substr(s, 2), a, "a"); return a[1] + 0 }
  return 0
}
function sysname(u) {
  if (u == 0) return "root"
  if (u == 1000) return "Android System (system_server)"
  if (u == 1001) return "Phone / radio (RIL)"
  if (u == 1002) return "Bluetooth stack"
  if (u == 1006) return "Camera"
  if (u == 1013) return "Media server"
  if (u == 1021) return "GPS"
  if (u == 1027) return "NFC"
  if (u == 1036) return "logd"
  if (u == 1041) return "Audio server"
  if (u == 1047) return "Camera server"
  if (u == 2000) return "shell (adb)"
  return "system uid " u
}
# fills K (kind) and L (label) for a numeric uid; u = Android user number
function lab(uid, u,   app) {
  if (uid < 0) { K = "core"; L = "isolated / other process"; return }
  if (uid < 10000) { K = "core"; L = sysname(uid); return }
  # the package map is keyed by the full uid (user * 100000 + app id), so look it up as it is:
  # with uid % 100000 an app of user 10 would get the package of user 0
  if (uid in pk) {
    K = pk[uid]; L = pn[uid]
    if (cnt[uid] > 1) L = L " +" (cnt[uid] - 1)
  } else { app = uid % 100000; K = "app"; L = "uid " uid " (package not found)" }
  if (u > 0) L = L " (user " u ")"
}
EOF

# ---------------------------------------------------------------- 1: estimated power use
# Android 14+ (BatteryUsageStats.dump):   Estimated power use (mAh):
#                                           Capacity: 5000, Computed drain: 403, actual drain: 0-0
#                                           Global
#                                             cpu: 101.0 apps: 100.0 duration: ...
#                                           UID u0a147: 25.2 fg: ... ( cpu=... )
# Older Android:  Screen: 12.3 / Uid u0a123: 5.67 ( cpu=5.67 )     (case of "UID" does not matter)
# "Estimated power use" appears once per period (since last charge, since last unplugged ...): the first one with per-app rows is used.
cat > "$W/p.awk" <<'EOF'
BEGIN { FS = " " }
FILENAME == MAPF {
  a = $1 + 0
  cnt[a]++
  if (!(a in pk)) { pk[a] = $3; pn[a] = $2 }
  else if ($3 == "system") pk[a] = "system"
  next
}
function indent(x,   t) { t = x; sub(/[^ \t].*$/, "", t); return length(t) }
/Estimated power use \(mAh\)/ {
  bn++; sec = 1; hin = indent($0); delete hwseen; next
}
# per-app rows can sit outside the block of the device-level rows: keep the first one of every id from anywhere
/^[ \t]*[Uu][Ii][Dd] [^ :]+: [0-9]+(\.[0-9]+)?/ {
  line = $0; sub(/^[ \t]+/, "", line)
  match(line, /^[Uu][Ii][Dd] [^ :]+: [0-9]+(\.[0-9]+)?/)
  split(substr(line, 5, RLENGTH - 4), q, ": ")
  if (!(q[1] in anyu)) { anyu[q[1]] = q[2] + 0 }
}
sec {
  if ($0 ~ /^[ \t]*$/) next
  if (indent($0) <= hin) { sec = 0; next }
  line = $0; sub(/^[ \t]+/, "", line)
  if (match(line, /Computed drain: [0-9]+(\.[0-9]+)?/)) { cdb[bn] = substr(line, RSTART + 15, RLENGTH - 15) + 0 }
  if (match(line, /^[Uu][Ii][Dd] [^ :]+: [0-9]+(\.[0-9]+)?/)) {
    split(substr(line, 5, RLENGTH - 4), q, ": ")
    nrow[bn]++; nu[bn]++
    rid[bn, nrow[bn]] = q[1]; rv[bn, nrow[bn]] = q[2] + 0; rk[bn, nrow[bn]] = "u"
    next
  }
  if (line ~ /^(Capacity|Computed|Over-counted|Unaccounted|User |Global)/) next
  if (match(line, /^[A-Za-z_][A-Za-z0-9_ \/-]*: [0-9]+(\.[0-9]+)?/)) {
    split(substr(line, 1, RLENGTH), q, ": ")
    if (q[1] in hwseen) next
    hwseen[q[1]] = 1
    nrow[bn]++
    nh[bn]++
    rid[bn, nrow[bn]] = q[1]; rv[bn, nrow[bn]] = q[2] + 0; rk[bn, nrow[bn]] = "h"
  }
}
function emit(id, v, kind,   uid) {
  if (v <= 0) return
  if (kind == "h") { printf "%d|%.2f|hw|%s|-\n", v * 100 + 0.5, v, id; return }
  uid = numuid(id)
  lab(uid, usr(id))
  printf "%d|%.2f|%s|%s|%s\n", v * 100 + 0.5, v, K, L, (uid >= 0 ? uid : id)
}
END {
  # block with per-app rows, else the first block with rows
  pick = 0
  for (i = 1; i <= bn; i++) if (nu[i] > 0) { pick = i; break }
  if (!pick) for (i = 1; i <= bn; i++) if (nrow[i] > 0) { pick = i; break }
  for (j = 1; j <= nrow[pick]; j++) emit(rid[pick, j], rv[pick, j], rk[pick, j])
  # no per-app rows in the picked block: the ones found elsewhere in the dump
  if (!nu[pick]) for (id in anyu) emit(id, anyu[id], "u")
  # the picked block has no device-level rows: take them from the first block that has some
  if (!nh[pick]) for (i = 1; i <= bn; i++) if (nh[i] > 0) {
    for (j = 1; j <= nrow[i]; j++) if (rk[i, j] == "h") emit(rid[i, j], rv[i, j], "h")
    if (!cdb[pick]) cdb[pick] = cdb[i]
    break
  }
  print cdb[pick] + 0 > CDF
}
EOF
cat "$W/lib.awk" "$W/p.awk" > "$W/pp.awk"
awk -v MAPF="$W/map" -v CDF="$W/cd" -f "$W/pp.awk" "$W/map" "$W/dump" > "$W/rows"

since=$(grep -m 1 'Time on battery:' "$W/dump" | sed 's/^[ \t]*//' | cut -c1-120)
[ -n "$since" ] || since=$(grep -m 1 -i 'since last' "$W/dump" | sed 's/^[ \t]*//' | cut -c1-120)

if [ -s "$W/rows" ]; then
  # share of the computed drain; without it the device-level rows (cpu, screen ...), else everything listed
  # total = the larger of Android's "Computed drain", the device-level rows and the biggest row (a share can never pass 100%;
  # some ROMs print the computed drain in another number format)
  tot=$(awk -F'|' -v C="$(cat "$W/cd" 2>/dev/null)" 'BEGIN { t = C + 0 }
    $3 == "hw" { h += $2 } { if ($2 + 0 > m) m = $2 + 0; a += $2 }
    END { if (h > t) t = h; if (m > t) t = m; if (t <= 0) t = a; printf "%.2f", t }' "$W/rows")
  echo "src=power"; echo "unit=mAh"; echo "since=$since"; echo "total=$tot"
  sort -t'|' -k1,1 -nr "$W/rows" | head -n "$N" | awk -F'|' -v T="$tot" '
    { p = (T > 0 ? $2 * 100 / T : 0); printf "R|%s|%.1f|%s|%s|%s\n", $2, p, $3, $4, $5; c++ }
    END { print "n=" c + 0 }'
  exit 0
fi

# ---------------------------------------------------------------- 2: partial wake lock time per uid
cat > "$W/w.awk" <<'EOF'
function dur(s,   v, m) {
  v = 0
  if (match(s, /[0-9]+d /)) v += substr(s, RSTART, RLENGTH - 2) * 86400
  if (match(s, /[0-9]+h /)) v += substr(s, RSTART, RLENGTH - 2) * 3600
  if (match(s, /[0-9]+m /)) v += substr(s, RSTART, RLENGTH - 2) * 60
  if (match(s, /[0-9]+s /)) v += substr(s, RSTART, RLENGTH - 2)
  return v
}
FILENAME == MAPF {
  a = $1 + 0
  cnt[a]++
  if (!(a in pk)) { pk[a] = $3; pn[a] = $2 }
  else if ($3 == "system") pk[a] = "system"
  next
}
/All partial wake locks:/ { sec = 1; next }
sec {
  if ($0 !~ /^[ \t]/ || $0 ~ /^[ \t]*$/) { sec = 0; next }
  line = $0; sub(/^[ \t]+/, "", line)
  if (line !~ /^Wake lock /) { sec = 0; next }
  split(line, f, " ")
  id = f[3]
  sub(/:$/, "", id)   # "Wake lock u0a123: ..." -> the id without the colon
  if (!match(line, /: ([0-9]+d )?([0-9]+h )?([0-9]+m )?([0-9]+s )?[0-9]+ms \(/)) next
  d = dur(substr(line, RSTART, RLENGTH))
  if (d <= 0) next
  uid = numuid(id)
  key = (uid >= 0 ? uid : id)
  sec_[key] += d
  idm[key] = id
  um[key] = usr(id)
}
END {
  for (k in sec_) {
    lab((k ~ /^[0-9]+$/ ? k + 0 : -1), um[k])
    printf "%d|%d|%s|%s|%s\n", sec_[k], sec_[k], K, L, k
  }
}
EOF
cat "$W/lib.awk" "$W/w.awk" > "$W/ww.awk"
awk -v MAPF="$W/map" -f "$W/ww.awk" "$W/map" "$W/dump" > "$W/wrows"
if [ -s "$W/wrows" ]; then
  tot=$(awk -F'|' '{ s += $2 } END { print s + 0 }' "$W/wrows")
  echo "src=wake"; echo "unit=s"; echo "since=$since"; echo "total=$tot"
  sort -t'|' -k1,1 -nr "$W/wrows" | head -n "$N" | awk -F'|' -v T="$tot" '
    { p = (T > 0 ? $2 * 100 / T : 0); printf "R|%s|%.1f|%s|%s|%s\n", $2, p, $3, $4, $5; c++ }
    END { print "n=" c + 0 }'
  exit 0
fi

# ---------------------------------------------------------------- nothing readable
echo "src=none"
echo "since=$since"
echo "diag=power section: $(grep -c 'Estimated power use' "$W/dump") wake lock section: $(grep -c 'All partial wake locks' "$W/dump") lines: $(wc -l < "$W/dump")"
grep -m 3 -iE 'Estimated power|Statistics since|Battery stats' "$W/dump" | sed 's/^[ \t]*/diag=/' | cut -c1-140
exit 0
