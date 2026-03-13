import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
    id: root

    property var pluginApi: null

    property string name: "Notifications Provider"
    property var launcher: null
    property string supportedLayouts: "list"
    property string emptyBrowsingMessage: "No notifications found"

    property var notifications: []
    property bool notificationsLoaded: false
    property string pendingFocusAppName: ""

    Process {
        id: notificationsProc
        running: false
        command: ["qs", "-c", "noctalia-shell", "ipc", "call", "notifications", "getHistory"]
        stdout: StdioCollector { id: notificationsStdout }

        onExited: (exitCode, exitStatus) => {
            Logger.i("LauncherNotifications", "Finished fetching notifications, exit code: " + exitCode + ", exit status: " + exitStatus);

            if (exitCode !== 0) {
                Logger.e("LauncherNotifications", "Failed to fetch notifications");
                root.notifications = [];
                root.notificationsLoaded = true;
                if (root.launcher)
                    root.launcher.updateResults();
                return;
            }

            try {
                var data = JSON.parse(notificationsStdout.text.trim());
                root.notifications = Array.isArray(data) ? data : [];
                root.notificationsLoaded = true;
                if (root.launcher)
                    root.launcher.updateResults();
            } catch (e) {
                Logger.e("LauncherNotifications", "Failed to parse notifications JSON: " + e);
                root.notifications = [];
                root.notificationsLoaded = true;
                if (root.launcher)
                    root.launcher.updateResults();
            }
        }
    }

    Process {
        id: niriWindowsProc
        running: false
        command: ["niri", "msg", "-j", "windows"]
        stdout: StdioCollector { id: niriWindowsStdout }

        onExited: (exitCode, exitStatus) => {
            Logger.i("LauncherNotifications", "Finished fetching niri windows, exit code: " + exitCode + ", exit status: " + exitStatus);

            if (exitCode !== 0) {
                Logger.e("LauncherNotifications", "Failed to fetch niri windows for app: " + root.pendingFocusAppName);
                root.pendingFocusAppName = "";
                return;
            }

            try {
                var windows = JSON.parse(niriWindowsStdout.text.trim());
                var bestWindow = root.findBestWindowMatch(root.pendingFocusAppName, Array.isArray(windows) ? windows : []);
                if (bestWindow && bestWindow.id !== undefined && bestWindow.id !== null) {
                    Quickshell.execDetached(["niri", "msg", "action", "focus-window", "--id", String(bestWindow.id)]);
                } else {
                    Logger.i("LauncherNotifications", "No matching window found for app: " + root.pendingFocusAppName);
                }
            } catch (e) {
                Logger.e("LauncherNotifications", "Failed to parse niri windows JSON: " + e);
            }

            root.pendingFocusAppName = "";
        }
    }

    function init() {
        Logger.i("LauncherNotifications", "Initialized");
    }

    function handleCommand(searchText) {
        return searchText.startsWith(">notif");
    }

    function commands() {
        return [
            {
                "name": ">notif",
                "description": "Browse recent notifications",
                "icon": "bell",
                "isTablerIcon": true,
                "onActivate": function () {
                    launcher.setSearchText(">notif ");
                    refreshNotifications();
                }
            }
        ];
    }

    function refreshNotifications() {
        notificationsLoaded = false;
        notificationsProc.running = true;
    }

    function onOpened() {
        notifications = [];
        refreshNotifications();
    }

    function getResults(searchText) {
        if (!searchText.startsWith(">notif"))
            return [];

        if (notificationsProc.running) {
            return [
                {
                    "name": "Loading notifications...",
                    "icon": "refresh",
                    "isTablerIcon": true,
                    "onActivate": function () {}
                }
            ];
        }

        if (!notificationsLoaded) {
            return [
                {
                    "name": "Notifications not loaded",
                    "description": "Try reopening the launcher or refreshing",
                    "icon": "alert-circle",
                    "isTablerIcon": true,
                    "onActivate": function () {
                        refreshNotifications();
                    }
                }
            ];
        }

        var query = searchText.slice(6).trim().toLowerCase();
        return getNotificationResults(query);
    }

    function formatTimestamp(timestamp) {
        if (!timestamp)
            return "";

        var seconds = Math.floor((Date.now() - timestamp) / 1000);
        if (seconds < 60)
            return "just now";
        if (seconds < 3600)
            return Math.floor(seconds / 60) + "m ago";
        if (seconds < 86400)
            return Math.floor(seconds / 3600) + "h ago";
        return Math.floor(seconds / 86400) + "d ago";
    }

    function matchesQuery(query, notification) {
        if (query === "")
            return true;

        var haystack = [
            notification.summary || "",
            notification.body || "",
            notification.appName || ""
        ].join(" ").toLowerCase();

        return haystack.indexOf(query) !== -1;
    }

    function normalizeText(value) {
        return (value || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    }

    function fuzzyMatchScore(needle, haystack) {
        if (needle === "")
            return 0;

        needle = normalizeText(needle);
        haystack = normalizeText(haystack);

        if (needle === "" || haystack === "")
            return -1;
        if (haystack === needle)
            return -100;
        if (haystack.indexOf(needle) !== -1)
            return haystack.indexOf(needle) - 50;

        var score = 0;
        var j = 0;
        var lastMatchIndex = -1;

        for (var i = 0; i < haystack.length && j < needle.length; i++) {
            if (haystack[i] === needle[j]) {
                if (lastMatchIndex !== -1)
                    score += (i - lastMatchIndex - 1) * 10;
                else
                    score += i;

                if (i > 0 && haystack[i - 1] === " ")
                    score -= 5;

                lastMatchIndex = i;
                j++;
            }
        }

        return j === needle.length ? score : -1;
    }

    function findBestWindowMatch(appName, windows) {
        var normalizedAppName = normalizeText(appName);
        if (normalizedAppName === "")
            return null;

        var bestWindow = null;
        var bestScore = Number.MAX_VALUE;

        for (var i = 0; i < windows.length; i++) {
            var window = windows[i];
            var candidates = [
                window.app_id || "",
                window.title || "",
                (window.app_id || "") + " " + (window.title || "")
            ];

            for (var j = 0; j < candidates.length; j++) {
                var score = fuzzyMatchScore(normalizedAppName, candidates[j]);
                if (score !== -1 && score < bestScore) {
                    bestScore = score;
                    bestWindow = window;
                }
            }
        }

        return bestWindow;
    }

    function focusNotificationApp(appName) {
        if (!appName) {
            launcher.close();
            return;
        }

        pendingFocusAppName = appName;
        niriWindowsProc.running = true;
        launcher.close();
    }

    function getNotificationResults(query) {
        var results = [];

        for (var i = 0; i < notifications.length; i++) {
            var notification = notifications[i];
            if (!matchesQuery(query, notification))
                continue;

            var descriptionParts = [];
            if (notification.appName)
                descriptionParts.push(notification.appName);
            if (notification.timestamp)
                descriptionParts.push(formatTimestamp(notification.timestamp));
            if (notification.body)
                descriptionParts.push(notification.body.replace(/\s+/g, " ").trim());

            results.push({
                "name": notification.summary || notification.appName || "Notification",
                "description": descriptionParts.join(" • "),
                "icon": notification.cachedImage || notification.originalImage || "bell",
                "isImage": !!(notification.cachedImage || notification.originalImage),
                "isTablerIcon": !(notification.cachedImage || notification.originalImage),
                "onActivate": function (appName) {
                    return function () {
                        root.focusNotificationApp(appName);
                    };
                }(notification.appName || "")
            });
        }

        if (results.length === 0) {
            results.push({
                "name": "No notifications found",
                "description": query === "" ? "You have no notification history" : "Try a different search term",
                "icon": "search-off",
                "isTablerIcon": true,
                "onActivate": function () {}
            });
        }

        return results;
    }
}
