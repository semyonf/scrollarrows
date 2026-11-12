//
//  ScrollArrows - menu bar app
//  Modifier + scroll -> Up/Down arrow keys, modifier + middle click -> Return
//
//  Build the app:  ./build.sh   (creates build/ScrollArrows.app)
//  Plain binary:   swiftc main.swift -o scroll_arrows
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ServiceManagement
import SwiftUI

// MARK: - Settings

/// User settings, persisted in UserDefaults. Read by the event tap on every event.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var scrollModifiers: UInt64 { didSet { d.set(scrollModifiers, forKey: "scrollModifiers") } }
    @Published var returnEnabled: Bool { didSet { d.set(returnEnabled, forKey: "returnEnabled") } }
    @Published var returnModifiers: UInt64 { didSet { d.set(returnModifiers, forKey: "returnModifiers") } }
    @Published var invertWheel: Bool { didSet { d.set(invertWheel, forKey: "invertWheel") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }

    private init() {
        let ctrl = CGEventFlags.maskControl.rawValue
        d.register(defaults: [
            "enabled": true,
            "scrollModifiers": ctrl,
            "returnEnabled": true,
            "returnModifiers": ctrl,
            "invertWheel": false,
            "showMenuBarIcon": true,
        ])
        enabled = d.bool(forKey: "enabled")
        scrollModifiers = (d.object(forKey: "scrollModifiers") as? NSNumber)?.uint64Value ?? ctrl
        returnEnabled = d.bool(forKey: "returnEnabled")
        returnModifiers = (d.object(forKey: "returnModifiers") as? NSNumber)?.uint64Value ?? ctrl
        invertWheel = d.bool(forKey: "invertWheel")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
    }

    var scrollFlags: CGEventFlags { CGEventFlags(rawValue: scrollModifiers) }
    var returnFlags: CGEventFlags { CGEventFlags(rawValue: returnModifiers) }
}

// MARK: - Modifier helpers

enum Modifiers {
    /// Display order follows macOS menus: Control, Option, Shift, Command.
    static let all: [(CGEventFlags, NSEvent.ModifierFlags, String)] = [
        (.maskControl, .control, "⌃"),
        (.maskAlternate, .option, "⌥"),
        (.maskShift, .shift, "⇧"),
        (.maskCommand, .command, "⌘"),
    ]

    static func symbols(_ raw: UInt64) -> String {
        let flags = CGEventFlags(rawValue: raw)
        return all.filter { flags.contains($0.0) }.map { $0.2 }.joined()
    }

    static func cgFlags(from ns: NSEvent.ModifierFlags) -> UInt64 {
        all.filter { ns.contains($0.1) }.reduce(CGEventFlags()) { $0.union($1.0) }.rawValue
    }
}

// MARK: - Virtual Key Codes

enum KeyCodes {
    static let upArrow: CGKeyCode = 126
    static let downArrow: CGKeyCode = 125
    static let returnKey: CGKeyCode = 36
    static let escape: UInt16 = 53
}

// MARK: - Scroll Debouncer

/// Tracks scroll events and applies debouncing to prevent event flooding
final class ScrollDebouncer {
    private var lastScrollTime: UInt64 = 0
    private let nanosecondsPerMs: UInt64 = 1_000_000

    // Debounce intervals in milliseconds
    private let wheelMs: UInt64 = 1
    private let trackpadMs: UInt64 = 5

    /// Returns true if the scroll event should be processed, false if debounced
    func shouldProcessScroll(isContinuous: Bool) -> Bool {
        let currentTime = mach_absolute_time()
        let debounceNs = (isContinuous ? trackpadMs : wheelMs) * nanosecondsPerMs
        if currentTime - lastScrollTime >= debounceNs {
            lastScrollTime = currentTime
            return true
        }
        return false
    }
}

enum ScrollDirection { case up, down }

// MARK: - Event Tap Manager

