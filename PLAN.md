PLEASE IMPLEMENT THIS PLAN:

# PreventSleep v2 Plan: Menu Bar App + Advanced Settings + Lid Delay Rules

## Summary

Build a macOS 15+ SwiftUI menu bar app in `/Users/jeremiah/projects/prevent-sleep` that:

- Prevents sleep indefinitely or for a custom duration (minutes/hours).
- Prevents sleep automatically based on enabled rules matching running items.
- Supports rule matching by executable path, process name, or window title (operator per window-title rule).
- Adds an Advanced Settings dialog for rule management and privileged lid-delay setup.
- Supports lid-close delay using global and app-dependent rules, with longest delay winning.

## Final Product Behavior

1. Menu bar icon shows active/inactive sleep-prevention status.
2. Menu includes:

- `Prevent Sleep Indefinitely` toggle.
- `Prevent Sleep For...` actions (preset durations + custom duration dialog).
- `Running Processes` list (live, user-owned non-system processes), each with toggle.
- `Enabled Rules` list (checked, includes grayed rows if not currently matched/running).
- `Advanced Settings...`
- `Launch at Login`
- `Quit`

3. Menu rule visibility behavior:

- Running processes are always shown.
- Enabled rules are always shown in menu, even when not currently detected (grayed + checked).
- Unchecking a rule in menu disables it and removes it from menu rule list.
- Disabled rules remain stored and visible in Advanced Settings.

4. Advanced Settings dialog contains:

- Global options (default new-rule identity mode, global timed behavior settings).
- Full rule table (enabled + disabled).
- Rule editor for match mode: `Executable Path`, `Process Name`, `Window Title`.
- Window-title operator per rule: `contains`, `exact`, `regex`.
- Per-rule actions: prevent while matched, keep-awake-after-exit duration, optional lid-delay duration.
- Global lid-delay rule (duration + enabled toggle).
- Privileged setup status and `Enable Lid Delay Privileged Access` action.

## Sleep and Timer Logic

1. Effective sleep-prevention ON when any of these are true:

- Global indefinite toggle is ON.
- Global manual timer is active.
- Any enabled rule currently matches.
- Any per-rule post-exit keep-awake timer is active.

2. Manual timed override:

- User picks minutes/hours.
- Timer runs independently of rule matching.
- Countdown shown in menu.

3. Per-rule timer semantics (chosen behavior):

- Rule keeps awake while matched.
- When match transitions true -> false, run that rule’s post-exit timer.
- If rule matches again before timer ends, cancel that timer.

4. Assertion mode:

- Standard mode prevents system idle sleep.
- Optional display behavior selector remains available (`System only` vs `System + display`) and applies immediately.

## Lid-Close Delay Logic

1. Lid delay is rule-based and toggleable:

- One global lid-delay rule.
- Additional per-rule lid-delay durations.

2. At each lid-close event:

- Compute eligible delays from enabled global lid rule plus enabled matched app rules.
- Effective delay = maximum eligible duration.
- If effective delay is zero, do nothing.
- If effective delay > 0, activate clamshell delay flow.

3. Clamshell delay flow:

- Set `SleepDisabled=1` via privileged `pmset`.
- Start delay timer.
- On timer expiry: set `SleepDisabled=0`.
- If lid is still closed at expiry: trigger immediate sleep (`pmset sleepnow`).
- On lid reopen before expiry: cancel timer and restore `SleepDisabled=0`.

4. Multiple simultaneous triggers:

- Longest active lid delay remains in effect.
- Re-close events recompute and may extend active delay.

5. Crash/force-quit safety:

- Persist “override active” marker.
- On next launch, if marker exists, force restore `SleepDisabled=0` and clear marker.

## Privileged Access Model (Chosen)

Use one-time privileged setup (not per-event prompts):

