# Generated API

## Output Modules
The Studio plugin writes ModuleScripts to `ReplicatedStorage/NetRay`:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`

## Requiring Modules

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NetServer = require(ReplicatedStorage.NetRay.Server)
local NetClient = require(ReplicatedStorage.NetRay.Client)
local Types = require(ReplicatedStorage.NetRay.Types)
```

## Exported Types
`Types` exports:
- `NetServer`, `NetClient`, `Net`
- `NetStats`
- `Connection`
- Numeric aliases (`u8`, `i8`, `u16`, ...)
- All schema `struct`, `enum`, `set`, and tagged enum types

## Event API Surface
Methods depend on `From` and runtime side.

### Client side
- Send allowed (`From: Client` or `Both`): `Fire(...)`
- Receive allowed (`From: Server` or `Both`, `Call != Polling`): `On(callback)`
- Receive allowed (`From: Server` or `Both`, `Call == Polling`): `Iter()`

### Server side
- Send allowed (`From: Server` or `Both`): `Fire(player, ...)`
- Send allowed (`From: Server` or `Both`): `FireAll(...)`
- Send allowed (`From: Server` or `Both`): `FireList(players, ...)`
- Send allowed (`From: Server` or `Both`): `FireExcept(excludedPlayer, ...)`
- Receive allowed (`From: Client` or `Both`, `Call != Polling`): `On(callback)`
- Receive allowed (`From: Client` or `Both`, `Call == Polling`): `Iter()`

## Function API Surface
Functions generate on both sides:
- `On(callback)` for inbound handling.
- `Call(...)` for outbound request/response.

Server signatures include `player: Player` where direction requires it.

## Handler Model
Event handler behavior depends on `Call`:
- `SingleSync` / `SingleAsync`: one active handler.
- `ManySync` / `ManyAsync`: multiple active handlers.
- `Polling`: buffered receive queue via `Iter()`.

Function handlers are single-slot (`On` replaces previous handler).

## Return Value Conventions
- Event `Fire*` methods return `boolean` (`true` on enqueue/send success).
- Validation/serialization failures throw runtime error codes.

## Scope Mapping
Nested schema scopes map to nested API tables:

```rust
scope Gameplay {
  scope Cars {
    event Spawned { Data: u16 }
  }
}
```

```luau
Net.Gameplay.Cars.Spawned
```

## Struct Payload Shapes
Given:

```rust
struct Pose {
  x: f32,
  y: f32,
}

event Move {
  From: Both,
  Data: Pose,
}
```

- Sender side: `Net.Move.Fire({ x = 10, y = 20 })`
- Receiver side with `DecodeStruct = Locals`: `On(function(x, y) ... end)`
- Receiver side with `DecodeStruct = Table`: `On(function(pose) ... end)`

## Runtime Loop and Stats
- `Net.StepReplication()` flushes pending event queues.
- Runtime also auto-flushes from `RunService.Heartbeat`.
- `Net.Stats.GetReliableQueueSize()`
- `Net.Stats.GetUnreliableQueueSize()`
- `Net.Stats.GetReliableDropped()`
- `Net.Stats.GetUnreliableDropped()`
