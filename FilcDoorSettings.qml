import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "filcDoor"

    property var targets: []
    property int targetsVersion: 0
    property bool isFetching: false
    property string fetchStatus: ""
    property bool apiKeyExists: false
    property int refreshAttempts: 0

    // Binding hook so the door dropdown re-renders when either the list or its
    // version counter changes.
    readonly property var selectionOptions: {
        root.targetsVersion;
        return root.targets;
    }

    Component.onCompleted: {
        refreshTimer.start();
    }

    // Retry until pluginService is injected (it lands one tick after load).
    Timer {
        id: refreshTimer
        interval: 250
        repeat: true
        onTriggered: {
            if (root.refreshState() || root.refreshAttempts >= 20) {
                refreshTimer.stop();
                root.refreshAttempts = 0;
            } else {
                root.refreshAttempts += 1;
            }
        }
    }

    function refreshState() {
        if (!root.pluginService)
            return false;
        root.apiKeyExists = root.loadValue("apiKey", "") !== "";
        const saved = root.loadValue("targets", []);
        root.targets = Array.isArray(saved) ? saved : [];
        return true;
    }

    // ---- Fetch doors (env-based curl; token never in argv) ----
    property int _fetchExit: -1
    property bool _fetchBodyReady: false
    property string _fetchBody: ""

    readonly property string listScript: `curl -sS -m 10 -H "Authorization: Bearer $FILC_TOKEN" -w "\\n%{http_code}" "$FILC_URL/api/doorlock/self/cards"`

    Process {
        id: fetchProcess
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                root._fetchBody = text;
                root._fetchBodyReady = true;
                root.finalizeFetch();
            }
        }

        stderr: StdioCollector {}

        onExited: exitCode => {
            root._fetchExit = exitCode;
            root.finalizeFetch();
        }
    }

    // Stuck-fetch watchdog: if onExited never fires, force-reset the UI.
    Timer {
        id: fetchWatchdog
        interval: 12000
        repeat: false
        onTriggered: {
            if (!root.isFetching)
                return;
            root.isFetching = false;
            root._fetchExit = -1;
            root._fetchBodyReady = false;
            root._fetchBody = "";
            root.fetchStatus = "Request timed out";
        }
    }

    function fetchDoors() {
        if (root.isFetching)
            return;
        const key = root.loadValue("apiKey", "");
        if (!key) {
            root.fetchStatus = "Set the API key first";
            ToastService.showWarning("filc Door", "Set the API key first");
            return;
        }
        const base = root.loadValue("baseUrl", "https://filc.petrik.hu");
        root.isFetching = true;
        root.fetchStatus = "Fetching…";

        root._fetchExit = -1;
        root._fetchBodyReady = false;
        root._fetchBody = "";
        fetchProcess.environment = ({
            "FILC_TOKEN": key,
            "FILC_URL": base
        });
        fetchProcess.command = ["sh", "-c", root.listScript];
        fetchProcess.running = true;
        fetchWatchdog.restart();
    }

    function finalizeFetch() {
        if (root._fetchExit === -1 || !root._fetchBodyReady)
            return;

        const exitCode = root._fetchExit;
        let body = root._fetchBody;
        root._fetchExit = -1;
        root._fetchBodyReady = false;
        root._fetchBody = "";
        root.isFetching = false;
        fetchWatchdog.stop();

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
        try {
            parsed = JSON.parse(body);
        } catch (e) {
            parsed = null;
        }

        if (exitCode !== 0) {
            root.fetchStatus = exitCode === 28 ? "Request timed out" : "Request failed (exit " + exitCode + ")";
            return;
        }

        const statusOk = (httpStatus >= 200 && httpStatus < 300);

        // Non-2xx: interpret the error body.
        if (httpStatus !== -1 && !statusOk) {
            if (parsed && parsed.code) {
                root.fetchStatus = parsed.code + (parsed.message ? ": " + parsed.message : "");
            } else {
                root.fetchStatus = "HTTP " + httpStatus;
            }
            return;
        }

        // Status unreadable → fall back to the old body-shape behaviour.
        if (httpStatus === -1 && parsed && parsed.code) {
            root.fetchStatus = parsed.code + (parsed.message ? ": " + parsed.message : "");
            return;
        }

        // 2xx (or unreadable with no error code): success. A 2xx with an
        // empty/HTML body is an empty list, not an error.
        const items = (parsed && Array.isArray(parsed.items)) ? parsed.items : [];
        const flat = [];
        for (let i = 0; i < items.length; i++) {
            const card = items[i];
            const devices = (card && card.authorizedDevices) || [];
            for (let j = 0; j < devices.length; j++) {
                const dev = devices[j];
                if (!dev)
                    continue;
                flat.push({
                    "label": ((card && card.name) || (card && card.id) || "?") + " → " + (dev.name || dev.id || "?"),
                    "value": ((card && card.id) || "") + "|" + (dev.id || "")
                });
            }
        }

        root.targets = flat;
        root.targetsVersion += 1;
        root.saveValue("targets", flat);
        root.fetchStatus = "Found " + flat.length + " door" + (flat.length === 1 ? "" : "s");

        const cur = root.loadValue("target", "");
        if (cur !== "") {
            // Revalidate: the saved target may have been deauthorized/removed.
            let stillValid = false;
            for (let k = 0; k < flat.length; k++) {
                if (flat[k].value === cur) {
                    stillValid = true;
                    break;
                }
            }
            if (!stillValid) {
                root.saveValue("target", "");
                root.targetsVersion += 1;
                root.fetchStatus = "Previously selected door is no longer available — pick another.";
            }
        } else if (flat.length === 1) {
            // Auto-select the only door if nothing is chosen yet.
            root.saveValue("target", flat[0].value);
            root.targetsVersion += 1;
        }
    }

    // ---- UI ----

    StyledText {
        width: parent.width
        text: "filc Door"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Open a school door through the filc API. The API key is stored in plaintext in ~/.config/dms/plugin_settings.json. Opening only queues an unlock message for the reader."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "baseUrl"
        label: "Base URL"
        description: "The filc API base URL"
        placeholder: "https://filc.petrik.hu"
        defaultValue: "https://filc.petrik.hu"
    }

    StyledText {
        text: "API key"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
        width: parent.width
    }

    DTextField {
        id: apiKeyField
        width: parent.width
        placeholderText: root.apiKeyExists ? "•••••••• (saved)" : "Paste your filc API key"
        echoMode: TextInput.Password
        showPasswordToggle: true
        onEditingFinished: {
            if (text !== "") {
                root.saveValue("apiKey", text);
                root.apiKeyExists = true;
            }
        }
    }

    DButton {
        text: "Fetch doors"
        iconName: "refresh"
        busy: root.isFetching
        enabled: !root.isFetching
        onClicked: root.fetchDoors()
    }

    StyledText {
        text: root.fetchStatus
        visible: root.fetchStatus !== ""
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        width: parent.width
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        id: targetSelect
        settingKey: "target"
        label: "Door"
        description: "The card and device to open"
        options: root.selectionOptions
        defaultValue: ""
    }

    StyledText {
        text: "The list is empty until you set the API key and press \"Fetch doors\"."
        visible: root.targets.length === 0
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        width: parent.width
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "showLabel"
        label: "Show label text in the bar"
        defaultValue: false
    }

    StringSetting {
        settingKey: "label"
        label: "Label"
        placeholder: "Door"
        defaultValue: ""
    }

    StyledText {
        text: targetSelect.value !== "" ? "Selected target: " + targetSelect.value : "No door selected yet."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        width: parent.width
        wrapMode: Text.WordWrap
    }
}
