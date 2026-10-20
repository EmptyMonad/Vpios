# Credits

## Rules and data

The game rules shipped under `Rulesets/` (and `Tutorials.json`, `Translations/` and
`WesnothImportMappings.json`) are derived from the open-source game
[Unciv](https://github.com/yairm210/Unciv) by Yair Morgenstern and the Unciv contributors,
used under the Mozilla Public License 2.0 (see `UNCIV_LICENSE.txt`).

## Art and sound

All images under `Art/` and all sounds under `Sound/` are original to Epochs. They are
generated procedurally, without any third-party images, samples or fonts other than
Pillow's bundled public-domain default font, by the scripts in `tools/assets/`
(`generate_art.py` with `icons.py`, `glyphs.py`, `tiles.py`, `units.py`, `symbols.py`,
`render3d.py`; `generate_sounds.py`). The religion and city-state symbols, map arrows, roads and
the Maya calendar icon are drawn by `symbols.py`; the religious signs they show (cross, crescent
and star, Star of David, dharma wheel, Om, khanda, yin-yang, torii, fire altar) are public-domain
symbols in drawings of our own. No Unciv, Fantasy Hex, Noun Project, game-icons.net, Wesnoth
or other third-party artwork or audio is included; `tools/assets/check_no_unciv_art.py <unciv
clone>` compares every app image with Unciv's, byte for byte and scaled or recoloured, and fails
on any match.
