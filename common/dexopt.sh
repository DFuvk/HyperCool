#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - optimize all apps (dex2oat). Runs ONLY when started from the WebUI.
#   dexopt.sh run <speed|speed-profile|everything|reset> <1-3> <0|1> [list]
#     list = only the apps named in $HC_DATA/dexopt.list (one package per line)
#   dexopt.sh stop      (finish the apps now compiling, start no new ones)
#   dexopt.sh poll      (progress for the WebUI)
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"

HC_DATA=/data/adb/hypercool
D=$HC_DATA/dexopt
B=/sys/class/power_supply/battery
WL=hypercool_dexopt
# guards: pause at 48.0 C, continue at 47.0 C (tenths of a degree)
T_PAUSE=480
T_RESUME=470
BAT_MIN=15
FREE_MIN_KB=1048576

num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

alive() {
  _p=$(cat "$D/pid" 2>/dev/null)
  num "$_p" && grep -q dexopt "/proc/$_p/cmdline" 2>/dev/null
}

# ----------------------------------------------------------------- stop / poll
case "$1" in
  stop)
    [ -d "$D" ] && alive && {
      [ -e "$D/reason" ] || echo user > "$D/reason"
      : > "$D/stop"
    }
    exit 0 ;;
  poll)
    if [ ! -f "$D/state" ]; then echo "phase=none"; exit 0; fi
    cat "$D/state"
    _ok=$(grep -c '^ok|' "$D/done.log" 2>/dev/null); _fl=$(grep -c '^fail|' "$D/done.log" 2>/dev/null)
    echo "ok=${_ok:-0}"
    echo "fail=${_fl:-0}"
    for _f in "$D"/cur.*; do [ -f "$_f" ] && echo "cur=$(cat "$_f" 2>/dev/null)"; done
    for _f in "$D"/note.*; do [ -f "$_f" ] && echo "note=$(cat "$_f" 2>/dev/null)"; done
    if alive; then echo "alive=1"; [ -e "$D/stop" ] && echo "stopreq=1"; else echo "alive=0"; fi
    echo "now=$(date +%s)"
    exit 0 ;;
  run) ;;
  *) echo "usage: dexopt.sh run <mode> <jobs> <force> | stop | poll"; exit 2 ;;
esac

MODE=$2; JOBS=$3; FORCE=$4; SCOPE=all
[ "$5" = list ] && SCOPE=list
LIST=$HC_DATA/dexopt.list
case "$MODE" in speed|speed-profile|everything|reset) ;; *) exit 2 ;; esac
case "$JOBS" in 1|2|3) ;; *) JOBS=1 ;; esac
[ "$FORCE" = 1 ] || FORCE=0
[ "$MODE" = reset ] && FORCE=0
# started by the screen-off keeper (common/dxauto.sh): wake lock expires by itself, stops when the battery is warm
AUTO=0; [ "$HC_DXAUTO" = 1 ] && AUTO=1
T_AUTO=450

mkdir -p "$HC_DATA"
alive && exit 0
rm -rf "$D"
mkdir -p "$D/claim" || exit 1
echo $$ > "$D/pid"

START=$(date +%s)
TOTAL=0
PHASE=running
WP=""

wstate() {
  {
    echo "phase=$PHASE"
    echo "mode=$MODE"
    echo "jobs=$JOBS"
    echo "force=$FORCE"
    echo "scope=$SCOPE"
    echo "total=$TOTAL"
    echo "start=$START"
    echo "end=$1"
    echo "reason=$2"
  } > "$D/state.tmp" && mv -f "$D/state.tmp" "$D/state"
}

notify() {
  # automatic run: config x_dexopt_notify=0 = no notification (read live)
  [ "$AUTO" = 1 ] && [ "$(sed -n 's/^x_dexopt_notify=//p' "$HC_DATA/config.conf" 2>/dev/null | tail -n 1 | tr -d '\r')" = 0 ] && return 0
  su -lp 2000 -c "cmd notification post -S bigtext -t 'HyperCool' hc_dex '$1'" </dev/null >/dev/null 2>&1 ||
    cmd notification post -S bigtext -t HyperCool hc_dex "$1" </dev/null >/dev/null 2>&1
}

