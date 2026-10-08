# MODLOG

2026-10-08
- Route: standalone Godot 4.7 game (Melty mode "standalone", primary rust, companion counter-strike-2). No loader exists for either game; CS2 is never launched (VAC), Rust is never launched (EAC).
- Rust 6000.3.15 IL2CPP; Bundles/shared/*.bundle are UnityFS; UnityPy 1.25.4 decompresses whole bundles (6-7 GB each) -> wrote prep/lazybundle.py (block-level lazy decompression + optional node filter). All CAB ids map to bundles (.work/cabs.json).
- Launch Site: prefab assets/bundled/prefabs/autospawn/monument/xlarge/launch_site_1.prefab inside assetscenes.bundle node BuildPlayer-AssetScene-monument.1: 1 root, 23161 children, 24881 MeshFilters, world positions present. Meshes live in content.bundle under assets/content/structures/launch_site/models/*.fbx (LOD0..2 + _col).
- Rust audio: FMOD FSB5 Vorbis inside audio.bundle .resource; vgmstream-cli decodes to wav.
- Rust textures: BC7 (25) / DXT1 (10), 2048x2048, UnityPy .image -> PNG works.
- CS2: VRF 20.0 CLI exports vsnd_c -> wav/mp3, vmdl_c -> glb (+png), vnmclip_c -> glb with animation (needs --game gameinfo.gi). Arms skeleton bones hand_R etc; knife bones weapon/weapon_offset.
- Cooper's binds: cs2_user_keys.vcfg is empty -> defaults; convars: sensitivity 2.5, crosshair style 2.
- Tooling gotcha: the agent shell truncates commands > ~8 KB and mangles backslash escapes; write files in small heredocs, use char(92)/char(34) in GDScript where a backslash or quote escape would be needed.
- Tooling gotcha 2: a leading `cd X &&` is dropped when a command runs in the background, so `rm -rf data` ran in the wrong folder and deleted game/data (only sheet copies). Rule: absolute paths everywhere, never a relative rm.
- Rust texture bundles (textures.N.bundle) are 2 LZ4 blocks each, the second ~4 GB uncompressed: any texture read decompresses 4 GB. lazybundle now caches by bytes (one giant block at a time) and prep_scene exports textures grouped by bundle.
- CS2 viewmodel in Godot: VRF clip glb = viewmodel skeleton (56 bones) + knife skeleton (3) + AnimationPlayer with absolute tracks (not additive; --gltf_compose_additive changes nothing). Rig faces +Z (wpn rest at z=+0.43 m), VRF units are metres. Re-parenting the arms mesh (82-bone skin) onto the clip skeleton rendered it unskinned even with name binds and merged bones; what works is keeping each model on its own imported skeleton, renaming the skeleton container nodes to the clip names and moving the clip AnimationPlayer under the same root (track paths resolve unchanged).
- Rust 2026-10 bundles are UnityFS with compression 0 (flags 0x40) and blocks up to 4014 MB: lazybundle now reads stored blocks straight from the file by offset. Before this, prep decompressed (copied) whole 4 GB blocks and died on low free RAM (run 7, textures.4).
- Release 0.1.0 uploaded to Melty draft rust-surf (modId 71a55670-...), one_click_check yes, release status draft, 3 media (2 stills + 21 s Movie Maker clip). Packaging gotcha: never drop .pyc from prep/python312 (embedded stdlib is .pyc only; first install test failed with 'No module named encodings').
