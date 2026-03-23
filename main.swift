//
//  ScrollArrows - Terminal-first CGEventTap implementation
//  Converts modifier+scroll to arrow key presses
//
//  Compile: swiftc main.swift -o scroll_arrows
//  Run: ./scroll_arrows
//

import Foundation
import CoreGraphics
import IOKit
import IOKit.hid

// MARK: - Configuration

struct Config {
    // Modifier keys to trigger arrow key generation (multiple can be specified)
    static var triggerModifiers: CGEventFlags = .maskControl
    
    // Modifier name for display
    static var triggerModifierName: String = "Control"
    
    // Debounce intervals in milliseconds
    static let debounceIntervalMs: Int = 1  // For mouse wheel
    static let debounceIntervalMsTrackpad: Int = 5  // For trackpad (higher due to more events)
    
    // Scroll delta threshold (point delta)
    static let scrollThreshold: Double = 1.0
    
    // Invert scroll direction (set via command line flag --invert)
    static var invertScrollDirection: Bool = false
    
    // Health check interval in seconds
    static let healthCheckInterval: Double = 5.0
    
    // Parse command line arguments
    static func parseArgs() {
        let args = ProcessInfo.processInfo.arguments
        var modifiers: CGEventFlags = []
        var modifierNames: [String] = []
        
        for arg in args {
            switch arg {
            case "--invert", "-i":
                invertScrollDirection = true
            case "--control", "-c":
                modifiers.insert(.maskControl)
                modifierNames.append("Control")
            case "--option", "-o":
                modifiers.insert(.maskAlternate)
                modifierNames.append("Option")
            case "--command", "-cmd":
                modifiers.insert(.maskCommand)
                modifierNames.append("Command")
            case "--shift", "-s":
                modifiers.insert(.maskShift)
                modifierNames.append("Shift")
            case "--help", "-h":
                printHelp()
                exit(0)
            default:
                break
            }
        }
        
        // Set modifiers if any were specified
        if !modifiers.isEmpty {
            triggerModifiers = modifiers
            triggerModifierName = modifierNames.joined(separator: "+")
        }
    }
    
    static func printHelp() {
        print("""
        ScrollArrows - Modifier+Scroll to Arrow Keys & Mouse Wheel to Return

        Usage: scroll_arrows [options]

        Options:
          --control, -c      Use Control key (can be combined with others)
          --option, -o       Use Option key (can be combined with others)
          --command, -cmd    Use Command key (can be combined with others)
          --shift, -s        Use Shift key (can be combined with others)
          --invert, -i       Invert scroll direction (for use with ScrollReverser)
          --help, -h         Show this help message

        Features:
          - Modifier + scroll wheel/trackpad → arrow keys (up/down)
          - Modifier + mouse wheel click (middle button) → Return key

        Examples:
          ./scroll_arrows                     # Default: Control key
          ./scroll_arrows --option            # Option + scroll
          ./scroll_arrows --control --shift   # Control+Shift + scroll
          ./scroll_arrows --command --invert  # Command + scroll, inverted
        """)
    }
}

// MARK: - Virtual Key Codes

struct KeyCodes {
    static let upArrow: CGKeyCode = 126
    static let downArrow: CGKeyCode = 125
    static let returnKey: CGKeyCode = 36
}

// MARK: - Scroll Detector

/// Tracks scroll events and applies debouncing to prevent event flooding
final class ScrollDebouncer {
    private var lastScrollTime: UInt64 = 0
    private let nanosecondsPerMs: UInt64 = 1_000_000
    
    /// Returns true if the scroll event should be processed, false if debounced
    func shouldProcessScroll(isContinuous: Bool) -> Bool {
        let currentTime = mach_absolute_time()

        // Use different debounce intervals for trackpad vs mouse
        let intervalMs = isContinuous ? Config.debounceIntervalMsTrackpad : Config.debounceIntervalMs
        let debounceNs = UInt64(intervalMs) * nanosecondsPerMs

        // Check if enough time has passed since last scroll
        if currentTime - lastScrollTime >= debounceNs {
            lastScrollTime = currentTime
            return true
        }

        return false
    }
}

// MARK: - Event Tap Manager

