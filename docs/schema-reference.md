---
title: Schema Reference
layout: default
nav_order: 4
---

## File-Level Declarations
Schema supports:
- `option`
- `scope`
- `struct`
- `enum`
- `event`
- `function`

## Comments
Both comment styles are supported:

```idl
// single line comment
-- single line comment
```

## Option Syntax
```idl
option Validate = Full;
option DecodeStruct = Table;
```

Option values may be string, identifier/keyword, or number tokens.

## Scopes
Scopes group declarations and support nesting.

```idl
scope Gameplay {
  scope Vehicles {
    event Spawned { Data: u16 }
  }
}
```

Generated API paths follow scope nesting:
- `Net.Gameplay.Vehicles.Spawned` on server/client modules.

Scope rules:
- You can nest scopes arbitrarily.
- `struct`, `enum`, `event`, `function`, and `scope` are all allowed inside a scope.
- Message IDs are assigned by declaration order while walking nested scopes.
- IDs are global per category (reliable, unreliable, function), not per scope.

## Scope and Name Resolution
### Root API table
Generated API root is always `Net`:

```luau
Net.Gameplay.Vehicles.Spawned
```

### Struct names are global
Struct declarations are collected globally across the full schema tree.  
Duplicate struct names (even in different scopes) cause `E_DUP_STRUCT`.

### Full message names
Internally, messages are tracked with their full scoped name (for example `Net.Gameplay.Vehicles.Spawned`).  
This affects generated symbol names and error context.

## Structs
Both field syntaxes are valid:

```idl
struct Car {
  id: u16,
  name: string<64>,
}
```

```idl
struct Car {
  u16 id;
  string<64> name;
}
```

Separators can be commas or semicolons. Trailing separators are accepted.

Struct emission notes:
- Structs are serialized field-by-field in declaration order.
- Struct field order is wire-significant (reordering fields changes payload layout).
- Referencing an unknown type name as a field/param will fail generation.

## Enums
Enum declarations are parsed:

```idl
enum Team {
  Red,
  Blue,
}
```

{: .warning }
Enums are currently parser-level only and are not emitted as runtime serialization types.

## Events
### Legacy Event Syntax
```idl
event reliable Position(u16 id, f32 x, f32 y);
event unreliable Ping(u16 seq);
event MatchStarted();
```

- Reliability prefix optional; default is `reliable`.

### Block Event Syntax
```idl
event Position {
  From: Client,
  Type: Reliable,
  Call: ManySync,
  Data: (u16, f32, f32),
}
```

Supported keys:
- `From`: `Client | Server | Both` (default `Both`).
- `Type`: `Reliable | Unreliable` (default from event reliability, then `Reliable`).
- `Call`: `SingleSync | ManySync | SingleAsync | ManyAsync | Polling` (default `ManySync`).
- `Data`: either a single type (`Data: Pose`) or tuple (`Data: (u16, string<32>)`).

Unknown keys trigger `E_EVENT_KEY`.

{: .note }
Current generator behavior is driven by `From` and `Type`. `Call` is accepted/validated for schema compatibility but does not currently switch emitted transport logic.

## Functions
### Legacy Function Syntax
```idl
function GetState(u16 id) -> (bool active, string<32> mode);
function Ping() -> ();
```

### Block Function Syntax
```idl
function GetState {
  Yield: SingleSync,
  Data: (u16),
  Return: (bool, string<32>),
}
```

Supported keys:
- `Yield`: currently only `SingleSync` is accepted.
- `Data`: request arguments.
- `Return`: response values.

Unknown keys trigger `E_FUNCTION_KEY`.

{: .note }
Function transport is request/response via generated `Call`/`On` on both sides. `Yield` is currently schema metadata with `SingleSync` as the accepted value.

## Separators and Trailing Tokens
- `event`/`function` blocks may end with optional `;`.
- Parameter/tuple lists allow trailing commas before `)`.
- Struct fields allow comma or semicolon separators.

## Declaration Ordering and Wire Compatibility
- Changing event/function declaration order changes assigned message IDs.
- Changing `Type` (Reliable/Unreliable) moves a message to a different ID space.
- Renaming scopes/messages changes API paths (and generated symbol names), even when payload shape stays the same.
