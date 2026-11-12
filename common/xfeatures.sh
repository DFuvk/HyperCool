#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - "More" features (safe ones default ON)

HC_XLISTS=${MODDIR:-/data/adb/modules/hypercool}/common

# apply_list <file> : write every "path|value" line, counted by wn()
apply_list() {
  [ -f "$1" ] || return 1
  while IFS= read -r _ln; do
    case "$_ln" in ''|'#'*) continue ;; esac
    _p=${_ln%%\|*}
    _v=${_ln#*\|}
    [ -n "$_p" ] && [ "$_p" != "$_v" ] || continue
    # vendor-specific nodes only on their own SoC family
    case "$_p" in *qcom*|*msm_*) on_qcom_ok || continue ;; *mtk*|*mediatek*) on_mtk_ok || continue ;; esac
    wn "$_p" "$_v"
  done < "$1"
}

# apply_props_file <file> [persist-only] : like hc_props but reads prop=value lines
apply_props_file() {
  [ -f "$1" ] || { echo 0; return; }
  _pc=0
  while IFS= read -r _ln; do
    case "$_ln" in ''|'#'*) continue ;; esac
    case "$_ln" in *=*) ;; *) continue ;; esac
    if [ "$2" = persist ]; then case "$_ln" in persist.*) ;; *) continue ;; esac; fi
    resetprop -n "${_ln%%=*}" "${_ln#*=}" 2>/dev/null && _pc=$((_pc + 1))
  done < "$1"
  echo "$_pc"
}

# ================================================================ MORE: kernel

# x_sched - scheduler, governor and schedtune tuning
f_x_sched() {
  on x_sched || { st x_sched off; return; }
  cnt_reset
  apply_list "$HC_XLISTS/x_kernel_list.txt"
  # governor rate limits (one 5 ms scheduling period)
  for _g in /sys/devices/system/cpu/cpufreq/policy*/schedutil \
            /sys/devices/system/cpu/cpu*/cpufreq/schedutil \
            /sys/devices/system/cpu/cpufreq/policy*/sugov_ext; do
    [ -d "$_g" ] || continue
    case "$_g" in */sugov_ext) on_mtk_ok || continue ;; esac
    # slower ramp-up only
    [ -f "$_g/up_rate_limit_us" ] && ! on walt_tune && wn "$_g/up_rate_limit_us" 5000
    # walt_tune also owns hispeed_load on schedutil/sugov_ext; do not overwrite its value.
    [ -f "$_g/hispeed_load" ] && ! on walt_tune && wn "$_g/hispeed_load" 99
  done
  for _g in /sys/devices/system/cpu/cpufreq/policy*/interactive \
            /sys/devices/system/cpu/cpu*/cpufreq/interactive; do
    [ -d "$_g" ] || continue
    [ -f "$_g/go_hispeed_load" ] && wn "$_g/go_hispeed_load" 99
  done
  # schedtune: no foreground boost, no idle preference on top-app
  if [ -d /dev/stune/top-app ]; then
    wn /dev/stune/top-app/schedtune.prefer_idle 0
    wn /dev/stune/top-app/schedtune.boost 0
  fi
  fin x_sched "scheduler, governor and schedtune tuned" "no CFS/schedutil/schedtune tunables (WALT kernel: use Calmer CPU governor)"
}

# x_kquiet - leftover kernel logging/dumps
f_x_kquiet() {
  on x_kquiet || { st x_kquiet off; return; }
  cnt_reset
  apply_list "$HC_XLISTS/x_quiet_list.txt"
  for _p in /sys/devices/platform/*/snapshot_crashdumper; do
    [ -e "$_p" ] && wn "$_p" 0
  done
  for _p in /sys/module/*/parameters/qdf_log_dump_at_kernel_enable; do
    [ -e "$_p" ] && wn "$_p" N
  done
  for _p in /sys/fs/f2fs/*/iostat_enable; do
    [ -e "$_p" ] && wn "$_p" 0
  done
  fin x_kquiet "EDAC/BPF/ramdump/crash dumper output off"
}

# x_net - network stack tuning
f_x_net() {
  on x_net || { st x_net off; return; }
  cnt_reset
  apply_list "$HC_XLISTS/x_net_list.txt"
  fin x_net "TCP slow-start/metrics/FastOpen and inotify limits tuned"
}

# x_io - extra block queue tuning
f_x_io() {
  on x_io || { st x_io off; return; }
  cnt_reset
  for _b in /sys/block/*; do
    [ -d "$_b/queue" ] || continue
    case "${_b##*/}" in
      sd*|mmcblk*|nvme*)
        wn "$_b/queue/nomerges" 0
        wn "$_b/queue/rq_affinity" 1 ;;
    esac
  done
  fin x_io "nomerges/rq_affinity tuned"
}

# x_xiaomi_fw - Xiaomi MiGT/Metis boost frameworks off
f_x_xiaomi_fw() {
  on x_xiaomi_fw || { st x_xiaomi_fw off; return; }
  cnt_reset
  if [ -d /sys/module/migt ]; then
    wn /proc/sys/migt/enable_pkg_monitor 0
    wn /sys/module/migt/parameters/enable_pkg_monitor 0
    wn /sys/module/migt/parameters/glk_freq_limit_walt 0
    wn /sys/module/migt/parameters/boost_policy 0
    wn /sys/module/migt/parameters/glk_disable 1
    wn /sys/module/migt/parameters/force_stask_to_big 0
  fi
  if [ -d /sys/module/metis ]; then
    wn /sys/module/metis/parameters/suspend_vip_enable 0
    wn /sys/module/metis/parameters/mi_link_enable 0
    wn /sys/module/metis/parameters/mi_switch_enable 0
  fi
  fin x_xiaomi_fw "MiGT/Metis boost frameworks off" "MiGT/Metis not present on this device"
}

# ================================================================ MORE: RAM

