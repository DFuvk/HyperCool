#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - screen-off radios (sourced by soff_watch.sh, functions.sh and uninstall.sh)
# radio_off [1]  : switch Location off (and Bluetooth when $1 = 1); what was switched off is written to
#                  $RSAVE, one line per radio (loc|<old location_mode>, bt|)
# radio_restore  : switch back only what radio_off switched off, then empty $RSAVE
RSAVE=${RSAVE:-${HC_DATA:-/data/adb/hypercool}/soff_radio.save}

loc_now() {
  case "$(cmd location is-location-enabled </dev/null 2>/dev/null | head -n 1)" in
    true*) echo on; return ;;
    false*) echo off; return ;;
  esac
  case "$(settings get secure location_mode 2>/dev/null)" in 0) echo off ;; [1-9]) echo on ;; *) echo ? ;; esac
}
bt_now() {
  case "$(settings get global bluetooth_on 2>/dev/null)" in 1) echo on ;; 0) echo off ;; *) echo ? ;; esac
}
# Android 13+ removed `svc bluetooth` (it moved to BluetoothShellCommand): use `cmd bluetooth_manager`
# there, and keep `svc bluetooth` for older ROMs
bt_set() {
  cmd bluetooth_manager "$1" </dev/null >/dev/null 2>&1 && return 0
  svc bluetooth "$1" </dev/null >/dev/null 2>&1
  return 0
}
# 0 = leave Bluetooth alone: audio is playing, an active audio/headset device is connected, or the
# Bluetooth dump is not in a format we know (unknown = leave alone)
bt_busy() {
  dumpsys audio </dev/null 2>/dev/null | grep -q 'state:started' && return 0
  _bd=$(dumpsys bluetooth_manager </dev/null 2>/dev/null)
  case "$_bd" in *A2dp*|*Headset*) ;; *) return 0 ;; esac
  printf '%s\n' "$_bd" | grep -Eq 'ActiveDevice: *([0-9A-Fa-fXx]{2}:){5}[0-9A-Fa-f]{2}' && return 0
  return 1
}
radio_off() {
  : > "$RSAVE"
  if [ "$(loc_now)" = on ]; then
    _lm=$(settings get secure location_mode 2>/dev/null)
    cmd location set-location-enabled false </dev/null >/dev/null 2>&1
    [ "$(loc_now)" = off ] || settings put secure location_mode 0 </dev/null >/dev/null 2>&1
    [ "$(loc_now)" = off ] && echo "loc|$_lm" >> "$RSAVE"
  fi
  if [ "$1" = 1 ] && [ "$(bt_now)" = on ] && ! bt_busy; then
    bt_set disable
    echo "bt|" >> "$RSAVE"
  fi
}
radio_restore() {
  [ -s "$RSAVE" ] || return 0
  # only what was really put back is dropped: a radio that could not be restored stays in the
  # file and is tried again at the next screen-on or at the next boot
  _fail=""
  while IFS='|' read -r _rk _rv; do
    case "$_rk" in
      loc)
        _ls=$(loc_now)
        [ "$_ls" = on ] && continue
        # state not readable: keep the entry and try again later
        [ "$_ls" = off ] || { _fail="$_fail$_rk|$_rv
"; continue; }
        cmd location set-location-enabled true </dev/null >/dev/null 2>&1
        sleep 1
        if [ "$(loc_now)" != on ]; then
          case "$_rv" in [1-9]) ;; *) _rv=3 ;; esac
          settings put secure location_mode "$_rv" </dev/null >/dev/null 2>&1
          sleep 1
        fi
        [ "$(loc_now)" = on ] || _fail="$_fail$_rk|$_rv
" ;;
      bt)
        # airplane mode: Bluetooth stays as the user wants it, but the entry is kept so that
        # Bluetooth can be put back when the airplane mode is over
        [ "$(settings get global airplane_mode_on 2>/dev/null)" = 1 ] && { _fail="$_fail$_rk|$_rv
"; continue; }
        _bs=$(bt_now)
        [ "$_bs" = on ] && continue
        [ "$_bs" = off ] || { _fail="$_fail$_rk|$_rv
"; continue; }
        bt_set enable
        sleep 1
        [ "$(bt_now)" = off ] && _fail="$_fail$_rk|$_rv
" ;;
    esac
  done < "$RSAVE"
  if [ -n "$_fail" ]; then
    printf '%s' "$_fail" > "$RSAVE"
  else
    : > "$RSAVE"
  fi
}
