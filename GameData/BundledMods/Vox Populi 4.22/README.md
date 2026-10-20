# Vox Populi 4.22 for Unciv

An **extension mod on Civ V – Gods & Kings + Civ V Brave New World** ([RobLoach/Civ-V-Brave-New-World](https://github.com/RobLoach/Civ-V-Brave-New-World)) carrying over Vox Populi 4.22's game data: tech tree, units, buildings, promotions, resources, improvement yields, the nine classic social policy trees and the beliefs.

- Techs, units and buildings replace the base ones wholesale (`techsToRemove`, `unitsToRemove`, `buildingsToRemove: ["All"]`); BNW's Great Work slots are kept.
- The policy branches take VP's names (Progress, Authority, Fealty, Statecraft, Artistry, Industry, Imperialism); BNW's ideologies stay.
- `jsons/VPNeeds.json` carries VP's needs-based happiness and military supply numbers. Desktop Unciv ignores it; the VPiOS build (EmptyMonad/Vpios) runs VP's happiness and supply rules from it.

Generated mechanically from the VP source (`LoneGazebo/Community-Patch-DLL`, tag `Release-4.22-TRUE`) and checked with:
- **Unciv 4.22.12's validator** on G&K + BNW + this mod: 0 errors.
- **A 150-turn all-AI simulation** on G&K + BNW + this mod.
- **iOS coverage:** every unique pattern the mod uses is one the Unciv 4X Swift port matches on (BNW's own Great Work markers aside).

## Not carried over

GAPS.md lists everything. In short:
- **Civ abilities (traits):** still BNW's. VP_RULES.md has VP's text.
- **Ideology tenets:** still BNW's.
- **Policy and belief effects that need engine work:** City-State influence, World Congress, tourism modifiers, golden-age points from happiness, and similar. These are listed per policy in GAPS.md, and each policy's civilopedia entry shows VP's full text.
- **Corporations and their buildings.**
- **Art:** new VP units and buildings use Unciv's placeholder icons. Renamed policies reuse the icon of the policy they replace.

## Install

1. Install **Civ V Brave New World** and this mod, either from the in-game mod browser or with **Download mod from URL**. The VPiOS build ships with both.
2. Start a new game on **Civ V – Gods & Kings** with both mods enabled.
