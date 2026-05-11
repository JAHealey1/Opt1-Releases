# Opt1

Opt1 is a free macOS helper for *RuneScape 3* clue scrolls. Open a clue scroll
on screen, hit the hotkey, and Opt1 reads it, matches it against the wiki
corpus, and renders the answer as a draggable overlay above your game window.
It also solves Celtic Knots, Slide Puzzles, Lockboxes, and Towers puzzles.

## System requirements

- macOS 14.0 (Sonoma) or newer
- Apple Silicon or Intel Mac (untested on Intel but should work)

## Install

### Recommended: Direct download

Latest release: [Download](https://github.com/JAHealey1/Opt1-Releases/releases/latest)
Open the .dmg, and drag `Opt1.app` into `/Applications`.

### Alternative: Homebrew

```bash
brew tap JAHealey1/opt1
brew install opt1
```

## First launch & permissions

Opt1 needs two macOS permissions before it can do anything useful:

1. **Screen Recording** — used to capture pixels of the *RuneScape 3* window so
   Opt1 can read clues, puzzles, and the compass. Without it, every solve
   silently fails. Granted via *System Settings → Privacy & Security → Screen
   & System Audio Recording → toggle Opt1 ON*.
2. **Accessibility** — required by the global hotkey (default `⌥1`). Without
   it, the menu bar items still work but the keyboard shortcut won't.
   Granted via *System Settings → Privacy & Security → Accessibility →
   toggle Opt1 ON*.

Opt1 prompts for both on first launch. If you decline, you can re-prompt
later via the menu bar item: *Opt1 → Permissions…*. macOS occasionally
forgets these toggles after upgrades — if Opt1 stops working after a
macOS update, re-toggle both permissions OFF and ON.

> **Recommended:** Enable Debug mode in *Opt1 → Settings… → Diagnostics*. The
> data written to the debug folder is essential for diagnosing any issues.

## Updates

You can check for updates in the menu bar via *Opt1 → Check for Updates…*.
During an update you can opt in to auto-updates in the future.

## Clue Support

| Type | Status | Notes |
|---|---|---|
| Simple, Riddle, Cryptic, Anagram, Emote, Coordinates | ✅ | |
| Map clues | ✅ | |
| Scan clues | ✅ | |
| Slide puzzles | ✅ | `⌥2` to snip puzzle area, or `⌥1` for autodetection *(experimental)* |
| Celtic Knot puzzles | ✅ | |
| Lockboxes | ✅ | |
| Towers puzzles | ✅ | |
| Elite/Master Compasses | ✅ | |

## Advanced Features

### Compass Auto-Triangulation

You can calibrate two triangulation spots in settings so that clicking the map manually is not necessary. When you have a compass clue:

1. Teleport to your first calibrated spot and press `⌥1`
2. Teleport to your second calibrated spot and press `⌥1`

The intersection is calculated and zoomed to automatically. You can also configure a separate pair of Eastern Lands triangulation points in settings.

### Other Features

| Feature | Notes |
|---|---|
| RuneScape UI scaling | Tell Opt1 your scale factor in settings *(experimental)* |
| Scan guidance | Enable in settings — pathing data is limited and will improve in future releases *(experimental)* |
| Custom keybinds | Configurable in settings |
| Puzzle solve speed | Tunable in settings |
| Draggable / resizable UI | All overlay panels can be repositioned and resized |

## Reporting issues

Found a bug, a misread clue, or a puzzle Opt1 gets wrong? Please open an
[issue](https://github.com/JAHealey1/Opt1-Releases/issues/new). Helpful
details:

- macOS version, chip family (Apple Silicon vs Intel), Opt1 version
  (visible at *Opt1 → Settings… → About*).
- The clue text or screenshot of the puzzle that failed.
- What Opt1 showed vs. what the correct answer was.
- If you have Debug mode enabled, include the contents of the relevant debug folder (*Opt1 → Settings... → Diagnostics → Debug output folder*)

## Credits & Licenses

Opt1 builds on three external bodies of work. The full notices live in
`LICENSES/` (in this repository) and in `THIRD_PARTY_LICENSES.md` (bundled
inside the `.app`). The same notices are also reachable in the running app
via *Settings → Credits & Licenses*.

### ClueTrainer (MIT)

Opt1 ports the binary-search / keyframe-interpolation
calibration tables from `CompassReader.ts` and
`CompassCalibrationFunction.ts`, and the teleport spot dataset from [ClueTrainer](https://github.com/Leridon/cluetrainer) into Swift.
ClueTrainer is © 2024 Lukas Gail and is distributed under the MIT License. The full
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
