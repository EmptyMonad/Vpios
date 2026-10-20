# vpios

A personal, sideloadable iOS build of the **Unciv 4X core** (MPL-2.0, `mami52/unciv4x-core`, itself a Swift translation of Unciv 4.22.1). The goal is to add Vox Populi engine mechanics that a data mod can't express.

- `Sources/`, `GameData/`: upstream core, unmodified except where commits say otherwise. Upstream commit is in `ci/UPSTREAM_COMMIT`.
- `Shell/`: what the published core leaves out (app entry, theme, art loading, mod downloader, ...). Written fresh here; no Unciv 4X App Store code or artwork.
- CI (`.github/workflows/build.yml`) builds on a macOS runner, posts the compiler report to the `ci-logs` branch, and uploads an unsigned `.ipa` artifact once the build is green. Sign it with AltStore/SideStore to install.

Not affiliated with Unciv 4X / AiArt LTD or the Unciv project. Licensed MPL-2.0 (see LICENSE, NOTICE.md).
