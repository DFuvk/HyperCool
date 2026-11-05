#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - app cache cleaner (run [force] | keeper)
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
LAST=$HC_DATA/cache_clean.last     # cleared_kb|apps_cleaned|epoch|apps_scanned
CHECK=$HC_DATA/cache_clean.check   # epoch of the last daily check
PIDF=$HC_DATA/cache_keeper.pid

cfgv() { sed -n "s/^$1=//p" "$HC_DATA/config.conf" 2>/dev/null | tail -n 1 | tr -d '\r'; }

# notification as the shell user (cmd notification needs a package); root as a fallback
notify() {
  _nt="HyperCool"; _nm=$1
  su -lp 2000 -c "cmd notification post -S bigtext -t '$_nt' hc_cache '$_nm'" </dev/null >/dev/null 2>&1 ||
    cmd notification post -S bigtext -t "$_nt" hc_cache "$_nm" </dev/null >/dev/null 2>&1
}

# "package kb" for every app cache dir (internal + external storage)
measure() {
  du -sk /data/data/*/cache /data/media/0/Android/data/*/cache 2>/dev/null | awk '{
    p = $2; sub(/^\/data\/data\//, "", p); sub(/^\/data\/media\/0\/Android\/data\//, "", p); sub(/\/cache$/, "", p)
    s[p] += $1 } END { for (k in s) print k, s[k] }'
}


# cannot skip an app (a cache dir moved aside was still emptied), so with a keep list the cache folders
# of all other apps are emptied here and the listed apps are not touched at all. Covered: every user
# (clones, work profile), CE and DE storage, external storage. What happened goes to cache_keep.log.
KEEP_TAG=.hc_keep_cache
KEEP_LOG=$HC_DATA/cache_keep.log

# package names of the keep list (nothing when the switch is off)
keep_list() {
  [ "$(cfgv x_cache_keep)" = 0 ] && return 0
  for _p in $(cfgv x_cache_keep_pkgs | tr ',' ' '); do
    case "$_p" in ''|.*|*..*|*[!A-Za-z0-9._]*) continue ;; esac
    echo "$_p"
  done
}

