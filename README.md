<img width="5391" height="1167" alt="Vector" src="https://github.com/user-attachments/assets/a4235325-fe07-4630-8053-6990c06b8241" />

# NetRay-Compiler [BETA]
IDL compiler for NetRay runtime modules.

## Documentation
- GitHub Pages docs source lives in [`docs/`](docs/).
- See [`docs/index.md`](docs/index.md) for full usage/reference docs.

## Current Frontend Availability
- Supported: Roblox Studio plugin.
- Install plugin: [Creator Store](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin).
- Not yet public: external CLI frontend.

## IDL Syntax Support
- Legacy NetRay syntax stays supported:
  - `event reliable Name(type value, ...);`
  - `function Name(type arg, ...) -> (type ret, ...);`
  - `struct Name { type field; ... }`
- Blink-style blocks are supported:
  - `event Name { From, Type, Call, Data }`
  - `function Name { Yield, Data, Return }`
  - `struct Name { field: type, ... }`

##  Mapping Notes
- `From`: `Client | Server | Both` (default `Both`).
- `Type`: `Reliable | Unreliable`.
- `Call`: `SingleSync | ManySync | SingleAsync | ManyAsync | Polling`.
- `Data`:
  - `Data: StructName` -> single argument API (`Fire(dataTable)`).
  - `Data: (T1, T2, ...)` -> positional API (`Fire(v1, v2, ...)`).

## Wire Compatibility
- Existing legacy schemas keep the same message-id multiplexing and encode order.
- Struct payloads are flattened in declared field order using existing primitive/container codecs.
- Runtime transport architecture remains 3 remotes (`Reliable`, `Unreliable`, `Function`) with arena+cursor batching.
- Flush now uses order-preserving segmented batching for event queues:
- Only contiguous runs of the same message ID are compacted, and only when that shrinks bytes.
- Reliable callback order remains unchanged.

## Planned Updates
- Multi Listeners
- More supported types
- FireClient, FireFiltered, FireExcept

## Contributing
- All contributions welcome
- Open a Pull request or open a issue

### Local docs preview
- Ensure you have ruby installed

Run from `docs/`:

```powershell
bundle install
bundle exec jekyll serve --config _config.yml,_config.local.yml
```

Then open `http://127.0.0.1:4000/`.

### Roblox Plugin
- To contribute to the Plugin check [Roblox-Plugin/README.md](Roblox-Plugin/README.md)

### Compiler + IDL
- To Contribute to Compiler and/or IDL check [src](src)
- Ensure it passes `VerifyForbidden` before submitting Pull Request
