# FAQ

## Is there a CLI?
No public standalone CLI is documented yet. The supported frontend in this repository is the Roblox Studio plugin workflow.

## Where are generated modules written?
Studio plugin output path:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`

## Does `option remote_scope` control remote names?
Yes. The plugin compiler and `src/Compiler.luau` both honor `option remote_scope`.

Remote names follow: `<Scope>_RELIABLE`, `<Scope>_UNRELIABLE`, `<Scope>_FUNCTION`.

## Can server send an event to one player directly?
Yes, generated server APIs include `Fire(player, ...)` when server send direction is allowed.

## Can I register multiple callbacks for one message?
It depends on `Call` mode:
- `SingleSync` / `SingleAsync`: single active handler.
- `ManySync` / `ManyAsync`: multiple handlers.
- `Polling`: no callbacks; consume via `Iter()`.

## Are enums supported?
Yes.
- Unit enums are emitted as Luau string-literal unions.
- Tagged enums are emitted as tagged table unions and serialized on the wire.

## What do `Call` and `Yield` modes do?
- Event `Call` controls receive API shape (`On` single/multi vs `Iter` polling).
- Function `Yield` currently supports only `SingleSync`.

## Why are callbacks receiving expanded struct fields?
You are using `option DecodeStruct = Locals` (default).
Use `option DecodeStruct = Table` to receive struct tables.

## Why are dropped stats often zero?
The runtime exposes drop counters, but many schemas and workloads will not trigger queue drops under normal conditions.
