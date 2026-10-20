# Notice

Unciv 4X, AiArt LTD.

This repository contains Covered Software derived from **Unciv 4.22.1**
(https://github.com/yairm210/Unciv), Copyright Yair Morgenstern and the Unciv contributors,
licensed under the Mozilla Public License 2.0.

- Unciv's credits: [GameData/UNCIV_CREDITS.md](GameData/UNCIV_CREDITS.md)
- Unciv's license: [GameData/UNCIV_LICENSE.txt](GameData/UNCIV_LICENSE.txt) (the same text as [LICENSE](LICENSE))

The Swift sources in `Sources/` are a translation of Unciv's Kotlin sources and are distributed under the same
license; each file carries the MPL-2.0 notice (Exhibit A).

## Bundled mods

- `GameData/BundledMods/Civ V Brave New World`: RobLoach/Civ-V-Brave-New-World (commit in `ci/BNW_COMMIT`), MPL-2.0; its LICENSE and CREDITS.md are in that folder.
- `GameData/BundledMods/Vox Populi 4.22`: generated from LoneGazebo/Community-Patch-DLL (tag Release-4.22-TRUE) game data and text by the vp2unciv converter. Vox Populi is the work of the Community Patch / Vox Populi team.
- `Sources/VP/`: Swift ports of Vox Populi rules (needs-based happiness, military supply, war weariness) written from that project's C++ sources.
