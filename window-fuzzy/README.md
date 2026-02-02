# Window Fuzzy

Fuzzy find open window and jump to focus.

Searches by id or title of open windows.

![screenshot of window-fuzzy](screenshot.png)

## Setup

In your niri `config.kdl`:

```kdl
    Mod+A hotkey-overlay-title="Focus Window (fuzzy search)" { spawn "qs" "-c" "noctalia-shell" "ipc" "call" "plugin:window-fuzzy" "toggle"; }

```

# License

MIT