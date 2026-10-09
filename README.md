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
  own model, viewmodel animations and shot sound from your CS2 install. Damage and fire rate always come
  from your CS2 files (`scripts/items/items_game.txt`, or `scripts/weapons.vdata` for what that file
  lacks); setup stops rather than run a gun on guessed numbers. Secondary stats a file does not give
  (recoil, spread, speed) fall back to a class average marked unverified in
  `sheets/weapon_defaults.json`, and setup lists those weapons as a warning. **B** opens a buy menu laid
  out by CS2 weapon class.
- **Aim lobby** (new in 0.2.0): **F2** switches to an aim range with humanoid bots, rounds, kills,
  time-to-kill and accuracy; **M** cycles its modes.
- **Settings** (new in 0.2.0): **Esc** opens a CS2-style settings menu. Binds, sensitivity and crosshair
  start from your own CS2 config; only what you change is saved. **F5** restarts the course (R is
  reload).
- Single player only.

## The first start

Prep needs Rust and CS2 installed through Steam and takes several minutes, most of it reading Rust's
texture bundles. Every file it writes is checked whole before it counts:

- CS2 models and clips: the glb's length field, its JSON and BIN chunks, a mesh in every model and an
  animation in every clip, and every PNG texture the model names (each PNG chunk's CRC). These checks
  match what Source2Viewer-CLI 20 wrote for the arms, knife and knife clips on a real install.
- Sounds: the wav RIFF size or the mp3 frame sync. Text files (`items_game.txt`, `weapons.vdata`) must
  parse to the last closing brace.
- Rust: every Launch Site mesh the placements file names, with its textures, and every course texture.

A CS2 file that fails is exported again on its own (twice by default, `sheets/prep.json`). Prep writes
`data/done-0.2.0.txt` only when every surf asset, the arms, the knife, all 35 weapons (model, every
clip, shot sound) and every weapon's damage and fire rate are in place. Otherwise it stops with the
reason on screen and in `data/prep.log`, writes the reasons to `data/prep_status.json` (the game shows
them in its error panel, so a partial install never looks like a working one) and runs again on the
next start, redoing only what is missing. The weapon stats files are exported fresh on every run, so a
CS2 update reaches them. The message names the usual fix: verify the game's files in Steam, or
reinstall Rust Surf if a prep tool was removed (antivirus programs sometimes quarantine command-line
tools such as `Source2Viewer-CLI.exe`).

## Known limits in 0.2.0

- Prep has run on a real install for the Rust content, the CS2 arms, knife, knife clips and sounds.
  The 35 weapon exports and the stats read are tested against a synthetic `items_game.txt` and
  `weapons.vdata` and a fake exporter (`prep/tests`), not yet on a fresh Windows install.
- Where CS2 keeps live weapon stats is unverified: the reader takes `items_game.txt` attributes (the
  CS:GO layout) first and `weapons.vdata` fields second, and the vdata path and field names in
  `sheets/prep.json` are from memory. If a CS2 update leaves a gun without damage or fire rate in both,
  setup stops and says so; that needs a Rust Surf update, not a reinstall.
- Weapon constants CS2 does not publish (recoil decay, penetration, armor) are CS:GO SDK defaults or
  estimates. `python3 tools/preflight.py --list` prints every sheet cell labelled unverified
  (about 200 in this build: weapon defaults, weapon alt/reload modes, HUD and settings values, prep's
  vdata map and others); `tools/package.py` records the count in the release's entries file.
- Rust weapons are not in this version.

## Layout

- `sheets/` the design, one JSON sheet per kind of thing (games, content, weapons, movement, course,
  materials, sounds, input, settings, hud, aim lobby, prep, systems, hooks, credits). The sheets are the
  source of truth; `game/data/` and `prep/` hold byte-identical copies (`tools/package.py` writes them).
- `game/` the Godot 4.7 project. Every script is one row of `sheets/systems.json`.
- `prep/` the one-time extractor Melty runs before the first start. `python3 -m unittest discover prep/tests`
  runs its tests (set `RS_DATA` to an extracted data folder to also check real exports).
- `tools/preflight.py` checks every table of every sheet: each cell filled, each row verified or labelled
  unverified, every cross-sheet reference, every copy. `--strict` also fails on unverified cells.
- `tools/package.py --godot <Godot 4.7.2> --data <extracted data folder>` builds the release zip. It
  copies the sheets into `game/data/` and `prep/`, then refuses to package unless preflight is clean,
  the prep unit tests pass, every game script passes Godot's `--check-only`, and the headless
  `--lobbytest` and `--wtest` runs exit 0 with their pass lines; and unless the game export holds every
  current sheet, the prep bundle has `python.exe`, `vrf/`, `vgm/` and every prep source, and the zip
  reads back whole.

## Credits

Godot Engine (MIT), UnityPy by K0lb3 (MIT), Source2Viewer-CLI / ValveResourceFormat (MIT),
vgmstream (see COPYING), Python (PSF). Rust is by Facepunch Studios and Counter-Strike 2 by
Valve; the game reads them from your own installs. Method from universal-modder. Built with AI
assistance (Claude).
