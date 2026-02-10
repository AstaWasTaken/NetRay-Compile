---
title: Type System
layout: default
nav_order: 5
---

## Primitive Types
- `bool` / `boolean`
- `u8`, `i8`
- `u16`, `i16`
- `u32`, `i32`
- `f32`, `f64`
- `string`

Type aliases are normalized internally (`boolean` and `bool` both map to `bool`).

## Numeric Ranges
Integer checks (when validation is active) use these ranges:

| Type | Range |
| --- | --- |
| `u8` | `0` to `255` |
| `i8` | `-128` to `127` |
| `u16` | `0` to `65535` |
| `i16` | `-32768` to `32767` |
| `u32` | `0` to `4294967295` |
| `i32` | `-2147483648` to `2147483647` |

Notes:
- `f32` and `f64` are numeric but not integer-range checked.
- `bool` is encoded as a tagged byte.

## String Bounds
Supported forms:
- `string`
- `string<64>`
- `string(64)`
- `string(8, 64)` (upper bound is used)

Declared max length must be `<= 65535`.
Without declared max, runtime uses varint length prefixes (up to `4294967295`).

## Optional
```idl
optional u16
optional string<32>
optional array<u8, 32>
```

Encoding behavior:
- Optional values carry a 1-byte presence tag.
- Tag `0`: value is `nil`.
- Tag `1`: value is present and encoded immediately after.

## Array
```idl
array<u16>
array<u16, 128>
array<Pose, 50>
```

- Optional max bound syntax: second generic argument.
- Declared max must be `<= 65535`.
- Without declared max, runtime uses varint count prefixes (up to `4294967295`).

Array notes:
- Dense arrays are expected when full validation is enabled.
- Boolean arrays may be packed in generated codecs for size efficiency.

## Map
```idl
map<string<32>, u16>
map<u16, Pose, 128>
```

- Optional max entry bound syntax: third generic argument.
- Declared max must be `<= 65535`.
- Without declared max, runtime uses varint count prefixes (up to `4294967295`).

Map notes:
- Maps are encoded by iterating `next(table, key)`.
- Key iteration order in Lua tables is not stable, so map wire ordering is not guaranteed.
- For deterministic results, prefer stable key spaces and avoid depending on insertion order.

## Struct References
Use struct names as field/parameter types:

```idl
struct Pose {
  x: f32,
  y: f32,
}

event Move {
  Data: Pose,
}
```

When used in callbacks, struct parameters are affected by `DecodeStruct`:
- `Locals`: struct fields may expand into individual callback arguments.
- `Table`: struct is passed as one table argument.

## Passthrough
Passthrough values bypass buffer serialization and travel as extra Remote arguments.

```idl
event Example {
  Data: (u16, passthrough Player),
}
```

Forms:
- `passthrough` (treated as `any`)
- `passthrough <TypeName>`

When validation is enabled (`Validate` not `Off`):
- pass count must match schema.
- values must be non-`nil`.
- typed passthrough values are checked by `typeof` and `IsA`.

## Validation Modes and Type Safety
- `Validate = Off`: minimal checks.
- `Validate = Basic`: schema/bounds/tag checks.
- `Validate = Full`: strongest runtime shape/type checks for values.

Use `Full` while developing schemas, then relax only if needed for performance.

## Current Non-Supported Type Targets
- Enum values as serialization types are not emitted.
- Unknown type names that are not declared structs will fail generation.