/// Manages the Core Graphics event tap lifecycle
final class EventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let debouncer = ScrollDebouncer()
    private var healthCheckTimer: Timer?
    private var isRunning = false
    
    func start() -> Bool {
        print("[\(Date())] ScrollArrows: Starting event tap manager...")

        // Check TCC permissions first
        guard checkAndRequestPermissions() else {
            print("[\(Date())] ScrollArrows: ERROR - Accessibility permissions not granted")
            print("[\(Date())] ScrollArrows: Please grant Accessibility access in System Settings > Privacy & Security > Accessibility")
            return false
        }

        // Create the event tap
        guard createEventTap() else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create event tap")
            return false
        }

        // Start health monitoring
        startHealthCheck()

        isRunning = true
        print("[\(Date())] ScrollArrows: Event tap started successfully")
        print("[\(Date())] ScrollArrows: \(Config.triggerModifierName) + scroll → arrow keys")
        print("[\(Date())] ScrollArrows: \(Config.triggerModifierName) + mouse wheel click → Return key")
        print("[\(Date())] ScrollArrows: Press Ctrl+C to stop")

        // Run the main run loop
        RunLoop.current.run()

        return true
    }
    
    func stop() {
        print("[\(Date())] ScrollArrows: Shutting down...")
        
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        
        isRunning = false
        print("[\(Date())] ScrollArrows: Stopped")
    }
    
    // MARK: - Permissions
    
    private func checkAndRequestPermissions() -> Bool {
        // Check Input Monitoring permission
        let listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let listenGranted = (listenAccess == kIOHIDAccessTypeGranted)
        print("[\(Date())] ScrollArrows: Input Monitoring access: \(listenGranted ? "granted" : "not granted")")
        
        // Check Accessibility permission (PostEvent)
        let postAccess = IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
        let postGranted = (postAccess == kIOHIDAccessTypeGranted)
        print("[\(Date())] ScrollArrows: Accessibility access: \(postGranted ? "granted" : "not granted")")
        
        // If either is granted, we're good
        if listenGranted || postGranted {
            return true
        }
        
        // Request accessibility access (this triggers the system dialog)
        print("[\(Date())] ScrollArrows: Requesting accessibility access...")
        let requestResult = IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
        print("[\(Date())] ScrollArrows: Access request result: \(requestResult ? "granted" : "denied")")
        
        return requestResult
    }
    
    // MARK: - Event Tap Creation
    
    private func createEventTap() -> Bool {
        // Define the events we want to intercept
        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) |
                                      (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.otherMouseDown.rawValue) |
                                      (1 << CGEventType.otherMouseUp.rawValue) |
                                      (1 << CGEventType.tapDisabledByTimeout.rawValue) |
                                      (1 << CGEventType.tapDisabledByUserInput.rawValue)
        
        // Create the callback
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        // Create the event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            print("[\(Date())] ScrollArrows: ERROR - CGEvent.tapCreate returned nil")
            print("[\(Date())] ScrollArrows: This usually means:")
            print("[\(Date())] ScrollArrows:   1. Accessibility permissions not granted")
            print("[\(Date())] ScrollArrows:   2. Another app has grabbed the event tap")
            print("[\(Date())] ScrollArrows:   3. The process is sandboxed")
            return false
        }
        
        eventTap = tap
        
        // Create run loop source
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create run loop source")
            return false
        }
        
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        
        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)
        
        return true
    }
    
    // MARK: - Event Handling
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled events (recovery mechanism)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[\(Date())] ScrollArrows: WARNING - Tap disabled by system, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle mouse wheel button press (middle button / other mouse button)
        if type == .otherMouseDown {
            let flags = event.flags
            let hasModifier = flags.contains(Config.triggerModifiers)

            // Check if this is the mouse wheel button (button 2) with modifier
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if hasModifier && buttonNumber == 2 {
                // Generate Return key and swallow the event
                generateReturnKey(currentFlags: flags)
                return nil  // Swallow the event
            }

            return Unmanaged.passUnretained(event)
        }

        // Ignore otherMouseUp events when modifier is pressed (we already handled the press)
        if type == .otherMouseUp {
            let flags = event.flags
            let hasModifier = flags.contains(Config.triggerModifiers)

            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if hasModifier && buttonNumber == 2 {
                // Swallow the release event
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        // Only process scroll wheel events
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        // Check if trigger modifier is pressed
        let flags = event.flags
        // Check if ANY of the configured modifiers are pressed
        let hasModifier = flags.contains(Config.triggerModifiers)

        // If modifier not pressed, pass through unchanged
        guard hasModifier else {
            return Unmanaged.passUnretained(event)
        }

        // Check if this is a continuous device (trackpad/magic mouse)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        // Check if we should debounce (use different interval for trackpad)
        guard debouncer.shouldProcessScroll(isContinuous: isContinuous) else {
            // Still need to swallow the event to prevent scrolling
            return nil
        }

        // Extract scroll delta
        let delta = extractScrollDelta(from: event)

        // If delta is too small, ignore
        guard abs(delta) >= Config.scrollThreshold else {
            return Unmanaged.passUnretained(event)
        }

        // Determine direction and generate arrow key
        var adjustedDelta = delta

        if isContinuous {
            // Trackpad: always invert to match finger movement direction (undo macOS natural scrolling)
            adjustedDelta = -delta
        } else if Config.invertScrollDirection {
            // Mouse wheel: only apply --invert flag if set
            adjustedDelta = -delta
        }

        let direction: ScrollDirection = adjustedDelta > 0 ? .up : .down

        // Swallow the scroll event and generate arrow key
        generateArrowKey(direction: direction, currentFlags: flags)

        // Return nil to swallow the event
        return nil
    }
    
    private func extractScrollDelta(from event: CGEvent) -> Double {
        // Check if this is a continuous device (trackpad/magic mouse)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        
        if isContinuous {
            // For continuous devices, use the point delta for smoother response
            let pointDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            return Double(pointDelta)
        } else {
            // For discrete devices (notched wheels), use the line delta
            let lineDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            return Double(lineDelta)
        }
    }
    
    private func generateArrowKey(direction: ScrollDirection, currentFlags: CGEventFlags) {
        let keyCode = (direction == .up) ? KeyCodes.upArrow : KeyCodes.downArrow

        // Create event source
        guard let source = CGEventSource(stateID: .privateState) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create event source")
            return
        }

        // Strip the trigger modifier to prevent Control+Arrow (which triggers Mission Control)
        var modifiedFlags = currentFlags
        modifiedFlags.remove(Config.triggerModifiers)

        // Create key down event
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create key down event")
            return
        }
        keyDownEvent.flags = modifiedFlags

        // Create key up event
        guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create key up event")
            return
        }
        keyUpEvent.flags = modifiedFlags

        // Post events
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)

        let directionStr = (direction == .up) ? "UP" : "DOWN"
        print("[\(Date())] ScrollArrows: Generated \(directionStr) arrow key")
    }

    private func generateReturnKey(currentFlags: CGEventFlags) {
        // Create event source
        guard let source = CGEventSource(stateID: .privateState) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create event source")
            return
        }

        // Strip the trigger modifier
        var modifiedFlags = currentFlags
        modifiedFlags.remove(Config.triggerModifiers)

        // Create key down event
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: KeyCodes.returnKey, keyDown: true) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create Return key down event")
            return
        }
        keyDownEvent.flags = modifiedFlags

        // Create key up event
        guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: KeyCodes.returnKey, keyDown: false) else {
            print("[\(Date())] ScrollArrows: ERROR - Failed to create Return key up event")
            return
        }
        keyUpEvent.flags = modifiedFlags

        // Post events
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)

        print("[\(Date())] ScrollArrows: Generated Return key")
    }
    
    // MARK: - Health Monitoring
    
    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: Config.healthCheckInterval, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
    }
    
    private func checkTapHealth() {
        guard let tap = eventTap else { return }
        
        let isEnabled = CGEvent.tapIsEnabled(tap: tap)
        
        if !isEnabled {
            print("[\(Date())] ScrollArrows: WARNING - Tap disabled, attempting recovery...")
            
            // Try to re-enable
            CGEvent.tapEnable(tap: tap, enable: true)
            
            // Check if re-enable worked
            if CGEvent.tapIsEnabled(tap: tap) {
                print("[\(Date())] ScrollArrows: Tap re-enabled successfully")
            } else {
                print("[\(Date())] ScrollArrows: ERROR - Failed to re-enable tap, recreating...")
                
                // Tear down and recreate
                if let source = runLoopSource {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                    runLoopSource = nil
                }
                
                eventTap = nil
                
                // Try to recreate
                if createEventTap() {
                    print("[\(Date())] ScrollArrows: Tap recreated successfully")
                } else {
                    print("[\(Date())] ScrollArrows: ERROR - Failed to recreate tap")
                }
            }
        }
    }
}

// MARK: - Supporting Types

enum ScrollDirection {
    case up
    case down
}

// MARK: - Signal Handling

func setupSignalHandlers() {
    signal(SIGINT) { _ in
        print("\n[\(Date())] ScrollArrows: Received SIGINT, shutting down...")
        exit(0)
    }
    
    signal(SIGTERM) { _ in
        print("\n[\(Date())] ScrollArrows: Received SIGTERM, shutting down...")
        exit(0)
    }
}

// MARK: - Main Entry Point

// Parse command line arguments
Config.parseArgs()

print("========================================")
print("ScrollArrows - Modifier+Scroll to Arrows")
print("========================================")
print("")

// Print configuration info
if Config.invertScrollDirection {
    print("Invert scroll direction: enabled")
}
print("")

// Setup signal handlers for clean shutdown
setupSignalHandlers()

// Create and start the manager
let manager = EventTapManager()

// Keep the manager alive
withExtendedLifetime(manager) {
    _ = manager.start()
}
