# Noir

Noir is an in-game Lua scratchpad for Garry's Mod. It provides a code editor, a REPL, a file browser, and an execution layer that runs code across realms (self, server, clients, or shared). It is built on [gmod-monaco](https://github.com/Metastruct/gmod-monaco) and runs best on the GMod chromium branch.

![The editor with the file tree open](assets/editor_with_file_tree_open.png)

> More screenshots in [assets folder](https://github.com/JustMrPhoenix/Noir/tree/master/assets)

## Features

- **Run code anywhere** on self, server, all clients, a specific client, or shared. Return values and captured output (`print`, `Msg`, errors) are sent back to the console, including output from hooks and timers that fire after the run.
- **REPL console** built on the same Monaco editor, with foldable results and clickable `@file.lua:line` links to function definitions.
- **JIT decompiler** (`jit_decompiler2`): reconstructs readable Lua from LuaJIT 2.1 bytecode for functions with no source on disk, resolving constants, upvalues, and real local names.
- **easylua-style helpers**: `me`, `this`, `there`, `dir`, search tables (`all`, `us`, `bots`, `props`), and `last`; unrecognized identifiers resolve through entity search.
- **In-world entity picker**: point at, list nearby, or filter entities by class/model and pass the reference back to your code.
- **Find in Files**: searches every Lua file locally and on the remote server, on a per-frame time budget with an accurate progress bar (`Ctrl+Shift+F`).
- **Autorun**: runs a configured list of scripts on load, with crash protection that disables autorun if a script crashed the game.
- **File browser** for opening and saving across `DATA`, `LUA`, and `GAME` paths.
- **GMod-aware autocomplete** covering the API (functions, methods, enums, hooks) plus your live runtime tables, with wiki docs on hover.
- **luacheck diagnostics** as you type.
- **Monaco editor features**: command palette, code folding, tabs, activity bar with file tree, snippets, minimap, and a custom theme.
- **NDL**: a debug library (`NDL` global) with function detours, argument filters, and call tracers.

![REPL output showing folding, clickable source links, and magic vars](assets/repl_with_folding.png)

## Contributing

Open a PR. Lint your changes with [glualint](https://github.com/FPtje/GLuaFixer) before submitting
