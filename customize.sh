#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - installer
# shellcheck disable=SC2034
SKIPUNZIP=0
HC_DATA=/data/adb/hypercool

ui_print " "
ui_print "  HyperCool - Heat & Battery Fix"
ui_print "  one-shot at boot | tiny opt-in keepers only"
ui_print " "

_dev=$(getprop ro.product.device)
_os=$(getprop ro.mi.os.version.name)
[ -z "$_os" ] && _os=$(getprop ro.miui.ui.version.name)
ui_print "- Device : $(getprop ro.product.marketname) ($_dev)"
ui_print "- Android: $(getprop ro.build.version.release) (API $API)"
_soc=$(getprop ro.soc.manufacturer)
_plat=$(getprop ro.board.platform)
# ro.board.platform is the shared platform name (SD 675/730/730G/732G all report sm6150)
_model=$(getprop ro.soc.model)
[ -z "$_model" ] && _model=$(cat /sys/devices/soc0/machine 2>/dev/null)
if [ -n "$_model" ] && [ "$_model" != "$_plat" ]; then
  ui_print "- SoC    : ${_soc:-unknown} $_model${_plat:+ (platform $_plat)}"
else
  ui_print "- SoC    : ${_soc:-unknown} ${_plat:+($_plat)}"
fi
if [ -n "$_os" ]; then
  ui_print "- ROM    : HyperOS/MIUI $_os"
else
  ui_print "- ROM    : $(getprop ro.build.display.id)"
  ui_print "  Xiaomi-only options (night charging, Joyose,"
  ui_print "  autostart, MIUI blur) will be skipped."
fi
_st=""
case "$_soc" in [Mm]ediatek*|MediaTek*|MTK) _st=mtk ;; QTI|[Qq]ualcomm*) _st=qcom ;; esac
if [ "$_st" = qcom ] || { [ -z "$_st" ] && { [ -d /sys/class/kgsl/kgsl-3d0 ] || echo "$_soc $_plat" | grep -qiE 'qti|qualcomm|qcom|msm|sm[0-9]|sdm|kona|lahaina|taro|kalama|pineapple|parrot|crow|bengal|holi|lito|trinket'; }; }; then
  ui_print "- Qualcomm kernel features available"
  _lbl="Device: Qualcomm✓ | MediaTek"
elif [ "$_st" = mtk ] || [ -d /proc/ppm ] || [ -d /proc/perfmgr ] || echo "$_soc $_plat" | grep -qiE 'mediatek|mt[0-9]'; then
  ui_print "- MediaTek kernel features available"
  ui_print "  (CPU cap with PPM, Mali GPU, perfmgr touch boost, UFS)"
  _lbl="Device: Qualcomm | MediaTek✓"
else
  ui_print "! Unknown SoC: most kernel features will"
  ui_print "! show Unsupported, system features still work."
fi
sed -i "s#^description=.*#description=Heat and battery fix for Android - ${_lbl:-Device: Qualcomm | MediaTek} (one-shot at boot, only tiny opt-in keepers). Configure in WebUI, then reboot. Telegram Channel: @ModuleArchives.#" "$MODPATH/module.prop"

[ "$API" -lt 30 ] && abort "! Android 11 or newer is required"

mkdir -p "$HC_DATA/backup"

# Keep the user's config across updates; add any new keys with defaults.
if [ -f "$HC_DATA/config.conf" ]; then
  ui_print "- Existing config kept, merging new options"
  C="$HC_DATA/config.conf"
  if ! grep -q '^cfg_ver=' "$C"; then
    ui_print "- Migrating v1.0 config values"
    sed -i -e 's/^cpu_cap=1$/cpu_cap=95/' -e 's/^cpu_cap=2$/cpu_cap=88/' -e 's/^cpu_cap=3$/cpu_cap=80/' \
      -e 's/^charge_cool=1$/charge_cool=3000/' -e 's/^charge_cool=2$/charge_cool=2000/' -e 's/^charge_cool=3$/charge_cool=1500/' \
      -e 's/^doze_aggr=1$/doze_aggr=2/' "$C"
  fi
  if grep -qx 'wl_list=qcom_rx_wakelock;wlan_wow_wl;wlan_extscan_wl;netmgr_wl;NETLINK;IPA_WS;wlan_ipa;wlan_pno_wl;wcnss_filter_lock;IPCRTR_lpass_rx;hal_bluetooth_lock;sensor_ind' "$C"; then
    ui_print "- Wakelock list: removed notification wakelocks from the old default"
    sed -i 's/^wl_list=.*/wl_list=wlan_pno_wl;wlan_extscan_wl;wcnss_filter_lock/' "$C"
  fi
  # make sure the last line ends with a newline before appending missing keys
  [ -s "$HC_DATA/config.conf" ] && [ -n "$(tail -c1 "$HC_DATA/config.conf")" ] && echo >> "$HC_DATA/config.conf"
  grep -E '^[a-z_]+=' "$MODPATH/common/default.conf" | while IFS='=' read -r k v; do
    grep -q "^$k=" "$HC_DATA/config.conf" || echo "$k=$v" >> "$HC_DATA/config.conf"
  done
else
  ui_print "- Installing default config"
  cp -f "$MODPATH/common/default.conf" "$HC_DATA/config.conf"
fi
cp -f "$MODPATH/common/restore.sh" "$HC_DATA/restore.sh"
# guard: restores ROM changes even while the module is disabled (removes itself after uninstall)
mkdir -p /data/adb/service.d
cp -f "$MODPATH/common/hc_guard.sh" /data/adb/service.d/.hypercool_guard.sh
chmod 0755 /data/adb/service.d/.hypercool_guard.sh

if [ "$KSU" = "true" ]; then
  ui_print "- KernelSU $KSU_VER detected"
fi

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/common/restore.sh" 0 0 0755
set_perm "$MODPATH/common/charge_cal.sh" 0 0 0755
set_perm "$MODPATH/common/chg_watch.sh" 0 0 0755
set_perm "$MODPATH/common/soff_watch.sh" 0 0 0755
set_perm "$MODPATH/common/cache_clean.sh" 0 0 0755
set_perm "$MODPATH/common/cpu_watch.sh" 0 0 0755
set_perm "$MODPATH/common/dexopt.sh" 0 0 0755
set_perm "$MODPATH/common/hc_guard.sh" 0 0 0755

ui_print " "
ui_print "- Open the WebUI to choose features, then reboot."
ui_print "- Every option is applied once per boot."
ui_print " "
