# Vox Populi 4.22 for Unciv

An **extension mod for the Civ V – Gods & Kings ruleset** that carries over Vox Populi 4.22's data-layer changes: the tech tree, units, buildings, promotions, resources and improvement yields.
- Techs, units and buildings replace G&K's wholesale, via `techsToRemove`, `unitsToRemove` and `buildingsToRemove: ["All"]`.
- Everything else merges with G&K by name.
- It's packaged as an extension because the Unciv 4X iOS port only accepts its own bundled base rulesets.

Generated mechanically from the VP source (`LoneGazebo/Community-Patch-DLL`, tag `Release-4.22-TRUE`), and checked three ways:
- **Unciv 4.22.12 validator, run on G&K + this mod:** 0 errors, 1 harmless warning (Foreign Legion's auto-upgrade timing).
- **AI simulation:** a 250-turn, 4-civ game on G&K + this mod runs to completion.
- **iOS port coverage:** every unique and conditional pattern in the mod is one that the Unciv 4X Swift port matches on. The port is a translation of Unciv 4.22.1.

## What's in it

| | Count | Source |
|---|---|---|
| Techs | 82 | VP costs, prerequisites and grid layout; adds BNW's Internet; Pharmaceuticals stands in for Penicillin |
| Units | 151 | VP stats, costs, tech gates, upgrade lines, resource needs, free promotions; 25 new VP units |
| Buildings | 187 | VP costs, maintenance, yields, % bonuses, specialists and prerequisites, plus resource, terrain, feature, improvement, per-population and building-class yield effects; 67 new VP buildings |
| Promotions | 289 | VP combat modifiers mapped to Unciv uniques |
| Resources | 46 | VP yields; 11 new VP luxuries placed on VP terrains |
| Specialists | 5 | adds VP's Civil Servant |

## What isn't

GAPS.md has the full list. VP_RULES.md has VP's own rules text for the policies, beliefs and civ traits that still need translating.

- **Engine mechanics:** VP's needs-based happiness, City-State Diplomacy, corporations, vassalage, World Congress changes and AI. These live in VP's C++ game core, so no mod can carry them over.
- **Policies, beliefs and civ abilities:** these still use G&K's versions. VP_RULES.md is the spec for translating them.
- **BNW-only content missing from Unciv's G&K ruleset:** Bison, Cocoa and Brazilwood; Great Writers, Great Musicians and Archaeologists; Brazil and Venice as major civs. It's dropped wherever it was referenced.
- **Art:** new VP units and buildings have none, so Unciv shows its default placeholder icon.

## Install (Unciv 4X on iPhone, or any Unciv build)

1. Put this folder in a public GitHub repo, with `jsons/` at the repo root.
2. In Unciv, open **Mods → Download mod from URL**, paste the repo URL and download it. Optionally, add the GitHub topic `unciv-mod` to the repo so it also appears in the in-game mod browser.
3. Start a new game with **Civ V – Gods & Kings** as the base ruleset, then enable **Vox Populi 4.22** under mods.
