# Changelog

> Current build: **v2.0 (200)**. The v2.1 and v2.1.1 changes below are not part of it: this v2.0 build has no
> "Hold charge at a set level" (an older version's cut is put back at boot).

## v2.1.1 (211)

- Fix: Xiaomi qti kernels (qcom-battery, e.g. POCO F5 / marble) do not take the battery input_suspend node reliably and expose no usable power_supply/battery cut node, so Hold charge at a set level kept charging past the level. The keeper now tries qcom-battery/charging_enabled = 0 (charge current 0, the phone runs from the charger) before input_suspend and lets go with 1 twice (this driver only restores the charge current on the second write)
- Fix: a cut counts as working also when the charge current falls from 0.8 A or more to 0.3 A or less, even if the battery keeps reporting "Charging" for a moment

## v2.1 (210)

- Fix: Hold charge at a set level did nothing on kernels whose charge_control_end_threshold accepts a write but is ignored: the node was written and trusted, so the phone kept charging. The keeper now checks the first time the level is reached that the charging really stops and, if it does not, puts the node back and cuts the charger input instead
- Fix: On kernels where the cut node is charging_enabled / battery_charging_enabled (1 = normal), the value saved to let the charging through again was 0 instead of 1, so the phone could stay "not charging" after the level fell and charging never came back until a reboot
- Fix: a node (or all of them) that failed the 10 s test is tried again on the next charge cycle and at most 5 min later, instead of staying failed until a reboot
- New: two more cut nodes where the kernel has them: qcom-battery/restricted_charging and power_supply/battery/charge_disable
- The bug report lists the charge_hold and bcal_watch keepers too

## v2.0 (200)

- New: Auto clean app cache every 1 to 7 days (was daily only)
- New: Keep cache of chosen apps (skipped by the auto clean and Clean now; good for games so they do not load shaders again)
- New: CPU keeper. When a big-core cap, a little-core cap or Park prime core is on, a tiny keeper checks every 30 s (only while the phone is awake) and puts them back if the ROM undid them. It gives up for 10 minutes if the ROM undoes them 5 times in 10 minutes. No new setting
- Fix: Park prime core no longer stops at "core_ctl is disabled": it switches core_ctl on for that cluster until the next reboot, checks that the core is really parked (reports Unsupported otherwise) and locks the core_ctl nodes so the ROM cannot undo it
- New: Little-core frequency cap (50-99%, default off, with its own Lock switch)
- New: Optimize apps (dex2oat) in More: compiles all apps, system apps included, with progress in percent, app count and the names being compiled. Modes Speed (default), Speed-profile, Everything, Reset to default. Optimize all apps or only the apps you pick. Pauses at 48°C battery (continues at 47°C), stops at 15% battery without charger or under 1 GB free storage. Runs once, nothing changes at boot
- Fix: Park prime core status now reads "parked (paused via core_ctl, stays online at minimum frequency N MHz)".
- New: Fewer background jobs (More > Extra power saving, Off / Balanced / Strong): JobScheduler waits for more jobs and up to 1-2 hours, so background work runs in fewer batches. Only the settings this Android lists in dumpsys jobscheduler are written, and they are read back; if not taken they are put back and it says Unsupported.
- New: Compact background apps (More > RAM, off by default): about 90 s after the screen goes off, when free RAM is under 30%, background apps get their memory compacted (cmd activity compact, not closed), at most every 20 min. Runs in the screen-off keeper (no extra process) and stops when the screen turns on. Frees RAM, does not save battery.
- New: Keep Wi-Fi on while the screen is off (Battery drain, off by default): if the ROM switches Wi-Fi off with the screen off, it is turned on again, seen at once through Wi-Fi link events (plus a 60 s timer). Wi-Fi you switch off yourself stays off. Shares the screen-off keeper.
- New: Location and Bluetooth off during long screen-off (Battery drain, off by default): after the screen has been off for 5 to 120 min (default 15), Location is switched off and comes back right when the screen turns on. Bluetooth can be switched off the same way (extra option; skipped while audio plays or an audio device is connected, best effort). Location alarms, Find My Device and navigation with the screen off get no position meanwhile. Runs in the same screen-off keeper, nothing is polled.
- New: Safe mode. If three boots in a row do not finish, HyperCool switches itself off for the next boot (the module description says so) and the ROM stays as it is; turn it on again in the manager when you want.
- New: F2FS garbage collection (More > Storage, off by default): when the screen has been off 10 min and the reclaimable space (F2FS "unusable") is at least 1 to 15 GB (default 4), it runs the same gc_urgent garbage collection as Android idle maintenance for up to 7 min, at most once a week. No charger needed (30% battery when not charging); battery under 40 C to start, stops at 45 C (adjustable), under 20% battery or when the screen turns on. Optional weekly fstrim; a notification shows the result; pauses 7 days if two runs free almost nothing. Needs /data on F2FS with the gc_urgent node. Not tested on a device yet.
- New: Auto optimize apps (More > Storage, off by default): once a week, after the screen has been off 10 min, all apps (system apps included) are compiled in the background with the same script as the Optimize apps card: mode of your choice (speed-profile by default, or speed / everything), one app at a time, never a force recompile (apps that are already optimized are skipped). No charger needed (40% battery when not charging); starts under 40 C, stops at 45 C, under 15% battery, under 1 GB free storage or when the screen turns on (the apps now compiling finish). A run you start by hand counts as this week's run and is never stopped by it. Notification with the result (can be turned off). Runs in the screen-off keeper.
- New: Top battery use (Home): shows which apps and system parts used the most battery since the last charge, with filters for user apps, system apps and hardware. Read only; uses `dumpsys batterystats` (mAh estimate) and falls back to wake lock time when the ROM has no estimate.
- Change: Home shows Battery health in mAh (full-charge capacity, with the % of design capacity) instead of the battery level, and the device name is bigger, bold, with a capital codename (POCO F5 (Marble)).