clean_manual() {
  _kl=" $* "
  echo "keep list at $(date '+%Y-%m-%d %H:%M:%S'): $*" > "$KEEP_LOG"
  echo "mode: cache folders emptied directly (pm trim-caches not used)" >> "$KEEP_LOG"
  _ne=0
  for _d in /data/user/*/* /data/user_de/*/* /data/media/*/Android/data/*; do
    [ -d "$_d/cache" ] || continue
    _pk=${_d##*/}
    case "$_kl" in *" $_pk "*)
      echo "$_d: cache kept ($(du -sk "$_d/cache" 2>/dev/null | cut -f1) KB)" >> "$KEEP_LOG"; continue ;;
    esac
    rm -rf "$_d/cache"/* "$_d/cache"/.[!.]* "$_d/cache"/..?* 2>/dev/null
    _ne=$((_ne + 1))
  done
  for _p in "$@"; do
    [ -d /data/user/0/$_p ] || [ -d /data/media/0/Android/data/$_p ] || echo "$_p: no app folder found (wrong package name?)" >> "$KEEP_LOG"
  done
  echo "emptied $_ne cache folders" >> "$KEEP_LOG"
}

# puts back a cache dir that an older build left aside after an interrupted clean
keep_restore() {
  for _d in /data/user/*/* /data/user_de/*/* /data/media/*/Android/data/*; do
    [ -d "$_d/$KEEP_TAG" ] || continue
    if [ -d "$_d/cache" ]; then
      mv "$_d/cache"/* "$_d/$KEEP_TAG"/ 2>/dev/null
      rmdir "$_d/cache" 2>/dev/null || rm -rf "$_d/cache"
    fi
    mv "$_d/$KEEP_TAG" "$_d/cache" 2>/dev/null
  done
}

run_clean() {
  # one clean at a time (keeper and the WebUI button); a lock older than 10 min is stale
  _lk=$HC_DATA/.cc_lock
  if ! mkdir "$_lk" 2>/dev/null; then
    [ -n "$(find "$_lk" -maxdepth 0 -mmin +10 2>/dev/null)" ] || return 0
    rm -rf "$_lk"; mkdir "$_lk" 2>/dev/null || return 0
  fi
  _b=$HC_DATA/.cc_before; _a=$HC_DATA/.cc_after
  keep_restore
  _kp=$(keep_list)
  measure > "$_b"
  # apps that keep their cache do not count for the total or the result
  if [ -n "$_kp" ]; then
    awk -v l=" $(echo $_kp) " 'index(l, " " $1 " ") == 0' "$_b" > "$_b.f" && mv -f "$_b.f" "$_b"
  fi
  _tot=$(awk '{ t += $2 } END { print t + 0 }' "$_b")
  _min=$(cfgv x_cache_min); case "$_min" in ''|*[!0-9]*) _min=0 ;; esac
  date +%s > "$CHECK"
  if [ "$1" != force ] && [ $((_tot / 1024)) -lt "$_min" ]; then
    echo "$_tot|$(date +%s)" > "$HC_DATA/cache_clean.skip"
    rm -f "$_b"; rmdir "$_lk" 2>/dev/null; return 0
  fi
  if [ -n "$_kp" ]; then
    clean_manual $_kp
  else
    pm trim-caches 999999999999999 </dev/null >/dev/null 2>&1
    sleep 2
  fi
  measure > "$_a"
  # cleared = sum of per-app decrease; apps = how many apps got smaller; n = apps scanned
  _res=$(awk 'NR == FNR { b[$1] = $2; n++; next } { a[$1] = $2 }
    END { for (k in b) { d = b[k] - ((k in a) ? a[k] : 0); if (d > 4) { c++; t += d } } print (t + 0) "|" (c + 0) "|" (n + 0) }' "$_b" "$_a")
  echo "${_res%\|*}|$(date +%s)|${_res##*\|}" > "$LAST"
  rm -f "$_b" "$_a" "$HC_DATA/cache_clean.skip"
  rmdir "$_lk" 2>/dev/null
  # daily or manual clean: tell the user (Cache clean notification)
  if [ "$(cfgv x_cache_notify)" != 0 ]; then
    _kb=${_res%%\|*}; _ap=${_res#*\|}; _ap=${_ap%%\|*}
    notify "App cache cleaned: $(awk -v k="${_kb:-0}" 'BEGIN { if (k >= 1024) printf "%.0f MB", k / 1024; else printf "%d KB", k }') from ${_ap:-0} apps"
  fi
}

# x_cache_days: 1-7 days between two cleans (default 1)
days() {
  _dy=$(cfgv x_cache_days)
  case "$_dy" in [1-7]) echo "$_dy" ;; *) echo 1 ;; esac
}

keeper() {
  _old=$(cat "$PIDF" 2>/dev/null)
  case "$_old" in ''|*[!0-9]*) ;; *)
    [ "$_old" != "$$" ] && grep -q cache_clean "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
  esac
  echo $$ > "$PIDF"
  while :; do
    # first check 15 min after start: keeps the heavy boot phase free
    sleep 900
    [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && break
    [ "$(cfgv x_cache_auto)" = 1 ] || break
    _now=$(date +%s)
    _last=$(cat "$CHECK" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    if [ "$_last" = 0 ]; then
      echo "$_now" > "$CHECK"          # first day starts now
    elif [ $((_now - _last)) -ge $((86400 * $(days))) ]; then
      run_clean
    fi
  done
  rm -f "$PIDF"
}

case "$1" in
  run) run_clean "$2"; cat "$LAST" 2>/dev/null ;;
  keeper) keeper ;;
  *) echo "usage: cache_clean.sh run [force] | keeper" ;;
esac
