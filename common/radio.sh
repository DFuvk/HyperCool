#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - screen-off radios (sourced by soff_watch.sh, functions.sh and uninstall.sh)
# radio_off [1]  : switch Location off (and Bluetooth when $1 = 1); what was switched off is written to
#                  $RSAVE, one line per radio (loc|<old location_mode>, bt|). Entries that could not be
#                  restored stay saved and are retried at the next screen-on or boot.
# radio_restore  : switch back only what radio_off switched off, then empty $RSAVE
# data_off M N   : switch mobile data (M = 1) and NFC (N = 1) off; saved to $DSAVE (data|, nfc|).
#                  Returns 2 when mobile data has to stay on for now (call, audio, tethering)
# data_restore   : switch back only what data_off switched off
RSAVE=${RSAVE:-${HC_DATA:-/data/adb/hypercool}/soff_radio.save}
DSAVE=${DSAVE:-${HC_DATA:-/data/adb/hypercool}/soff_data.save}

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
# radio_save <key> <value> : replace entry with same key in $RSAVE (keeps other entries)
radio_save() {
  [ -e "$RSAVE" ] || : > "$RSAVE"
  _tmp="$RSAVE.tmp.$$"
  grep -v "^$1|" "$RSAVE" > "$_tmp" 2>/dev/null || :
  printf '%s\n' "$1|$2" >> "$_tmp"
  mv "$_tmp" "$RSAVE"
}
radio_unsave() { [ -s "$RSAVE" ] && sed -i "/^$1|/d" "$RSAVE" 2>/dev/null; return 0; }

radio_off() {
  [ -e "$RSAVE" ] || : > "$RSAVE"
  _rrc=0
  if [ "$(loc_now)" = on ]; then
    _lm=$(settings get secure location_mode 2>/dev/null)
    # record first: a keeper killed right after the switch can still restore it
    radio_save loc "$_lm"
    cmd location set-location-enabled false </dev/null >/dev/null 2>&1
    sleep 1
    if [ "$(loc_now)" != off ]; then
      settings put secure location_mode 0 </dev/null >/dev/null 2>&1
      sleep 1
      # still on: put the mode back now, and drop the record that was just written
      if [ "$(loc_now)" != off ]; then
        radio_unsave loc
        case "$_lm" in [1-9]) settings put secure location_mode "$_lm" </dev/null >/dev/null 2>&1 ;; esac
        _rrc=2
      fi
    fi
  fi
  if [ "$1" = 1 ] && [ "$(bt_now)" = on ] && ! bt_busy; then
    # record first for the same reason as location; verification below decides whether it stays
    radio_save bt ""
    bt_set disable
    _bi=0
    while [ "$_bi" -lt 3 ]; do
      sleep 1
      [ "$(bt_now)" = off ] && break
      _bi=$((_bi + 1))
    done
    case "$(bt_now)" in
      off) ;;
      # the switch can still be finishing; keep the record so a later off
      # is undone at screen-on. If it is still on then, restore is a no-op.
      *) _rrc=2 ;;
    esac
  fi
  return $_rrc
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
        # How the location was enabled does not matter: put the exact saved mode back too.
        # The old code only wrote it when enabling had failed, then dropped the loc record,
        # leaving e.g. location_mode 0 after a successful enable.
        case "$_rv" in [1-9]) ;; *) _rv=3 ;; esac
        settings put secure location_mode "$_rv" </dev/null >/dev/null 2>&1
        sleep 1
        _lm_now=$(settings get secure location_mode 2>/dev/null)
        if [ "$(loc_now)" != on ] || [ "$_lm_now" != "$_rv" ]; then
          _fail="$_fail$_rk|$_rv
"
          continue
        fi ;;
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