/// Manages the Core Graphics event tap lifecycle
final class EventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let debouncer = ScrollDebouncer()
    private var healthCheckTimer: Timer?
    private let settings = Settings.shared
    private let scrollThreshold: Double = 1.0

    var isActive: Bool { eventTap != nil }

    /// Creates the tap. Returns false while Accessibility access is missing.
    func start() -> Bool {
        if eventTap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        guard createEventTap() else { return false }
        startHealthCheck()
        log("Event tap started")
        return true
    }

    // MARK: Event tap creation

    private func createEventTap() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) |
                                      (1 << CGEventType.otherMouseDown.rawValue) |
                                      (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("ERROR - CGEvent.tapCreate returned nil")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            log("ERROR - Failed to create run loop source")
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: Event handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Recovery: the system disables slow taps; turn it back on
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("WARNING - Tap disabled by system, re-enabling...")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard settings.enabled else { return Unmanaged.passUnretained(event) }

        // Middle button (button 2) with modifier -> Return
        if type == .otherMouseDown || type == .otherMouseUp {
            let flags = event.flags
            let isMiddle = event.getIntegerValueField(.mouseEventButtonNumber) == 2
            guard settings.returnEnabled, isMiddle, flags.contains(settings.returnFlags) else {
                return Unmanaged.passUnretained(event)
            }
            if type == .otherMouseDown {
                postKey(KeyCodes.returnKey, flags: flags, strip: settings.returnFlags)
            }
            return nil  // swallow both press and release
        }

        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let trigger = settings.scrollFlags
        guard flags.contains(trigger) else { return Unmanaged.passUnretained(event) }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        guard debouncer.shouldProcessScroll(isContinuous: isContinuous) else {
            return nil  // swallow to prevent scrolling
        }

        let delta = Double(event.getIntegerValueField(
            isContinuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1))

        guard abs(delta) >= scrollThreshold else { return Unmanaged.passUnretained(event) }

        var adjustedDelta = delta
        if isContinuous {
            // Trackpad: invert to match finger movement (undo natural scrolling)
            adjustedDelta = -delta
        } else if settings.invertWheel {
            adjustedDelta = -delta
        }

        let direction: ScrollDirection = adjustedDelta > 0 ? .up : .down
        postKey(direction == .up ? KeyCodes.upArrow : KeyCodes.downArrow, flags: flags, strip: trigger)
        return nil
    }

    /// Posts key down + up. The trigger modifiers are stripped so that e.g.
    /// Control+Arrow does not open Mission Control.
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, strip: CGEventFlags) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            log("ERROR - Failed to create key event")
            return
        }
        var f = flags
        f.remove(strip)
        down.flags = f
        up.flags = f
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: Health monitoring

    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
    }

    private func checkTapHealth() {
        guard let tap = eventTap else { return }
        if CGEvent.tapIsEnabled(tap: tap) { return }

        log("WARNING - Tap disabled, attempting recovery...")
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            log("Tap re-enabled successfully")
            return
        }

        log("ERROR - Failed to re-enable tap, recreating...")
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        if createEventTap() {
            log("Tap recreated successfully")
        } else {
            log("ERROR - Failed to recreate tap, exiting")
            exit(1)
        }
    }
}

func log(_ message: String) {
    print("[\(Date())] ScrollArrows: \(message)")
}

// MARK: - Launch at login

enum LoginItem {
    /// SMAppService needs an app bundle; a plain binary cannot register itself.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Settings UI

/// Click, then press and release the modifier combination. Esc cancels.
/// State lives in classes: the @State macro needs a compiler plugin that plain swiftc lacks.
final class Recorder: ObservableObject {
    @Published var recording = false
    @Published var peak: NSEvent.ModifierFlags = []
    private var monitor: Any?

    func start(onCommit: @escaping (UInt64) -> Void) {
        stop()
        peak = []
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == KeyCodes.escape { self.stop() }
                return nil
            }
            let held = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if held.isEmpty {
                // All keys released: save the largest combination that was held
                let combo = Modifiers.cgFlags(from: self.peak)
                if combo != 0 { onCommit(combo) }
                self.stop()
            } else {
                self.peak.formUnion(held)
            }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}

struct ModifierRecorder: View {
    @Binding var value: UInt64
    @ObservedObject var recorder: Recorder

    var body: some View {
        Button(action: {
            if recorder.recording { recorder.stop() } else { recorder.start { value = $0 } }
        }) {
            Text(label)
                .frame(minWidth: 150)
                .foregroundColor(recorder.recording ? .accentColor : .primary)
        }
    }

