# Rust Surf 0.2.0

A CS:GO-style surf game and aim trainer that plays from your own copies of **Rust** and
**Counter-Strike 2**. No game content is in this download: on the first start Melty runs a one-time
prep step that reads what the game needs from your Rust and CS2 installs. Neither game is launched
or modified.

## What you get

- **Surf**: a linear course through the real Rust **Launch Site** (its buildings, chutes and
  concrete and sheet-metal textures are read from your Rust install). Source-engine movement: air
  strafing, ramp sliding, bunny hops, 64 tick, sv_airaccelerate 150. Timer with checkpoints, a personal
  best on disk and a ghost of your best run.
- **CS2 weapons** (new in 0.2.0): the CS2 arms with the default CT knife and 35 CS2 guns, each with its
  own model, viewmodel animations and shot sound from your CS2 install. Damage, fire rate, magazine,
  recoil and spread come from your CS2 `scripts/items/items_game.txt`; a value that file does not give
  falls back to a class average marked unverified in `sheets/weapon_defaults.json`. **B** opens a buy
  menu laid out by CS2 weapon class.
- **Aim lobby** (new in 0.2.0): **F2** switches to an aim range with humanoid bots, rounds, kills,
  time-to-kill and accuracy; **M** cycles its modes.
- **Settings** (new in 0.2.0): **Esc** opens a CS2-style settings menu. Binds, sensitivity and crosshair
  start from your own CS2 config; only what you change is saved. **F5** restarts the course (R is
  reload).
- Single player only.

## The first start

Prep needs Rust and CS2 installed through Steam and takes several minutes, most of it reading Rust's
texture bundles. Every file it exports is checked, a file that fails is exported again on its own, and
prep only marks itself done when **every** surf asset, the arms, the knife, all 35 weapons and the
weapon stats are in place. If anything is missing it stops with the reason on screen and in
`data/prep.log`, writes the reasons to `data/prep_status.json` (the game shows them in its error
panel), and runs again on the next start, redoing only what is missing. The message names the usual
fix: verify the game's files in Steam, or reinstall Rust Surf if a prep tool was removed (antivirus
programs sometimes quarantine command-line tools such as `Source2Viewer-CLI.exe`).

## Known limits in 0.2.0

- The weapon export and the stats read from a real CS2 `items_game.txt` are tested against a synthetic
  file and a fake exporter (`prep/tests`), not yet on a fresh Windows install. If a CS2 update changes
  the file so a weapon cannot be found, prep says which and stops instead of guessing.
- Weapon constants CS2 does not publish (recoil decay, penetration, armor) are CS:GO SDK defaults or
  estimates, each labelled unverified in `sheets/weapon_defaults.json`.
- Rust weapons are not in this version.

## Layout

- `sheets/` the design, one JSON sheet per kind of thing (games, content, weapons, movement, course,
  materials, sounds, input, settings, hud, aim lobby, prep, systems, hooks, credits). The sheets are the
  source of truth; `game/data/` and `prep/` hold byte-identical copies.
- `game/` the Godot 4.7 project. Every script is one row of `sheets/systems.json`.
- `prep/` the one-time extractor Melty runs before the first start. `python3 -m unittest discover prep/tests`
  runs its tests.
- `tools/preflight.py` lists every unfilled or unverified sheet cell and any copy that drifted from its
  sheet. `tools/package.py` builds the release zip and refuses when the prep bundle, the game export or
  a sheet copy is incomplete.

## Credits

Godot Engine (MIT), UnityPy by K0lb3 (MIT), Source2Viewer-CLI / ValveResourceFormat (MIT),
vgmstream (see COPYING), Python (PSF). Rust is by Facepunch Studios and Counter-Strike 2 by
Valve; the game reads them from your own installs. Method from universal-modder. Built with AI
assistance (Claude).
