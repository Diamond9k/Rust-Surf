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
  own model, viewmodel animations and shot sound from your CS2 install. Every stat the gun model reads
  (damage, fire rate, clip, fire mode, armor penetration, range falloff, wall penetration, spread,
  inaccuracy, recoil pattern and seed, recovery, move speed) comes from your CS2 files
  (`scripts/items/items_game.txt`, or `scripts/weapons.vdata` for what that file lacks). A stat your
  CS2 files do not give falls back to a class value in `sheets/weapon_defaults.json`, and never
  quietly: the game's error panel names each such gun and the missing stats (the Zeus needs only
  damage, rate, charges and range). **B** opens a buy menu laid out by CS2
  weapon class.
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
  animation in every clip, and every PNG texture the model names: each PNG chunk's CRC, and the pixel data
  must inflate to exactly the size the image header gives with a valid filter on every row, so a texture
  garbled during a batch export fails even when its CRCs are intact. These checks pass on all 79 PNGs and
  every glb that Source2Viewer-CLI 20 and UnityPy wrote for the arms, knife, knife clips and Launch Site
  on a real install.
- Sounds: the wav RIFF size or the mp3 frame sync. Text files (`items_game.txt`, `weapons.vdata`) must
  parse to the last closing brace.
- Rust: every Launch Site mesh the placements file names, with its textures (the same PNG check), and
  every course texture.

A CS2 file that fails has its damaged output and any damaged texture deleted, then is exported again on
its own (twice by default, `sheets/prep.json`). After every batch all of them are checked again, including
those an earlier run left whole, since a later export can overwrite a texture two models share. Prep writes
`data/done-0.2.0.txt` only when every surf asset, the arms, the knife, all 35 weapons (model, every
clip, shot sound) are in place and `items_game.txt` exported whole and names every weapon. Otherwise it
stops with the reason on screen, in a Windows message box (the launcher's console window may close
before you can read it; the box closes itself after 15 minutes so an unattended setup still exits) and in
`data/prep.log`, writes the reasons to `data/prep_status.json` (the game
shows them in its error panel, so a partial install never looks like a working one) and runs again on
the next start, redoing only what is missing. A run also removes the done file and marks
`prep_status.json` unfinished before it exports anything, so setup closed half way through is set up again
on the next start and named in the error panel, never left looking finished. A data folder with content
missing and no `prep_status.json` at all (setup never got to run, for example its Python was removed) says
so in the error panel too.

Each Source2Viewer-CLI call has a time limit (30 minutes for a batch, 10 for the one-file retries), and
after three calls in one run time out setup stops and names the files, instead of sitting at a frozen
window for hours on a damaged VPK or an antivirus holding the tool.

**CS2 updates.** `prep_status.json` keeps the size and modified time of CS2's `game/csgo/pak01_dir.vpk`
(and `steam.inf` when there is one). At every start the game compares them with your CS2 folder; when CS2
has updated since setup it says so in the error panel and removes the done file, so Melty runs setup again
on the next start, and that run exports every CS2 file fresh (stats, models, clips, sounds) instead of
keeping the old version's. That every CS2 patch rewrites `pak01_dir.vpk` is how Source VPKs work but has
not been watched on a real update here.

Missing weapon stats (`stats_required` in `sheets/prep.json`) do not stop setup in 0.2.0: the key names
CS2 uses have not been read from a real install yet, and a wrong guess would fail setup for every player
on every start. They are listed as a setup warning and in the game's error panel instead, naming the gun
and the stats; `stats_required_blocks` in the same sheet turns them into a stop once the names are
confirmed. The weapon stats files are exported fresh on every run, so a
CS2 update reaches them. The message names the usual fix: verify the game's files in Steam, or
reinstall Rust Surf if a prep tool was removed (antivirus programs sometimes quarantine command-line
tools such as `Source2Viewer-CLI.exe`).

## Known limits in 0.2.0

