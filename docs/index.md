---
layout: home

hero:
  name: "NetRay Compiler"
  text: "Next-Gen Roblox Networking"
  tagline: Generate type-safe, optimized networking code directly in Roblox Studio. Stop writing boilerplate. Start shipping features.
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started
    - theme: alt
      text: View Schema Reference
      link: /schema-reference
    - theme: alt
      text: View Changelog
      link: /changelog
  image:
    src: /Vector.png
    alt: NetRay Compiler Logo

features:
  - title: End-to-End Type Safety
    details: Define your network protocol once in IDL. Get fully typed Luau code for both Client and Server instantly.
  - title: High Performance
    details: Optimized binary serialization and intelligent batching ensure minimal bandwidth and CPU usage.
  - title: Studio Native
    details: No external CLI required. The NetRay Compiler plugin integrates seamlessly into your Roblox Studio workflow.
---

## Why NetRay?

NetRay Compiler bridges the gap between complex networking requirements and developer experience. By using a specialized Interface Definition Language (IDL), it eliminates category errors and manual remote management.

### Key Capabilities
- **Strict Schema Definitions**: Define events, functions, and structs in a clear, concise syntax.
- **Automated Replication**: Changes flow automatically from your schema to your game code.
- **Runtime Optimization**: Built-in support for reliable/unreliable channels, segmented batching, and order preservation.
- **Modern Event Modes**: `Call` supports single-handler, multi-handler, and polling receive APIs.

## Example Schema

```rust
struct PlayerData {
    Health: u8,
    Inventory: { u16 }
}

event PlayerAction {
    From: Client,
    Type: Reliable,
    Call: SingleAsync,
    Data: (Vector3, string)
}
```
