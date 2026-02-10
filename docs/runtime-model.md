---
title: Runtime Model
layout: default
nav_order: 8
---

## Transport Layout
Generated runtime uses three remotes in `ReplicatedStorage`:
- `<Scope>_RELIABLE` (`RemoteEvent`)
- `<Scope>_UNRELIABLE` (`UnreliableRemoteEvent`)
- `<Scope>_FUNCTION` (`RemoteFunction`)

`<Scope>` comes from plugin scope text box (default `NetRay`).

## Remote Lifecycle
- Server runtime: finds or creates remotes.
- Client runtime: waits for existing remotes.
- If a remote exists with wrong class, server throws.

## Message IDs
IDs are assigned during analysis, independently per category:
- Reliable events: 1..N
- Unreliable events: 1..N
- Functions: 1..N

Message ID width auto-selects `u8` or `u16` based on max ID (hard max `65535`).

## Batching and Flush
- Events are queued into arena buffers.
- `StepReplication()` flushes reliable and unreliable queues.
- `StepReplication()` is auto-connected to `RunService.Heartbeat`.
- The method is also exposed on returned `Net` table.

## Segmented Run Compaction
Flush logic can compact contiguous runs of same message ID into a segment marker format when that is smaller.

## Payload Versioning
All payloads include a leading payload version byte.  
Mismatched version is treated as schema error.

## Stats
Generated `Net.Stats` exposes:
- `GetReliableDropped()`
- `GetUnreliableDropped()`
- `GetReliableQueueSize()`
- `GetUnreliableQueueSize()`

{: .note }
Current dropped counters are initialized but not incremented by emitted runtime, so dropped values remain `0` with current generator behavior.
