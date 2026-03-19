# ScrollArrows

**Navigate lists hands-free while reading with your scroll wheel.**

Instead of clicking down arrows 90 times while sorting through emails, just hold **Ctrl** and scroll. Instantly jump through your Apple Mail inbox without moving your hand to the keyboard. ScrollArrows converts your scroll wheel into arrow keys—making list navigation feel natural and seamless.

## What It Does

ScrollArrows is a lightweight macOS utility that lets you navigate lists using your mouse scroll wheel:

1. **Hold Ctrl** + scroll your mouse wheel → generates **Up/Down arrow keys**
2. **Release Ctrl** and continue → normal scrolling within your message/document
3. **Works everywhere** — Mail, Messages, Finder, web browsers, any app with lists

No clicking. No menu. Just hold and scroll.

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

### 1. Build It

```bash
swiftc main.swift -o scroll_arrows
```

### 2. Grant Permissions

Run it once:
```bash
./scroll_arrows
```

Then go to **System Settings → Privacy & Security → Accessibility** and enable Terminal (or whichever app you're using).

### 3. Start Using

```bash
./scroll_arrows
```

That's it. Hold Ctrl and scroll to navigate lists.

## Run at Startup (Optional)

Want ScrollArrows to start automatically when you log in?

### 1. Install the Binary

```bash
swiftc main.swift -o scroll_arrows
sudo cp scroll_arrows /usr/local/bin/scroll_arrows
```

### 2. Create Launch Agent

Save this as `~/Library/LaunchAgents/com.scrollarrows.launchd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.scrollarrows.launchd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/scroll_arrows</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
```

### 3. Enable It

```bash
launchctl load ~/Library/LaunchAgents/com.scrollarrows.launchd.plist
```

It will now start automatically on every login, running silently in the background.

### Manage the Service

```bash
# Check if it's running
launchctl list | grep scrollarrows

# Stop it
launchctl unload ~/Library/LaunchAgents/com.scrollarrows.launchd.plist

# Restart it
launchctl unload ~/Library/LaunchAgents/com.scrollarrows.launchd.plist
launchctl load ~/Library/LaunchAgents/com.scrollarrows.launchd.plist
```

## Options

```bash
./scroll_arrows --invert    # Invert scroll direction (if you use ScrollReverser)
./scroll_arrows -i          # Short form
./scroll_arrows --help      # Show help
```

## Customize the Modifier Key

By default, it uses **Control**. Want to use Cmd or Option instead?

Edit `main.swift` and change the `Config` struct:

```swift
struct Config {
    static let triggerModifier: CGEventFlags = .maskControl  // Change to:
    // .maskCommand    (⌘)
    // .maskAlternate  (⌥)
    // .maskShift      (⇧)
}
```

Then recompile:
```bash
swiftc main.swift -o scroll_arrows
```

## Troubleshooting

**It's not working - I see warnings about "Tap disabled"**
- Normal on macOS Sequoia/Tahoe. The utility auto-recovers. Just leave it running.

**No arrow keys being generated**
1. Check: Did you grant Accessibility permissions? (System Settings → Privacy & Security → Accessibility)
2. Check: Are you holding the right modifier? (Default is Ctrl)
3. Check: Is another app (Karabiner, BetterTouchTool) intercepting your mouse events first?

**Permissions reset after recompilation**
- Each new compilation creates a new binary. You may need to re-grant Accessibility permissions.
- To help persistence:
  ```bash
  xattr -d com.apple.quarantine ./scroll_arrows
  codesign --force --deep -s - ./scroll_arrows
  ```

**Permission issues on iTerm2 or other terminals**
- Try resetting permissions:
  ```bash
  # For Terminal.app
  tccutil reset Accessibility com.apple.Terminal

  # For iTerm2
  tccutil reset Accessibility com.googlecode.iterm2
  ```
  Then re-grant in System Settings.

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
- **Debounced**: 80ms lockout prevents event spam

**Components** (for developers):
- `EventTapManager` — Manages system event interception
- `ScrollDebouncer` — Prevents rapid-fire events
- `handleEvent()` — Core scroll-to-arrow conversion logic
- `generateArrowKey()` — Creates synthetic arrow key events

## Compatibility

- **macOS Sequoia (15.x)**: ✓ Fully supported
- **macOS Tahoe (26.x)**: ✓ Fully supported
- Requires: Accessibility permissions

## License

MIT License - Use freely for personal and commercial projects.
