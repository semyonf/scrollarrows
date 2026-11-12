> 100% Vibecode: planned, implemented and documented by Gemini 3 Pro, MiniMax 2.5 and Claude Haiku

# ScrollArrows

**Navigate lists hands-free while reading with your scroll wheel.**

Instead of clicking down arrows 90 times while sorting through emails, just hold **Ctrl** and scroll. Instantly jump through your Apple Mail inbox without moving your hand to the keyboard. ScrollArrows converts your scroll wheel into arrow keys—making list navigation feel natural and seamless.

## What It Does

ScrollArrows is a lightweight macOS utility that lets you navigate lists using your mouse scroll wheel:

1. **Hold Ctrl** + scroll your mouse wheel → generates **Up/Down arrow keys**
2. **Release Ctrl** and continue → normal scrolling within your message/document
3. **Works everywhere** — Mail, Messages, Finder, web browsers, any app with lists

No clicking. Just hold and scroll. Settings live in a small menu bar icon.

## The Real-World Use Case

You're sorting through your Apple Mail inbox. Instead of:
- Clicking the down arrow 90 times ↓↓↓
- Reaching for your trackpad over and over
- Breaking focus while scanning subjects

You just:
- **Hold Ctrl** and **scroll** through email list (hands stay on mouse)
- **Release Ctrl** and **scroll** to read the full message
- Your workflow stays smooth and natural

## Quick Start

### 1. Build the app

```bash
./build.sh
```

This creates `build/ScrollArrows.app`. Move it to `/Applications` if you like.

### 2. Launch and grant access

```bash
open build/ScrollArrows.app
```

macOS asks for Accessibility access. Enable **ScrollArrows** in **System Settings → Privacy & Security → Accessibility**. The app picks up the permission by itself, no restart needed.

### 3. Use it

Hold Ctrl and scroll. The arrows icon in the menu bar shows that the app is active.

## Settings

Click the menu bar icon → **Settings…**:

- **Scroll → arrow keys** — click the field, press the modifier keys you want (e.g. ⌃⌥), release them. Esc cancels.
- **Middle click → Return** — turn on or off, and pick its modifier the same way.
- **Invert mouse wheel direction** — for ScrollReverser and similar tools.
- **Launch at login** — registers the app as a login item.
- **Show icon in menu bar** — turn off to hide the icon. To get the settings back, open ScrollArrows again (Finder, Spotlight or `open`).

The menu also has a quick **Enabled** toggle.

Accessibility permission is tied to the code signature. With the default ad hoc signature a rebuild may require granting it again. Sign with your own certificate to avoid that:

```bash
SIGN_ID="Apple Development: you@example.com" ./build.sh
```

### Migrating from the launchd version

If you set up the old `launchd` agent, remove it, otherwise both copies will handle the same events:

```bash
launchctl bootout gui/$(id -u)/com.scrollarrows.launchd
rm ~/Library/LaunchAgents/com.scrollarrows.launchd.plist
```

## Troubleshooting

**It's not working - I see warnings about "Tap disabled"**
- Normal on macOS Sequoia/Tahoe. The utility auto-recovers. Just leave it running.

**No arrow keys being generated**
1. Check: Did you grant Accessibility permissions? (System Settings → Privacy & Security → Accessibility)
2. Check: Are you holding the right modifier? (Default is Ctrl)
3. Check: Is another app (Karabiner, BetterTouchTool) intercepting your mouse events first?

**Accessibility asks again after a rebuild**
- The permission is tied to the code signature, and an ad hoc signature changes with every build. Build with `SIGN_ID` (see Settings), or reset the entry and grant it again:
  ```bash
  tccutil reset Accessibility com.scrollarrows.app
  ```

## Uninstall

Turn off **Launch at login** in Settings, quit from the menu, then delete the app and its settings:

```bash
rm -rf /Applications/ScrollArrows.app
defaults delete com.scrollarrows.app
```

## How It Works (Technical Details)

**The Pipeline:**
1. Intercepts mouse scroll events at the system level (CGEventTap)
2. Detects if your modifier key (Ctrl by default) is held
3. Converts scroll deltas into Up/Down arrow key presses
4. Works with both trackpads (continuous scroll) and mouse wheels (discrete notches)
5. Includes intelligent debouncing to prevent event flooding

**Key Features:**
- **Lightweight**: Native Swift + CoreGraphics, minimal resource usage
- **Universal**: Works with trackpads and mouse wheels
- **Auto-Recovery**: Handles macOS permission edge cases automatically
- **Debounced**: at most one arrow per 40 ms (mouse wheel) or 200 ms (trackpad); trackpad momentum is ignored

**Components** (for developers):
- `EventTapManager` — Manages system event interception
- `ScrollDebouncer` — Prevents rapid-fire events
- `handleEvent()` — Core scroll-to-arrow conversion logic
- `postKey()` — Creates synthetic arrow and Return key events

## Compatibility

- **macOS Sequoia (15.x)**: ✓ Fully supported
- **macOS Tahoe (26.x)**: ✓ Fully supported
- Requires: Accessibility permissions

## License

MIT License - Use freely for personal and commercial projects.