# ro.lmk.* props: resetprop without -p is runtime only, the ROM values return on reboot.
# The value that was there before is written to $HC_DATA/persist_props, so it can be put back
# when the feature is switched off or the module is removed.
x_set_prop_persist() {
  _xp=$1; _xv=$2
  _xo=$(getprop "$_xp" 2>/dev/null)
  if [ -n "$_xo" ] && [ "$_xo" != "$_xv" ]; then
    grep -q "^$_xp=" "$HC_DATA/persist_props" 2>/dev/null || echo "$_xp=$_xo" >> "$HC_DATA/persist_props"
  fi
  resetprop -n "$_xp" "$_xv" 2>/dev/null
}
# put the saved props back and forget them
x_restore_props() {
  [ -s "$HC_DATA/persist_props" ] || { rm -f "$HC_DATA/persist_props"; return 0; }
  while IFS='=' read -r _p _v; do
    [ -n "$_p" ] || continue
    resetprop -n "$_p" "$_v" 2>/dev/null
  done < "$HC_DATA/persist_props"
  rm -f "$HC_DATA/persist_props"
}

# x_ram_opt - RAM optimizer: VM list, LMK/minfree, lmkd, reclaim
f_x_ram_opt() {
  if ! on x_ram_opt; then
    restore_feature x_ram_opt
    x_restore_props
    st x_ram_opt off
    return
  fi
  cnt_reset
  _lvl=$(cfg x_ram_level 1)
  if [ "$_lvl" = 2 ]; then _lvlname=maximum; else _lvl=1; _lvlname=moderate; fi

  apply_list "$HC_XLISTS/x_ram_vm.txt"

  _tk=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
  _tk=${_tk:-0}

  # memory management flags (recorded, restored when the switch goes off)
  _sdk=$(getprop ro.build.version.sdk)
  if [ "${_sdk:-0}" -ge 30 ]; then
    set_d x_ram_opt runtime_native usap_pool_enabled false
  fi
  set_d x_ram_opt activity_manager use_compaction true

  # classic LMK minfree, scaled to RAM size and level
  if [ -f /sys/module/lowmemorykiller/parameters/minfree ]; then
    _p=$(( _tk / 4 ))
    if [ "$_lvl" = 2 ]; then
      _f1=$(( _p * 25 / 1000 )); _f2=$(( _p * 3 / 100 )); _f3=$(( _p * 4 / 100 ))
      _f4=$(( _p * 5 / 100 ));  _f5=$(( _p * 6 / 100 )); _f6=$(( _p * 8 / 100 ))
    else
      _f1=$(( _p * 15 / 1000 )); _f2=$(( _p / 50 ));       _f3=$(( _p * 25 / 1000 ))
      _f4=$(( _p * 3 / 100 ));   _f5=$(( _p * 35 / 1000 )); _f6=$(( _p / 20 ))
    fi
    wn /sys/module/lowmemorykiller/parameters/minfree \
      "$((_f1/4)),$((_f2/4)),$((_f3/4)),$((_f4/4)),$((_f5/4)),$((_f6/4))"
  fi

  # lmkd props (persistent -> tracked in $HC_DATA/persist_props, deleted on off/uninstall)
  if [ ! -f /sys/module/lowmemorykiller/parameters/minfree ]; then
    if [ "$_lvl" = 2 ]; then
      x_set_prop_persist ro.lmk.low 900
      x_set_prop_persist ro.lmk.medium 600
    else
      x_set_prop_persist ro.lmk.low 1001
      x_set_prop_persist ro.lmk.medium 900
    fi
    x_set_prop_persist ro.lmk.critical 0
    if [ -f /proc/pressure/memory ]; then
      x_set_prop_persist ro.lmk.use_psi true
      if [ "$_lvl" = 2 ]; then
        x_set_prop_persist ro.lmk.psi_partial_stall_ms 70
        x_set_prop_persist ro.lmk.psi_complete_stall_ms 500
        x_set_prop_persist ro.lmk.thrashing_limit 60
        x_set_prop_persist ro.lmk.swap_util_max 80
        x_set_prop_persist ro.lmk.kill_heaviest_task true
      else
        x_set_prop_persist ro.lmk.psi_partial_stall_ms 200
        x_set_prop_persist ro.lmk.psi_complete_stall_ms 800
        x_set_prop_persist ro.lmk.thrashing_limit 100
        x_set_prop_persist ro.lmk.swap_util_max 100
        x_set_prop_persist ro.lmk.kill_heaviest_task false
      fi
    else
      x_set_prop_persist ro.lmk.use_psi false
    fi
    # lmkd reloads its props on reinit (Android 11+); SIGHUP would just kill it
    setprop lmkd.reinit 1 2>/dev/null
  fi

  # vendor memory-reclaim frameworks off
  for _n in /sys/module/process_reclaim/parameters/enable_process_reclaim \
            /sys/kernel/mi_reclaim/enable \
            /sys/kernel/mi_reclaim/greclaim_enable \
            /sys/kernel/low_free/low_free_enable \
            /sys/module/memplus_core/parameters/memory_plus_enabled \
            /proc/sys/vm/memory_plus \
            /sys/module/opchain/parameters/opchain_enable; do
    [ -e "$_n" ] && wn "$_n" 0
  done

  fin x_ram_opt "VM/LMK tuned for $_lvlname ($((_tk / 1024)) MB RAM)"
}

# x_multitask - cached-process limits profile
f_x_multitask() {
  _mt=$(cfg x_multitask 0)
  if [ "$_mt" = 0 ]; then
    if grep -q '^x_multitask|' "$HC_ROMBAK" 2>/dev/null; then
      restore_feature x_multitask
      cmd activity memory-factor reset </dev/null >/dev/null 2>&1
    fi
    rm -f "$HC_DATA/x_multitask.base"
    st x_multitask off
    return
  fi
  case "$_mt" in
    1) _mult=100; _mname=balanced ;;
    2) _mult=125; _mname=performance ;;
    3) _mult=75;  _mname=low-ram ;;
    *) st x_multitask skipped "unknown level $_mt"; return ;;
  esac
  cnt_reset
  # max_cached_processes from dumpsys activity settings
  _cur=$(dumpsys activity settings </dev/null 2>/dev/null | sed -n 's/^ *max_cached_processes=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  # stock value saved on the first run, so levels never compound across boots
  _base=$(cat "$HC_DATA/x_multitask.base" 2>/dev/null)
  case "$_base" in ''|*[!0-9]*) _base=$_cur; [ -n "$_base" ] && echo "$_base" > "$HC_DATA/x_multitask.base" ;; esac
  if [ -n "$_base" ]; then
    _nv=$(( _base * _mult / 100 )); [ "$_nv" -lt 8 ] && _nv=8
    if [ "$_mult" = 100 ]; then
      # Balanced = stock: give back any earlier value instead of pinning the stock one
      restore_feature x_multitask; cnt_ok
    else
      set_d x_multitask activity_manager max_cached_processes "$_nv"
    fi
  fi
  cmd activity memory-factor reset </dev/null >/dev/null 2>&1
  fin x_multitask "max_cached_processes ${_base:-?} -> ${_nv:-?} ($_mname)" "max_cached_processes not reported by this ROM"
}

