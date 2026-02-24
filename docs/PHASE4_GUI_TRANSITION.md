# Phase 4 — GUI Transition (Kickoff)

Status: In Progress
Issue: https://github.com/romeo-folie/clipster/issues/19
Source: PRD §14, §14.1

## Goal
Evolve `clipsterd` from headless LaunchAgent daemon into an app-bundle-capable runtime while preserving:

1. Existing IPC contract (`version:1`) for `clipster` CLI clients
2. Existing SQLite data compatibility
3. Backward-compatible config behavior

## Constraints (Binding)
- GUI phase builds on current daemon core; no greenfield replacement daemon.
- IPC protocol remains stable and versioned.
- Schema changes must be additive and migration-safe.

## Workstreams

### 1) Runtime model and process lifecycle
- Define app-bundle startup path vs headless startup path
- Define launch/stop/restart semantics for users and CLI commands
- Preserve current socket location and ownership model

### 2) Permissions & security
- Document TCC and Accessibility permission requirements
- Define CGEvent and paste-to-previous-app permission flow
- Map notarisation/signing impact for app bundle + helper binaries

### 3) UI integration seams
- Introduce clear seams for AppKit/SwiftUI layer integration
- Keep core services (monitoring/storage/ipc) in reusable module(s)
- Avoid regressions in existing CLI behavior

### 4) Migration plan
- LaunchAgent/plist migration strategy
- Data/config migration strategy
- Rollback strategy

## Deliverables
- Architecture document with sequence + component diagrams
- Risk register and mitigations
- Implementation issue breakdown for execution

## Proposed sequence
1. Approve architecture + migration strategy
2. Add app-capable entrypoint scaffolding (no user-facing GUI yet)
3. Integrate menu-bar shell and permission preflight flow
4. Incrementally ship GUI features behind stable IPC
