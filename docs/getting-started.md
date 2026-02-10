---
title: Getting Started
layout: default
nav_order: 2
---

## Install the Plugin
Use the official Creator Store listing:

- [NetRayCompilerPlugin on Roblox Creator Store](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin)

In Studio:
1. Open the link above.
2. Click **Get**.
3. Restart Studio if it is already open.

## Open the Plugin in Studio
1. Start Roblox Studio.
2. Open the **NetRay** toolbar.
3. Click **NetRayCompiler**.

## First Compile
1. Enter a remote scope name (for example `NetRay`).  (Optional)
2. Paste IDL into the editor.
3. Click **Compile to ReplicatedStorage**.

On success, the plugin writes:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`

## Scope Name and Remote Names
If scope is `Combat`, generated remotes are:
- `Combat_RELIABLE`
- `Combat_UNRELIABLE`
- `Combat_FUNCTION`

## Important
{: .warning }
`option remote_scope = "...";` in schema text is currently not used by the compiler frontend. Use the plugin scope text box instead.