- Advanced Settings action runs installer with admin auth.
- Installer writes narrowly scoped `/etc/sudoers.d/preventsleep` entry for current user and specific `pmset` commands needed by this app.
- Runtime uses `sudo -n` for non-interactive lid event handling.
- If setup missing/invalid, lid-delay controls are disabled and UI shows actionable error/status.

## Process and Window Detection

1. Running process source:

- `libproc` PID scan.
- Keep user-owned (`uid == getuid()`), filter system-daemon paths.
- Dedupe rows by executable path for menu list.

2. Window title source:

- `CGWindowListCopyWindowInfo` best-effort collection.
- Match rule text against visible window titles.
- Missing/unavailable titles simply do not match.

3. Rule matching details:

- Executable path: exact normalized path match.
- Process name: case-insensitive exact name match.
- Window title: operator chosen per rule (`contains`, `exact`, `regex`), case-insensitive by default for contains/exact.

## Project Structure (to create)

- `/Users/jeremiah/projects/prevent-sleep/PreventSleep.xcodeproj`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/App/PreventSleepApp.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/App/MenuContentView.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/App/AdvancedSettingsView.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Domain/RuleModels.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Domain/TimerModels.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/SleepAssertionController.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/ProcessScanner.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/WindowScanner.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/LidStateMonitor.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/PrivilegedPowerController.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/RuleStore.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Services/LoginItemController.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/ViewModel/AppState.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleep/Scripts/install_privileged_access.sh`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleepTests/AppStateTests.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleepTests/RuleMatchingTests.swift`
- `/Users/jeremiah/projects/prevent-sleep/PreventSleepTests/LidDelayLogicTests.swift`

## Key Interfaces and Types

- `enum MatchMode { executablePath, processName, windowTitle }`
- `enum WindowTitleOperator { contains, exact, regex }`
- `struct SleepRule { id, enabled, label, matchMode, matchValue, titleOperator?, preventWhileMatched, keepAwakeAfterExitSeconds, lidDelaySeconds }`
- `struct GlobalSettings { preventIndefinitely, manualTimerEndDate?, globalLidDelayEnabled, globalLidDelaySeconds, defaultNewRuleMatchMode }`
- `protocol SleepAssertionControlling`
- `protocol ProcessScanning`
- `protocol WindowScanning`
- `protocol LidStateMonitoring`
- `protocol PrivilegedPowerControlling`

## Persistence

- Store settings + rules in JSON at `~/Library/Application Support/PreventSleep/state.json`.
- Persist immediately on edits/toggles.
- Keep disabled rules in storage for Advanced Settings visibility.
- Store transient safety flag for lid-delay override recovery.

## Testing and Validation

1. Unit tests:

- Global indefinite ON activates sleep prevention.
- Manual timer activates and expires correctly.
- Rule matching by executable path/process name/window title operators.
- Per-rule post-exit timer behavior and cancellation on rematch.
- Enabled rule appears in menu model while not running (grayed state).
- Disabling from menu hides it from enabled-menu list but keeps it in rule store.
- Lid delay effective duration picks max(global, matched rules).
- Lid delay start/expire/open-event state transitions.
- Crash-recovery flag restores `SleepDisabled`.

2. Integration/manual tests:

- Verify assertions with `pmset -g assertions`.
- Verify lid-close delay with global-only and app-rule-only scenarios.
- Verify longest-delay precedence when multiple matching rules are active.
- Verify privileged setup success/failure UX paths.
- Verify persistence across app relaunch and system reboot/login.

## Assumptions and Defaults

- Target is local/distributed non-App-Store usage (privileged setup and sudoers flow allowed).
- Running menu list remains process-focused; window-title rules are managed primarily in Advanced Settings.
- Window-title detection is best-effort from CGWindow metadata (no forced Accessibility workflow).
- Lid-delay feature is disabled until privileged setup is completed successfully.
- This plan supersedes the prior simpler rule model and includes the new advanced-settings/lid-delay rule system.
