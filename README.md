# BasaltOS

BasaltOS is a desktop operating system for
[CC:Tweaked](https://tweaked.cc/) built with
[Basalt 2.5](https://github.com/Pyroxenium/Basalt2/tree/basalt2.5).
It combines a familiar windowed desktop with a modular service and app
architecture designed specifically for ComputerCraft.

> BasaltOS is currently an early preview (`0.1.0`).

## Highlights

- Window manager with movable, resizable and focus-aware application windows
- Desktop, taskbar, start menu, launcher and system notifications
- Local user accounts with separate home directories and settings
- Shared clipboard, drag and drop, file operations and file associations
- Basalt Store for discovering and installing additional applications
- Device Manager for inspecting attached ComputerCraft peripherals
- Built-in support for Basalt 2.5, Obsidian and FLIMG-based images
- Service-oriented internals with isolated application environments

## Included applications

BasaltOS ships with a practical starter set:

- **Filely** — file manager with copy, cut, paste and app associations
- **Terminal** and **Shell** — graphical and native command-line access
- **Notepad** and **Editor** — text editing and source-code workflows
- **Calculator** and **Calendar** — compact offline utilities
- **Settings** — appearance and system configuration
- **Task Manager** — inspect, focus, pause and terminate processes
- **Device Manager** — inspect connected peripherals
- **Basalt Store** — browse and install BasaltOS applications
- **Paint**, **Image Viewer** and **Pastebin** integrations

## Requirements

- An Advanced Computer running a current version of CC:Tweaked
- A terminal resolution of at least `51x19`
- The HTTP API enabled
- Approximately 1.5 MB of installed storage
- Approximately 1.5 MB of additional free space while installing or updating

The default ComputerCraft computer storage limit may be too small. If the
installer reports insufficient space, increase the computer space limit in
your CC:Tweaked or CraftOS-PC configuration before continuing.

## Installation

Run this command from the CraftOS shell:

```shell
wget run https://raw.githubusercontent.com/Pyroxenium/BasaltOS/refs/heads/main/install.lua
```

The installer downloads the current release, stages it before making changes,
and installs BasaltOS into the computer root. It preserves:

- Existing local users and their files under `/users`
- Machine configuration in `/system/config.dat`
- Runtime logs under `/system/logs`
- The previous `startup.lua`, saved as `startup.before-basaltos.lua`

If applying the installation fails, files already changed during that attempt
are restored automatically. After installation, select **Reboot** to enter
BasaltOS.

On first boot, BasaltOS asks you to create the first account. That account
becomes the administrator; no default password is created.

### Updating

Run the same installation command again. The installer replaces system files
while retaining local accounts, user data and configuration.

## Developing applications

Applications live in `/system/apps/<app-id>/` and normally contain:

```text
myapp/
├── app.json
├── main.lua
├── icon.bimg
└── taskbar.bimg
```

A minimal `app.json` looks like this:

```json
{
  "id": "myapp",
  "name": "My App",
  "version": "1.0.0",
  "description": "A BasaltOS application",
  "author": "Your Name",
  "category": "utilities",
  "executable": "main.lua",
  "singleton": false,
  "window": {
    "fullscreen": false,
    "resizable": true,
    "default_width": 32,
    "default_height": 12,
    "min_width": 20,
    "min_height": 8
  }
}
```

Inside an app, `require("app")` exposes the public BasaltOS services. Basalt,
Obsidian and FLIMG are available from the public library directory.

The most relevant project directories are:

```text
os/
├── startup.lua
└── system/
    ├── apps/       Built-in applications
    ├── assets/     Shared icons and visual assets
    ├── core/       Kernel and core APIs
    ├── lib/public/ Public application libraries
    └── services/   Desktop and operating-system services
```

The installer reads `install-manifest.txt`. A GitHub Actions workflow
regenerates and commits it automatically whenever files under `os/` change.
Runtime state (`users`, logs and `system/config.dat`) is intentionally excluded.

## Packages

BasaltOS can run code straight from compressed packages (`.bpk`). A package
holds Lua sources and assets; it stays compressed on disk and is unpacked into
memory when one of its files is first read. The package runtime
(`os/system/boot/bpk.lua`) is loaded by `startup.lua` before the kernel and
makes packaged files appear at their normal paths, so apps and services read
them like any other file.

An app may ship its code and assets as `app.bpk` next to `app.json` and its
icons. The Basalt Store installs such apps as they are: the package is checked
after the download and stays compressed in the app folder. Apps made of plain
files keep working unchanged. A real file always wins over a packaged file
with the same path, which is useful while developing.

The tools run headless in [CraftOS-PC](https://www.craftos-pc.cc/) on Windows:

```shell
tools\build.ps1
tools\test.ps1
```

`tools\build.ps1` writes the packed system to `build\dist` (about a sixth of
the size of `os/`) and, when a
[BasaltOSStore](https://github.com/Pyroxenium/BasaltOSStore) checkout lies next
to this repository, the packed store to `build\dist-store`. The build fails if
the image grows beyond half of a default computer's storage.
`tools\test.ps1` boots the source tree and the packed image on throwaway
computers and checks the package runtime, a packaged game and an installation
from the store.

`tools\build.ps1 -Publish` also copies the image to `dist/` in the repository:
`dist/install-manifest.txt` and the image itself under `dist/os/`. Commit
`dist/` together with the sources it was built from; nothing rebuilds it
automatically yet.

The installer prefers a packed image: if the branch it installs from has a
`dist/` folder, that is what ends up on the computer (about 250 KB instead of
1.5 MB); otherwise it installs the files under `os/` as before. On a computer
that already runs an unpacked BasaltOS, it also removes the old files under
`/system` that the image does not list, because a real file would otherwise
keep running in place of the packaged one. Users, logs and
`system/config.dat` stay.

To try a branch other than `main`, name it after the address; `source` forces
the plain files:

```shell
wget run https://raw.githubusercontent.com/Pyroxenium/BasaltOS/refs/heads/dev/install.lua dev
wget run https://raw.githubusercontent.com/Pyroxenium/BasaltOS/refs/heads/dev/install.lua dev source
```

## Contributing

Bug reports and pull requests are welcome. Please include clear reproduction
steps and screenshots for visual issues where possible:

- [Report an issue](https://github.com/Pyroxenium/BasaltOS/issues)
- [Open a pull request](https://github.com/Pyroxenium/BasaltOS/pulls)

## License

BasaltOS is released under the [MIT License](LICENSE).
