# Errors and Troubleshooting

## Parse & Schema Errors

### Token/Structure Errors
- `Unexpected token at line:column`
- `Unexpected token in scope`
- `Expected event parameter list or event block`
- `Expected function parameter list or function block`

### Event/Function Key Errors
- `E_EVENT_KEY`: unknown key in event block.
- `E_EVENT_FROM`: invalid `From` value.
- `E_EVENT_TYPE`: invalid `Type` value.
- `E_EVENT_CALL`: invalid `Call`/`Yield` call-mode token.
- `E_FUNCTION_KEY`: unknown key in function block.
- `E_UNSUPPORTED_YIELD`: function block `Yield` not supported (currently only `SingleSync`).

### Analyzer/Option Errors
- `E_DUP_STRUCT`: duplicate struct name.
- `E_DUP_ENUM`: duplicate enum name.
- `E_DUP_SET`: duplicate set name.
- `E_DUP_DECL`: name collision between struct/enum/set declarations.
- `Invalid Validate option value ...`
- `Invalid TypeBranding option value ...`
- `Invalid DecodeStruct option value ...`

## Runtime Error Codes
Generated runtime uses short error strings to save binary size & string constants:

| Error | Meaning |
| :--- | :--- |
| `E_BOUNDS` | Buffer read/write bounds violation. |
| `E_SCHEMA` | Invalid payload schema, version, or message shape. |
| `E_TAG` | Invalid optional/boolean tag values. |
| `E_TYPE` | Lua type mismatch at runtime boundary. |
| `E_PASS` | Passthrough argument validation failure. |

## Plugin-Side Failures
| Error | Context |
| :--- | :--- |
| `Schema is empty` | Schema editor has no content. |
| `Compile failed: ...` | Parser/analyzer/generator error. |
| `Compiled, but write failed: ...` | Module write path failed (permissions/locked). |
| `Select exactly one Script...` | Invalid selection count or non-source object selected. |

## Quick Troubleshooting
::: tip Fixes
1. **Validation**: Start with `option Validate = Full;` while authoring schema.
2. **Direction**: Confirm `From` and call direction match your runtime usage.
3. **Uniqueness**: Keep schema names unique, especially structs.
4. **Callbacks**: If callbacks receive unexpected params, check `option DecodeStruct`.
5. **Replication**: If remotes fail on client, verify plugin scope name matches server text.
:::
