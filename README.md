# vpios

A personal, sideloadable iOS build of the **Unciv 4X core** (MPL-2.0, `mami52/unciv4x-core`, a Swift translation of Unciv 4.22.1), extended with **Vox Populi 4.22** game mechanics.

## What you get

- The app ships with two mods, copied into its Mods folder on launch: **Civ V Brave New World** (RobLoach, MPL-2.0) and **Vox Populi 4.22**, which is generated from VP's source by `vp2unciv`.
- To play VP, start a new game on *Civ V – Gods & Kings* with both mods ticked.

### VP engine rules (`Sources/VP/`)

These are active only when a mod ships `jsons/VPNeeds.json`:

- **Needs-based happiness** (`VPNeeds.swift`):
  - Sources: Distress, Poverty, Illiteracy, Boredom, Religious Unrest, Isolation, Pillaged Tiles, Famine, Occupation, Urbanization and Puppets.
  - Each city's unhappiness is capped at its population, specialists aside.
  - Yield medians are smoothed each round and saved.
  - Base and luxury happiness use VP's values.
  - Approval % is shown in the top bar.
- **Military supply** (`VPSupply.swift`):
  - Supply comes from difficulty, cities and 20% of population, reduced by era and tech progress.
  - Each unit over the cap costs 5% production and 5% growth.
  - Growth drops 2.5% per approval point below 50.
- **War weariness** (`VPWar.swift`): accumulates during long wars, halves in peace, and shows as Unhappiness.
- **Instant yields** (`VPInstantYields.swift`): VP's yields on birth, border growth, techs, policies, buildings, great people, conquest and founding, scaled by era, read from `jsons/VPData.json`.
- **Monopolies** (`VPMonopolies.swift`): over 50% of a resource is a Global Monopoly (tile and city yields, happiness, golden age length), over 25% of a strategic one a Strategic Monopoly (combat bonuses).
- **Corporations** (`VPCorporations.swift`):
  - A Headquarters needs the Corporations tech and a Global Monopoly on one of its resources; one per civ, and it grants a free Office.
  - Only the founder can build Offices. Each Office earns its yield per Franchise, up to the Franchise limit.
  - Franchises spread to nearby foreign cities from Office cities, plus VP's random spread (there are no international trade routes, see `GAPS.md`).

### VP data (`GameData/BundledMods/Vox Populi 4.22`)

- Techs, units, buildings and promotions.
- The nine policy trees, ideology tenets (on BNW's ideology rules), beliefs, and 27 civ abilities.
- `GAPS.md` lists everything not carried over.

## Layout

- `Sources/`, `GameData/`: the upstream core (`ci/UPSTREAM_COMMIT`). Engine changes are marked `// VP:` and kept in `Sources/VP/`.
- `Shell/`: the parts the published core leaves out (app entry, theme, art loading, mod downloader, bundled mods, self-test). Written fresh here; no Unciv 4X App Store code or artwork.
- CI (`.github/workflows/build.yml`) does the following on a macOS runner:
  1. Builds the app.
  2. Launches it on a simulator.
  3. Plays an 80-turn all-AI VP game (`-vpSelfTest`).
  4. Posts the report to the `ci-logs` branch.
  5. Uploads an unsigned `.ipa` artifact.

## Install on iPhone

1. Open the repo's Actions page, pick the latest green run, and download **VPiOS-unsigned-ipa**.
2. Unzip it.
3. Sideload `VPiOS-unsigned.ipa` with AltStore or SideStore, using a free Apple ID (re-sign every 7 days).

Not affiliated with Unciv 4X / AiArt LTD, the Unciv project, or the Vox Populi team. Licensed MPL-2.0 (see LICENSE, NOTICE.md).