# ================================================================ MORE: Google

# x_gms_freeze - disable the safe ads/tracking/analytics GMS components
f_x_gms_freeze() {
  if ! on x_gms_freeze; then
    restore_feature x_gms_freeze
    st x_gms_freeze off
    return
  fi
  cnt_reset
  # components dropped from the list (or from an older list) are enabled again
  prune_pkgs x_gms_freeze "$(grep -v '^#' "$HC_XLISTS/x_gms_safe.txt" | tr '\n' ',')"
  _dis=0; _alr=0; _miss=0
  # components already disabled (by you or another module) are left alone and not recorded
  _dcf=$HC_DATA/.gms_disabled
  dumpsys package com.google.android.gms </dev/null 2>/dev/null | \
    sed -n '/disabledComponents:/,/enabledComponents:/p' > "$_dcf"
  while IFS= read -r _c; do
    case "$_c" in ''|'#'*) continue ;; esac
    _pk=${_c%%/*}
    if ! pkg_installed "$_pk"; then _miss=$((_miss + 1)); continue; fi
    if pkg_disabled "$_pk"; then _alr=$((_alr + 1)); continue; fi
    if has_rec x_gms_freeze pkg - "$_c"; then
      if pm disable --user 0 "$_c" </dev/null >/dev/null 2>&1; then _alr=$((_alr + 1)); cnt_ok; else _miss=$((_miss + 1)); fi
      continue
    fi
    if grep -qx " *${_c#*/}" "$_dcf" 2>/dev/null; then _alr=$((_alr + 1)); cnt_ok; continue; fi
    if pm disable --user 0 "$_c" </dev/null >/dev/null 2>&1; then
      rec x_gms_freeze pkg - "$_c"
      _dis=$((_dis + 1)); cnt_ok
    else
      # class not present in this GMS version
      _miss=$((_miss + 1))
    fi
  done < "$HC_XLISTS/x_gms_safe.txt"
  rm -f "$_dcf"
  _d="$_dis newly disabled, $_alr already off, $_miss not in this GMS version"
  fin x_gms_freeze "$_d" "$_d"
}

# x_track - extended telemetry switches (keys HyperCool's tracking_off already sets are not repeated)
f_x_track() {
  if ! on x_track; then
    restore_feature x_track
    st x_track off
    return
  fi
  cnt_reset
  for _k in play_store_panel_logging_enabled clearcut_events clearcut_gcm \
            bugreport_in_power_menu; do
    set_s x_track global "$_k" 0
  done
  set_s x_track global gms_checkin_timeout_min 120
  fin x_track "extended GMS/usage telemetry off"
}

# ================================================================ MORE: logging

# x_log_nuke - deep log cleanup at boot
f_x_log_nuke() {
  if ! on x_log_nuke; then
    restore_feature x_log_nuke
    st x_log_nuke off
    return
  fi
  cnt_reset
  _k=0
  _okc=0
  # init services: "stop" (kill -9 only makes init restart them); leftover logcat dumpers are killed
  _svc="logcatd tcpdump traced_perf idd-logreader idd-logreadermain aplogd vendor.tcpdump vendor_tcpdump"
  on_qcom_ok && _svc="$_svc cnss_diag vendor.cnss_diag"
  on_mtk_ok && _svc="$_svc mobile_log_d emdlogger1 emdlogger2 emdlogger3 emdlogger5 mdlogger connsyslogger"
  for _s in $_svc; do
    case "$(getprop "init.svc.$_s")" in running|restarting) setprop ctl.stop "$_s" 2>/dev/null && { _k=$((_k + 1)); _okc=1; } ;; esac
  done
  for _p in $(pidof logcat 2>/dev/null); do kill "$_p" 2>/dev/null && { _k=$((_k + 1)); _okc=1; }; done
  [ "$_k" -gt 0 ] && log "x_log_nuke: stopped $_k log service(s)/process(es)"
  logcat -c </dev/null >/dev/null 2>&1 && _okc=1
  dmesg -c </dev/null >/dev/null 2>&1 && _okc=1
  logcat -G 64k </dev/null >/dev/null 2>&1 && _okc=1
  cmd activity logging disable-text </dev/null >/dev/null 2>&1 && _okc=1
  cmd autofill set log_level off </dev/null >/dev/null 2>&1 && _okc=1
  cmd display ab-logging-disable </dev/null >/dev/null 2>&1 && _okc=1
  cmd display dmd-logging-disable </dev/null >/dev/null 2>&1 && _okc=1
  cmd display dwb-logging-disable </dev/null >/dev/null 2>&1 && _okc=1
  cmd input_method tracing stop </dev/null >/dev/null 2>&1 && _okc=1
  cmd statusbar tracing stop </dev/null >/dev/null 2>&1 && _okc=1
  for _wl in $(dumpsys window </dev/null 2>/dev/null | grep -E "^  (Proto|Logcat):" | sed 's/^  .*://'); do
    cmd window logging disable "$_wl" </dev/null >/dev/null 2>&1
    cmd window logging disable-text "$_wl" </dev/null >/dev/null 2>&1
  done
  cmd window logging disable </dev/null >/dev/null 2>&1
  cmd window logging disable-text </dev/null >/dev/null 2>&1
  cmd window tracing size 0 </dev/null >/dev/null 2>&1 && _okc=1
  cmd voiceinteraction set-debug-hotword-logging false </dev/null >/dev/null 2>&1 && _okc=1
  cmd wifi set-verbose-logging disabled -l 0 </dev/null >/dev/null 2>&1 && _okc=1
  # nothing worked? then the feature did not do anything and must not be reported as applied
  [ "$_okc" -gt 0 ] && cnt_ok
  # earlier builds set netstats_poll_interval=60000 (default 30 min: 30x more polling)
  restore_feature x_log_nuke netstats_enabled
  restore_feature x_log_nuke netstats_poll_interval
  restore_feature x_log_nuke netstats_persist_threshold
  restore_feature x_log_nuke netstats_global_alert_bytes
  # tags no longer in the list (older builds also disabled crash/ANR/tombstone) get their value back
  _tl=",$(grep -v '^#' "$HC_XLISTS/x_dropbox_tags.txt" 2>/dev/null | tr '\n' ','),"
  _dks=$(grep "^x_log_nuke|settings|global|dropbox:" "$HC_ROMBAK" 2>/dev/null | cut -d'|' -f4)
  for _dk in $_dks; do
    case "$_tl" in *",${_dk#dropbox:},"*) ;; *) restore_feature x_log_nuke "$_dk" ;; esac
  done
  # shellcheck disable=SC2013 # one tag per line
  for _t in $(grep -v '^#' "$HC_XLISTS/x_dropbox_tags.txt" 2>/dev/null); do
    case "$_t" in ''|'#'*) continue ;; esac
    set_s x_log_nuke global "dropbox:$_t" disabled
  done
  fin x_log_nuke "log daemons stopped, buffers shrunk, dropbox reports off" "nothing could be turned off on this ROM"
}

