# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

KOReader is a document viewer for e-ink devices. This repo is the **Lua frontend**; the C/native
half (LuaJIT, mupdf, crengine, blitbuffer, FFI bindings) lives in the `koreader-base` submodule at
`base/`. Anything you `require("ffi/…")`, `require("libs/…")`, or `require("lua-…")` comes from
`base/`, not from this tree.

## Commands

Everything goes through `./kodev` (a wrapper around `make` with target/debug plumbing).
Run `./kodev -h` or `./kodev <cmd> -h` for full usage.

```sh
./kodev fetch-thirdparty          # init/sync submodules — REQUIRED before first build
./kodev build                     # build emulator (debug by default); build <TARGET> for devices
./kodev run                       # run emulator
./kodev run -s kobo-clara         # simulate a device's screen (also: -W/-H/-D for width/height/dpi)
./kodev run -t                    # simulate keyboard-only device (no touch)
./kodev check                     # shellcheck + luacheck + repo-specific greps (what CI gates on)
./kodev clean
./kodev release <TARGET>          # build an OTA/release package
```

Targets: `emulator` (default), `android-{arm,arm64,x86,x86_64}`, `cervantes`,
`kindle{,hf,pw2,-legacy}`, `kobo{,v4,v5}`, `linux`, `macos`, `pocketbook`,
`remarkable{,-aarch64}`, `sony-prstux`, `win32`.

### Tests (busted, run in parallel via meson)

```sh
./kodev test                      # everything (front + base)
./kodev test front                # frontend specs only
./kodev test front readerbookmark # single spec (name = filename minus `_spec.lua`)
./kodev test base util            # single base test
./kodev test -l                   # list available tests
./kodev cov                       # coverage summary (-f for line-level report)
```

### Other

```sh
./kodev prompt                    # LuaJIT REPL inside KOReader's environment
./kodev wbuilder                  # minimal UI harness for iterating on widgets (tools/wbuilder.lua)
./kodev log                       # tail logcat for a running Android build
make po                           # pull translations from Weblate (l10n submodule)
```

`./kodev build` installs into `koreader-<dist>-<machine>[-debug]/koreader/`, where the Lua sources
are **symlinks** back into the source tree — editing Lua and re-running `./kodev run` needs no
rebuild. On macOS you need Homebrew's `findutils`, `gnu-getopt`, `make`, and `util-linux` ahead of
the system ones in `$PATH` (see `doc/Building.md`).

## Architecture

### Startup path

`reader.lua` → `setupkoenv.lua` (sets `package.path` to `common/;frontend/;plugins/exporter.koplugin/`)
→ opens the two settings globals `G_defaults` / `G_reader_settings` → `require("device")` →
`CanvasContext:init` → `frontend/ui/data/onetime_migration.lua` → `Bidi.setup` → `UIManager` →
either `ReaderUI:showReader(file)` or `FileManager:showFiles(dir)` → `UIManager:run()`.

Order matters early on: language and Bidi/RTL setup must happen *before* UIManager and widgets are
loaded, because widgets cache mirroring settings at load time.

### Device abstraction

`frontend/device.lua` probes for filesystem markers (`/proc/usid` → Kindle, `/bin/kobo_config.sh` →
Kobo, …) and returns `frontend/device/<platform>/device.lua`, falling back to `device/sdl` (the
emulator). Platform devices extend `device/generic/device.lua`. `Device.screen` and `Device.input`
are the framebuffer and input abstractions; capability queries (`Device:hasColorScreen()`,
`hasKeys()`, `isTouchDevice()`, …) are how frontend code stays portable. Shell-level per-platform
glue lives in `platform/<name>/`, build rules in `make/<target>.mk`.

### Widgets, events, UIManager

Class chain: `EventListener` → `Widget` → `WidgetContainer` → `InputContainer`. Use `:extend{}` to
define a subclass, `:new{}` to instantiate (`:new` calls `_init` then `init`). `Widget:paintTo(bb, x, y)`
draws; `getSize()` returns a `Geom`.

Events are `Event:new("Name", ...)`, dispatched to the method `onName`. A `WidgetContainer` passes
an event to its array children **first**, and only handles it itself if no child returned `true`.
Returning `true` consumes the event. `UIManager:sendEvent` starts from the topmost window,
`UIManager:broadcastEvent` hits everything. See `doc/Events.md`.

`UIManager` owns the window stack (`show`/`close`), the scheduler
(`scheduleIn`/`nextTick`/`unschedule`/`debounce`), and the repaint+refresh pipeline. Two conventions
you must follow when writing widgets:

- **`show_parent`**: cascade it to child widgets (`Foo:new{ show_parent = self.show_parent or self }`).
  `UIManager:setDirty` only flags *window-level* widgets (ones passed to `show`), so a subwidget must
  pass its `show_parent`, or the repaint silently doesn't happen.
- **`movable`**: name a persistent wrapping `MovableContainer` `self.movable`; `setDirty` and `Button`
  check it to handle translucency correctly.

`setDirty(widget, refreshtype, region)` — refreshtype is `"full"`, `"partial"`, `"ui"`, `"fast"`,
`"a2"`, their `flash*`/`[bracketed]` variants, or a lambda returning `(type, region)` evaluated after
painting. `nil` widget = refresh without repaint; `"all"` = flag the whole stack. Read the long
comment above `UIManager:setDirty` in `frontend/ui/uimanager.lua` before touching refresh logic.

