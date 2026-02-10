---
title: Generated API
layout: default
nav_order: 7
---

## Output Modules
Plugin compile generates:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`

## Requiring Modules
Server script:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.NetRay.Server)
```

Client script:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.NetRay.Client)
```

Types:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.NetRay.Types)
type NetServer = typeof(Types.NetServer)
type NetClient = typeof(Types.NetClient)
```

## Event API Surface
Event methods depend on `From`.

### `From: Client`
- Client: `Fire(...)`
- Server: `On(callback)`

### `From: Server`
- Server: `FireAll(...)`
- Client: `On(callback)`

### `From: Both`
- Client: `Fire(...)`, `On(callback)`
- Server: `FireAll(...)`, `On(callback)`

## Function API Surface
Functions generate on both sides:
- `.On(callback)` for inbound request handling.
- `.Call(...)` for outbound request/response.

Server `Call` signature includes `player: Player` as first arg.

## Handler Model
- `On` stores one active handler per message.
- Registering a new handler replaces the previous one.
- Returned `Connection:Disconnect()` clears the handler if token matches.

## Return Value Conventions
- Event `Fire`/`FireAll` returns `boolean` and returns `true` on successful enqueue.
- Serialization/validation failures throw error codes instead of returning `false`.

## Scope Mapping
Nested schema scopes map to nested API tables:

```idl
scope Gameplay {
  scope Cars {
    event Spawned { Data: u16 }
  }
}
```

Usage:

```luau
Net.Gameplay.Cars.Spawned.Fire(15)
```

## Scope Design Tips
- Use top-level scopes as game systems (`Combat`, `Inventory`, `Match`).
- Nest by feature (`Inventory.Trade`, `Inventory.Crafting`) to keep call-sites obvious.
- Avoid very deep chains unless needed; readability of `Net.A.B.C.D` can degrade quickly.

## Struct Payload Shapes in API
Given:

```idl
struct Pose {
  x: f32,
  y: f32,
}

event Move {
  From: Both,
  Data: Pose,
}
```

API shape:
- Sender side: `Net.Move.Fire({ x = 10, y = 20 })`
- Receiver side:
  - with `DecodeStruct = Table`: callback gets one `data` table.
  - with `DecodeStruct = Locals`: callback can receive expanded fields.
