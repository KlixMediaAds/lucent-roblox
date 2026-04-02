# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Roblox game project named **lucent-roblox**, managed with [Rojo](https://rojo.space/) for syncing files into Roblox Studio.

## Development Workflow

**Serve to Roblox Studio (live sync):**
```
rojo serve default.project.json
```

**Build a place file:**
```
rojo build default.project.json -o lucent.rbxl
```

> `.rbxl` and `.rbxlx` place files are gitignored — never commit them.

## Project Structure

Source lives under `src/`, mapped to Roblox's DataModel by `default.project.json`:

| Folder | Roblox location |
|---|---|
| `src/server/` | `ServerScriptService.Server` |
| `src/client/` | `StarterPlayer.StarterPlayerScripts.Client` |
| `src/shared/` | `ReplicatedStorage.Shared` |

- **Server** code runs only on the server (`Script`s).
- **Client** code runs only on each player's client (`LocalScript`s).
- **Shared** modules are accessible from both sides via `ReplicatedStorage` (`ModuleScript`s).

## Rojo File Conventions

Rojo maps files to Roblox instances based on naming:

- `*.server.lua` / `*.server.luau` → `Script`
- `*.client.lua` / `*.client.luau` → `LocalScript`
- `init.lua` / `init.luau` inside a folder → instance of the folder name
- Plain `*.lua` / `*.luau` → `ModuleScript`
