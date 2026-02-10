---
title: FAQ
layout: default
nav_order: 11
---

## Is there a CLI?
Not yet. Current supported workflow is the Roblox Studio plugin only.

## Where are generated modules written?
Always to `ReplicatedStorage/NetRay` with modules:
- `Server`
- `Client`
- `Types`

## Does `option remote_scope` control remote names?
No in current frontend flow. Use the plugin scope textbox.  
Remote names become `<Scope>_RELIABLE`, `<Scope>_UNRELIABLE`, and `<Scope>_FUNCTION`.

## Can server send an event to one player directly?
Generated event send API on server is `FireAll(...)` only. Per-player event send method is not currently emitted.

## Can I register multiple callbacks for one message?
No. `On(...)` stores one active handler per message. Registering another replaces the previous one.

## Are enums fully supported?
Enums are parsed but not emitted as serialization/runtime types.

## Why are callbacks receiving expanded struct fields?
You are likely using `option DecodeStruct = Locals` (default).  
Set `option DecodeStruct = Table` if you want full struct tables in callbacks.

## Why are dropped stats always zero?
Current generated runtime initializes dropped counters but does not increment them.