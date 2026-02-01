import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
    id: root

    // Required properties
    property var pluginApi: null
    property var launcher: null
    property string name: "Personal provider"

    // Window data cache
    property var windows: []
    property bool windowsLoaded: false
    property string _windowsOutput: ""

    // Process to fetch windows from niri
    Process {
        id: niriWindowsProc
        command: ["niri", "msg", "-j", "windows"]
        onStarted: {
            _windowsOutput = "";
        }
        onStdout: data => {
            _windowsOutput += data;
        }
        onExited: code => {
            if (code !== 0) {
                Logger.e("NiriFocus", "Failed to fetch windows, exit code: " + code);
                windows = [];
                windowsLoaded = true;
                return;
            }
            try {
                var data = JSON.parse(_windowsOutput);
                windows = data || [];
                windowsLoaded = true;
                Logger.i("NiriFocus", "Loaded " + windows.length + " windows");
                if (launcher) {
                    launcher.updateResults();
                }
            } catch (e) {
                Logger.e("NiriFocus", "Failed to parse windows JSON: " + e + " Output: " + _windowsOutput.substring(0, 100));
                windows = [];
                windowsLoaded = true;
            }
        }
    }

    // Check if this provider handles the command
    function handleCommand(searchText) {
        return searchText.startsWith(">win");
    }

    // Return available commands when user types ">"
    function commands() {
        return [
            {
                "name": ">win",
                "description": "Focus niri window",
                "icon": "app-window",
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
        windowsLoaded = false;
    }

    // Get search results
    function getResults(searchText) {
        if (searchText.startsWith(">win")) {
            // Fetch windows if not already loaded or loading
            if (!windowsLoaded && !niriWindowsProc.running) {
                refreshWindows();
            }
            return getWindowResults(searchText);
        }

        return [];
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

        if (!windowsLoaded) {
            return [
                {
                    "name": "Loading windows...",
                    "description": "Fetching window list from niri",
                    "icon": "refresh",
                    "isTablerIcon": true,
                    "onActivate": function () {}
                }
            ];
        }

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
