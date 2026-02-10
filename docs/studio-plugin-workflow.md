---
title: Studio Plugin Workflow
layout: default
nav_order: 3
---

Install source: [NetRayCompilerPlugin on Creator Store](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin)

## UI Overview
The plugin widget includes:
- **Remote Scope Name** textbox.
- **IDL Schema** multiline editor.
- **Compile to ReplicatedStorage** button.
- **Load Selection** button.
- **Clear** button.
- Status line for compile/write feedback.

## Buttons
### Compile to ReplicatedStorage
- Compiles current schema text locally (no HTTP).
- Writes/updates `ModuleScript`s under `ReplicatedStorage/NetRay`:
  - `Server`
  - `Client`
  - `Types`

### Load Selection
- Requires exactly one selected `LuaSourceContainer` (`Script`, `LocalScript`, or `ModuleScript`).
- Loads the selected script's entire `Source` text into the schema editor.

### Clear
- Clears only the editor text.

## Persistence
- Scope textbox and schema text are saved in plugin settings.
- Last values are restored when the plugin opens again.

## Write Behavior
- If `ReplicatedStorage/NetRay` does not exist, plugin creates a `Folder`.
- Existing non-`ModuleScript` children named `Server`, `Client`, or `Types` are replaced.
- Existing matching `ModuleScript`s are overwritten in place.

## Common Plugin Errors
- `Schema is empty`: editor has no schema text.
- `Compile failed: ...`: parser/analyzer/generator failure.
- `Compiled, but write failed: ...`: compile succeeded but writing modules failed.
- `Select exactly one Script or ModuleScript ...`: invalid selection count/type for **Load Selection**.