# ---------- mobile data and NFC (soff_data) ----------
# mobile data of the default data SIM: mobile_data<subId>, plain mobile_data on single-SIM ROMs
data_now() {
  _dv=""
  _dsid=$(settings get global multi_sim_data_call 2>/dev/null)
  case "$_dsid" in ''|*[!0-9]*) ;; *) _dv=$(settings get global "mobile_data$_dsid" 2>/dev/null) ;; esac
  case "$_dv" in 0|1) ;; *) _dv=$(settings get global mobile_data 2>/dev/null) ;; esac
  case "$_dv" in 1) echo on ;; 0) echo off ;; *) echo ? ;; esac
}
# data_set enable|disable: svc data, then the telephony shell command when svc did not change it
data_set() {
  _dw=on; [ "$1" = disable ] && _dw=off
  svc data "$1" </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(data_now)" = "$_dw" ] && return 0
  cmd phone data "$1" </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(data_now)" = "$_dw" ]
}
# 0 = mobile data has to stay on now: a phone call, any audio playing (music, video, VoIP calls),
# or hotspot / USB / Bluetooth tethering. A call state that cannot be read counts as busy.
data_busy() {
  # one mCallState line per SIM slot: any slot not idle (or nothing readable) = in a call
  _dcs=$(dumpsys telephony.registry </dev/null 2>/dev/null | grep 'mCallState=')
  [ -n "$_dcs" ] || return 0
  printf '%s\n' "$_dcs" | grep -qvE 'mCallState=0([^0-9]|$)' && return 0
  dumpsys audio </dev/null 2>/dev/null | grep -q 'state:started' && return 0
  # current state lines only ("ap0 - TetheredState - lastError = 0"), not the event log below them
  dumpsys tethering </dev/null 2>/dev/null | grep -qE '^[[:space:]]*[A-Za-z0-9_.-]+ - TetheredState' && return 0
  for _ti in /sys/class/net/ap* /sys/class/net/swlan* /sys/class/net/rndis* /sys/class/net/ncm* /sys/class/net/bt-pan*; do
    [ "$(cat "$_ti/operstate" 2>/dev/null)" = up ] && return 0
  done
  return 1
}
nfc_now() {
  case "$(dumpsys nfc </dev/null 2>/dev/null | grep -m 1 'mState=')" in
    *mState=on*) echo on ;;
    *mState=off*) echo off ;;
    *mState=turning*) echo turning ;;
    *) echo ? ;;
  esac
}
# nfc_set enable|disable: svc nfc, then the NFC shell command of newer Android versions
nfc_set() {
  _nw=on; [ "$1" = disable ] && _nw=off
  svc nfc "$1" </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(nfc_now)" = "$_nw" ] && return 0
  cmd nfc "$1-nfc" </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(nfc_now)" = "$_nw" ]
}
# data_save <key> : add an entry to $DSAVE (keeps other entries)
data_save() {
  [ -e "$DSAVE" ] || : > "$DSAVE"
  grep -q "^$1|" "$DSAVE" 2>/dev/null && return 0
  printf '%s|\n' "$1" >> "$DSAVE"
}
data_unsave() { sed -i "/^$1|/d" "$DSAVE" 2>/dev/null; }

data_off() {
  [ -e "$DSAVE" ] || : > "$DSAVE"
  _drc=0
  # saved before switching: a slow switch-off still gets switched back on. The entry is dropped
  # only when the state is still on afterwards (nothing changed)
  if [ "$2" = 1 ] && [ "$(nfc_now)" = on ]; then
    data_save nfc
    if ! nfc_set disable; then
      sleep 2
      [ "$(nfc_now)" = on ] && data_unsave nfc
    fi
  fi
  # airplane mode: mobile data is already down, nothing to do
  if [ "$1" = 1 ] && [ "$(settings get global airplane_mode_on 2>/dev/null)" != 1 ] && [ "$(data_now)" = on ]; then
    if data_busy; then
      _drc=2
    else
      data_save data
      if ! data_set disable; then
        sleep 2
        [ "$(data_now)" = on ] && data_unsave data
      fi
    fi
  fi
  return $_drc
}
data_restore() {
  [ -s "$DSAVE" ] || return 0
  # only what was really put back is dropped: the rest stays saved for the next screen-on or boot
  _dfail=""
  while IFS='|' read -r _dk _dr; do
    case "$_dk" in
      data)
        _dn=$(data_now)
        [ "$_dn" = on ] && continue
        [ "$_dn" = off ] && data_set enable && continue
        _dfail="${_dfail}data|
" ;;
      nfc)
        _nn=$(nfc_now)
        [ "$_nn" = turning ] && { sleep 2; _nn=$(nfc_now); }
        [ "$_nn" = on ] && continue
        [ "$_nn" = off ] && nfc_set enable && continue
        _dfail="${_dfail}nfc|
" ;;
    esac
  done < "$DSAVE"
  if [ -n "$_dfail" ]; then
    printf '%s' "$_dfail" > "$DSAVE"
  else
    : > "$DSAVE"
  fi
}
