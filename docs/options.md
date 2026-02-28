# Options

## Supported Options

### `Validate`
```rust
option Validate = Off;   // default
option Validate = Basic;
option Validate = Full;
```

**Behavior:**
- **`Off`**: Minimal validation.
- **`Basic`**: Bounds and tag checks.
- **`Full`**: Strict type/shape checks.

::: danger Invalid Value
Providing an invalid option value will cause a compilation error: `Invalid Validate option value ...`
:::

### `TypeBranding`
```rust
option TypeBranding = Off;  // default
option TypeBranding = On;
```

**Behavior in generated `Types`:**
- **`Off`**: numeric aliases are plain `number`.
- **`On`**: numeric aliases are branded Luau types (for example `Brand<number, "u16">`).

### `DecodeStruct`
```rust
option DecodeStruct = Locals; // default
option DecodeStruct = Table;
```

**Behavior for incoming callbacks (`On` handlers):**
- **`Locals`**: struct payload params are expanded to callback args.
- **`Table`**: struct payload params stay as a single table value.

**Example:**
Given `struct Pose { x: f32, y: f32 }`:
- `Locals` callback receives: `(x, y)`
- `Table` callback receives: `({ x: ..., y: ... })`

### `remote_scope`
```rust
option remote_scope = "Combat";
```

**Compiler behavior (plugin and `src/Compiler.luau`):**
- Used as the generated remote name prefix.
- Takes precedence over the fallback scope argument passed to `Compiler.compile(source, scope)`.

## Option Name Matching
Option names are case-insensitive (`validate`, `Validate`, `VALIDATE` all work).
