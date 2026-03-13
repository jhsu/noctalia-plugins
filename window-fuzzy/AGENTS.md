# AGENTS.md - Noctalia Plugin Development Guide

This is a Quickshell/QML plugin for the Noctalia desktop environment.

## Build/Lint/Test Commands

This is a pure QML plugin - no build step required. Files are interpreted at runtime by Quickshell.

```bash
# No build command (QML is interpreted)
# No test runner configured
# No linting configured (consider adding qmllint)
```

To test changes:
1. Install plugin in Noctalia (copy to `~/.config/noctalia/plugins/`)
2. Restart Noctalia or reload plugins
3. Test functionality in the live environment

## Code Style Guidelines

### Formatting
- 4-space indentation (no tabs)
- Opening brace on same line (K&R style)
- Max line length: ~100 characters
- Use semicolons consistently (optional in QML but be consistent)

### Naming Conventions
- **Files**: PascalCase (`Main.qml`, `LauncherProvider.qml`)
- **Components/Types**: PascalCase (`Item`, `Process`, `IpcHandler`)
- **Properties**: camelCase (`pluginApi`, `windowsLoaded`)
- **Functions**: camelCase (`handleCommand`, `getResults`)
- **IDs**: lowercase or camelCase (`root`, `niriWindowsProc`)
- **Signals**: camelCase (`onOpened`, `onExited`)

### Imports (Group in order)
1. Qt/QML core: `import QtQuick`
2. Quickshell: `import Quickshell`, `import Quickshell.Io`
3. Project qs namespace: `import qs.Services.UI`, `import qs.Commons`

### Type Safety
- Prefer typed properties: `property string name`, `property bool windowsLoaded`
- Use `property var` only when necessary (dynamic data)
- Always type function parameters: `function toggle(language: string, text: string)`

### Error Handling
- Check null before accessing: `if (!pluginApi) return`
- Handle process errors in `onExited`: check exit code
- Wrap JSON parsing in try/catch
- Use `Logger.e(tag, message)` for errors (from `qs.Commons`)

### QML Patterns
- Always give root element an `id: root` for self-reference
- Use closures to preserve scope in loops (common pattern):
  ```qml
  onActivate: function (windowId) {
      return function () { /* use windowId */ };
  }(w.id)
  ```
- Arrow functions for simple callbacks: `code => { ... }`

### Comments
- Use `//` for all comments (single-line and inline)
- Document required properties and public functions
- Keep comments concise and current

### Manifest (manifest.json)
- Keep version semver-compliant
- `minNoctaliaVersion` must match API compatibility
- Entry points must match file names exactly

### Performance
- Don't block the main thread with synchronous operations
- Use `Process` for external commands
- Cache expensive operations (like window list fetching)

## Architecture Patterns

### Plugin Structure
- `Main.qml`: Entry point, handles IPC via `IpcHandler`
- `LauncherProvider.qml`: Provider pattern for launcher integration
- `manifest.json`: Plugin metadata and entry points

### Provider Interface
Providers must implement:
- `handleCommand(searchText)` - return true if provider handles this command
- `commands()` - return array of command objects
- `onOpened()` - called when launcher opens
- `getResults(searchText)` - return array of result objects

### Result Object Format
```qml
{
    "name": "Display name",
    "description": "Hover description",
    "icon": "icon-name",
    "isTablerIcon": true,
    "onActivate": function() { /* action */ }
}
```
