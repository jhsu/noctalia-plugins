import QtQuick
import Quickshell.Io
import qs.Services.UI

Item {
    property var pluginApi: null

    IpcHandler {
        target: "plugin:window-fuzzy"
        function toggle(language: string, text: string) {
            pluginApi.withCurrentScreen(screen => {
                var launcherPanel = PanelService.getPanel("launcherPanel", screen);
                if (!launcherPanel)
                    return;

                var searchText = launcherPanel.searchText || "";
                var isInWindowSearchMode = searchText.startsWith(">win");

                if (!launcherPanel.isPanelOpen) {
                    launcherPanel.open();
                    launcherPanel.setSearchText(">win ");
                } else if (isInWindowSearchMode) {
                    launcherPanel.close();
                } else {
                    launcherPanel.setSearchText(">win ");
                }
            });
        }
    }
}
