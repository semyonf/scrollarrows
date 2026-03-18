# ScrollArrows - Modifier+Scroll to Arrow Keys

A lightweight macOS utility that converts modifier key + mousewheel scroll into discrete arrow key presses. Built with native Swift and CoreGraphics for maximum performance and minimal resource usage.

## Features

- **Modifier+Scroll Detection**: Press `Control` + scroll to generate arrow keys
- **Universal Scroll Handling**: Works with both trackpads (continuous) and notched mouse wheels (discrete)
- **Debouncing**: Prevents event flooding with intelligent debouncing
- **Auto-Recovery**: Automatically recovers from tap disable events
- **Terminal-First**: Pure CLI binary for testing before GUI integration

## Compilation

```bash
# Compile the Swift source
swiftc main.swift -o scroll_arrows
```

## Running

```bash
# Execute the binary
./scroll_arrows
```

## Initial Setup (Critical)

### 1. Grant Accessibility Permissions

Before the utility can intercept input events, you must grant Accessibility permissions:

1. Run the utility: `./scroll_arrows`
2. The utility will detect missing permissions and prompt you
3. Open **System Settings → Privacy & Security → Accessibility**
4. Enable the terminal app you're using (Terminal.app, iTerm2, etc.)
5. If using a raw binary, you may need to add it manually via the "+" button

### 2. Verify Permissions

The utility will output permission status on startup:
```
ScrollArrows: Input Monitoring access: granted
ScrollArrows: Accessibility access: granted
```

## Usage

1. Launch the utility: `./scroll_arrows`
2. Hold **Control** (or configured modifier)
3. Scroll with mouse wheel or trackpad
4. Arrow keys are generated instead of scroll

### Command Line Options

```bash
./scroll_arrows --invert    # Invert scroll direction (for ScrollReverser)
./scroll_arrows -i          # Short form for --invert
./scroll_arrows --help      # Show help message
```

### Changing the Modifier (compile-time)

Edit [`main.swift`](main.swift) and modify the `Config` struct:

```swift
struct Config {
    // Change to your preferred modifier:
    // .maskControl, .maskCommand, .maskAlternate, .maskShift
    static let triggerModifier: CGEventFlags = .maskControl
}
```

Then recompile:
```bash
swiftc main.swift -o scroll_arrows
```

## Troubleshooting

### "Tap disabled by system" warnings

This is normal on macOS Sequoia/Tahoe. The utility includes auto-recovery that will re-enable the tap automatically.

### No arrow keys generated

1. **Check permissions**: Ensure Accessibility is granted
2. **Check modifier**: Verify you're holding the correct modifier key
3. **Check other apps**: Other utilities (Karabiner, BetterTouchTool) may be intercepting events first

### "Silent Disable Race" (Tap exists but no callbacks fire)

This occurs when TCC permissions aren't properly persisted. Try:

```bash
# Reset accessibility for terminal
tccutil reset Accessibility com.apple.Terminal

# Or for iTerm2
tccutil reset Accessibility com.googlecode.iterm2
```

Then re-grant permissions in System Settings.

### Permission denied after recompilation

Each compilation creates a new binary with a new signature. Re-add to Accessibility:
```bash
# Remove quarantine attribute
xattr -d com.apple.quarantine ./scroll_arrows

# Re-sign (optional, helps with TCC persistence)
codesign --force --deep -s - ./scroll_arrows
```

## Architecture

### Event Tap Pipeline

1. **CGEventTap** at `cgSessionEventTap` (headInsertEventTap)
2. **Modifier Detection**: Check `event.flags` for trigger modifier
3. **Scroll Delta Extraction**: Read `scrollWheelEventPointDeltaAxis1` or `scrollWheelEventDeltaAxis1`
4. **Continuity Check**: Handle trackpads vs. mouse wheels differently
5. **Debouncing**: 80ms temporal lockout prevents flooding
6. **Synthetic Key Generation**: Create paired keyDown/keyUp events with modifier stripped

### Key Components

| Component | Purpose |
|-----------|---------|
| [`EventTapManager`](main.swift:89) | Manages CGEventTap lifecycle |
| [`ScrollDebouncer`](main.swift:56) | Prevents event flooding |
| [`checkAndRequestPermissions()`](main.swift:130) | TCC/Accessibility handling |
| [`handleEvent()`](main.swift:197) | Core event processing |
| [`generateArrowKey()`](main.swift:252) | Synthetic keystroke generation |

## macOS Version Compatibility

- **macOS Sequoia (15.x)**: Fully supported with Accessibility permissions
- **macOS Tahoe (26.x)**: Fully supported with Accessibility permissions
- **Note**: Input Monitoring permissions require 30-day renewal; Accessibility does not

## Next Steps

This is the Terminal-first validation version. To create a full GUI application:

1. Wrap the `EventTapManager` in an `ObservableObject`
2. Create a SwiftUI `MenuBarExtra` app
3. Add `LSUIElement` to Info.plist to hide Dock icon
4. Add settings UI for modifier selection

## License

MIT License - Use freely for personal and commercial projects.
