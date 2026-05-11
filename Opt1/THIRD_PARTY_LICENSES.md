# Third-Party Licenses & Attributions

Opt1 is a free, non-commercial fan tool for *RuneScape*. It does not automate
input, does not display ads, and is not monetised in any way (no paid tier, no
donate-to-unlock, no telemetry-for-revenue). It builds on top of code and
data published by the RuneScape community and uses art assets that are
ultimately the property of Jagex Ltd. The notices below cover everything Opt1
ships that originated outside this repository.

If you are redistributing Opt1 or a fork, you must keep this file (or a
substantively equivalent notice) alongside the binary.

---

## 1. ClueTrainer

**Origin.** [ClueTrainer](https://github.com/Leridon/cluetrainer) — an
in-browser clue-scroll helper by Lukas Gail. Opt1 ports several pieces of
ClueTrainer's source into Swift, including:

- The Celtic Knot rotation cost / canonical-pick logic in
  `Opt1/Solvers/CelticKnotSolver.swift`.
- The elite compass reader pipeline — flood-fill rose detection, MSAA
  detection, AA pixel-count windows, and the binary-search /
  keyframe-interpolation calibration tables — adapted from
  `src/trainer/ui/neosolving/cluereader/CompassReader.ts` and
  `…/capture/CompassCalibrationFunction.ts` into
  `Opt1/Detection/EliteCompassDetector.swift`,
  `Opt1/Detection/CompassCalibration.swift`, and
  `Opt1/Detection/UncertainAngle.swift`.
- The teleport spot dataset (ported from `src/data/teleport_data.ts` into
  `Opt1/Matching/Resources/teleports.json`).

**License (MIT).**

> MIT License
>
> Copyright (c) 2024 Lukas Gail
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

ClueTrainer's upstream license carve-out (it scopes the MIT grant to
`src/` excluding `src/oldlib.ts` and `src/skillbertssolver/`) is honoured —
Opt1 only ports from files inside that grant.

---

## 2. RuneScape Wiki

**Origin.** [RuneScape Wiki](https://runescape.wiki) — the community-maintained
wiki for *RuneScape*. Opt1 ships PNG assets sourced from the wiki:

- World-map tiles bundled under `Opt1/Matching/Resources/MapTiles/`.
- Teleport icons bundled under `Opt1/Matching/Resources/TeleportIcons/`.

Each asset folder also contains a co-located `LICENSE.txt` with the same
notice for forked or partial redistributions.

**License — Creative Commons Attribution-NonCommercial-ShareAlike 3.0
Unported (CC BY-NC-SA 3.0).** Full license text:
<https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode>. Plain-language
summary: <https://creativecommons.org/licenses/by-nc-sa/3.0/>.

**Attribution.** "Sprites and map tiles sourced from the RuneScape Wiki
(<https://runescape.wiki>), © RuneScape Wiki contributors."

**Compliance posture.**

- **BY (attribution):** This file, the per-folder `LICENSE.txt` files, and
  the in-app *Credits & Licenses* screen all credit the RuneScape Wiki.
- **NC (non-commercial):** Opt1 is free, ad-free, and is not monetised. There
  is no paid tier, no donation-to-unlock, and no commercial redistribution.
- **SA (share-alike):** The wiki assets are shipped unmodified inside their
  own clearly-licensed folders. Opt1's Swift code is its own work and is
  *not* a derivative of the assets — under SA's "collective work" allowance,
  the Swift source remains under Opt1's own terms while the assets keep
  their CC BY-NC-SA 3.0 licence. We do not bake modified versions of these
  PNGs into Swift code or bundle resources.

---

## 3. Jagex Ltd.

**Origin.** *RuneScape* is © Jagex Ltd. The art that ultimately appears in
the wiki sprites and map tiles is Jagex's intellectual property. Opt1
references this art purely for the purpose of helping legitimate players
solve in-game clue scrolls — the same posture taken by long-running
community tools such as [RuneLite](https://runelite.net/),
[Alt1](https://runeapps.org/alt1), and ClueTrainer.

Opt1 is not affiliated with, endorsed by, or sponsored by Jagex Ltd. If you
are a Jagex rights-holder and would like Opt1 to remove or change a specific
asset, please open an issue on the public releases repository at
<https://github.com/jacobhealey/Opt1-Releases>.

---

## 4. Opt1 itself

Opt1's Swift source is © 2026 Jacob Healey. It is shipped free of charge for
non-commercial use; redistribution of the binary should preserve this file
and the per-asset `LICENSE.txt` notices. See `Opt1-Releases/LICENSES/LICENSE`
in the public release repository for the user-facing terms.
