---
title: Errors and Troubleshooting
layout: default
nav_order: 9
---

## Parse/Schema Errors
### Token/structure errors
- `Unexpected token at line:column`
- `Unexpected token in scope`
- `Expected event parameter list or event block`
- `Expected function parameter list or function block`

### Event/function key errors
- `E_EVENT_KEY`: unknown key in event block.
- `E_EVENT_FROM`: invalid `From` value.
- `E_EVENT_TYPE`: invalid `Type` value.
- `E_EVENT_CALL`: invalid `Call`/`Yield` call-mode token.
- `E_FUNCTION_KEY`: unknown key in function block.
- `E_UNSUPPORTED_YIELD`: function block `Yield` not supported (currently only `SingleSync`).

### Analyzer/option errors
- `E_DUP_STRUCT`: duplicate struct name.
- `Invalid Validate option value ...`
- `Invalid TypeBranding option value ...`
- `Invalid DecodeStruct option value ...`

## Runtime Error Codes
Generated runtime uses short error strings:
- `E_BOUNDS`: buffer read/write bounds violation.
- `E_SCHEMA`: invalid payload schema/version/message shape.
- `E_TAG`: invalid optional/boolean tag values.
- `E_TYPE`: Lua type mismatch at runtime boundary.
- `E_PASS`: passthrough argument validation failure.

## Plugin-Side Failures
- `Schema is empty`: schema editor has no content.
- `Compile failed: ...`: parser/analyzer/generator error.
- `Compiled, but write failed: ...`: module write path failed.
- Load Selection errors: invalid selection count or non-source object selected.

## Quick Fixes
1. Start with `option Validate = Full;` while authoring schema.
2. Confirm `From` and call direction match your runtime usage.
3. Keep schema names unique, especially structs.
4. If callbacks receive unexpected params, check `DecodeStruct` option.
5. If remotes fail on client, verify plugin scope name matches both ends.
