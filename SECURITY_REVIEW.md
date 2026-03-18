# Security Review: ScrollArrows

**Date:** 2026-03-18
**Scope:** Full codebase (`main.swift`, 458 lines)

## Summary

ScrollArrows is a small, focused macOS utility (single Swift file) with no network code, no file I/O, and no external dependencies. The attack surface is inherently small. However, several issues were identified ranging from memory safety concerns to logic flaws.

**No critical vulnerabilities found.** The issues below are ordered by severity.

---

## Findings

### 1. MEDIUM — Unsafe `Unmanaged` pointer (use-after-free risk)

**Location:** `main.swift:225,229`

```swift
let refcon = Unmanaged.passUnretained(self).toOpaque()  // line 229
// ...in callback...
let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()  // line 225
```

`passUnretained` does not increment the reference count. If the `EventTapManager` instance were deallocated while the event tap callback is still registered, the callback would dereference a dangling pointer (use-after-free). The current code mitigates this via `withExtendedLifetime` at line 456, but this is fragile — any refactor that changes the lifetime of `manager` would introduce a crash or memory corruption.

**Recommendation:** Use `passRetained`/`takeRetainedValue`, or store a strong reference in a global variable to make the lifetime guarantee explicit rather than implicit.

---

### 2. MEDIUM — Async-signal-unsafe functions in signal handlers

**Location:** `main.swift:422-430`

```swift
signal(SIGINT) { _ in
    print("\n[\(Date())] ScrollArrows: Received SIGINT, shutting down...")
    exit(0)
}
```

`print()`, `Date()`, and string interpolation are **not async-signal-safe**. Calling them inside a signal handler can cause deadlocks (e.g., if the signal fires while `print()` already holds a lock on stdout) or undefined behavior.

**Recommendation:** Use `DispatchSource.makeSignalSource()` for safe signal handling, or limit the handler to calling `_exit(1)` with no I/O.

---

### 3. MEDIUM — Signal handlers skip resource cleanup

**Location:** `main.swift:422-430`

The signal handlers call `exit(0)` directly without calling `manager.stop()`. The event tap is never disabled and the run loop source is never removed. The `manager` variable is not accessible from the signal handler closure, making cleanup structurally impossible with the current design.

**Recommendation:** Use `DispatchSource` signal sources that can reference the manager, or store the manager in a global for cleanup access.

---

### 4. LOW — Overly permissive permission check

**Location:** `main.swift:200`

```swift
if listenGranted || postGranted {
    return true
}
```

The app needs **both** Input Monitoring (to intercept scroll events) and Accessibility/PostEvent (to inject synthetic key events). Accepting either one as sufficient means the app may start successfully but fail silently at runtime.

**Recommendation:** Change to `&&` and provide separate error messages for each missing permission.

---

### 5. LOW — Event mask is broader than necessary

**Location:** `main.swift:216-220`

The event mask subscribes to `keyDown` and `keyUp` events, but the callback only processes `scrollWheel` events (all others are passed through at line 278-280). Every keystroke on the system flows through this callback unnecessarily, adding latency and expanding the interception surface.

**Recommendation:** Remove `keyDown` and `keyUp` from the event mask. Only subscribe to `scrollWheel` and the tap-disabled event types.

---

### 6. LOW — Race condition between health check and event callback

**Location:** `main.swift:376-409` vs `267-316`

`checkTapHealth()` runs on a `Timer` and can tear down and recreate the event tap (lines 393-406) while the callback may be mid-execution. The `eventTap` property and `isRunning` flag have no synchronization.

**Recommendation:** Ensure both the timer and event tap callback execute on the same serial queue/run loop, or add synchronization around shared state.

---

### 7. LOW — `mach_absolute_time()` used without timebase conversion

**Location:** `main.swift:111-118`

`mach_absolute_time()` returns ticks in an unspecified unit. On Intel Macs 1 tick ≈ 1 nanosecond, but on Apple Silicon this is not guaranteed. The code assumes ticks are nanoseconds.

**Recommendation:** Use `mach_timebase_info()` to convert to real nanoseconds, or use `DispatchTime.now()` / `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`.

---

### 8. INFO — Verbose logging exposes system state

**Location:** Throughout `main.swift`

Every event, permission check, and health check is logged to stdout with timestamps. An attacker able to read stdout could observe when modifier keys are pressed and the tool's internal state.

**Recommendation:** Add a `--quiet` flag or make verbose logging opt-in via `--verbose`.

---

### 9. INFO — Synthetic events posted at HID level

**Location:** `main.swift:361-362`

Posting to `.cghidEventTap` injects events at the lowest level, before any application-level input filtering. Any bug in direction/keycode logic would inject unintended keystrokes system-wide.

**Recommendation:** No change needed — this is by design. Note for future development that keystroke injection must be tested carefully.

---

## Not Found (Positive)

- No network code — no remote attack surface
- No file I/O — no path traversal or injection risks
- No `eval`, `exec`, `NSTask`, or shell execution
- No hardcoded secrets or credentials
- No deserialization of untrusted data
- Swift memory safety prevents buffer overflows
- CLI argument parsing uses safe `switch/case` with whitelisted values
- Proper use of `guard` statements for error handling
- TCC permissions correctly gate privileged operations