`InputContainer` adds `key_events` and `ges_events` (via `registerTouchZones`) tables — see its
header docstring for the key-combination syntax.

### Apps are module aggregators

`ReaderUI` (`frontend/apps/reader/readerui.lua`) and `FileManager`
(`frontend/apps/filemanager/filemanager.lua`) are `InputContainer`s that `registerModule(name, instance)`
dozens of feature modules. Registration order is significant — e.g. `view` must be child #1 (all
paintable widgets live under `ReaderView`), and `menu` is registered after `link`/`highlight` so taps
in those zones don't open the menu. Reader modules live in `frontend/apps/reader/modules/` and by
convention hold `self.ui`, `self.view`, `self.document`, `self.dialog`. Use
`registerPostInitCallback` / `registerPostReaderReadyCallback` for work that needs a fully built UI.

### Document layer

`frontend/document/documentregistry.lua` maps a file to a backend: `credocument` (crengine —
reflowable EPUB/FB2/MOBI/…), `pdfdocument` / `djvudocument` (paged, rendered through
`koptinterface.lua` + k2pdfopt for reflow), `picdocument`. Rendered tiles are cached via
`doccache.lua` / `tilecacheitem.lua`. `document.info.has_pages` distinguishes paged from reflowable
and drives which reader modules get registered.

### Plugins

A plugin is `plugins/<name>.koplugin/` with `_meta.lua` (`fullname`, `description`) and `main.lua`
returning a `WidgetContainer:extend{ name = "…" }`. `frontend/pluginloader.lua` discovers them (plus
`extra_plugin_paths`), honors `plugins_disabled`, and loads `provider*` plugins first. Typical hooks:
`init()`, `onDispatcherRegisterActions()`, `addToMainMenu(menu_items)` with a `sorting_hint`, and
`is_doc_only`. `plugins/hello.koplugin/` is the reference example.

`frontend/dispatcher.lua` is the central registry of user-bindable actions, consumed by the gestures,
hotkeys, and profiles plugins — new user-facing actions go through `Dispatcher:registerAction`.

### Settings layers

Three, in increasing specificity: `G_defaults` (`defaults.lua`, via `luadefaults.lua`) →
`G_reader_settings` (`settings.reader.lua`, via `luasettings.lua`) → per-document `doc_settings`
(`docsettings.lua`, sidecar files). Paths come from `datastorage.lua` (`KO_HOME` overrides).
Migrations for renamed/removed settings go in `frontend/ui/data/onetime_migration.lua` (global) or
`frontend/ui/data/settings_migration.lua` (per-document).

Main-menu layout is data-driven: `frontend/ui/elements/reader_menu_order.lua` and
`filemanager_menu_order.lua`, with shared entries in the other `frontend/ui/elements/*.lua` tables.

## Conventions CI enforces

`./kodev check` fails on all of these:

- **No literal sizes.** `padding`, `margin`, `bordersize`, `width`, `height`, `radius`, `linesize`
  and `Geom:new{ w=…, h=… }` must use `frontend/ui/size.lua` (`Size.padding.default`, …) or
  `Screen:scaleBySize(n)`. Genuine exceptions need a `-- unscaled_size_check: ignore` comment.
- **Spaces, never tabs**; 4-space indent, LF, final newline (`.editorconfig`).
- **Tagged annotations only**: write `--- @todo`, `--- @fixme`, `--- @warning`; a bare `-- TODO` fails.
- **luacheck** over `{reader,setupkoenv,datastorage}.lua frontend plugins spec`. The only permitted
  globals are `G_reader_settings` and `G_defaults`; use `-- luacheck: ignore` sparingly.

Other repo norms:

- Logging: `require("logger")` → `logger.dbg/info/warn/err`. Lua always evaluates arguments, so never
  inline expensive computation in a `logger.dbg` call — guard it with `if dbg.is_on then`.
- i18n: `local _ = require("gettext")`, then `_("text")`; plurals `_.ngettext` (aliased `N_`),
  context `_.pgettext` (`C_`), both (`NC_`). Keep `%1`/`%2` placeholders intact. `l10n/` is a
  submodule synced from Weblate — never hand-edit `.po` files.
- User-visible strings live inline in the module, not in a central strings table.

## Tests

Specs are in `spec/unit/*_spec.lua` (busted). Every spec starts with `require("commonrequire")`
inside `setup()`, which stubs the framebuffer/input into dummy mode and points settings at throwaway
`*.tests.lua` files. Globals that spec files may use: `disable_plugins()`, `load_plugin(name)`,
`fastforward_ui_events()`, `screenshot(screen, filename)`, plus `package.unload/replace/reload` and
`spec/unit/mock_time.lua`. Sample documents come from the `test/` submodule, symlinked into the build
as `spec/front/unit/data`. `*_bench.lua` files are benchmarks, run via `./kodev test bench`.

## Further reading

`doc/Building.md` (prerequisites, per-distro), `doc/Building_targets.md`, `doc/Events.md`,
`doc/Hacking.md`, `doc/Unit_tests.md`, `doc/Porting.md` (new device support),
`doc/Collaborating_with_Git.md`. Generated API docs: `make doc`.
