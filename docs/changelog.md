---
title: Changelog
---

# Changelog

## v0.1.1

- Expanded IDL type coverage, event call-mode APIs, parser/analyzer capabilities, and runtime generation performance.

### Added
- New IDL type support: `f16`, `buffer`, `vector`/`vector3`, `cframe`, `brickcolor`, `color3`, `datetime`, `datetimemillis`, `instance(...)`, and `unknown`.
- `set` declarations and tagged enums (`enum Name { ... }` with default `Type` tag, or `enum Name = Tag { ... }` / `enum Name = "tag-name" { ... }`).
- Inline type declarations in schemas (`struct { ... }`, inline `enum { ... }`).
- `fixedarray<T, N>` support plus shorthand forms like `T[N]`.
- Map shorthand support (`{[K]: V}`).
- Extended bounds syntax for numeric/string/collection types (range-style and bracket forms).
- `option remote_scope = ...` support in compiler scope resolution.

### Changed
- Parser/analyzer improvements across type resolution, declaration analysis, and option handling.
- Event call-mode generation updates (`SingleSync`, `ManySync`, `SingleAsync`, `ManyAsync`, `Polling` with `Iter()`).
- Blink-style event/function block parsing is now supported alongside legacy syntax.
- Function `Yield` parsing remains restricted to `SingleSync` in current generator behavior.
- Runtime generation improvements (segmented queue batching, canonical encode/decode paths, stricter validation flow).
- Generator architecture has been split into dedicated modules (`Runtime`, `Emitters`, `EmitTypes`, `Utilities`, `Types`) for maintainability.
- Lower byte usage per payload, including reduced metadata overhead in bounded collections.

### Performance
- Lower bandwidth usage (approximately `~1-2%` for reliable and unreliable paths).
- Decoding speed has improved significantly.
- Encoding speed has improved slightly.
- Lower packet byte usage overall.

## v0.1.0

Initial public baseline for the Roblox Studio plugin workflow.

### Included
- Core IDL schema parsing for `option`, `scope`, `struct`, `enum`, `event`, and `function`.
- Generation of `Server`, `Client`, and `Types` modules under `ReplicatedStorage`.
- Reliable/unreliable event channels and request/response function APIs.
- Validation option levels (`Off`, `Basic`, `Full`) and generated typed Luau API surface.
