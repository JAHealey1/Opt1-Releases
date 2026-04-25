# Opt1

Opt1 is a free macOS helper for *RuneScape* clue scrolls. Drop a clue scroll
on screen, hit the hotkey, and Opt1 reads it, matches it against the wiki
corpus, and renders the answer as a draggable overlay above your game window.
It also covers the Celtic Knot, sliding-puzzle, lockbox, and towers
sub-puzzles, and overlays teleport sprites on the world map.

## Free distribution

- **No ads.** No banners, no interstitials.
- **No monetisation.** No paid tier, no donations-to-unlock, no in-app
  purchases, no telemetry sold to third parties.
- **No automation.** Opt1 reads pixels from the screen and draws an overlay.
  It never moves your mouse, presses keys, or sends input to the game client.

## Downloads

Latest builds are published as releases on this repository. The auto-update
appcast (`appcast.xml`) is hosted alongside the binaries so the in-app
Sparkle integration can fetch updates automatically.

## Credits & Licenses

Opt1 builds on three external bodies of work. The full notices live in
`LICENSES/` (in this repository) and in `THIRD_PARTY_LICENSES.md` (bundled
inside the `.app`). The same notices are also reachable in the running app
via *Settings → Credits & Licenses*.

### ClueTrainer (MIT)

Opt1 ports several pieces of [ClueTrainer](https://github.com/Leridon/cluetrainer)
into Swift — the Celtic Knot rotation cost / canonical-pick logic, the
elite compass reader (flood-fill rose detection, MSAA detection, AA
pixel-count windows, and the binary-search / keyframe-interpolation
calibration tables ported from `CompassReader.ts` and
`CompassCalibrationFunction.ts`), and the teleport spot dataset.
ClueTrainer is
© 2024 Lukas Gail and is distributed under the MIT License. The full
licence text is reproduced in `LICENSES/THIRD_PARTY_LICENSES.md`.

### RuneScape Wiki (CC BY-NC-SA 3.0)

The world-map tiles and teleport icons that ship with Opt1 are sourced from
the [RuneScape Wiki](https://runescape.wiki) and are © RuneScape Wiki
contributors, distributed under the Creative Commons
Attribution-NonCommercial-ShareAlike 3.0 Unported licence. Opt1's
non-commercial posture (no ads, no payments, no donations) preserves the
NC clause; assets are shipped unmodified in their own folders, each with a
co-located `LICENSE.txt`, which preserves the SA clause without the licence
propagating to Opt1's Swift source.

### Jagex Ltd.

*RuneScape* is © Jagex Ltd. The art that ultimately appears in the wiki
sprites and map tiles is Jagex's intellectual property. Opt1 references this
art purely for the purpose of helping legitimate players solve in-game clue
scrolls — the same fan-tool posture taken by long-running community projects
like [RuneLite](https://runelite.net/), [Alt1](https://runeapps.org/alt1),
and ClueTrainer. Opt1 is not affiliated with, endorsed by, or sponsored by
Jagex Ltd. If you are a Jagex rights-holder and want a specific asset
removed or changed, please open an issue on this repository.

## License

Opt1's own source code is © 2026 Jacob Healey. See `LICENSES/LICENSE` for
the user-facing redistribution terms. Redistribution of the Opt1 binary
should preserve `LICENSES/THIRD_PARTY_LICENSES.md` (or an equivalent notice)
alongside the build.
