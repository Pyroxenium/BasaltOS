# BasaltOS

A lightweight, public operating system for ComputerCraft, inspired by Basalt.

Overview
- BasaltOS is a modular, minimal OS built on Basalt UI components. It's intended as a starting point for building and testing apps and UI features in a ComputerCraft environment.

Key Features
- App launcher and startup script (`startup.lua`)
- Organized system layout under `system/` and `apps/`
- Basalt UI library inside `lib/public/basalt/` for rapid UI development
- Logging and service modules in `logs/` and `services/`
- Shared binary [FLIMG v1](system/lib/public/FLIMG.md) images with RGB palettes,
  2x3 subpixels, layers, animation timing, RAW/RLE blocks and frame deltas
- FLIMG Studio under `system/apps/flimgstudio` for lossless pixel/cell editing,
  palettes, layers, timelines and BIMG/OSF import

Developing
- Apps: Create a new folder in `apps/` with an `app.json` and `main.lua` to register an app.
- Plugins/Themes: Extend or modify items in `lib/public/basalt/plugins/`.
- Debugging: Check `logs/` for runtime messages and `services/` for service status.

Basalt render pacing
- `basalt.setRenderInterval(seconds)` limits automatic render passes while
  continuing to process every input event. Rapid invalidations are coalesced
  and a trailing timer guarantees that the newest state is rendered.
- `basalt.getRenderInterval()` returns the configured interval.
- `basalt.flush()` immediately renders pending changes. An interval of `0`
  restores render-after-every-event behavior.
- BasaltOS uses an interval of `0.05` seconds (at most 20 automatic renders
  per second).

Filely file icons
- An app associated with a file type may declare a colored 1x1 icon in `app.json`:
  `"file_icon": {"char": 131, "fg": "white", "bg": "lightBlue"}`.
- `char` is a ComputerCraft character code from 0 to 255; `fg` and `bg` are optional `colors.*` names or values.
- A missing `fg` or `bg` uses Filely's current row background. The legacy `color` field is accepted as an alias for `bg`.
- Filely renders the glyph as a subpixel icon. Files without a declared icon use character 131 in light gray; folders use character 131 in yellow.

System-wide file operations
- Apps can access the `fileops` service through `require("app").fileops`.
- `fileops.copy(path)` and `fileops.cut(path)` place a typed file selection on the shared clipboard.
- `fileops.paste(directory)` copies or moves it, choosing a friendly unique name when the target already exists.
- `fileops.canPaste(directory)` and `fileops.getClipboardInfo()` allow UIs to present the same actions as Filely and the desktop.

Basalt Store
- The versioned [Basalt Store catalog format](BASALT_STORE_CATALOG.md) lists every app and its explicit GitHub-hosted files without using the GitHub API.
- The `basaltstore` service validates and caches the catalog per user, retaining the last good catalog for offline use.
- Store installs are staged, matched against the catalog ID/version, and handed to the Registry only after every declared file is present.

Window close requests
- Managed apps can register `window.setCloseHandler(function(resolve) ... end)`.
- Call `resolve(true)` to allow the close or `resolve(false)` to cancel it. The callback may answer later, so confirmation dialogs can be asynchronous.
- `window.setCloseHandler(nil)` removes the handler. While a request is pending, repeated close clicks are coalesced.
- Process termination, including Task Manager's `End task`, forcibly closes the window and bypasses the handler.

Contributing
- Contributions are welcome. Open issues or PRs with a brief description and reproduction steps or screenshots when applicable.

License
- See `LICENSE` for license details.

Contact
- For questions or feedback, open an issue or contact the maintainer via the repository.

Enjoy building with BasaltOS!