# x_diag - vendor diagnostics off
f_x_diag() {
  if ! on x_diag; then
    restore_feature x_diag
    st x_diag off
    return
  fi
  cnt_reset
  for _s in charge_logger misight vendor.mi_misight; do
    case "$(getprop "init.svc.$_s")" in
      running|restarting) setprop ctl.stop "$_s" 2>/dev/null && cnt_ok ;;
    esac
  done
  setprop debug.sys.looper_stats_enabled false 2>/dev/null
  if cmd looper_stats disable </dev/null >/dev/null 2>&1; then cnt_ok; fi
  set_s x_diag system anr_debugging_mechanism 0
  set_s x_diag system send_security_reports 0
  # props only where the ROM already exposes them
  for _pv in persist.sys.stability.nativehangII.enable=false \
             persist.sys.turbosched.local.enable=false \
             persist.vendor.wifisalog.enable=false \
             persist.sys.offlinelog.bootlog=false \
             persist.vendor.camera.mawlog.aiasd=0; do
    [ -n "$(getprop "${_pv%%=*}")" ] && { resetprop -n "${_pv%%=*}" "${_pv#*=}" 2>/dev/null && cnt_ok; }
  done
  on_qcom_ok && wn /sys/module/msm_video/parameters/msm_vidc_debug 0
  on_qcom_ok && for _p in /sys/devices/platform/qcom,mmrm*/debug /sys/devices/platform/*/qcom,mmrm/debug; do
    [ -e "$_p" ] && wn "$_p" 0
  done
  fin x_diag "vendor log services and diagnostics off"
}

# ================================================================ MORE: storage

# x_cache_auto - app-cache clean every 1-7 days (keeper: common/cache_clean.sh)
hc_cache_pid() {
  _cp=$(cat "$HC_DATA/cache_keeper.pid" 2>/dev/null)
  case "$_cp" in ''|*[!0-9]*) return 1 ;; esac
  grep -q cache_clean "/proc/$_cp/cmdline" 2>/dev/null && echo "$_cp"
}
f_x_cache_auto() {
  if _cp=$(hc_cache_pid); then
    kill "$_cp" 2>/dev/null
    _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_cp" ]; do sleep 1; _i=$((_i + 1)); done
  fi
  rm -f "$HC_DATA/cache_keeper.pid"
  on x_cache_auto || { st x_cache_auto off; return; }
  _mn=$(num x_cache_min 0)
  if command -v nice >/dev/null 2>&1; then
    nohup nice -n 19 sh "$MODDIR/common/cache_clean.sh" keeper >/dev/null 2>&1 &
  else
    nohup sh "$MODDIR/common/cache_clean.sh" keeper >/dev/null 2>&1 &
  fi
  _i=0
  while [ "$_i" -lt 5 ] && ! hc_cache_pid >/dev/null; do sleep 1; _i=$((_i + 1)); done
  if _cp=$(hc_cache_pid); then
    if [ "$_mn" -gt 0 ]; then _md="when app cache >= $_mn MB"; else _md="always"; fi
    _dy=$(num x_cache_days 1); case "$_dy" in [1-7]) ;; *) _dy=1 ;; esac
    if [ "$_dy" = 1 ]; then _dn="daily"; else _dn="every $_dy days"; fi
    st x_cache_auto applied "clean $_dn, $_md (keeper pid $_cp, checks every 15 min while awake)"
  else
    st x_cache_auto failed "cache keeper did not start"
  fi
}

# ---------------------------------------------------------------- extra power saving

# x_kpower - kernel power-saving switches: power-efficient workqueues (unbound work runs on
f_x_kpower() {
  on x_kpower || { st x_kpower off; return; }
  cnt_reset
  _d=""; _pw=""
  _wq=/sys/module/workqueue/parameters/power_efficient
  if [ -e "$_wq" ]; then
    # stock kernels expose it read-only (boot parameter); then only report its state
    wtry "$_wq" Y
    case $? in
      0) cnt_ok; _d="power-efficient workqueues on" ;;
      *) case "$(cat "$_wq" 2>/dev/null)" in
           Y|1) _pw="power-efficient workqueues already on (kernel)" ;;
           *) _pw="power-efficient workqueues: read-only in this kernel" ;;
         esac ;;
    esac
  fi
  _bs=/sys/module/battery_saver/parameters/enabled
  if [ -e "$_bs" ]; then
    if grep -q '[0-9]' "$_bs" 2>/dev/null; then _v=1; else _v=Y; fi
    wn "$_bs" "$_v" && _d="${_d:+$_d, }kernel battery_saver module on"
  fi
  fin x_kpower "${_d}${_pw:+; $_pw}" "no writable power_efficient / battery_saver node${_pw:+; $_pw}"
}

# x_vm_lite - less background memory work: no swap/zram read-ahead (page-cluster 0)
f_x_vm_lite() {
  on x_vm_lite || { st x_vm_lite off; return; }
  cnt_reset
  _d=""
  [ -e /proc/sys/vm/page-cluster ] && wn /proc/sys/vm/page-cluster 0 && _d="swap read-ahead off"
  [ -e /proc/sys/vm/compaction_proactiveness ] && wn /proc/sys/vm/compaction_proactiveness 0 && \
    _d="${_d:+$_d, }proactive compaction off"
  fin x_vm_lite "$_d"
}

# x_zram - zram size, compression algorithm and swap order (kernel default priority)
hc_zram_back() { # put a zram setup back: <alg> <bytes> <backing_dev>
  { echo 1 > /sys/block/zram0/reset; } 2>/dev/null
  [ -n "$3" ] && [ "$3" != none ] && { echo "$3" > /sys/block/zram0/backing_dev; } 2>/dev/null
  [ -n "$1" ] && { echo "$1" > /sys/block/zram0/comp_algorithm; } 2>/dev/null
  { echo "$2" > /sys/block/zram0/disksize; } 2>/dev/null && mkswap /dev/block/zram0 >/dev/null 2>&1 && swapon /dev/block/zram0 2>/dev/null
}
f_x_zram() {
  on x_zram || { st x_zram off; return; }
  cnt_reset
  _z=/sys/block/zram0; _zd=/dev/block/zram0
  { [ -f "$_z/disksize" ] && [ -b "$_zd" ]; } || { st x_zram skipped "no zram0 on this kernel/ROM"; return; }
  _gb=$(rng x_zram_size 4 2 8)
  [ "$_gb" = 0 ] && _gb=$(rng x_zram_custom 4 1 12)   # 0 = custom size, never above 12 GB
  [ "$_gb" = 0 ] && _gb=4
  # sizes above 2 GB overflow 32-bit shell math (mksh): bytes via awk, kernel takes "<n>G"
  _want=$(awk -v g="$_gb" 'BEGIN { printf "%.0f", g * 1073741824 }')
  _algs=" $(tr -d '[]' < "$_z/comp_algorithm" 2>/dev/null) "
  _calg=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$_z/comp_algorithm" 2>/dev/null)
  _alg=$(cfg x_zram_alg lz4)
  case "$_algs" in *" $_alg "*) ;; *) _alg=$_calg ;; esac
  _csz=$(rd "$_z/disksize")
  _cpr=$(awk '$1 ~ /\/zram0$/ {print $5}' /proc/swaps 2>/dev/null)
  _was="was $(awk -v b="${_csz:-0}" 'BEGIN { m = b / 1048576; if (m >= 1024) printf "%.1f GB", m / 1024; else printf "%d MB", m }' | sed 's/\.0 GB/ GB/') ${_calg:-?}${_cpr:+, priority $_cpr}"
  if [ "$_csz" = "$_want" ] && [ "$_calg" = "$_alg" ] && [ -n "$_cpr" ]; then
    cnt_ok; fin x_zram "zram0 $_gb GB $_alg, priority ${_cpr:-?} (already set)"; return
  fi
  # data already in zram must fit back into RAM before the swap can be switched off
  _used=$(awk '$1 ~ /\/zram0$/ {print $4}' /proc/swaps 2>/dev/null)
  _avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
  # anything that still leaves ~400 MB free (Android may close background apps to make room)
  _lim=$((${_avail:-0} - 409600))
  if [ "${_used:-0}" -gt "$_lim" ]; then
    st x_zram skipped "$((${_used:-0} / 1024)) MB in zram right now, too much to move back into RAM ($((${_avail:-0} / 1024)) MB free); left as is ($_was)"; return
  fi
  _bd=$(rd "$_z/backing_dev")
  _sp=$(awk '$1 ~ /\/zram0$/ {print $1; exit}' /proc/swaps 2>/dev/null)
  if [ -n "$_sp" ] && ! swapoff "$_sp" 2>/dev/null; then
    st x_zram failed "swapoff refused; zram left as is ($_was)"; return
  fi
  { echo 1 > "$_z/reset"; } 2>/dev/null
  [ -n "$_bd" ] && [ "$_bd" != none ] && { echo "$_bd" > "$_z/backing_dev"; } 2>/dev/null
  [ "$_alg" != "$_calg" ] && { echo "$_alg" > "$_z/comp_algorithm"; } 2>/dev/null
  if { echo "${_gb}G" > "$_z/disksize"; } 2>/dev/null && mkswap "$_zd" >/dev/null 2>&1 && swapon "$_zd" 2>/dev/null; then
    _nalg=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$_z/comp_algorithm" 2>/dev/null)
    _npr=$(awk '$1 ~ /\/zram0$/ {print $5}' /proc/swaps 2>/dev/null)
    cnt_ok
    fin x_zram "zram0 $_gb GB ${_nalg:-$_alg}, priority ${_npr:-?} ($_was)"
  else
    hc_zram_back "$_calg" "$_csz" "$_bd"
    st x_zram failed "kernel refused $_gb GB / $_alg; ROM zram put back ($_was)"
  fi
}

# x_job_limit - JobScheduler waits for more jobs / longer so background work runs in fewer, bigger batches
# Only keys this Android lists in "dumpsys jobscheduler" are written; a partial readback is kept and reported.
HC_JS_KEYS="min_ready_cpu_only_jobs_count min_ready_non_active_jobs_count max_cpu_only_job_batch_delay_ms max_non_active_job_batch_delay_ms conn_max_connectivity_job_batch_delay_ms"
hc_js_read() { # -> key=value lines of HC_JS_KEYS from the live JobScheduler constants
  dumpsys jobscheduler </dev/null 2>/dev/null | sed -n 's/^ *\([a-z_]*\)=\([0-9][0-9]*\).*/\1=\2/p' | grep -E "^($(echo $HC_JS_KEYS | tr ' ' '|'))="
}
f_x_job_limit() {
  _jl=$(cfg x_job_limit 0)
  if [ "$_jl" = 0 ]; then
    grep -q '^x_job_limit|' "$HC_ROMBAK" 2>/dev/null && restore_feature x_job_limit
    st x_job_limit off
    return
  fi
  case "$_jl" in
    1) _jc=5; _jn=8;  _jd=3600000; _jname="balanced, waits up to 1 h" ;;
    2) _jc=8; _jn=12; _jd=7200000; _jname="strong, waits up to 2 h" ;;
    *) st x_job_limit skipped "unknown level $_jl"; return ;;
  esac
  cnt_reset
  _cur=$(hc_js_read)
  [ -n "$_cur" ] || { st x_job_limit skipped "this Android does not list the JobScheduler batching settings"; return; }
  _want=""
  for _k in $HC_JS_KEYS; do
    echo "$_cur" | grep -q "^$_k=" || continue
    case "$_k" in
      min_ready_cpu_only_jobs_count) _v=$_jc ;;
      min_ready_non_active_jobs_count) _v=$_jn ;;
      *) _v=$_jd ;;
    esac
    set_d x_job_limit jobscheduler "$_k" "$_v"
    _want="$_want $_k=$_v"
  done
  # JobScheduler takes DeviceConfig changes a moment later: wait up to 6 s. Keep whatever
  # took effect and report partial instead of rolling back every key when one does not take.
  _t=0; _need=$(printf '%s\n' $_want | grep -c .)
  _got=0; _bad=""
  while [ "$_t" -lt 6 ]; do
    sleep 1
    _now=$(hc_js_read)
    _got=0; _bad=""
    for _w in $_want; do
      if echo "$_now" | grep -qx "$_w"; then
        _got=$((_got + 1))
      else
        _bad="$_bad ${_w%%=*}"
      fi
    done
    [ "$_need" -gt 0 ] && [ "$_got" -ge "$_need" ] && break
    _t=$((_t + 1))
  done
  if [ "$_got" -eq 0 ]; then
    restore_feature x_job_limit
    log "  x_job_limit: JobScheduler did not take any value, put back"
    st x_job_limit skipped "JobScheduler did not take the values (put back to stock)"
    return
  fi
  if [ "$_got" -lt "$_need" ]; then
    log "  x_job_limit: $_got/$_need values took, left unchanged:$_bad"
    st x_job_limit partial "$_got/$_need JobScheduler settings applied ($_jname); the rest stayed unchanged"
    return
  fi
  fin x_job_limit "background jobs batched ($_jname)"
}

