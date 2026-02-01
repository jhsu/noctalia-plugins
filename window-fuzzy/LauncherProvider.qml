import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
    id: root

    // Required properties
    property var pluginApi: null

    property string name: "Window Fuzzy Provider"
    property var launcher: null
    property string supportedLayouts: "list"

    property string selectedCategory: "all"

    // optional
    property string emptyBrowsingMessage: "No windows found"

    // Window data cache
    property var windows: []
    property bool windowsLoaded: false
    property string _windowsOutput: ""

    // Process to fetch windows from niri
    Process {
        id: niriWindowsProc
        running: false
        command: ["niri", "msg", "-j", "windows"]
        stdout: StdioCollector { id: windowsStdout }
        onExited: (exitCode, exitStatus) => {
            Logger.i("NiriFocus: Finished fetching windows, exit code: " + exitCode + ", exit status: " + exitStatus);
            if (exitCode !== 0) {
                Logger.e("NiriFocus: Failed to fetch windows, exit code: " + exitCode);
                root.windows = [];
                root.windowsLoaded = true;
                return;
            }
            try {
                var data = JSON.parse(windowsStdout.text.trim());
                root.windows = data || [];
                root.windowsLoaded = true;
                Logger.i("NiriFocus: Loaded " + root.windows.length + " windows");
                if (root.launcher) {
                    root.launcher.updateResults();
                }
            } catch (e) {
                Logger.e("NiriFocus: Failed to parse windows JSON: " + e + " Output: " + root._windowsOutput.substring(0, 100));
                root.windows = [];
                root.windowsLoaded = true;
            }
        }
    }

    function init() {
        Logger.i("WindowFuzzy", "Initialized");
    }

    // Check if this provider handles the command
    function handleCommand(searchText) {
        return searchText.startsWith(">win");
    }

    // Show in regular search results
    // function handleSearch(searchText) {
    // }

    // Return available commands when user types ">"
    function commands() {
        return [
            {
                "name": ">win",
                "description": "Focus niri window",
                "icon": "search",
                "isTablerIcon": true,
                "onActivate": function () {
                    launcher.setSearchText(">win ");
                    refreshWindows();
                }
            }
        ];
    }

    // Refresh the window list
    function refreshWindows() {
        windowsLoaded = false;
        niriWindowsProc.running = true;
    }

    // Called when launcher is opened
    function onOpened() {
        windows = [];
        refreshWindows();
    }

    // Get search results
    function getResults(searchText) {
        if (!searchText.startsWith(">win")) {
            return [];
        }

        // if loading
        if (niriWindowsProc.running) {
            return [
                {
                    name: "Loading...",
                    icon: "refresh",
                    isTablerIcon: true,
                    "isImage": false,
                    onActivate: function () {}
                }
            ];
        }
        //
        // if not loaded
        if (!windowsLoaded) {
            return [
                {
                    name: "Windows not loaded",
                    description: "Try reopening the launcher",
                    icon: "alert-circle",
                    isTablerIcon: true,
                    onActivate: function () {
                        root.init();
                    }
                }
            ];
        }
        var query = searchText.slice(4).trim().toLowerCase();

        return getWindowResults(query);
    }

    // Simple fuzzy search - checks if all chars in needle appear in order in haystack
    function fuzzyMatch(needle, haystack) {
        if (needle === "")
            return true;
        needle = needle.toLowerCase();
        haystack = haystack.toLowerCase();
        var j = 0;
        for (var i = 0; i < haystack.length && j < needle.length; i++) {
            if (haystack[i] === needle[j])
                j++;
        }
        return j === needle.length;
    }

    // Get window focus results
    function getWindowResults(searchText) {
        var query = searchText.slice(4).trim();

        var results = [];
        for (var i = 0; i < windows.length; i++) {
            var w = windows[i];
            var displayText = "[" + (w.app_id || "unknown") + "] " + (w.title || "Untitled");
            var searchStr = (w.app_id || "") + " " + (w.title || "");

            if (query === "" || fuzzyMatch(query, searchStr)) {
                results.push({
                    "name": displayText,
                    "description": "Focus this window",
                    "icon": "app-window",
                    "isTablerIcon": true,
                    "windowId": w.id,
                    "onActivate": function (windowId) {
                        return function () {
                            Quickshell.execDetached(["niri", "msg", "action", "focus-window", "--id", String(windowId)]);
                            launcher.close();
                        };
                    }(w.id)
                });
            }
        }

        if (results.length === 0) {
            results.push({
                "name": "No windows found",
                "description": "Try a different search term",
                "icon": "search-off",
                "isTablerIcon": true,
                "onActivate": function () {}
            });
        }

        return results;
    }
}
