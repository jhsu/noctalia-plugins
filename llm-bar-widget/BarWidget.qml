import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.System
import qs.Services.UI
import qs.Widgets

Item {
    id: root

    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""
    property int sectionWidgetIndex: -1
    property int sectionWidgetsCount: 0

    readonly property string screenName: screen?.name ?? ""
    readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
    readonly property bool isBarVertical: barPosition === "left" || barPosition === "right"
    readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
    readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)
    readonly property int refreshIntervalMs: pluginApi?.pluginSettings?.refreshIntervalMs
        || pluginApi?.manifest?.metadata?.defaultSettings?.refreshIntervalMs
        || 900000
    readonly property string codexHome: pluginApi?.pluginSettings?.codexHome
        || pluginApi?.manifest?.metadata?.defaultSettings?.codexHome
        || ""
    readonly property real contentWidth: isBarVertical ? capsuleHeight : content.implicitWidth + Style.marginM * 2
    readonly property real contentHeight: isBarVertical ? content.implicitHeight + Style.marginM * 2 : capsuleHeight

    property bool loading: false
    property int availableCount: -1
    property string statusText: "..."
    property string detailText: "Loading Codex usage limits..."
    property string errorText: ""
    property string nextResetText: ""
    property string usagePercentText: ""
    property string lastUpdatedText: ""

    implicitWidth: contentWidth
    implicitHeight: contentHeight

    function formatStatus(data) {
        if (!data.ok) {
            availableCount = -1
            statusText = "!"
            errorText = data.error || "Unable to fetch Codex limits"
            detailText = errorText
            nextResetText = ""
            usagePercentText = ""
            lastUpdatedText = data.retrieved_at || ""
            return
        }

        availableCount = Number(data.available_count || 0)
        usagePercentText = data.usage_percent_text || ""
        statusText = usagePercentText.length > 0 ? usagePercentText : availableCount.toString()
        errorText = ""
        nextResetText = data.next_limit_reset_relative || ""
        lastUpdatedText = data.retrieved_at || ""

        var lines = [
            "Codex usage: " + (usagePercentText.length > 0 ? usagePercentText : "unknown"),
            "Codex reset credits: " + availableCount,
            "Credits returned: " + Number(data.credits_returned || 0)
        ]
        if (nextResetText.length > 0)
            lines.push("Next limit reset: " + nextResetText)
        if (lastUpdatedText.length > 0)
            lines.push("Updated: " + lastUpdatedText)
        detailText = lines.join("\n")
    }

    function refresh() {
        if (fetchProcess.running)
            return

        loading = true
        fetchProcess.exec({
            command: ["python3", "-c", pythonScript, codexHome]
        })
    }

    readonly property string pythonScript: `
import json, os, sys, urllib.request, urllib.error
from datetime import datetime, timezone
from pathlib import Path

API_BASE = "https://chatgpt.com/backend-api"
ORIGINATOR = "Codex Desktop"
USER_AGENT = "noctalia-codex-usage-widget/1.0"

def emit(payload):
    print(json.dumps(payload, separators=(",", ":")))

def duration(seconds):
    seconds = int(max(0, seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    if days:
        return f"in {days}d {hours}h"
    if hours:
        return f"in {hours}h {minutes}m"
    return f"in {minutes}m"

def fetch_json(path, access_token, account_id):
    req = urllib.request.Request(
        API_BASE + path,
        headers={
            "Authorization": "Bearer " + access_token,
            "ChatGPT-Account-ID": account_id,
            "originator": ORIGINATOR,
            "User-Agent": USER_AGENT,
        },
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.loads(response.read().decode("utf-8", "replace"))

def reset_candidates_from_window(window):
    if not isinstance(window, dict):
        return []
    out = []
    if isinstance(window.get("reset_after_seconds"), (int, float)):
        out.append((float(window["reset_after_seconds"]), "window"))
    reset_at = window.get("reset_at")
    if isinstance(reset_at, (int, float)):
        value = float(reset_at)
        if value > 10000000000:
            value = value / 1000
        out.append((value - datetime.now(timezone.utc).timestamp(), "window"))
    return out

def collect_limit_resets(usage):
    candidates = []
    rate_limit = usage.get("rate_limit") if isinstance(usage, dict) else None
    if isinstance(rate_limit, dict):
        candidates += reset_candidates_from_window(rate_limit.get("primary_window"))
        candidates += reset_candidates_from_window(rate_limit.get("secondary_window"))

    additional = usage.get("additional_rate_limits") if isinstance(usage, dict) else None
    if isinstance(additional, list):
        for item in additional:
            limit = item.get("rate_limit") if isinstance(item, dict) else None
            if isinstance(limit, dict):
                candidates += reset_candidates_from_window(limit.get("primary_window"))
                candidates += reset_candidates_from_window(limit.get("secondary_window"))

    return sorted(seconds for seconds, _ in candidates if seconds >= 0)

def primary_used_percent(usage):
    rate_limit = usage.get("rate_limit") if isinstance(usage, dict) else None
    if isinstance(rate_limit, dict):
        window = rate_limit.get("primary_window")
        if isinstance(window, dict) and isinstance(window.get("used_percent"), (int, float)):
            return float(window["used_percent"])

    return None

codex_home_arg = sys.argv[1] if len(sys.argv) > 1 else ""
codex_home = Path(codex_home_arg).expanduser() if codex_home_arg else Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
auth_path = codex_home / "auth.json"

try:
    auth = json.loads(auth_path.read_text(encoding="utf-8"))
    tokens = auth.get("tokens") or {}
    access_token = tokens.get("access_token")
    account_id = tokens.get("account_id")
    if not access_token or not account_id:
        raise RuntimeError("Missing tokens.access_token or tokens.account_id")

    data = fetch_json("/wham/rate-limit-reset-credits", access_token, account_id)
    usage = fetch_json("/wham/usage", access_token, account_id)

    credits = [c for c in data.get("credits", []) if isinstance(c, dict)]
    now = datetime.now(timezone.utc)
    available = [c for c in credits if c.get("status") == "available"]
    expiries = []
    for credit in available:
        raw = credit.get("expires_at")
        if not raw:
            continue
        try:
            expiries.append(datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc))
        except ValueError:
            pass
    expiries.sort()
    next_expiry = expiries[0] if expiries else None
    limit_resets = collect_limit_resets(usage)
    next_limit_reset_seconds = limit_resets[0] if limit_resets else None
    usage_percent = primary_used_percent(usage)

    emit({
        "ok": True,
        "available_count": data.get("available_count", len(available)),
        "credits_returned": len(credits),
        "total_earned_count": data.get("total_earned_count"),
        "usage_percent": usage_percent,
        "usage_percent_text": f"{usage_percent:.0f}%" if usage_percent is not None else "",
        "next_limit_reset_relative": duration(next_limit_reset_seconds) if next_limit_reset_seconds is not None else "",
        "next_expiry_relative": duration((next_expiry - now).total_seconds()) if next_expiry else "",
        "next_expiry_local": next_expiry.astimezone().strftime("%Y-%m-%d %H:%M %Z") if next_expiry else "",
        "retrieved_at": datetime.now().astimezone().strftime("%H:%M"),
    })
except FileNotFoundError:
    emit({"ok": False, "error": "Codex auth not found at " + str(auth_path), "retrieved_at": datetime.now().astimezone().strftime("%H:%M")})
except urllib.error.HTTPError as exc:
    emit({"ok": False, "error": "Codex usage endpoint returned HTTP " + str(exc.code), "retrieved_at": datetime.now().astimezone().strftime("%H:%M")})
except Exception as exc:
    emit({"ok": False, "error": str(exc), "retrieved_at": datetime.now().astimezone().strftime("%H:%M")})
`

    Rectangle {
        id: visualCapsule
        x: Style.pixelAlignCenter(parent.width, width)
        y: Style.pixelAlignCenter(parent.height, height)
        width: root.contentWidth
        height: root.contentHeight
        color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
        radius: Style.radiusL
        border.color: Style.capsuleBorderColor
        border.width: Style.capsuleBorderWidth

        RowLayout {
            id: content
            anchors.centerIn: parent
            spacing: Style.marginS

            NIcon {
                icon: root.errorText.length > 0 ? "alert-circle" : "terminal-2"
                color: root.errorText.length > 0 ? Color.mError : Color.mPrimary
                pointSize: root.barFontSize
                applyUiScale: true
            }

            NText {
                text: root.loading ? "..." : root.statusText
                color: root.errorText.length > 0 ? Color.mError : Color.mOnSurface
                pointSize: root.barFontSize
                font.weight: Font.Bold
            }

            NText {
                visible: !root.isBarVertical && root.nextResetText.length > 0 && root.errorText.length === 0
                text: root.nextResetText
                color: Color.mOnSurfaceVariant
                pointSize: root.barFontSize
            }

            NText {
                visible: !root.isBarVertical && root.errorText.length === 0 && root.availableCount >= 0
                text: root.availableCount + " resets"
                color: Color.mOnSurfaceVariant
                pointSize: root.barFontSize
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor

        onClicked: root.refresh()
        onEntered: TooltipService.show(root, root.detailText, BarService.getTooltipDirection())
        onExited: TooltipService.hide()
    }

    Process {
        id: fetchProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.formatStatus(JSON.parse(text.trim()))
                } catch (error) {
                    root.formatStatus({"ok": false, "error": "Invalid Codex usage response"})
                }
            }
        }

        stderr: StdioCollector {}

        onExited: {
            root.loading = false
            if (mouseArea.containsMouse)
                TooltipService.show(root, root.detailText, BarService.getTooltipDirection())
        }
    }

    Timer {
        interval: root.refreshIntervalMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
