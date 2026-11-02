import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ---- Settings (read via injected pluginData, refreshed by the host) ----
    readonly property string baseUrl: (pluginData.baseUrl !== undefined && pluginData.baseUrl !== "")
        ? pluginData.baseUrl : "https://filc.petrik.hu"
    readonly property string apiKey: pluginData.apiKey || ""
    readonly property string target: pluginData.target || ""
    readonly property string label: pluginData.label || ""
    readonly property bool showLabel: pluginData.showLabel === true

    // ---- Derived ----
    readonly property string cardId: {
        const t = root.target || "";
        const i = t.indexOf("|");
        return i < 0 ? t : t.substring(0, i);
    }
    readonly property string deviceId: {
        const t = root.target || "";
        const i = t.indexOf("|");
        return i < 0 ? "" : t.substring(i + 1);
    }
    readonly property bool configComplete: root.baseUrl !== "" && root.apiKey !== "" && root.cardId !== ""

    // Friendly "<card> → <device>" name if the settings saved a targets list.
    readonly property string doorName: {
        const t = root.target || "";
        const targets = pluginData.targets;
        if (Array.isArray(targets)) {
            for (let i = 0; i < targets.length; i++) {
                const o = targets[i];
                if (o && o.value === t)
                    return o.label || t;
            }
        }
        return t;
    }

    // ---- State ----
    property bool busy: false
    property bool error: false
    property real openCooldownUntil: 0
    property real pulse: 1.0

    readonly property color stateColor: {
        if (!root.configComplete) return Theme.surfaceVariantText;
        if (root.error) return Theme.error;
        if (root.busy) return Theme.surfaceVariantText;
        return Theme.primary;
    }

    readonly property string statusLine: {
        if (root.busy) return "Request in flight…";
        if (root.error) return "Last request failed";
        if (!root.configComplete) return "Not configured — open Settings → Plugins";
        return "Idle";
    }

    // ---- Constant curl script. All dynamic values arrive via environment ----
    // (the API key must never appear in an argument vector).
    readonly property string openScript: `curl -sS -m 10 -X POST -H "Authorization: Bearer $FILC_TOKEN" -H "Content-Type: application/json" --data "$FILC_BODY" -w "\\n%{http_code}" "$FILC_URL/api/doorlock/self/cards/$FILC_CARD/activate"`

    // ---- Request process (single instance, re-armed per click) ----
    property int _pendingExit: -1
    property bool _bodyReady: false
    property string _body: ""

    Process {
        id: doorProcess
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                root._body = text;
                root._bodyReady = true;
                root.finalizeDoor();
            }
        }

        stderr: StdioCollector {}

        onExited: exitCode => {
            root._pendingExit = exitCode;
            root.finalizeDoor();
        }
    }

    function openDoor() {
        if (root.busy)
            return;
        if (!root.configComplete) {
            ToastService.showWarning("filc Door", "Configure the widget in Settings → Plugins");
            return;
        }
        const now = Date.now();
        if (now < root.openCooldownUntil) {
            const remaining = Math.ceil((root.openCooldownUntil - now) / 1000);
            ToastService.showWarning("filc Door", "Please wait " + remaining + "s");
            return;
        }
        root.openCooldownUntil = now + 3000;

        root.busy = true;
        root.error = false;

        // Body may only be {} when the card has exactly one authorized device.
        const body = root.deviceId !== "" ? JSON.stringify({ "deviceId": root.deviceId }) : "{}";

        // Clear the stale request flags so a late exit from a previous run
        // cannot be mistaken for this one.
        root._pendingExit = -1;
        root._bodyReady = false;
        root._body = "";
        doorProcess.environment = ({
            "FILC_TOKEN": root.apiKey,
            "FILC_URL": root.baseUrl,
            "FILC_CARD": root.cardId,
            "FILC_BODY": body
        });
        doorProcess.command = ["sh", "-c", root.openScript];
        doorProcess.running = true;
        busyWatchdog.restart();
    }

    function finalizeDoor() {
        // Wait for BOTH the exit code and the drained stdout before handling.
        if (root._pendingExit === -1 || !root._bodyReady)
            return;

        const exitCode = root._pendingExit;
        let body = root._body;
        root._pendingExit = -1;
        root._bodyReady = false;
        root._body = "";
        root.busy = false;
        busyWatchdog.stop();

        // Split off the trailing HTTP status line appended by curl -w.
        let httpStatus = -1;
        const nl = body.lastIndexOf("\n");
        if (nl >= 0) {
            const tail = body.substring(nl + 1).trim();
            if (/^\d{3}$/.test(tail)) {
                httpStatus = parseInt(tail, 10);
                body = body.substring(0, nl);
            }
        }

        let parsed = null;
        let isJson = false;
        try {
            parsed = JSON.parse(body);
            isJson = (parsed && typeof parsed === "object");
        } catch (e) {
            isJson = false;
        }

        const statusReadable = (httpStatus !== -1);
        const statusOk = (httpStatus >= 200 && httpStatus < 300);

        // Success = HTTP 2xx (or, when the status line is unreadable, the old
        // body-shape check: JSON without a `code` field). A 2xx with an
        // empty/HTML body is success, not an error.
        const success = statusReadable
            ? (exitCode === 0 && statusOk)
            : (exitCode === 0 && isJson && parsed.code === undefined);

        if (success) {
            root.error = false;
            errorClearTimer.stop();
            ToastService.showInfo("Door request sent", root.doorName);
            return;
        }

        root.error = true;
        errorClearTimer.restart();

        let detail = "";
        if (exitCode === 28) {
            detail = "Request timed out";
        } else if (exitCode !== 0) {
            detail = "curl error (exit " + exitCode + ")";
        } else if (isJson && parsed.code !== undefined) {
            detail = (parsed.code || "UNKNOWN") + (parsed.message ? ": " + parsed.message : "");
            const s = (parsed.status !== undefined && parsed.status !== "") ? parsed.status : (statusReadable ? httpStatus : "");
            if (s !== "")
                detail += " (HTTP " + s + ")";
        } else if (statusReadable) {
            detail = "HTTP " + httpStatus;
        } else {
            detail = "Unexpected response from server";
        }
        ToastService.showError("Door request failed", detail);
    }

    Timer {
        id: errorClearTimer
        interval: 4000
        repeat: false
        onTriggered: root.error = false
    }

    // Stuck-busy watchdog: if the process never signals onExited (e.g. sh
    // failed to start), force-reset so the widget can be clicked again.
    Timer {
        id: busyWatchdog
        interval: 12000
        repeat: false
        onTriggered: {
            if (!root.busy)
                return;
            root.busy = false;
            root._pendingExit = -1;
            root._bodyReady = false;
            root._body = "";
            root.error = true;
            errorClearTimer.restart();
            ToastService.showError("Door request failed", "Request timed out");
        }
    }

    SequentialAnimation {
        id: busyPulse
        running: root.busy
        loops: Animation.Infinite
        NumberAnimation { target: root; property: "pulse"; from: 1.0; to: 0.45; duration: 500; easing.type: Easing.InOutQuad }
        NumberAnimation { target: root; property: "pulse"; from: 0.45; to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
    }

    pillClickAction: () => {
        root.openDoor();
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: "door_open"
                filled: true
                size: root.iconSize
                color: root.stateColor
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.busy ? root.pulse : 1.0
            }

            StyledText {
                text: root.label
                visible: root.showLabel && root.label !== ""
                color: root.stateColor
                font.pixelSize: root.textSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DIcon {
                name: "door_open"
                filled: true
                size: root.iconSize
                color: root.stateColor
                anchors.horizontalCenter: parent.horizontalCenter
                opacity: root.busy ? root.pulse : 1.0
            }

            StyledText {
                text: root.label
                visible: root.showLabel && root.label !== ""
                color: root.stateColor
                font.pixelSize: root.textSize
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    popoutWidth: 320

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "filc Door"
            detailsText: root.configComplete ? "Queue an unlock for the configured door" : "Not configured yet"

            Column {
                width: parent.width
                spacing: Theme.spacingM

                StyledText {
                    text: root.doorName
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Theme.fontWeightMedium
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    text: root.statusLine
                    color: root.error ? Theme.error : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                Row {
                    spacing: Theme.spacingM

                    DButton {
                        text: "Open door"
                        iconName: "door_open"
                        busy: root.busy
                        enabled: root.configComplete && !root.busy
                        onClicked: root.openDoor()
                    }

                    DButton {
                        text: "Close"
                        onClicked: {
                            if (typeof popout.closePopout === "function")
                                popout.closePopout();
                        }
                    }
                }
            }
        }
    }
}
