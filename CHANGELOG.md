# Changelog

> Current build: **v2.1.1 (211)**.

## v2.1.1 (211)

- Fixed: the RAM optimizer no longer disables Xiaomi's perfmgr (`/sys/module/perfmgr/parameters/perfmgr_enable`). perfmgr is a GPU/frame boost framework, not a memory-reclaim one: the write added no RAM, was not restored when the switch was turned off (only a reboot brought it back), and was the only perfmgr parameter HyperCool changed. The VM, LMK and other vendor reclaim writes stay.
- Changed: the RAM optimizer details no longer list perfmgr under vendor reclaim frameworks.

## v2.1 (210)

- New: WebUI redesign: dark violet palette, separate rounded cards, flat top bar, floating bottom navigation with a tonal active tab
- New: Appearance in Tools: Dark theme (Standard, AMOLED, Light, Follow system) and Colors (System Dynamic from the wallpaper, HyperCool Violet, 9 color presets)
- Changed: the HyperCool title in the header keeps its color gradient, as in v2.0.1
- New: Experimental features are collected in a red "Experimental" zone at the bottom of their page (red title, red icons and switches)
- Changed: the labels KERNEL, SYSTEM, XIAOMI, SAFE, MODERATE, EXPERIMENTAL and the status labels (Applied, Partial, Failed) are now soft tonal pills instead of bright outlines
- Fixed: false "Applied" status. Protected apps and Block background apps now check that the background permission really changed; Debloat, Disable apps and Joyose count an app only if it is really disabled; GMS Doze, Smart Pixels and Adaptive refresh rate show Partial or Failed when they could not be confirmed; log and debug props show Failed when no prop was accepted
- Changed: Quick presets Max battery and Cool gaming now also switch on auto F2FS GC, auto dex2oat and runtime power (Max battery also fewer background jobs and Location/Bluetooth off during long screen-off). Keep Wi-Fi on, Charge limit, Adaptive refresh rate, ZRAM, Multitasking and Compact background apps are left as you set them when a preset does not mention them
- New: Appearance > Blur toolbar (on by default): frosted glass effect on the header and the bottom bar
- Changed: the header has rounded bottom corners, and the bottom bar no longer has an outline
- Changed: banner: the version pill is removed so the artwork can never show a stale version, and the remaining text lines up with the subtitle

## v2.0.1 (201)

- Fix: Keep Wi-Fi on while the screen is off could turn Wi-Fi back on while the screen was on (a screen event replayed at start, or a panel brightness node that stays 0). It now asks the power service and only acts when the screen is really off; the screen-on state clears the intent
- Fix: Compact background apps counted every compaction as failed because it looked for the wrong output text ("Finished compacting"); Android prints "Finished some compaction for <pid>". The state file now shows the real count
- Fix: Location and Bluetooth off during long screen-off: `svc bluetooth` no longer exists on Android 13+, so Bluetooth was never switched off. It now uses `cmd bluetooth_manager` first, with `svc bluetooth` as the fallback for older ROMs

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
