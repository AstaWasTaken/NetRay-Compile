# Schema Reference

## File-Level Declarations
Top-level declarations in an IDL file:
- `option` - Configure compiler behavior.
- `scope` - Namespace grouping.
- `struct` - Define data structures.
- `enum` - Define enums (unit or tagged).
- `set` - Define packed boolean-flag sets.
- `event` - Define network messages.
- `function` - Define request/response RPCs.

## Comments
Line comments are supported:

```rust
// This is a comment
-- This is also a comment
```

## Option Syntax

```rust
option Validate = Full;
option DecodeStruct = Table;
```

Option values may be strings, identifiers/keywords, or numbers.

## Scopes
Scopes namespace messages and can nest arbitrarily.

```rust
scope Gameplay {
  scope Vehicles {
    event Spawned { Data: u16 }
  }
}
```

Generated path: `Net.Gameplay.Vehicles.Spawned`

::: tip Scope Rules
- IDs are assigned by declaration order.
- IDs are global per category (`Reliable`, `Unreliable`, `Function`), not per scope.
:::

## Name Resolution

### Root API Table
Generated APIs start at `Net`.

```luau
Net.Gameplay.Vehicles.Spawned
```

### Global Type Names
Struct/enum/set names must be unique across the full schema (not just within one scope).

Possible errors include `E_DUP_STRUCT`, `E_DUP_ENUM`, `E_DUP_SET`, and `E_DUP_DECL`.

## Structs
Two field styles are supported.

```rust
struct Car {
  id: u16,
  name: string<64>,
}
```

```rust
struct Car {
  u16 id;
  string<64> name;
}
```

::: info Layout Rules
- Fields are serialized in declaration order.
- Reordering fields changes wire format.
:::

## Enums

```rust
enum Team {
  Red,
  Blue,
}
```

Emitted as Luau string-literal unions.

## Sets

```rust
set Flags {
  A,
  B,
  C
}
```

Emitted as `{ A: boolean, B: boolean, C: boolean }` and encoded as packed bits.

## Tagged Enums

```rust
enum Command {
  Move { x: u16, y: u16 },
  Stop,
}
```

Default tag field is `Type`.

```rust
enum Command = "kind-type" {
  Move { x: u16, y: u16 },
  Stop,
}
```

Custom tag fields can be identifiers or quoted strings.

## Events

### Block Syntax

```rust
event Position {
  From: Client,
  Type: Reliable,
  Call: ManySync,
  Data: (u16, f32, f32),
}
```

| Key | Values | Default | Description |
| :-- | :----- | :------ | :---------- |
| `From` | `Client`, `Server`, `Both` | `Both` | Who sends this event. |
| `Type` | `Reliable`, `Unreliable` | `Reliable` | Delivery channel. |
| `Call` | `SingleSync`, `ManySync`, `SingleAsync`, `ManyAsync`, `Polling` | `ManySync` | Receive-side handler model. |
| `Data` | Type or Tuple | - | Event payload. |

`Call` behavior in current generator:
- `SingleSync` / `SingleAsync`: single active `On` handler.
- `ManySync` / `ManyAsync`: multiple active `On` handlers.
- `Polling`: no `On`; generated API exposes `Iter()`.

::: danger Unknown Keys
Unknown block keys trigger `E_EVENT_KEY`.
:::

### Legacy Syntax

```rust
event reliable Position(u16 id, f32 x, f32 y);
event unreliable Ping(u16 seq);
```

## Functions

### Block Syntax

```rust
function GetState {
  Yield: SingleSync,
  Data: (u16),
  Return: (bool, string<32>),
}
```

| Key | Values | Default | Description |
| :-- | :----- | :------ | :---------- |
| `Yield` | `SingleSync` | `SingleSync` | Function mode (only `SingleSync` is currently valid). |
| `Data` | Type or Tuple | - | Request args. |
| `Return` | Type or Tuple | - | Response args. |

### Legacy Syntax

```rust
function GetState(u16 id) -> (bool active, string<32> mode);
```

## Syntax Rules
- Struct fields and list items may use `,` or `;`.
- Trailing separators are allowed.
- Reordering `event`/`function` declarations changes message IDs and can break wire compatibility.
