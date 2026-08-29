// Battery widget for the bar: icon + percentage + live charge/discharge
// power, with a popup showing daily/weekly/monthly consumption.

import "Model.js" as Model
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui

// Consumption is tracked by sampling UPower's battery energy (Wh) on a slow
// timer: a drop while discharging accrues to today's "used" bucket, a rise
// while charging to "charged". Buckets are persisted per calendar day to
// $XDG_STATE_HOME/omarchy/battery-info/history.json so the totals survive
// shell restarts; the gap since the last recorded sample is attributed on
// load so suspend/off time is not lost. One bar surface per monitor exists,
// so only the instance that owns the IPC target writes the file (identical
// sampled data plus an atomic rename keep even a transient race benign).
Panel {
    id: root

    // ------------------------------------------------------------- palette
    readonly property color foreground: bar ? bar.foreground : Color.foreground

    // ------------------------------------------------------------- live state
    readonly property var device: UPower.displayDevice
    readonly property bool batteryPresent: !!(device && device.isPresent)
    readonly property int percent: Math.round(Model.batteryFraction(device) * 100)
    readonly property bool onBattery: UPower.onBattery
    readonly property bool fullyCharged: batteryPresent && device.state === UPowerDeviceState.FullyCharged
    readonly property bool chargeThresholdActive: Model.chargeThresholdActive(device, onBattery, upowerStates())
    readonly property bool batteryFlowIdle: fullyCharged || chargeThresholdActive
    readonly property bool charging: batteryPresent && !onBattery && !batteryFlowIdle
    // UPower EnergyRate is an unsigned magnitude. Direction comes from the
    // device state; treating the rate as signed used to label discharging as
    // charging and point the arrow the wrong way.
    readonly property real batteryRateWatts: batteryPresent ? Math.max(0, Number(device.changeRate || 0)) : 0
    readonly property bool chargingFlow: batteryPresent && device.state === UPowerDeviceState.Charging && batteryRateWatts >= 0.05
    readonly property bool dischargingFlow: batteryPresent && (onBattery || device.state === UPowerDeviceState.Discharging) && batteryRateWatts >= 0.05
    readonly property bool hasPowerFlow: chargingFlow || dischargingFlow
    // ------------------------------------------------------------- settings
    readonly property bool showPercentage: setting("showPercentage", true) === true
    // Standard Zhuhai one-household residential tariff. A household's other
    // month-to-date use can be supplied as a baseline so this device crosses
    // the same marginal tier as the electricity meter.
    readonly property real configuredTariffBaseRate: Number(setting("tariffBaseRate", 0.60886875))
    readonly property real configuredMonthlyBaselineKWh: Number(setting("monthlyBaselineKWh", 0))
    readonly property real tariffBaseRate: isFinite(configuredTariffBaseRate) && configuredTariffBaseRate >= 0 ? configuredTariffBaseRate : 0.60886875
    readonly property real monthlyBaselineKWh: isFinite(configuredMonthlyBaselineKWh) && configuredMonthlyBaselineKWh >= 0 ? configuredMonthlyBaselineKWh : 0
    // ------------------------------------------------------------- work mode
    // The machine's power profiles (power-saver / balanced / performance) are
    // listed through the omarchy helper, so switching here respects the same
    // per-AC/battery memory the shell uses elsewhere. The list is refreshed on
    // every panel open, on a slow tick while open, and after each switch.
    property var profiles: []
    property string activeProfile: ""
    property int profileIndex: 0
    property bool cursorActive: false
    // ------------------------------------------------------------- history
    property var dayBuckets: ({
    })
    property var lastSample: null
    property var pendingBatteryLast: null
    property var pendingRaplLast: null
    property bool historyReady: false
    property bool historyDirty: false
    property bool ipcOwner: false
    property real lastPersistTime: 0
    property string lastDayKey: ""
    property string historyError: ""
    property bool historyRecoveryStarted: false
    property bool historyRecoveryDone: false
    // ------------------------------------------------------------- RAPL
    // Whole-machine draw is measurable through the RAPL platform (psys)
    // energy counter — it spans the CPU, the iGPU and the rest of the
    // platform, so it is the closest proxy for how much the machine is
    // actually pulling right now. The kernel keeps the counter out of reach
    // of unprivileged readers, so the plugin reads it via a passwordless
    // sudoers rule scoped to that exact sysfs file. Falls back to
    // battery-only stats when unavailable. Adapter supply ≈ platform draw +
    // whatever is simultaneously flowing into the battery.
    readonly property string raplNode: "psys"
    property bool raplAvailable: false
    property bool raplProbeDone: false
    property int raplFailCount: 0
    property real raplLastUj: 0
    property real raplLastTime: 0
    // Platform-wide instantaneous draw (short moving window from the energy
    // counter deltas; RAPL has no true instantaneous reading).
    property real sysPowerW: 0
    // Adapter supply: platform draw plus battery inflow. Only meaningful
    // while plugged in.
    readonly property real adapterWatts: sysPowerW + (chargingFlow ? batteryRateWatts : 0)
    readonly property real maxRaplWatts: 300
    readonly property real systemToday: Model.sumRange(dayBuckets, Model.todayKey(), Model.todayKey(), "system")
    readonly property real systemWeek: Model.sumRange(dayBuckets, Model.weekStartKey(), Model.todayKey(), "system")
    readonly property real systemMonth: Model.sumRange(dayBuckets, Model.monthStartKey(), Model.todayKey(), "system")
    readonly property string historyDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/battery-info"
    readonly property string historyPath: historyDir + "/history.json"
    readonly property real drainedToday: Model.sumRange(dayBuckets, Model.todayKey(), Model.todayKey(), "drained")
    readonly property real drainedWeek: Model.sumRange(dayBuckets, Model.weekStartKey(), Model.todayKey(), "drained")
    readonly property real drainedMonth: Model.sumRange(dayBuckets, Model.monthStartKey(), Model.todayKey(), "drained")
    readonly property real chargedToday: Model.sumRange(dayBuckets, Model.todayKey(), Model.todayKey(), "charged")
    readonly property real chargedWeek: Model.sumRange(dayBuckets, Model.weekStartKey(), Model.todayKey(), "charged")
    readonly property real chargedMonth: Model.sumRange(dayBuckets, Model.monthStartKey(), Model.todayKey(), "charged")
    readonly property real costToday: Model.rangeElectricityCost(dayBuckets, Model.todayKey(), Model.todayKey(), "system", tariffBaseRate, monthlyBaselineKWh)
    readonly property real costWeek: Model.rangeElectricityCost(dayBuckets, Model.weekStartKey(), Model.todayKey(), "system", tariffBaseRate, monthlyBaselineKWh)
    readonly property real costMonth: Model.rangeElectricityCost(dayBuckets, Model.monthStartKey(), Model.todayKey(), "system", tariffBaseRate, monthlyBaselineKWh)
    readonly property real monthTariffKWh: monthlyBaselineKWh + systemMonth / 1000
    readonly property int tariffTier: Model.zhuhaiTier(monthTariffKWh, new Date())
    readonly property real tariffMarginalRate: Model.zhuhaiMarginalRate(monthTariffKWh, new Date(), tariffBaseRate)
    readonly property var recentDays: historyReady ? Model.recentDayRows(dayBuckets, 7, Model.todayKey(), "system", tariffBaseRate, monthlyBaselineKWh) : []
    // Panel power row: precise value. Plugged with no battery flow reads
    // "Charging power 0 W" — connected but not charging — instead of a bare
    // dash, so the zero is legible rather than looking like missing data.
    readonly property string powerRowLabel: {
        if (!batteryPresent)
            return "Power flow";

        if (chargingFlow)
            return "Charging power";

        if (dischargingFlow)
            return "Discharge power";

        return "Battery power";
    }
    // Adapter row: the supply the wall is actually delivering (system draw +
    // battery inflow), or a dash while on battery / counter unavailable.
    readonly property string adapterRowValue: {
        if (!onBattery && raplAvailable && sysPowerW > 0)
            return Model.formatPower(adapterWatts);

        return "\u2014";
    }
    readonly property string powerRowValue: {
        if (!batteryPresent)
            return "\u2014";

        if (chargingFlow)
            return "\u2191 " + Model.formatPower(batteryRateWatts);

        if (dischargingFlow)
            return "\u2193 " + Model.formatPower(batteryRateWatts);

        return "0 W";
    }

    function upowerStates() {
        return {
            "Charging": UPowerDeviceState.Charging,
            "Discharging": UPowerDeviceState.Discharging,
            "FullyCharged": UPowerDeviceState.FullyCharged,
            "PendingCharge": UPowerDeviceState.PendingCharge,
            "PendingDischarge": UPowerDeviceState.PendingDischarge,
            "Empty": UPowerDeviceState.Empty
        };
    }

    function stateName() {
        return Model.upowerStateName(device.state, upowerStates());
    }

    function batteryIcon() {
        return Model.batteryIcon(device, onBattery, upowerStates());
    }

    function statusLabel() {
        return Model.modeLabel(device, onBattery, upowerStates());
    }

    function formatRangeWh(fromKey, toKey, field) {
        if (!historyReady || !Model.hasRangeData(dayBuckets, fromKey, toKey, field))
            return "\u2014";

        return Model.formatWh(Model.sumRange(dayBuckets, fromKey, toKey, field));
    }

    function formatRangeCost(fromKey, toKey) {
        if (!historyReady)
            return "\u2014";

        return Model.formatCurrency(Model.rangeElectricityCost(dayBuckets, fromKey, toKey, "system", tariffBaseRate, monthlyBaselineKWh));
    }

    // Bar label: icon + percent + live power. Plugged in, the adapter supply
    // in watts is shown (RAPL platform draw + battery inflow); on battery the
    // discharge flow (↓) is shown instead.
    function buttonLabel() {
        if (!batteryPresent)
            return "";

        var label = batteryIcon();
        if (showPercentage)
            label += " " + percent + "%";

        if (!onBattery)
            label += raplAvailable && sysPowerW > 0 ? " " + Model.formatCompactPower(adapterWatts) : (chargingFlow ? " \u2191" + Model.formatCompactPower(batteryRateWatts) : "");
        else if (dischargingFlow)
            label += " \u2193" + Model.formatCompactPower(batteryRateWatts);
        return label;
    }

    // ------------------------------------------------------------- sampling
    function addAcrossDays(field, amount, startTimestamp, endTimestamp) {
        var pieces = Model.splitAmountByDay(startTimestamp, endTimestamp, amount);
        for (var i = 0; i < pieces.length; i++)
            addToBucket(pieces[i].key, field, pieces[i].amount);

    }

    function batteryDeltaField(difference, previousState, currentState) {
        if (difference < 0 && (previousState === "Discharging" || currentState === "Discharging"))
            return "drained";

        if (difference > 0 && (previousState === "Charging" || currentState === "Charging"))
            return "charged";

        return "";
    }

    // UPower's display device can appear a beat after the widget is created,
    // so the load path only stashes state; the baseline and any catch-up gap
    // are applied on the first sample that sees a live device.
    function sample() {
        if (!batteryPresent || !historyReady)
            return ;

        startHistoryRecovery();
        var energy = Number(device.energy || 0);
        if (energy <= 0)
            return ;

        var now = Date.now() / 1000;
        var state = stateName();
        var cap = Number(device.energyCapacity || energy);
        // Attribute the energy gap since the last recorded sample — covers
        // shutdown/suspend and the window before the device came up.
        if (pendingBatteryLast) {
            var last = pendingBatteryLast;
            pendingBatteryLast = null;
            if (energy > 0 && Number(last.energy || 0) > 0) {
                var gap = energy - Number(last.energy);
                if (Math.abs(gap) > 0 && Math.abs(gap) <= cap) {
                    var gapField = batteryDeltaField(gap, String(last.state || ""), state);
                    if (gapField)
                        addAcrossDays(gapField, Math.abs(gap), Number(last.ts || now), now);

                }
            }
        }
        if (!lastSample || lastSample.energy <= 0) {
            lastSample = {
                "ts": now,
                "energy": energy,
                "state": state
            };
            return ;
        }
        var diff = energy - lastSample.energy;
        if (diff !== 0 && Math.abs(diff) <= cap) {
            var field = batteryDeltaField(diff, String(lastSample.state || ""), state);
            if (field)
                addAcrossDays(field, Math.abs(diff), lastSample.ts, now);

        }
        lastSample = {
            "ts": now,
            "energy": energy,
            "state": state
        };
        // Persist deltas promptly and refresh the baseline periodically even when
        // nothing changed, so a stale `last` never over-attributes an old gap.
        if (historyDirty || now - lastPersistTime > 300)
            persist();

    }

    function addToBucket(key, field, amount) {
        var buckets = Object.assign({
        }, dayBuckets);
        var b = Object.assign({
            "drained": 0,
            "charged": 0
        }, buckets[key] || {
        });
        b[field] = Number(b[field] || 0) + amount;
        buckets[key] = b;
        dayBuckets = buckets;
        historyDirty = true;
    }

    // One RAPL counter read: advances the live system-power figure and accrues
    // the consumed Wh to today's "system" bucket. Counter resets (reboot,
    // suspend resume) produce a negative or absurd delta and are skipped.
    function onRaplRead(raw) {
        var uj = parseFloat(String(raw || "").trim());
        if (!isFinite(uj) || uj <= 0) {
            raplFailCount++;
            if (raplProbeDone && raplFailCount >= 3)
                raplAvailable = false;

            return ;
        }
        raplFailCount = 0;
        raplProbeDone = true;
        raplAvailable = true;
        var now = Date.now() / 1000;
        // First read after a restart: attribute the gap since the stored RAPL
        // baseline (covers time the shell was down) unless the counter reset.
        if (raplLastUj <= 0 && pendingRaplLast) {
            var saved = pendingRaplLast;
            pendingRaplLast = null;
            var prev = Number(saved.rapl || 0);
            var savedAt = Number(saved.ts || now);
            var gapSeconds = Math.max(0, now - savedAt);
            var maxGapUj = Math.max(5, gapSeconds) * maxRaplWatts * 1e+06;
            if (prev > 0 && uj >= prev && uj - prev <= maxGapUj)
                addAcrossDays("system", (uj - prev) / 3.6e+09, savedAt, now);

        }
        if (raplLastUj > 0) {
            var dUj = uj - raplLastUj;
            var dt = now - raplLastTime;
            var maxDeltaUj = Math.max(2, dt) * maxRaplWatts * 1e+06;
            if (dUj > 0 && dUj <= maxDeltaUj && dt > 0) {
                addAcrossDays("system", dUj / 3.6e+09, raplLastTime, now);
                // Only trust the derived wattage on short deltas; a gap that
                // spans a suspend would deflate the figure for no reason.
                if (dt <= 60)
                    sysPowerW = dUj / dt / 1e+06;
            } else if (dUj < 0) {
                sysPowerW = 0; // counter reset since last read
            }
        }
        raplLastUj = uj;
        raplLastTime = now;
    }

    // History file was loaded: validate before adopting it. Invalid state is
    // left untouched on disk and surfaced in the panel instead of becoming an
    // empty object that gets persisted over the user's history.
    function onHistoryLoaded(raw) {
        var data = Model.parseHistory(raw);
        if (!data.valid) {
            historyError = data.error || "History could not be read";
            console.warn("battery-info:", historyError, historyPath);
            return ;
        }

        dayBuckets = data.days;
        lastDayKey = Model.todayKey();
        pendingBatteryLast = data.last;
        pendingRaplLast = data.last ? Object.assign({
        }, data.last) : null;
        // The RAPL baseline only means anything from the same counter node;
        // an old file written from another node (e.g. package → platform
        // switch) would attribute a bogus energy gap on the first read.
        if (pendingRaplLast && pendingRaplLast.raplNode !== raplNode)
            pendingRaplLast = Object.assign({
            }, pendingRaplLast, {
                "rapl": 0
            });

        historyError = "";
        historyReady = true;
        sample();
        startHistoryRecovery();
    }

    // No history file yet (first run): start tracking from the current state.
    function onHistoryFresh() {
        dayBuckets = {
        };
        lastDayKey = Model.todayKey();
        pendingBatteryLast = null;
        pendingRaplLast = null;
        historyError = "";
        historyReady = true;
        sample();
        startHistoryRecovery();
    }

    function onHistoryLoadFailed(error) {
        if (error === FileViewError.FileNotFound) {
            onHistoryFresh();
            return ;
        }

        historyError = error === FileViewError.PermissionDenied ? "History permission denied" : "History could not be loaded";
        console.warn("battery-info:", historyError, historyPath);
    }

    // UPower keeps coarse percentage/state history independently of this
    // plugin. Use it once per load to fill missing or recorded-zero battery
    // days; precise live Wh totals always win.
    function startHistoryRecovery() {
        if (!historyReady || !batteryPresent || historyRecoveryStarted)
            return ;

        historyRecoveryStarted = true;
        var nativePath = String(device.nativePath || "BAT0").replace(/[^A-Za-z0-9_]/g, "_");
        var objectPath = "/org/freedesktop/UPower/devices/battery_" + nativePath;
        historyRecoveryProc.command = ["busctl", "--system", "--json=short", "call", "org.freedesktop.UPower", objectPath, "org.freedesktop.UPower.Device", "GetHistory", "suu", "charge", "3456000", "300"];
        historyRecoveryProc.running = true;
    }

    function onHistoryRecovered(raw) {
        historyRecoveryDone = true;
        var recovered = Model.recoverUPowerHistory(raw, Number(device.energyCapacity || 0));
        var merged = Model.mergeRecoveredBatteryHistory(dayBuckets, recovered);
        if (!Model.historyChanged(dayBuckets, merged))
            return ;

        dayBuckets = merged;
        historyDirty = true;
        persist();
    }

    function persist() {
        if (!ipcOwner || !historyReady || !lastSample || writeProc.running)
            return ;

        historyDirty = false;
        lastPersistTime = Date.now() / 1000;
        Model.pruneBuckets(dayBuckets, 400);
        var last = {
            "ts": lastSample.ts,
            "energy": lastSample.energy,
            "state": lastSample.state,
            "rapl": raplLastUj,
            "raplNode": raplNode
        };
        var payload = JSON.stringify({
            "version": 4,
            "days": dayBuckets,
            "last": last
        });
        writeProc.command = ["bash", "-c", "mkdir -p \"$1\" && tmp=\"$1/history.json.tmp\" && if [ -f \"$1/history.json\" ]; then cp -p \"$1/history.json\" \"$1/history.json.bak\"; fi && printf '%s' \"$2\" > \"$tmp\" && mv \"$tmp\" \"$1/history.json\"", "battery-info", historyDir, payload];
        writeProc.running = true;
    }

    function togglePercentage() {
        root.settings = Object.assign({
        }, root.settings, {
            "showPercentage": !root.showPercentage
        });
        if (root.bar && root.bar.shell)
            root.bar.shell.updateEntryInline(root.moduleName, root.settings);

    }

    function profileIcon(name) {
        return Model.profileIcon(name);
    }

    function updateProfiles(raw) {
        var parsed = Model.parseProfiles(raw, profileIndex);
        // Keep the last known list across a transient empty payload so the
        // buttons don't blink out around AC plug/unplug events.
        if (parsed.profiles.length === 0)
            return ;

        profiles = parsed.profiles;
        activeProfile = parsed.activeProfile;
        profileIndex = parsed.profileIndex;
        if (opened && !cursorActive) {
            var idx = profiles.indexOf(activeProfile);
            if (idx >= 0)
                profileIndex = idx;

        }
    }

    function refreshPowerProfiles() {
        if (!profilesProc.running)
            profilesProc.running = true;

    }

    function selectProfileByDelta(delta) {
        profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles);
    }

    function activateSelectedProfile() {
        if (profileIndex < 0 || profileIndex >= profiles.length)
            return ;

        setProfile(profiles[profileIndex]);
    }

    function setProfile(profile) {
        if (!profile || actionProc.running)
            return ;

        actionProc.command = ["omarchy-powerprofiles-set", root.onBattery ? "battery" : "ac", profile];
        actionProc.running = true;
    }

    moduleName: "eipi10.battery-info"
    ipcTarget: "eipi10.battery-info"
    // manageIpc: false so this panel can own the single IpcHandler the target
    // permits — it doubles as the "who writes the history file" gate.
    manageIpc: false
    // Prefetch the profile list at startup so the picker is populated on the
    // first open instead of flashing in a tick later.
    Component.onCompleted: root.refreshPowerProfiles()
    visible: batteryPresent
    implicitWidth: batteryPresent ? button.implicitWidth : 0
    implicitHeight: batteryPresent ? button.implicitHeight : 0
    onOpenedChanged: {
        if (opened) {
            root.sample();
            root.refreshPowerProfiles();
            var idx = profiles.indexOf(activeProfile);
            root.profileIndex = idx >= 0 ? idx : 0;
            root.cursorActive = false;
        }
    }

    Process {
        id: raplProc

        // Platform (psys) scope: whole-machine draw, not just the CPU package.
        command: ["sudo", "-n", "cat", "/sys/class/powercap/intel-rapl:1/energy_uj"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.onRaplRead(text)
        }

    }

    IpcHandler {
        id: ipc

        function open() {
            root.open();
        }

        function close() {
            root.close();
        }

        function show() {
            root.open();
        }

        function hide() {
            root.close();
        }

        function toggle() {
            root.toggle();
        }

        function togglePercentage() {
            root.togglePercentage();
        }

        target: "eipi10.battery-info"
        Component.onCompleted: root.ipcOwner = enabled
        onEnabledChanged: root.ipcOwner = enabled
    }

    FileView {
        id: historyFile

        path: root.historyPath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.onHistoryLoaded(text())
        onLoadFailed: function(error) {
            root.onHistoryLoadFailed(error);
        }
    }

    Process {
        id: writeProc

        command: ["true"]
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.historyDirty = true;
                root.historyError = "History could not be saved";
            }
        }
    }

    Process {
        id: historyRecoveryProc

        command: ["true"]
        onExited: function(exitCode) {
            root.historyRecoveryDone = true;
            if (exitCode !== 0)
                console.warn("battery-info: UPower history recovery failed");

        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.onHistoryRecovered(text)
        }
    }

    Process {
        id: profilesProc

        command: ["omarchy-powerprofiles-list", "--active-state"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.updateProfiles(text)
        }

    }

    Process {
        id: actionProc

        onExited: root.refreshPowerProfiles()
    }

    // Refresh the work-mode list while the panel is open.
    Timer {
        id: profileTimer

        interval: 5000
        running: root.opened
        repeat: true
        onTriggered: root.refreshPowerProfiles()
    }

    // Read the RAPL platform counter on a fast tick so the adapter/system
    // figures track the present moment (RAPL has no instantaneous reading;
    // this is a ~2s moving window). Fails soft and stops retrying once
    // proven unavailable. The slow sample timer below keeps persisting.
    Timer {
        id: raplTimer

        interval: 2000
        running: root.batteryPresent && (root.raplProbeDone ? root.raplAvailable : true)
        repeat: true
        onTriggered: {
            if (!raplProc.running)
                raplProc.running = true;
        }
    }

    // Sample on a slow tick; the panel refreshes live through UPower bindings
    // anyway, this loop only feeds the consumption buckets and flow label.
    Timer {
        id: sampleTimer

        interval: 10000
        running: root.batteryPresent
        repeat: true
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    // Refresh the calendar window when the local day flips mid-session.
    Timer {
        id: dayTimer

        interval: 60000
        repeat: true
        running: root.batteryPresent
        onTriggered: {
            var key = Model.todayKey();
            if (key !== root.lastDayKey) {
                root.lastDayKey = key;
                root.dayBuckets = Object.assign({
                }, root.dayBuckets);
            }
        }
    }

    WidgetButton {
        id: button

        anchors.fill: parent
        bar: root.bar
        text: root.buttonLabel()
        fontSize: Style.font.caption
        horizontalMargin: 6
        tooltipText: root.batteryPresent ? root.percent + "%" + (root.onBattery ? " on battery" : " plugged in") + (root.hasPowerFlow ? " \u00b7 " + (root.dischargingFlow ? "\u2193" : "\u2191") + Model.formatCompactPower(root.batteryRateWatts) : "") + (root.onBattery ? "" : (root.raplAvailable && root.sysPowerW > 0 ? " \u00b7 adp " + Model.formatCompactPower(root.adapterWatts) : "")) + " \u00b7 today " + Model.formatWh(root.systemToday) + " / " + Model.formatCurrency(root.costToday) : ""
        onPressed: function(b) {
            if (b === Qt.RightButton)
                root.togglePercentage();
            else
                root.toggle();
        }
    }

    KeyboardPanel {
        id: panel

        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened && root.batteryPresent
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(380))
        contentHeight: panel.fittedContentHeight(column.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent
            onMoveRequested: function(dx, dy) {
                if (!root.cursorActive) {
                    root.cursorActive = true;
                    return ;
                }
                if (dx !== 0)
                    root.selectProfileByDelta(dx);
                else if (dy !== 0)
                    root.selectProfileByDelta(dy);
            }
            onActivateRequested: function() {
                if (root.cursorActive)
                    root.activateSelectedProfile();

            }
            onCloseRequested: root.close()
            onTabRequested: function(direction) {
                root.switchPanel(direction);
            }

            Column {
                id: column

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(14)

                // ---------- Hero: battery icon · title/status · percentage ----------
                Item {
                    width: parent.width
                    implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

                    Text {
                        id: heroIcon

                        text: root.batteryIcon()
                        color: root.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.display
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        id: heroLabels

                        anchors.left: heroIcon.right
                        anchors.leftMargin: Style.space(14)
                        anchors.right: heroPercent.left
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                            text: "Battery"
                            color: root.foreground
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                            elide: Text.ElideRight
                            width: parent.width
                        }

                        Text {
                            id: heroStatus

                            text: root.statusLabel().toUpperCase()
                            color: Qt.darker(root.foreground, 1.4)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                            elide: Text.ElideRight
                            width: parent.width
                        }

                    }

                    Text {
                        id: heroPercent

                        text: root.percent + "%"
                        color: root.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.displayLarge
                        font.bold: true
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                    }

                }

                // ---------- Charge/discharge power + time remaining ----------
                Row {
                    width: parent.width
                    spacing: Style.space(20)

                    Column {
                        width: (parent.width - parent.spacing) / 2
                        spacing: Style.spacing.labelGap

                        InfoPair {
                            label: "Adapter power"
                            value: root.adapterRowValue
                        }

                        InfoPair {
                            label: root.powerRowLabel
                            value: root.powerRowValue
                        }

                        InfoPair {
                            label: "System power"
                            value: root.raplAvailable ? Model.formatPower(root.sysPowerW) : "\u2014"
                        }

                        InfoPair {
                            label: root.charging ? "Time to full" : (root.onBattery ? "Time left" : "Time to full")
                            value: {
                                var secs = root.charging ? Number(root.device.timeToFull || 0) : (root.onBattery ? Number(root.device.timeToEmpty || 0) : Number(root.device.timeToFull || 0));
                                return Model.formatDuration(secs);
                            }
                        }

                    }

                    Column {
                        width: (parent.width - parent.spacing) / 2
                        spacing: Style.spacing.labelGap

                        InfoPair {
                            label: "Battery size"
                            value: Model.formatWh(root.device ? root.device.energyCapacity : 0)
                        }

                        InfoPair {
                            label: "Charge level"
                            value: root.percent + "%"
                        }

                    }

                }

                // ---------- Consumption, Zhuhai electricity, and daily history ----
                PanelSeparator {
                    foreground: root.foreground
                }

                PanelSectionHeader {
                    text: "CONSUMPTION"
                    foreground: root.foreground
                    fontFamily: root.bar.fontFamily
                }

                Column {
                    width: parent.width
                    spacing: Style.space(6)

                    Row {
                        id: consumHeader

                        readonly property real cellW: (width - Style.space(48) - spacing * 4) / 4

                        width: parent.width
                        spacing: Style.space(8)

                        Item {
                            width: Style.space(48)
                            height: 1
                        }

                        ConsumHeader {
                            width: consumHeader.cellW
                            text: "System"
                        }

                        ConsumHeader {
                            width: consumHeader.cellW
                            text: "Cost"
                        }

                        ConsumHeader {
                            width: consumHeader.cellW
                            text: "Used"
                        }

                        ConsumHeader {
                            width: consumHeader.cellW
                            text: "Charged"
                        }

                    }

                    ConsumRow {
                        period: "Today"
                        system: root.formatRangeWh(Model.todayKey(), Model.todayKey(), "system")
                        cost: root.formatRangeCost(Model.todayKey(), Model.todayKey())
                        used: root.formatRangeWh(Model.todayKey(), Model.todayKey(), "drained")
                        charged: root.formatRangeWh(Model.todayKey(), Model.todayKey(), "charged")
                    }

                    ConsumRow {
                        period: "Week"
                        system: root.formatRangeWh(Model.weekStartKey(), Model.todayKey(), "system")
                        cost: root.formatRangeCost(Model.weekStartKey(), Model.todayKey())
                        used: root.formatRangeWh(Model.weekStartKey(), Model.todayKey(), "drained")
                        charged: root.formatRangeWh(Model.weekStartKey(), Model.todayKey(), "charged")
                    }

                    ConsumRow {
                        period: "Month"
                        system: root.formatRangeWh(Model.monthStartKey(), Model.todayKey(), "system")
                        cost: root.formatRangeCost(Model.monthStartKey(), Model.todayKey())
                        used: root.formatRangeWh(Model.monthStartKey(), Model.todayKey(), "drained")
                        charged: root.formatRangeWh(Model.monthStartKey(), Model.todayKey(), "charged")
                    }

                    Text {
                        width: parent.width
                        topPadding: Style.space(4)
                        text: "LAST 7 DAYS"
                        color: root.foreground
                        opacity: 0.5
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 0.8
                    }

                    Repeater {
                        model: root.recentDays

                        ConsumRow {
                            required property var modelData

                            period: modelData.label + (modelData.batteryEstimated ? "*" : "")
                            system: Model.formatWh(modelData.systemWh)
                            cost: Model.formatCurrency(modelData.cost)
                            used: Model.formatWh(modelData.drainedWh)
                            charged: Model.formatWh(modelData.chargedWh)
                        }
                    }

                    Text {
                        width: parent.width
                        text: {
                            if (root.historyError)
                                return root.historyError;

                            var tariff = "Zhuhai \u00b7 " + Model.zhuhaiSeasonLabel(new Date()) + " tier " + root.tariffTier + " \u00b7 " + Model.formatRate(root.tariffMarginalRate);
                            return tariff + " \u00b7 device estimate" + (root.monthlyBaselineKWh > 0 ? " \u00b7 baseline " + root.monthlyBaselineKWh.toFixed(1) + " kWh" : "") + "\n* recovered from UPower; system energy unavailable";
                        }
                        color: root.historyError ? Color.urgent : root.foreground
                        opacity: root.historyError ? 1 : 0.55
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                }

                // ---------- Work mode: machine power profile picker ----------
                PanelSeparator {
                    foreground: root.foreground
                }

                Column {
                    width: parent.width
                    spacing: Style.space(10)

                    PanelSectionHeader {
                        text: "WORK MODE"
                        foreground: root.foreground
                        fontFamily: root.bar.fontFamily
                    }

                    Row {
                        id: profileRow

                        readonly property real cellWidth: root.profiles.length > 0 ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length : 0

                        width: parent.width
                        spacing: Style.space(6)

                        Repeater {
                            model: root.profiles

                            Button {
                                required property var modelData
                                required property int index

                                width: profileRow.cellWidth
                                iconText: root.profileIcon(String(modelData))
                                iconSize: Style.font.title
                                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                                fontSize: Style.font.bodySmall
                                foreground: root.foreground
                                fontFamily: root.bar.fontFamily
                                horizontalPadding: Style.spacing.controlPaddingX
                                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                                bordered: true
                                active: root.activeProfile === modelData
                                hasCursor: root.cursorActive && root.profileIndex === index
                                onClicked: root.setProfile(modelData)
                                onHovered: function(h) {
                                    if (h) {
                                        root.cursorActive = true;
                                        root.profileIndex = index;
                                    }
                                }
                            }

                        }

                    }

                }

            }

        }

    }

    component InfoPair: Row {
        property string label: ""
        property string value: ""

        width: parent.width
        spacing: Style.space(8)

        InfoLabel {
            text: label
        }

        Item {
            width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
            height: 1
        }

        InfoValue {
            text: value
        }

    }

    component InfoLabel: Text {
        color: root.foreground
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
    }

    component InfoValue: Text {
        color: root.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
    }

    component ConsumHeader: Text {
        color: root.foreground
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignRight
    }

    component ConsumRow: Row {
        property string period: ""
        property string system: ""
        property string cost: ""
        property string used: ""
        property string charged: ""
        readonly property real cellW: (width - Style.space(48) - spacing * 4) / 4

        width: parent.width
        spacing: Style.space(8)

        ConsumPeriod {
            text: period
        }

        ConsumValue {
            width: cellW
            text: system
        }

        ConsumValue {
            width: cellW
            text: cost
        }

        ConsumValue {
            width: cellW
            text: used
        }

        ConsumValue {
            width: cellW
            text: charged
        }

    }

    component ConsumPeriod: Text {
        width: Style.space(48)
        color: root.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
    }

    component ConsumValue: Text {
        color: root.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignRight
    }

}
