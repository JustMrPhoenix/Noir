# NDL — Noir Debug Library

Function detour / filter / tracer utilities plus a few debug helpers. Lives on the global `NDL`
(alias `Noir.DebugLib`). Standalone — Noir doesn't depend on it; it's a tool for code running in the
REPL. Loaded last in `Noir.Load()` via `ndl/load.lua`.

All the `Inject`/`Detour`/`Trace*` functions take `(targetTbl, funcName, ...)` — they mutate
`targetTbl[funcName]` in place and remember the original so it can be restored later.

---

## Injection — `injection.lua`

### `NDL.Inject(targetTbl, funcName, toInject)`
Replace `targetTbl[funcName]` with `toInject`. The replacement gets no reference to the original —
it *is* the new function. Injects stack: injecting over an existing inject pushes a layer, so
`RestoreInject` unwinds one at a time. Errors if the function doesn't exist.

```lua
NDL.Inject(_G, "print", function(...) end) -- silence print entirely
```

### `NDL.Detour(targetTbl, funcName, detourFunc)`
Like `Inject`, but the detour receives the original (the trampoline) as its **first argument**.
Whatever the detour returns is what the caller gets:

- pass through: `return original(...)`
- replace: return your own values
- suppress: return nothing
- an error in the detour propagates to the caller (a broken detour fails the call; it does **not**
  fall back to the original)

```lua
NDL.Detour(_G, "print", function(original, ...)
	return original("[hooked] ", ...)
end)
```

### `NDL.RestoreInject(targetTbl, funcName)`
Pop the top inject/detour layer, restoring whatever was underneath (an original, or a previous
layer). No-op if nothing is injected there. Trace history is left intact.

```lua
NDL.RestoreInject(_G, "print")
```

### `NDL.RestoreAllInjects()`
Restore every injected function to its bottom-most original and drop all inject bookkeeping. Also
bound to the **`ndl_restoreall`** concommand for panic recovery. Trace history is kept.

### `NDL.FilterArgs(targetTbl, funcName, filterFunc)`
Detour that only rewrites arguments. `filterFunc(...)` returns either `false`/`nil` (call the
original with the untouched args) or `true` followed by the replacement arg list. On a filter error
the original is called with the untouched args.

```lua
-- force every print to be uppercase
NDL.FilterArgs(_G, "print", function(...)
	local args = {...}
	for i, v in ipairs(args) do args[i] = string.upper(tostring(v)) end
	return true, unpack(args)
end)
```

### `NDL.TraceCalls(targetTbl, funcName, name)`
Wrap the function so every call prints its args, return values, timing, and a traceback, and appends
a record to `NDL.traces[original]`. `name` is a label for the output (defaults to `funcName`).

```lua
NDL.TraceCalls(math, "floor", "math.floor")
```

### `NDL.TraceOneCall(targetTbl, funcName, name)`
Same as `TraceCalls` but auto-restores itself after the first traced call.

### `NDL.WipeTraces()`
Drop all retained trace history (frees any entities/tables it pinned). Trace history survives inject
restores, so this is the explicit way to reclaim it. Also the **`ndl_wipetraces`** concommand.

### Builders — `Make*`
These return a wrapped function without installing it; pair them with `NDL.Inject` when you want to
build the closure yourself. The `Trace*`/`FilterArgs`/`Detour` helpers above are thin wrappers over
these.

- `NDL.MakeArgsFilter(originalFunc, filterFunc)` — see `FilterArgs`.
- `NDL.MakeCallTracer(originalFunc, name, additionalCallback, limit)` — call tracer. `additionalCallback(TraceData)`
  runs after each traced call; `limit` (a number, may be passed in place of `additionalCallback`)
  caps how many calls are traced before falling through to the original untraced.
- `NDL.MakeErrorTracer(originalFunc, name, additionalCallback, limit)` — only traces calls that
  **error**; re-raises the error after logging. Successful calls pass through silently.

`TraceData` records (also stored in `NDL.traces[original]`) look like:
`{ args = {...}, returns = {...}, startCall = SysTime, finishCall = SysTime, trace = traceInfo }`.

### State
- `NDL.injections` — `[targetTbl][funcName] = { layer, ... }` stack of active injects.
- `NDL.originalFuncs` — `[injectedFunc] = whatItReplaced`.
- `NDL.traces` — `[originalFunc] = { TraceData, ... }`.
- `NDL.MaxTraceRecords` (default `1000`) — per-function cap; oldest records drop past it.

---

## Execution / tracebacks — `execution.lua`

### `NDL.PCall(func, ...)  ->  ok, result`
`pcall` wrapper. On success `result` is a **table** of the return values; on failure `result` is the
error message.

```lua
local ok, res = NDL.PCall(risky, 1, 2)
if ok then print(unpack(res)) end
```

### `NDL.Call(func, ...)  ->  ok, result`
Same as `PCall` but on error it also prints the error and a traceback via `NDL`.

### `NDL.GetTraceInfo(startFrom)  ->  { debug.getinfo, ... }`
Collect `debug.getinfo` for every stack frame from `startFrom` (default `2`) upward.

### `NDL.PrintTrace(startLvl)  ->  traceInfo`
Print a formatted traceback (default start level `3`) and return the raw trace info.

---

## Logging — `logging.lua`

- `NDL.Msg(...)` — colored `[NDL]` console line. Inside a Noir run context (`__CONTEXT`) it falls
  back to plain `print` so output routes back over the run channel.
- `NDL.Error(...)` — like `Msg` with a red `[ERROR]` prefix.
- `NDL.Print(...)` — plain `print` with an `[NDL]` prefix.
- `NDL.PrintChat(...)` — `chatAddText` with an `[NDL]` prefix (client chat box).

---

## Reflection — `utils.lua`

### `NDL.getlocals(func)  ->  locals, names`
`{ name = value }` of a function's locals, plus an ordered `{ name, ... }` list. `nil` values are
stored as `NIL`.

### `NDL.getupvalues(func)  ->  upvals, names`
Same shape, for upvalues.

### `NDL.AllInfo(func)  ->  { func, info, locals, upvals }`
Bundle of `debug.getinfo(func)` plus its locals and upvalues.

```lua
PrintTable(NDL.AllInfo(SomeFunction))
```

---

## Concommands

- `ndl_restoreall` — `NDL.RestoreAllInjects()`
- `ndl_wipetraces` — `NDL.WipeTraces()`
