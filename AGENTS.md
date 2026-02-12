# AGENTS.md

Repository-specific instructions for Codex agents working on PreventSleep.

## Scope

These instructions apply to the entire repository.

## Project Purpose

PreventSleep is a macOS 15+ menu bar app that keeps the Mac awake based on:

- Global manual controls (indefinite or timed)
- Rule matches (process path/name/window title)
- Per-rule post-exit timers
- Optional lid-close delay rules (requires privileged setup)

## Source of Truth

Use these files as the primary references:

- Product behavior: `README.md`
- Build config: `project.yml`
- App entry/menu UI: `PreventSleep/App/PreventSleepApp.swift`, `PreventSleep/App/MenuContentView.swift`, `PreventSleep/App/AdvancedSettingsView.swift`
- Runtime orchestration: `PreventSleep/ViewModel/AppState.swift`
- Domain types: `PreventSleep/Domain/RuleModels.swift`
- Tests: `PreventSleepTests/*.swift`

## Required Workflow

1. Before making changes:
   - Read relevant files.
   - Preserve existing behavior unless the task explicitly changes it.
2. After making changes:
   - Build the app.
   - Run tests.
   - Report exactly what changed and what was validated.

Use these commands:

```bash
xcodebuild -project PreventSleep.xcodeproj -scheme PreventSleep -configuration Debug -destination 'platform=macOS' build
xcodebuild -project PreventSleep.xcodeproj -scheme PreventSleep -configuration Debug -destination 'platform=macOS' test
```

If `project.yml` changes, regenerate project:

```bash
xcodegen generate
```

## Behavioral Invariants (Do Not Break)

1. Effective sleep prevention is ON when any are true:
   - `globalSettings.preventIndefinitely`
   - `globalSettings.manualTimerEndDate` is active
   - any enabled rule is matched and `preventWhileMatched == true`
   - any post-exit timer is active
2. Match semantics:
   - Executable path: normalized exact path
   - Process name: case-insensitive exact
   - Window title: `contains`, `exact`, `regex` (case-insensitive)
3. Disabled rules must remain persisted in state storage.
4. Menu behavior:
   - Running processes list is always shown.
   - Enabled rules list includes inactive-but-enabled rules (grayed).
   - Disabling from menu removes from enabled list but keeps rule stored.
5. Lid-delay behavior:
   - Longest delay wins across global + matched rules.
   - Uses `pmset -a disablesleep 1` then restores `0`.
   - If timer expires and lid is still closed, call `pmset sleepnow`.
   - Crash-recovery marker must restore `disablesleep=0` on next launch.

## Privileged Access Rules

- Privileged setup is optional and used only for lid-delay controls.
- Do not broaden sudoers scope beyond:
  - `/usr/bin/pmset -a disablesleep 0`
  - `/usr/bin/pmset -a disablesleep 1`
  - `/usr/bin/pmset sleepnow`
- Installer script location:
  - `PreventSleep/Scripts/install_privileged_access.sh`

## Persistence Rules

- State file path:
  - `~/Library/Application Support/PreventSleep/state.json`
- Persist immediately after edits to rules/global settings.
- Keep backward-compatible JSON shape unless migration is explicitly requested.

## UI/UX Notes

- App is `LSUIElement` (menu bar only, no Dock icon).
- Advanced Settings and Custom Duration windows are opened through explicit window coordination.
- If settings window appears missing, it may be behind active app windows; avoid removing `NSApp.activate(ignoringOtherApps: true)` unless task requires different behavior.

## Testing Expectations

At minimum, preserve passing coverage for:

- Global/manual keep-awake activation
- Rule matching modes/operators
- Post-exit timer start/cancel behavior
- Enabled rule list/menu disable semantics
- Lid-delay longest-duration and recovery behavior

Add/update tests in `PreventSleepTests` when behavior changes.