lock() {
  [ -w /sys/power/wake_lock ] || return 0
  if [ "$AUTO" = 1 ]; then echo "$WL 10800000000000" > /sys/power/wake_lock 2>/dev/null; else echo "$WL" > /sys/power/wake_lock 2>/dev/null; fi
}
unlock() { [ -w /sys/power/wake_unlock ] && echo "$WL" > /sys/power/wake_unlock 2>/dev/null; }

# shellcheck disable=SC2329
cleanup() {
  for _w in $WP; do kill "$_w" 2>/dev/null; done
  unlock
  if [ "$PHASE" = running ]; then PHASE=stopped; wstate "$(date +%s)" killed; fi
  rm -f "$D/pid" "$D"/cur.* "$D"/note.*
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# queue: every enabled app, system apps included
cmd package list packages -e 2>/dev/null | sed 's/^package://' > "$D/queue.raw"
[ -s "$D/queue.raw" ] || cmd package list packages 2>/dev/null | sed 's/^package://' > "$D/queue.raw"
tr -d '\r' < "$D/queue.raw" | grep -E '^[A-Za-z0-9._]+$' | sort -u > "$D/queue"
rm -f "$D/queue.raw"
if [ "$SCOPE" = list ]; then
  # only the chosen apps that are installed and enabled
  : > "$D/want"
  [ -r "$LIST" ] && tr -d '\r' < "$LIST" | grep -E '^[A-Za-z0-9._]+$' | sort -u > "$D/want"
  : > "$D/queue.sel"
  [ -s "$D/want" ] && grep -Fxf "$D/want" "$D/queue" > "$D/queue.sel" 2>/dev/null
  mv -f "$D/queue.sel" "$D/queue"
fi
TOTAL=$(wc -l < "$D/queue" 2>/dev/null)
num "$TOTAL" || TOTAL=0
TOTAL=$((TOTAL + 0))
if [ "$TOTAL" -eq 0 ]; then
  PHASE=stopped; wstate "$(date +%s)" noapps
  exit 0
fi

wstate "" ""
lock

# 0 = go on, 1 = stop (a reason is written and the stop flag is set)
guard() {
  [ -e "$D/stop" ] && return 1
  # a value that cannot be read is not "safe": stop instead of guessing (battery, space, heat)
  _c=$(cat $B/capacity 2>/dev/null); _s=$(cat $B/status 2>/dev/null)
  if ! num "$_c"; then
    [ -e "$D/reason" ] || echo battery > "$D/reason"
    : > "$D/stop"; return 1
  fi
  if [ "$_c" -le "$BAT_MIN" ]; then
    case "$_s" in Charging|Full) ;; *)
      [ -e "$D/reason" ] || echo battery > "$D/reason"
      : > "$D/stop"; return 1 ;;
    esac
  fi
  _a=$(df -k /data 2>/dev/null | tail -n 1 | awk '{print $(NF-2)}')
  if ! num "$_a"; then
    [ -e "$D/reason" ] || echo storage > "$D/reason"
    : > "$D/stop"; return 1
  fi
  if [ "$_a" -lt "$FREE_MIN_KB" ]; then
    [ -e "$D/reason" ] || echo storage > "$D/reason"
    : > "$D/stop"; return 1
  fi
  _t=$(cat $B/temp 2>/dev/null)
  if ! num "$_t"; then
    # battery temperature not readable: do not keep compiling
    [ -e "$D/reason" ] || echo hot > "$D/reason"
    : > "$D/stop"; return 1
  fi
  if [ "$AUTO" = 1 ] && [ "$_t" -ge "$T_AUTO" ]; then
    [ -e "$D/reason" ] || echo hot > "$D/reason"
    : > "$D/stop"; return 1
  fi
  if [ "$_t" -ge "$T_PAUSE" ]; then
    rm -f "$D/cur.$K"
    while :; do
      echo "Paused, battery $((_t / 10)).$((_t % 10))°C. Continues at $((T_RESUME / 10))°C." > "$D/note.$K"
      sleep 10
      if [ -e "$D/stop" ]; then rm -f "$D/note.$K"; return 1; fi
      _t=$(cat $B/temp 2>/dev/null)
      if ! num "$_t"; then
        rm -f "$D/note.$K"
        [ -e "$D/reason" ] || echo hot > "$D/reason"
        : > "$D/stop"; return 1
      fi
      [ "$_t" -le "$T_RESUME" ] && break
    done
    rm -f "$D/note.$K"
  fi
  return 0
}

TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 1200"

compile() {
  if [ "$MODE" = reset ]; then
    $TMO cmd package compile --reset "$1" 2>&1
  elif [ "$FORCE" = 1 ]; then
    $TMO cmd package compile -m "$MODE" -f "$1" 2>&1
  else
    $TMO cmd package compile -m "$MODE" "$1" 2>&1
  fi
}

# each worker walks the queue and claims an index with mkdir (atomic)
worker() {
  K=$1
  trap - EXIT
  trap 'exit 1' INT TERM
  _i=1
  while [ "$_i" -le "$TOTAL" ]; do
    guard || break
    if ! mkdir "$D/claim/$_i" 2>/dev/null; then _i=$((_i + 1)); continue; fi
    _pkg=$(sed -n "${_i}p" "$D/queue")
    _i=$((_i + 1))
    [ -n "$_pkg" ] || continue
    echo "$_pkg" > "$D/cur.$K"
    _out=$(compile "$_pkg")
    case "$_out" in
      *Success*) echo "ok|$_pkg" >> "$D/done.log" ;;
      *) echo "fail|$_pkg" >> "$D/done.log"
         echo "$_pkg: $(echo "$_out" | head -n 1 | cut -c1-160)" >> "$D/fail.log" ;;
    esac
    rm -f "$D/cur.$K"
  done
  rm -f "$D/cur.$K" "$D/note.$K"
}

_k=1
while [ "$_k" -le "$JOBS" ]; do
  worker "$_k" &
  WP="$WP $!"
  _k=$((_k + 1))
done
wait

END=$(date +%s)
_ok=$(grep -c '^ok|' "$D/done.log" 2>/dev/null); _ok=${_ok:-0}
_fl=$(grep -c '^fail|' "$D/done.log" 2>/dev/null); _fl=${_fl:-0}
_dn=$((_ok + _fl))
_why=$(cat "$D/reason" 2>/dev/null)
_min=$(( (END - START + 30) / 60 ))
if [ "$_dn" -ge "$TOTAL" ]; then
  PHASE=done; wstate "$END" ""
  if [ "$MODE" = reset ]; then _msg="Reset $_ok apps to default."; else _msg="Optimized $_ok apps."; fi
  [ "$_fl" -gt 0 ] && _msg="$_msg $_fl failed."
  _msg="$_msg ${_min} min."
else
  PHASE=stopped; wstate "$END" "${_why:-stopped}"
  case "$_why" in
    battery) _msg="Stopped: battery low or not readable. $_dn of $TOTAL apps done." ;;
    storage) _msg="Stopped: storage almost full or not readable. $_dn of $TOTAL apps done." ;;
    hot) _msg="Stopped: battery too warm or the temperature is not readable. $_dn of $TOTAL apps done." ;;
    screen) _msg="Stopped: screen turned on. $_dn of $TOTAL apps done." ;;
    *) _msg="Stopped. $_dn of $TOTAL apps done." ;;
  esac
fi
[ "$AUTO" = 1 ] && _msg="Auto optimize: $_msg"
notify "$_msg"
exit 0
