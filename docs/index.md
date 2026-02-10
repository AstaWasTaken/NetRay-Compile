---
title: Home
layout: default
nav_order: 1
---

<div class="home-hero">
  <p class="status-pill">Studio Plugin Available</p>
  <h1>NetRay Compiler Documentation</h1>
  <p>Compile NetRay IDL into generated <code>Server</code>, <code>Client</code>, and <code>Types</code> modules directly inside Roblox Studio.</p>
</div>

**External CLI status:** External CLI is not publicly available yet. Current supported user workflow is the Roblox Studio plugin.

## What This Covers
- Installing and running the Studio plugin.
- Full NetRay IDL schema reference (legacy + block style).
- Type system, options, and limits.
- Generated API behavior on server and client.
- Runtime model, remotes, error codes, and troubleshooting.

## Fast Links
<div class="quick-grid">
  <a class="quick-card" href="getting-started">Getting Started</a>
  <a class="quick-card" href="studio-plugin-workflow">Studio Plugin Workflow</a>
  <a class="quick-card" href="schema-reference">Schema Reference</a>
  <a class="quick-card" href="type-system">Type System</a>
  <a class="quick-card" href="options">Options</a>
  <a class="quick-card" href="generated-api">Generated API</a>
  <a class="quick-card" href="runtime-model">Runtime Model</a>
  <a class="quick-card" href="errors-and-troubleshooting">Errors &amp; Troubleshooting</a>
  <a class="quick-card" href="schema-examples">Schema Examples</a>
  <a class="quick-card" href="faq">FAQ</a>
</div>

## Current Product Status
- Supported frontend: Roblox Studio plugin.
- Install plugin: [Creator Store](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin).
- Generated outputs: `ReplicatedStorage/NetRay/Server`, `ReplicatedStorage/NetRay/Client`, `ReplicatedStorage/NetRay/Types`.
- External CLI: planned, not released.
