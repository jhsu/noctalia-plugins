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
    readonly property string codexExecutable: pluginApi?.pluginSettings?.codexExecutable
        || pluginApi?.manifest?.metadata?.defaultSettings?.codexExecutable
        || "codex"
    readonly property string helperPath: decodeURIComponent(
        Qt.resolvedUrl("codex_usage.py").toString().replace(/^file:\/\//, "")
    )
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
            command: ["python3", helperPath, codexHome, codexExecutable]
        })
    }

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
