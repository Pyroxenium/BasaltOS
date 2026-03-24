# BasaltOS

A lightweight, public operating system for ComputerCraft, inspired by Basalt.

Overview
- BasaltOS is a modular, minimal OS built on Basalt UI components. It's intended as a starting point for building and testing apps and UI features in a ComputerCraft environment.

Key Features
- App launcher and startup script (`startup.lua`)
- Organized system layout under `system/` and `apps/`
- Basalt UI library inside `lib/public/basalt/` for rapid UI development
- Logging and service modules in `logs/` and `services/`

Developing
- Apps: Create a new folder in `apps/` with an `app.json` and `main.lua` to register an app.
- Plugins/Themes: Extend or modify items in `lib/public/basalt/plugins/`.
- Debugging: Check `logs/` for runtime messages and `services/` for service status.

Contributing
- Contributions are welcome. Open issues or PRs with a brief description and reproduction steps or screenshots when applicable.

License
- See `LICENSE` for license details.

Contact
- For questions or feedback, open an issue or contact the maintainer via the repository.

Enjoy building with BasaltOS!