    private var label: String {
        if !recorder.recording { return Modifiers.symbols(value) }
        let held = Modifiers.cgFlags(from: recorder.peak)
        return held == 0 ? "Press modifiers…" : Modifiers.symbols(held)
    }
}

/// Window-local state of the settings view.
final class SettingsUIState: ObservableObject {
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var loginError: String?
    @Published var trusted = AXIsProcessTrusted()
    let scrollRecorder = Recorder()
    let returnRecorder = Recorder()

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func refresh() {
        trusted = AXIsProcessTrusted()
        launchAtLogin = LoginItem.isEnabled
    }

    func stopRecording() {
        scrollRecorder.stop()
        returnRecorder.stop()
    }
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var ui: SettingsUIState
    let accessTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $settings.enabled)
                LabeledContent("Scroll → arrow keys") {
                    ModifierRecorder(value: $settings.scrollModifiers, recorder: ui.scrollRecorder)
                }
                Toggle("Invert mouse wheel direction", isOn: $settings.invertWheel)
            }
            Section {
                Toggle("Middle click → Return", isOn: $settings.returnEnabled)
                LabeledContent("Middle click modifier") {
                    ModifierRecorder(value: $settings.returnModifiers, recorder: ui.returnRecorder)
                }
                .disabled(!settings.returnEnabled)
            } footer: {
                Text("Click a shortcut, press and release the modifier keys. Esc cancels.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { ui.launchAtLogin },
                    set: { ui.setLaunchAtLogin($0) }))
                    .disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text("Available only when running ScrollArrows.app.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let err = ui.loginError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                Toggle("Show icon in menu bar", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("To bring this window back, open ScrollArrows again.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section {
                LabeledContent("Accessibility") {
                    if ui.trusted {
                        Text("Granted").foregroundColor(.secondary)
                    } else {
                        Button("Open System Settings") { AppDelegate.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onReceive(accessTimer) { _ in ui.refresh() }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let tap = EventTapManager()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settingsUI = SettingsUIState()
    private var retryTimer: Timer?
    private var iconObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        if !tap.start() {
            // Ask once with the system prompt, then keep retrying until granted
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            log("Waiting for Accessibility access...")
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { return }
                if self.tap.start() {
                    t.invalidate()
                    self.updateIcon()
                }
            }
        }
        updateIcon()

        // Hidden icon would leave no way to reach settings at first run
        if !Settings.shared.showMenuBarIcon && !AXIsProcessTrusted() {
            showSettings()
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = Settings.shared.showMenuBarIcon

        iconObserver = Settings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.statusItem.isVisible = Settings.shared.showMenuBarIcon
                self?.updateIcon()
            }
        }
    }

    private func updateIcon() {
        let active = tap.isActive && Settings.shared.enabled
        let name = active ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.dotted"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ScrollArrows")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !active
    }

    /// Rebuilt on every open so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        if !tap.isActive {
            menu.addItem(withTitle: "Accessibility access needed…",
                         action: #selector(openAccessibility), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }

        let toggle = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = s.enabled ? .on : .off

        let info = menu.addItem(withTitle: "\(Modifiers.symbols(s.scrollModifiers)) + scroll → ↑ ↓", action: nil, keyEquivalent: "")
        info.isEnabled = false
        if s.returnEnabled {
            let ret = menu.addItem(withTitle: "\(Modifiers.symbols(s.returnModifiers)) + middle click → Return", action: nil, keyEquivalent: "")
            ret.isEnabled = false
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit ScrollArrows", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
    }

    @objc private func openAccessibility() {
        AppDelegate.openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(ui: settingsUI)))
            window.delegate = self
            window.title = "ScrollArrows"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsUI.refresh()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settingsUI.stopRecording()
    }
}

// MARK: - Main Entry Point

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    ScrollArrows - modifier + scroll -> arrow keys, modifier + middle click -> Return

    Runs as a menu bar app. All settings are in the menu bar icon -> Settings…
    If the icon is hidden, open the app again to show the settings window.
    """)
    exit(0)
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
