# Getting Started

## Installation

1. **Get the Plugin**

   Open the [NetRay Compiler Plugin](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin) on the Roblox Creator Store and click **Get**.

2. **Open in Studio**

   Launch Roblox Studio, open the **Plugins** tab, and look for the **NetRay** toolbar.

3. **Launch Interface**

   Click the **NetRayCompiler** button to open the compiler interface window.

## Your First Schema

1. In the **Scope Name** field, enter a name for your network definition (e.g., `NetRay`). -- Can be left empty.
2. Paste the following example into the editor:

    ```rust
    // A simple reliable event
    event reliable Greet {
        From: Client,
        Data: string,
    }
    ```

3. Click **Compile to ReplicatedStorage**.

::: tip Generated Assets
If successful, the plugin creates a folder structure in `ReplicatedStorage`:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`
:::

## Understanding Scopes

The **Scope Name** you enter (e.g., `Combat`) determines the names of the underlying RemoteEvents:
- `Combat_RELIABLE`
- `Combat_UNRELIABLE`
- `Combat_FUNCTION`

## Next Steps

- Learn the full [IDL Syntax](/schema-reference).
- see how to use the generated code in the [Using Generated API](/generated-api) guide.
