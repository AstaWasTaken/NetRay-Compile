# CLI Workflow

The NetRay CLI is a standalone frontend for the same compiler core used by the Studio plugin.

## Install With Rokit

```sh
rokit add AstaWasTaken/NetRay-Compile@<version> netray
```

The repo name stays `NetRay-Compile`, but the install command above aliases it to `netray` for day-to-day use.

## Compile a Schema

```sh
netray compile path/to/schema.idl --out-dir generated --scope NetRay
```

### Arguments
- `<schema-path>`: required path to the input IDL schema.

### Options
- `--out-dir <dir>`: required output directory for generated modules.
- `--scope <name>`: optional fallback scope when the schema does not set `option remote_scope`.

## Generated Output

On success, the CLI writes:
- `generated/Server.luau`
- `generated/Client.luau`
- `generated/Types.luau`

If the output directory does not exist, it is created automatically.

## Scope Precedence

`option remote_scope` in the schema takes precedence over the `--scope` CLI option.

Example:

```rust
option remote_scope = "Combat";
```

With that option present, generated remotes use `Combat_*` names even if you pass `--scope NetRay`.

## Failure Behavior

- Missing input file: exits with code `1`
- Invalid schema: exits with code `1`
- Invalid output path / write failure: exits with code `1`

Errors are printed directly in the terminal so the command is usable in scripts and CI jobs.
