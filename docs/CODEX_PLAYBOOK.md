# Codex Playbook

This document is an implementation guide for Codex contributors.

## Architecture Overview

Core layers:

- `App/`
  - Menu bar UI and window presentation
- `Domain/`
  - Rules, settings, timers, and matching types
- `Services/`
  - Sleep assertions, process/window scanning, lid monitoring, privileged power control, persistence, login item
- `ViewModel/`
  - `AppState`: single runtime coordinator and state owner
- `PreventSleepTests/`
  - Unit tests for matching logic, timer semantics, lid-delay behavior

## Key Runtime Flow

1. Startup:
   - Load persisted state from `RuleStore`.
   - Recover stale lid override if needed.
   - Perform initial process/window scan.
2. Loop:
   - Scan processes/windows every ~3s.
   - Tick timers every ~1s.
3. Recompute:
   - Matched rule IDs
   - Post-exit timers
   - Effective sleep prevention state
4. Apply:
   - Update IOKit assertion mode (`systemOnly` or `systemAndDisplay`)
5. Persist:
   - Save state changes immediately.

## Main Files by Concern

- Sleep assertion and mode:
  - `PreventSleep/Services/SleepAssertionController.swift`
- Rule matching and timer semantics:
  - `PreventSleep/ViewModel/AppState.swift`
- Process scanning:
  - `PreventSleep/Services/ProcessScanner.swift`
- Window title scanning:
  - `PreventSleep/Services/WindowScanner.swift`
- Lid state + delay:
  - `PreventSleep/Services/LidStateMonitor.swift`
  - `PreventSleep/Services/PrivilegedPowerController.swift`
  - `PreventSleep/ViewModel/AppState.swift`
- Persistence:
  - `PreventSleep/Services/RuleStore.swift`

## Build/Test/Run Commands

Build:

```bash
xcodebuild -project PreventSleep.xcodeproj -scheme PreventSleep -configuration Debug -destination 'platform=macOS' build
```

Test:

```bash
xcodebuild -project PreventSleep.xcodeproj -scheme PreventSleep -configuration Debug -destination 'platform=macOS' test
```

Run app:

```bash
open ~/Library/Developer/Xcode/DerivedData/PreventSleep-*/Build/Products/Debug/PreventSleep.app
```

Live logs:

```bash
/usr/bin/log stream --style compact --level debug --predicate 'process == "PreventSleep" OR subsystem == "com.jeremiah.preventsleep"'
```

## Safe Change Guidelines

When changing matching logic:

- Keep path normalization behavior.
- Keep case-insensitive name/title behavior unless explicitly requested.
- Add/adjust tests in `RuleMatchingTests.swift`.

When changing timer behavior:

- Preserve post-exit semantics:
  - Start timer only on matched -> unmatched transition.
  - Cancel timer when rematched.
- Update tests in `RuleMatchingTests.swift` and/or `AppStateTests.swift`.

When changing lid-delay behavior:

- Preserve longest-delay-wins.
- Preserve restore-to-`disablesleep=0` on lid open, timeout, and crash recovery.
- Keep privileged checks before issuing `pmset`.
- Update tests in `LidDelayLogicTests.swift`.

When changing windows/menu interactions:

- Verify menu actions still trigger from `MenuBarExtra`.
- Keep app activation behavior for external windows unless intentionally redesigned.

## Manual Validation Checklist

1. Menu icon appears and toggles active/inactive symbol.
2. `Prevent Sleep Indefinitely` toggles assertions.
3. Timed override appears and expires.
4. Running process toggle creates/disables executable-path rules.
5. Enabled rules show inactive rows in menu.
6. Advanced Settings can add/edit/disable/delete rules.
7. Launch-at-login toggle updates state without crash.
8. Privileged setup status refreshes correctly.
9. Lid-delay behavior:
   - Global delay only
   - Rule delay only
   - Combined longest delay
   - Lid reopen cancel path
   - Crash recovery path

## Known Operational Gotcha

Because this is an `LSUIElement` app, windows can appear behind the active app in some contexts. If a settings window seems missing:

- Check Mission Control and app switcher.
- Look for AppKit logs mentioning non-active ordering.
- Confirm action path is firing before changing UI architecture.