# x_eas - make sure the Energy Aware Scheduler is on (some ROMs/kernels switch it off)
f_x_eas() {
  on x_eas || { st x_eas off; return; }
  cnt_reset
  _ea=/proc/sys/kernel/sched_energy_aware
  [ -e "$_ea" ] || { st x_eas skipped "no sched_energy_aware (kernel without EAS)"; return; }
  if [ "$(cat "$_ea" 2>/dev/null)" = 1 ]; then cnt_ok; _d="EAS already on"
  else wn "$_ea" 1; _d="EAS switched on (was off)"
  fi
  fin x_eas "$_d"
}

# x_balanced - balanced system defaults: undoes performance tweaks left by other tools
# x_cache_keep - apps that keep their cache during the clean (applied by common/cache_clean.sh)
f_x_cache_keep() {
  on x_cache_keep || { st x_cache_keep off; return; }
  _kn=$(cfg x_cache_keep_pkgs "" | tr ',' '\n' | grep -c .)
  if [ "$_kn" -gt 0 ]; then
    st x_cache_keep applied "$_kn app(s) keep their cache during the clean"
  else
    st x_cache_keep applied "no apps picked yet, every app cache is cleaned"
  fi
}

# x_cache_notify - notification after each app cache clean (posted by common/cache_clean.sh)
f_x_cache_notify() {
  [ "$(cfg x_cache_notify 1)" = 1 ] || { st x_cache_notify off; return; }
  st x_cache_notify applied "notification after the daily auto clean and after Clean now"
}

