---
title: Options
layout: default
nav_order: 6
---

## Supported Options
### `Validate`
```idl
option Validate = Off;   // default
option Validate = Basic;
option Validate = Full;
```

Behavior:
- `Off`: minimal validation.
- `Basic`: schema/bounds/tag checks.
- `Full`: includes stronger runtime type/shape checks.

Invalid value fails compile: `Invalid Validate option value ...`.

### `TypeBranding`
```idl
option TypeBranding = Off;  // default
option TypeBranding = On;
```

Behavior in generated `Types`:
- `Off`: numeric aliases are plain `number`.
- `On`: numeric aliases are branded Luau types (`Brand<number, "u16">`, etc).

### `DecodeStruct`
```idl
option DecodeStruct = Locals; // default
option DecodeStruct = Table;
```

Behavior for incoming callbacks (`On` handlers):
- `Locals`: struct payload params are expanded to local callback args.
- `Table`: struct payload params stay as table values.

Example with `Data: Pose` where `Pose` has `x` and `y`:
- `Locals` callback receives `data_x, data_y`.
- `Table` callback receives `data`.

## Option Name Matching
Option names are case-insensitive during resolution (`validate`, `Validate`, `VALIDATE` all work).

## Important Frontend Note
`option remote_scope = "..."` may appear in legacy schemas, but current compiler flow does not consume it.  
Set remote scope using the plugin scope text box.
