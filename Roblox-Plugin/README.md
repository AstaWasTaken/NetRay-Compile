# NetRay Studio Plugin (Rojo)

This folder contains a local Roblox Studio plugin that compiles NetRay IDL with no HTTP requests.

For full language/runtime reference docs, see [`../docs/index.md`](../docs/index.md).

## Project Files

- `default.project.json`: Sync target that places `NetRayCompilerPlugin` in `ReplicatedStorage/Roblox-Plugin` with `Compiler` as a child of that script.
- `plugin-debug.project.json`: Live plugin debug target (`PluginDebugService`) for seeing the toolbar button while serving.
- `plugin.project.json`: Build target for an upload/test plugin model.
- `NetRayCompilerPlugin.server.luau`: Plugin UI + compile workflow.
- `Compiler/`: Bundled compiler modules adapted for Studio `ModuleScript` requires.

## Rojo Commands

From `Roblox-Plugin/`:

1. Source sync into `ReplicatedStorage`:
   - `rojo serve default.project.json`
2. Live plugin debug in Studio (shows toolbar button):
   - `rojo serve plugin-debug.project.json`
3. Build plugin model for local plugin install/upload:
   - `rojo build plugin.project.json -o build/NetRayCompilerPlugin.rbxm`

To install as a local plugin directly:

- `rojo build plugin.project.json -o "$env:LOCALAPPDATA/Roblox/Plugins/NetRayCompilerPlugin.rbxm"`

## Studio Usage

1. Open the **NetRay** toolbar button.
2. Paste IDL into the editor (or use **Load Selection** from a selected script).
3. Click **Compile to ReplicatedStorage**.

Output is always written to:

- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`