# x_rpm - runtime power management "auto" for idle USB / I2C / SPI devices (the kernel can power
# them down when idle). Skipped: devices without runtime PM, input devices (touch, keys, HID), USB
# audio / HID / video / wireless interfaces, and touch, fingerprint, NFC, audio, haptics and charger
# chips matched by driver name. Kernel nodes: stock values return after a reboot when off.
hc_rpm_skip() {
  for _hi in "$1"/input* "$1"/*/input*; do
    [ -e "$_hi" ] && return 0
  done
  for _ic in "$1"/bInterfaceClass "$1"/*/bInterfaceClass; do
    [ -f "$_ic" ] || continue
    case "$(cat "$_ic" 2>/dev/null)" in 01|03|0e|e0) return 0 ;; esac
  done
  _dn=$(readlink "$1/driver" 2>/dev/null); _dn=${_dn##*/}
  echo "$_dn $(cat "$1/name" 2>/dev/null)" | grep -qiE \
    'touch|_ts|ts_|fts|goodix|synaptics|nvt|novatek|focal|ilitek|himax|fpc|finger|nfc|nci|sn1|st21|audio|codec|snd|wcd|tfa|cs35|cs40|aw8|aw9|fsa|haptic|vib|charg|chg|bq2|ln8|sc8|fuel|gauge|bms|pd_|typec|husb|rt17|sgm|max77|pm8|pmic'
}
f_x_rpm() {
  on x_rpm || { st x_rpm off; return; }
  cnt_reset
  _rn=0; _rs=0; _ra=0
  for _rc in /sys/bus/usb/devices/*/power/control /sys/bus/i2c/devices/*/power/control /sys/bus/spi/devices/*/power/control; do
    [ -f "$_rc" ] || continue
    _rd=${_rc%/power/control}
    [ "$(cat "$_rc" 2>/dev/null)" = auto ] && { _ra=$((_ra + 1)); continue; }
    case "$(cat "$_rd/power/runtime_status" 2>/dev/null)" in ''|unsupported) continue ;; esac
    if hc_rpm_skip "$_rd"; then _rs=$((_rs + 1)); continue; fi
    wn "$_rc" auto && _rn=$((_rn + 1))
  done
  _rl=""; [ "$_rs" -gt 0 ] && _rl=", $_rs left on (touch/input, audio, charger, NFC...)"
  _rx="$_ra already auto$_rl"
  # nothing left to change: the kernel already runs every idle device in auto
  if [ "$HC_OK$HC_FAIL$HC_RO" = 000 ] && [ "$_ra" -gt 0 ]; then
    st x_rpm applied "already on: the kernel keeps all $_ra idle device(s) in auto, nothing to change$_rl"
    return
  fi
  fin x_rpm "$_rn idle device(s) set to auto (USB / I2C / SPI); $_rx" "no device to change ($_rx)"
}

hc_df_unlock() { # devfreq node: min_freq = lowest, max_freq = highest
  [ -f "$1/available_frequencies" ] || return 1
  _lo=$(tr ' ' '\n' < "$1/available_frequencies" | grep -E '^[0-9]+$' | sort -n | head -n 1)
  _hi=$(tr ' ' '\n' < "$1/available_frequencies" | grep -E '^[0-9]+$' | sort -n | tail -n 1)
  [ -n "$_lo" ] && [ -n "$_hi" ] || return 1
  wn "$1/max_freq" "$_hi"; wn "$1/min_freq" "$_lo"
}
f_x_balanced() {
  on x_balanced || { st x_balanced off; return; }
  cnt_reset
  # scheduler: no foreground boost, no idle-CPU preference for the top app
  [ -f /dev/stune/top-app/schedtune.boost ] && wn /dev/stune/top-app/schedtune.boost 0
  [ -f /dev/stune/top-app/schedtune.prefer_idle ] && wn /dev/stune/top-app/schedtune.prefer_idle 0
  [ -f /proc/sys/kernel/split_lock_mitigate ] && wn /proc/sys/kernel/split_lock_mitigate 1
  if [ -f /sys/kernel/debug/sched_features ]; then
    { echo NEXT_BUDDY > /sys/kernel/debug/sched_features; } 2>/dev/null && cnt_ok
    { echo TTWU_QUEUE > /sys/kernel/debug/sched_features; } 2>/dev/null && cnt_ok
  fi
  # memory / storage queue defaults
  on x_ram_opt || { [ -f /proc/sys/vm/vfs_cache_pressure ] && wn /proc/sys/vm/vfs_cache_pressure 120; }
  for _q in /sys/block/mmcblk0 /sys/block/mmcblk1 /sys/block/sd*; do
    [ -d "$_q/queue" ] || continue
    [ -f "$_q/queue/read_ahead_kb" ] && wn "$_q/queue/read_ahead_kb" 128
    [ -f "$_q/queue/nr_requests" ] && wn "$_q/queue/nr_requests" 64
  done
  # Oppo / OnePlus / Realme touch panel out of game mode
  _tp=/proc/touchpanel
  if [ -d "$_tp" ]; then
    for _kv in game_switch_enable:0 oplus_tp_limit_enable:1 oppo_tp_limit_enable:1 oplus_tp_direction:0 oppo_tp_direction:0; do
      [ -f "$_tp/${_kv%%:*}" ] && wn "$_tp/${_kv%%:*}" "${_kv#*:}"
    done
  fi
  if on_qcom_ok; then
    # CPU bus / DRAM / LLCC / L3 back to their full dynamic range (no forced floor)
    for _d in /sys/class/devfreq/*memlat* /sys/class/devfreq/*latfloor* /sys/class/devfreq/*ddr-lat*; do
      [ -d "$_d" ] && hc_df_unlock "$_d"
    done
    # optional: the other CPU / LLCC / DDR bandwidth voters (older Snapdragon kernels)
    if on x_bal_bus; then
      for _d in /sys/class/devfreq/*cpu*-lat /sys/class/devfreq/*cpu*-bw /sys/class/devfreq/*llccbw* \
        /sys/class/devfreq/*bus_llcc* /sys/class/devfreq/*bus_ddr* /sys/class/devfreq/*cpubw* \
        /sys/class/devfreq/*kgsl-ddr-qos*; do
        [ -d "$_d" ] && hc_df_unlock "$_d"
      done
    fi
    # kernel GPU / touch boosts off (custom kernels)
    for _n in /sys/class/kgsl/kgsl-3d0/devfreq/adrenoboost /sys/module/msm_perfmon/parameters/touch_boost_enable \
      /sys/module/msm_perfmon/parameters/touch_boost_freq /sys/module/msm_performance/parameters/touchboost \
      /sys/power/pnpmgr/touch_boost; do
      [ -f "$_n" ] && wn "$_n" 0
    done
    for _c in DDR LLCC L3; do
      _p=/sys/devices/system/cpu/bus_dcvs/$_c
      [ -f "$_p/available_frequencies" ] || continue
      _lo=$(tr ' ' '\n' < "$_p/available_frequencies" | grep -E '^[0-9]+$' | sort -n | head -n 1)
      _hi=$(tr ' ' '\n' < "$_p/available_frequencies" | grep -E '^[0-9]+$' | sort -n | tail -n 1)
      [ -n "$_hi" ] && wn "$_p/hw_max_freq" "$_hi"
      [ -n "$_lo" ] && wn "$_p/hw_min_freq" "$_lo"
    done
  fi
  if on_mtk_ok; then
    # PPM power / thermal policies back on
    if [ -f /proc/ppm/policy_status ]; then
      # shellcheck disable=SC2013
      for _i in $(grep -E 'PWR_THRO|THERMAL' /proc/ppm/policy_status | sed -n 's/^\[\([0-9]*\)\].*/\1/p'); do
        { echo "$_i 1" > /proc/ppm/policy_status; } 2>/dev/null && cnt_ok
      done
    fi
    [ -f /sys/kernel/fpsgo/common/force_onoff ] && wn /sys/kernel/fpsgo/common/force_onoff 2
    [ -f /proc/cpufreq/cpufreq_cci_mode ] && wn /proc/cpufreq/cpufreq_cci_mode 0
    [ -f /proc/cpufreq/cpufreq_power_mode ] && wn /proc/cpufreq/cpufreq_power_mode 0
    [ -f /sys/devices/platform/boot_dramboost/dramboost/dramboost ] && wn /sys/devices/platform/boot_dramboost/dramboost/dramboost 0
    [ -f /sys/devices/system/cpu/eas/enable ] && wn /sys/devices/system/cpu/eas/enable 2
    [ -f /sys/module/sspm_v3/holders/ged/parameters/is_GED_KPI_enabled ] && wn /sys/module/sspm_v3/holders/ged/parameters/is_GED_KPI_enabled 1
    # GED / pnpmgr GPU and CPU boosts off
    for _n in /sys/pnpmgr/mwn /sys/pnpmgr/boost_enable /sys/pnpmgr/boost_mode; do
      [ -f "$_n" ] && wn "$_n" 0
    done
    for _n in gx_boost_on gx_game_mode ged_smart_boost enable_gpu_boost ged_boost_enable gx_frc_mode cpu_boost_policy boost_extra; do
      [ -f "/sys/module/ged/parameters/$_n" ] && wn "/sys/module/ged/parameters/$_n" 0
    done
    [ -f /sys/kernel/ged/hal/gpu_boost_level ] && wn /sys/kernel/ged/hal/gpu_boost_level -1
    # GPU OPP not fixed, GED boost floor at the lowest OPP
    [ -f /proc/gpufreq/gpufreq_opp_freq ] && { { echo 0 > /proc/gpufreq/gpufreq_opp_freq; } 2>/dev/null && cnt_ok; }
    [ -f /proc/gpufreqv2/fix_target_opp_index ] && { { echo -1 > /proc/gpufreqv2/fix_target_opp_index; } 2>/dev/null && cnt_ok; }
    _ot=""; [ -f /proc/gpufreqv2/gpu_working_opp_table ] && _ot=/proc/gpufreqv2/gpu_working_opp_table
    [ -z "$_ot" ] && [ -f /proc/gpufreq/gpufreq_opp_dump ] && _ot=/proc/gpufreq/gpufreq_opp_dump
    if [ -n "$_ot" ] && [ -f /sys/kernel/ged/hal/custom_boost_gpu_freq ]; then
      _mi=$(awk -F'[][]' '{print $2}' "$_ot" | grep -E '^[0-9]+$' | tail -n 1)
      [ -n "$_mi" ] && wn /sys/kernel/ged/hal/custom_boost_gpu_freq "$_mi"
    fi
    # GPU power limiter, battery over-current limiter and EARA thermal back on
    if [ -f /proc/gpufreq/gpufreq_power_limited ]; then
      for _s in ignore_batt_oc ignore_batt_percent ignore_low_batt ignore_thermal_protect ignore_pbm_limited; do
        { echo "$_s 0" > /proc/gpufreq/gpufreq_power_limited; } 2>/dev/null && cnt_ok
      done
    fi
    [ -f /proc/mtk_batoc_throttling/battery_oc_protect_stop ] && { { echo "stop 0" > /proc/mtk_batoc_throttling/battery_oc_protect_stop; } 2>/dev/null && cnt_ok; }
    [ -f /sys/kernel/eara_thermal/enable ] && wn /sys/kernel/eara_thermal/enable 1
    # DRAM / vcore DVFS back to automatic
    for _d in /sys/devices/platform/*.dvfsrc/helio-dvfsrc/dvfsrc_req_ddr_opp; do
      [ -f "$_d" ] && { { echo -1 > "$_d"; } 2>/dev/null && cnt_ok; }
    done
    [ -f /sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp ] && { { echo -1 > /sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp; } 2>/dev/null && cnt_ok; }
    [ -d /sys/class/devfreq/mtk-dvfsrc-devfreq ] && hc_df_unlock /sys/class/devfreq/mtk-dvfsrc-devfreq
  fi
  fin x_balanced "balanced scheduler, storage queue and bus/DRAM defaults; protections on" "no matching nodes on this kernel"
}

# x_kcommon - common kernel and network tuning
f_x_kcommon() {
  on x_kcommon || { st x_kcommon off; return; }
  cnt_reset
  sync
  _k=/proc/sys/kernel
  for _kv in sched_child_runs_first:1 sched_autogroup_enabled:0 sched_nr_migrate:32 sched_schedstats:0 task_cpustats_enable:0; do
    [ -f "$_k/${_kv%%:*}" ] && wn "$_k/${_kv%%:*}" "${_kv#*:}"
  done
  on debug_off || { [ -f "$_k/perf_cpu_time_max_percent" ] && wn "$_k/perf_cpu_time_max_percent" 3; }
  # memory: no swap read-ahead, no proactive compaction, slower vmstat refresh
  [ -f /proc/sys/vm/page-cluster ] && wn /proc/sys/vm/page-cluster 0
  [ -f /proc/sys/vm/compaction_proactiveness ] && wn /proc/sys/vm/compaction_proactiveness 0
  on vm_tune || { [ -f /proc/sys/vm/stat_interval ] && wn /proc/sys/vm/stat_interval 15; }
  # storage: no I/O accounting or entropy sampling
  for _q in /sys/block/*/queue; do
    [ -f "$_q/iostats" ] && wn "$_q/iostats" 0
    [ -f "$_q/add_random" ] && wn "$_q/add_random" 0
  done
  [ -f /sys/module/mmc_core/parameters/use_spi_crc ] && wn /sys/module/mmc_core/parameters/use_spi_crc 0
  # network: best available congestion control, SACK / fast open, ECN only when the server asks (2)
  _n=/proc/sys/net/ipv4
  if [ -f "$_n/tcp_available_congestion_control" ]; then
    for _a in bbr3 bbr2 bbrplus bbr westwood cubic; do
      grep -qw "$_a" "$_n/tcp_available_congestion_control" && { wn "$_n/tcp_congestion_control" "$_a"; break; }
    done
  fi
  for _kv in tcp_low_latency:1 tcp_ecn:2 tcp_fastopen:3 tcp_sack:1 tcp_timestamps:0; do
    [ -f "$_n/${_kv%%:*}" ] && wn "$_n/${_kv%%:*}" "${_kv#*:}"
  done
  # OnePlus / Oppo / Realme scheduler helpers
  [ -f /sys/module/opchain/parameters/chain_on ] && wn /sys/module/opchain/parameters/chain_on 0
  [ -f /proc/task_info/task_sched_info/task_sched_info_enable ] && wn /proc/task_info/task_sched_info/task_sched_info_enable 0
  [ -f /proc/oplus_scheduler/sched_assist/sched_assist_enabled ] && wn /proc/oplus_scheduler/sched_assist/sched_assist_enabled 0
  _cc=$(cat "$_n/tcp_congestion_control" 2>/dev/null)
  fin x_kcommon "scheduler, memory, storage and network tuned${_cc:+ (TCP $_cc)}"
}
