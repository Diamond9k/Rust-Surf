# Rust Surf

A CS:GO-style surf game that plays from your own copies of **Rust** and **Counter-Strike 2**.

- You surf a linear course through the real Rust **Launch Site**: its buildings, chutes and
  concrete/sheet-metal textures are read from your Rust install when the game first runs.
- The movement is Source-engine surf: air strafing, ramp sliding, bunny hops, 64 tick,
  sv_airaccelerate 150.
- CS2 brings the rest: footsteps, landing, jump and wind sounds, the default CT knife in your
  hands with its real draw, idle and inspect animations, your own CS2 key binds, sensitivity and
  crosshair, all read from your CS2 install and Steam config.
- Timer with checkpoints, personal best on disk, and a ghost of your best run to race.
- Single player (v1).

No game content is included in this download: Melty runs a one-time prep step on your PC that
reads what the game needs from Rust and CS2. Neither game is launched or modified.

## Layout

- `sheets/` the design, one JSON sheet per kind of thing (games, content, movement, course,
  materials, sounds, input, viewmodel, systems, hooks, credits). The sheets are the source of truth.
- `game/` the Godot 4.7 project. Every script is one row of `sheets/systems.json`.
- `prep/` the one-time extractor Melty runs before the first start.
- `tools/preflight.py` lists every unfilled or unverified sheet cell. Build only when it is clean.

## Credits

Godot Engine (MIT), UnityPy by K0lb3 (MIT), Source2Viewer-CLI / ValveResourceFormat (MIT),
vgmstream (see COPYING), Python (PSF). Rust is by Facepunch Studios and Counter-Strike 2 by
Valve; the game reads them from your own installs. Method from universal-modder. Built with AI
assistance (Claude).
