# NetRay Studio Plugin (Rojo)

This folder contains a local Roblox Studio plugin that compiles NetRay IDL with no HTTP requests.

For full language/runtime reference docs, see [`../docs/index.md`](../docs/index.md).

This is essentially a mirror of `src` but for the plugin, with a Plugin Script for Plugin UI 
Plugin Edits should be for the UI/Plugin Script and not the compiler itself
Compiler changes are to be done in `src`  

Output is always written to:

- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`
