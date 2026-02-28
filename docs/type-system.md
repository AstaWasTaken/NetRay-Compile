# Type System

## Primitive Types
NetRay supports standard primitive types for efficient binary serialization.

- **Boolean:** `bool` / `boolean`
- **Integer (Unsigned):** `u8`, `u16`, `u32`
- **Integer (Signed):** `i8`, `i16`, `i32`
- **Float:** `f16` (New), `f32`, `f64`
- **String:** `string`
- **Buffer:** `buffer`
- **Roblox Types:**
  - `vector`: defaults to `vector<f32>` (X/Y/Z)
  - `cframe`: Position + YXZ Euler Angles (via `ToOrientation`)
  - `color3`: RGB values quantized to u8 (0-255)
  - `brickcolor`: u16 ID
  - `datetime`: Unix timestamp (f64)
  - `datetimemillis`: Unix timestamp millis (f64)
- **Dynamic:** `unknown`

::: info Type Normalization
Type aliases are normalized internally. For example, `boolean` and `bool` are treated as identical. `vector3` is normalized to `vector`.
:::

::: warning Precision
- **Color3** is quantized to 8-bit channels (0-255). Precision loss may occur.
- **CFrame** is serialized using `ToOrientation()`. This handles rotations compactly but may introduce minor precision loss or gimbal lock near vertical orientations.
:::

## Numeric Ranges
When validation is enabled (`Validate` option), integers are checked against these ranges:

| Type | Range |
| :--- | :--- |
| `u8` | `0` to `255` |
| `i8` | `-128` to `127` |
| `u16` | `0` to `65535` |
| `i16` | `-32,768` to `32,767` |
| `u32` | `0` to `4,294,967,295` |
| `i32` | `-2,147,483,648` to `2,147,483,647` |

**Notes:**
- `f32` and `f64` are not range-checked (standard IEEE 754 behavior).
- `bool` utilizes a single byte tag.

## String Bounds
Strings can be bounded or unbounded.

- `string`: Unbounded (up to 4GB).
- `string<64>`: Max 64 bytes.
- `string(64)`: Alternative syntax for Max 64 bytes.
- `string(8, 64)`: Alternative syntax with min/max bounds.

::: warning Size Limit
Declared max length must be `<= 65535`. Without a declared max, the runtime uses varint length prefixes which support up to `4,294,967,295` bytes.
:::

## Container Types

### Optional
```rust
optional u16
optional string<32>
optional array<u8, 32>
```
- Carries a **1-byte presence tag**.
- Tag `0`: `nil`.
- Tag `1`: value follows.

### Array
```rust
array<u16>
array<u16, 128>
array<Pose, 50>
```
- **Dynamic length list.**
- Optional max bound (2nd arg).
- Without declared max, uses varint count prefix.
- **Optimization:** Boolean arrays are bit-packed.

### FixedArray
```rust
fixedarray<u16, 128>
fixedarray<Pose, 50>
u16[128] // Shorthand
Pose[50] // Shorthand
```
- **Fixed length list.** Length is required.
- **No length prefix** emitted in payload (saves bandwidth).
- Boolean fixed arrays are bit-packed.

### Map
```rust
map<string<32>, u16>
map<u16, Pose, 128>
{[string<32>]: u16} // Shorthand
```
- Key-Value store.
- Optional max entry bound (3rd arg).
- **Note:** Iteration order is undefined (Lua `next` behavior). Do not rely on wire order.


## Set
```rust
set Weapons {
    Sword,
    Bow,
    Magic
}
```
- Defines a set of unique flags/identifiers.
- Emitted as a table of booleans: `export type Weapons = { Sword: boolean, Bow: boolean, Magic: boolean }`.
- Efficiently bit-packed on the wire.

## Tagged Enum (Sum Type)
```rust
enum Shape {
    Circle { radius: f32 },
    Rectangle { width: f32, height: f32 },
    Point // Unit variant
}
```
- Defines a type that can be one of several variants.
- Emitted as a Luau type union.
- **Wire Format:** 1-byte tag (or more for large enums) + variant payload.
- **Usage:**
  ```luau
  -- Generated Type
  export type Shape = 
      | { Type: "Circle", radius: number }
      | { Type: "Rectangle", width: number, height: number }
      | { Type: "Point" }
  ```

## Struct References

You can use defined structs as field types.

```rust
struct Pose {
  x: f32,
  y: f32,
}

event Move {
  Data: Pose,
}
```

::: tip Locals vs Table
If you use `option DecodeStruct = Locals;`, struct fields in callbacks will be unpacked as individual arguments instead of a single table.
:::

## Passthrough
Passthrough allows "any" type to bypass the binary serializer and be sent as a raw RemoteEvent argument.

```rust
event Example {
  Data: (u16, passthrough Player),
}
```

- `passthrough`: Treated as `any`.
- `passthrough <TypeName>`: Checked via `typeof` or `IsA` if validation is on.

::: warning Performance
Passthrough values are **not** optimized by NetRay. They use standard Roblox serialization logic and cost.
:::

## Validation Modes
Configure via `option Validate = ...;`

- **`Off`**: Minimal checks. High performance.
- **`Basic`**: Schema bounds and tag checks.
- **`Full`**: Strict shape and type checking for all values.

::: tip Recommendation
Use **`Full`** during development to catch bugs early. Switch to `Basic` or `Off` in production if profiling shows bottlenecks. `Off` is the default and recommended as it allows for maximum performance.
:::