- Prep has run on a real install for the Rust content, the CS2 arms, knife, knife clips and sounds.
  The 35 weapon exports and the stats read are tested against a synthetic `items_game.txt` (built to
  CS:GO's layout: prefab chains, nested attribute blocks, `[$WIN32]` conditionals, escaped quotes) and
  `weapons.vdata` and a fake exporter (`prep/tests`), not yet on a fresh Windows install. The release
  build itself cannot be made without that run: `tools/package.py` refuses unless its `--data` folder is
  a whole prep run of this version in which every one of the 35 guns got every required stat from CS2's
  own files.
- Where CS2 keeps live weapon stats is unverified: the reader takes `items_game.txt` attributes (the
  CS:GO layout) and fills gaps from `weapons.vdata` fields, and the vdata path and field names in
  `sheets/prep.json` are from memory. Where both files give a stat and disagree, the game plays the
  file `stats_conflict_winner` names (`items_game.txt` in 0.2.0, unverified), `data/prep.log` lists every
  disagreement, and no release can be packaged on files that disagree until someone has checked which
  value CS2 plays and marked that row verified. If the real files leave a gun without a required stat in both,
  that gun plays on class values and the error panel says which stats; that needs a Rust Surf update,
  not a reinstall. That the real CS2 files give every required stat for all 35 guns has not been seen.
- How Melty itself presents a setup that exits 1 has not been seen; the reasons are always in
  `data/prep.log`, in a message box on Windows (only tested with a stand-in here) and in the game's error
  panel, which reads `data/prep_status.json`.
- Weapon constants CS2 does not publish (recoil decay, penetration, armor) are CS:GO SDK defaults or
  estimates. `python3 tools/preflight.py --list` prints every sheet cell labelled unverified
  (342 when this README was last checked: weapon defaults, weapon alt/reload modes, HUD and settings values, prep's
  vdata map and others); `tools/package.py` records the count in the release's entries file. The 232 of
  them that decide play (the weapon, weapon-defaults, aim-lobby scoring and crosshair sheets, named in
  `tools/unverified_ack.json`) are a release decision, not a count: the release build refuses while any
  of them is new or has changed since someone reviewed it and recorded it with
  `python3 tools/preflight.py --ack` (`--critical` lists what waits). In this tree none is recorded yet,
  so 0.2.0 cannot be packaged until that review is done.
- Rust weapons are not in this version.

## Layout

- `sheets/` the design, one JSON sheet per kind of thing (games, content, weapons, movement, course,
  materials, sounds, input, settings, hud, aim lobby, prep, systems, hooks, credits). The sheets are the
  source of truth; `game/data/` and `prep/` hold byte-identical copies (`tools/package.py` writes them).
  `game/data/` is not in git: before exporting from the Godot editor run `python3 tools/package.py --sync`,
  or the export ships whatever copies were last there (`tools/preflight.py` reports any copy that differs).
- `game/` the Godot 4.7 project. Every script is one row of `sheets/systems.json`.
- `prep/` the one-time extractor Melty runs before the first start. `python3 -m unittest discover prep/tests`
  runs its tests (set `RS_DATA` to an extracted data folder to also check real exports, `RS_GODOT` to a
  Godot 4.7.2 binary for the reader parity test, `RS_UNITYPY_PYTHON` to a Python with UnityPy for the
  bundle import line).
- `tools/preflight.py` checks every table of every sheet: each cell filled, each row verified or labelled
  unverified, every cross-sheet reference, every copy. `--strict` also fails on unverified cells;
  `--critical` lists the gameplay-critical unverified rows not yet acknowledged for release and `--ack`
  records the current ones as reviewed (a hash of each whole row, so any later edit needs a new review).
- `tools/package.py --ci --godot <Godot 4.7.2 headless>` is what `.github/workflows/ci.yml` runs on
  every push. A run on GitHub's own runners has not been watched from here; what has been checked
  (2026-10-10): the workflow's pinned download URL answers 200 and its zip holds a Godot binary
  byte-identical (sha256 `8d106cbe...53f71e`) to the one that ran `CI=1 python3 tools/package.py --ci`
  locally to "CI: clean". It checks: recipe and README name one version (the README's first heading), sheet copies equal, preflight, the
  prep unit tests, `--import` and `--check-only` on every script, the game-vs-prep `items_game.txt`
  reader parity on the fixture, and the headless `--lobbytest`, `--wtest` and `--uitest` on the source
  project. It needs no game files: those tests play on a synthetic CS2 install generated by
  `prep/tests/ci_data.py` (an `items_game.txt` in CS:GO's layout naming all 35 guns, with test values,
  never CS2's), which prep's own stats reader turns into `weapon_stats.json`, so every gun's stats go
  file -> prep -> game on every push, and `--wtest` must compare every reference stat with that file.
  The same data folder holds a synthetic viewmodel from `prep/tests/ci_content.py` (box arms, a box
  knife and three short clips, written as glb files at their `content.json` paths in the layout VRF
  exports; nothing in them is CS2's), so the `--wtest` rig checks (`viewmodel_inside_hull`,
  `reequip_idle`, `knife_in_palm`) must pass on every push too: CI excuses no failing check, and a
  regression in `Viewmodel.equip` or the knife attachment fails it. They show the rig code works, not
  that CS2's real arms look right; the release gate below runs the same checks on real data and also
  needs all three to print PASS. When CI runs on GitHub, the count of gameplay-critical rows still
  waiting on review is posted as a warning annotation on the run. Inside CI the reader parity unit test fails instead of skipping when
  no Godot binary is given.
- `tools/package.py --godot <Godot 4.7.2> --data <prep output folder>` builds the release zip. It
  copies the sheets into `game/data/` and `prep/`, then refuses to package unless preflight is clean,
  the prep unit tests pass, and `--data` is a whole prep run of this version on a real Rust + CS2 install
  (done file, every content row, all 35 guns with model, clips and sound, every gameplay-critical
  unverified row acknowledged, and no gun left on
  class-average stats or on a stat CS2's two stats files disagree about while that is unchecked; the hashes
  of its `prep_status.json` and `weapon_stats.json` go in the entries file). Every game script must pass Godot's `--check-only`, and the game's own `items_game.txt` reader
  (`tools/kv_parity.gd`) must read the test fixture and the real file exactly as prep does. It then
  empties `dist/RustSurf`, exports the game into it itself (Godot's Windows export templates must be
  installed) and runs the headless `--lobbytest`, `--wtest` and `--uitest` on that exported pack with the
  `--data` folder, each under a wall-clock limit and required to exit 0 with its pass line and without a
  single Godot `ERROR:` line (a glb that fails to load prints only that), and a check that prints PASS
  only because it skipped fails the gate unless another gate covers it (the two fixture checks the
  exported pack cannot run, which the reader parity gate has already done), so the zip
  holds exactly the build that was tested. It also refuses unless the export holds every current sheet,
  the prep bundle has `python.exe` with its standard library, UnityPy, `vrf/`, `vgm/` and every prep
  source byte for byte and nothing a dev run left there (an allowlist), the bundle's own `python.exe`
  (under wine off Windows) imports everything setup imports and decodes a DXT1 and a BC7 block through
  UnityPy, `Source2Viewer-CLI.exe` and `vgmstream-cli.exe` each start from the bundle and print their
  usage (so a DLL missing from their folder is caught before release), and the zip reads back whole with its `LICENSES/`. Where the bundle check cannot run,
  `--no-bundle-smoke` builds anyway and the entries file says so. A refused build deletes any older zip
  of the same version.

## Credits

Godot Engine (MIT), UnityPy by K0lb3 (MIT), Source2Viewer-CLI / ValveResourceFormat (MIT),
vgmstream (see COPYING), Python (PSF). Rust is by Facepunch Studios and Counter-Strike 2 by
Valve; the game reads them from your own installs. Method from universal-modder. Built with AI
assistance (Claude).
