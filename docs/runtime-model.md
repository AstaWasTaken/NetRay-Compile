# Runtime Model

## Transport Layout
Generated runtime uses three remotes in `ReplicatedStorage`:

| Remote Name | Type | Purpose |
| :--- | :--- | :--- |
| `<Scope>_RELIABLE` | `RemoteEvent` | Reliable events. |
| `<Scope>_UNRELIABLE` | `UnreliableRemoteEvent` | Unreliable events. |
| `<Scope>_FUNCTION` | `RemoteFunction` | Request/response functions. |

`<Scope>` comes from compiler scope selection (for plugin: the Scope Name textbox).

## Generated Module Layout
The Studio plugin writes generated modules to:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`

## Queue Buffering
- Event payloads are queued in per-channel arenas.
- Queues flush on `RunService.Heartbeat` and via `Net.StepReplication()`.
- Runtime keeps reliable and unreliable queues separate.

## Message IDs
- IDs are 1-indexed per category.
- Categories are independent: `Reliable`, `Unreliable`, `Function` each have their own counter.
- ID width is auto-selected (`u8` when possible, otherwise `u16`).

::: warning Order Dependence
IDs are declaration-order dependent. Reordering events/functions in a live protocol breaks compatibility.
:::

## Batching and Segmented Compaction
Flush builds batched payloads and applies contiguous-run compaction for repeated message IDs.

This reduces overhead while preserving event order.

## Remote Lifecycle
- Server creates remotes if missing, or validates existing classes.
- Client waits for remotes to replicate.
- Class mismatches fail early to avoid silent protocol corruption.

## Stats
`Net.Stats` exposes queue and drop counters:

```luau
print(Net.Stats.GetReliableQueueSize())
print(Net.Stats.GetUnreliableDropped())
```

Dropped counters are available in the API and may remain low/zero depending on runtime pressure.
