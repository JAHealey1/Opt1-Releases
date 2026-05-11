import SwiftUI

/// In-app credits + third-party license screen, reached from the Settings
/// window via the *About → Credits & Licenses* navigation link.
///
/// Three top-level credit blocks (ClueTrainer / RuneScape Wiki / Jagex)
/// matching `Opt1/THIRD_PARTY_LICENSES.md` and the public Opt1-Releases
/// README, plus a *View full licenses* disclosure containing the verbatim
/// MIT and CC BY-NC-SA notices. Visible attribution here is required by
/// CC BY-NC-SA's BY clause; reproducing it in three coordinated surfaces
/// (per-asset folder, repo `THIRD_PARTY_LICENSES.md`, this view) is the
/// share-alike-friendly posture used by RuneLite/Alt1/ClueTrainer.
struct CreditsView: View {

    private static let mitLicenseText = """
    MIT License

    Copyright (c) 2024 Lukas Gail

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    private static let ccBySaSummary = """
    Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported
    (CC BY-NC-SA 3.0).

    You are free to share and adapt this material so long as:

      • You give appropriate attribution (BY)
      • You do not use the material for commercial purposes (NC)
      • You distribute your contributions under the same licence (SA)

    Full licence text:
      https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode

    Plain-language summary:
      https://creativecommons.org/licenses/by-nc-sa/3.0/

    Opt1's compliance posture:
      • BY  — credited here, in the per-asset LICENSE.txt files inside the
              Resources folders, and in THIRD_PARTY_LICENSES.md.
      • NC  — Opt1 is free, ad-free, and not monetised.
      • SA  — wiki assets ship unmodified in their own folders, each with a
              co-located LICENSE.txt; the licence does not propagate to
              Opt1's Swift code under the "collective work" allowance.
    """

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String ?? "?"
        let build = dict?["CFBundleVersion"] as? String ?? "?"
        return "Opt1 \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                creditBlock(
                    title: "ClueTrainer",
                    subtitle: "MIT License — © 2024 Lukas Gail",
                    body: """
                    Opt1 ports several pieces of ClueTrainer into Swift, including \
                    the Celtic Knot rotation cost / canonical-pick logic, the \
                    elite compass reader (flood-fill rose detection, MSAA detection, \
                    AA pixel-count windows, and the binary-search / keyframe \
                    calibration tables from CompassReader.ts and \
                    CompassCalibrationFunction.ts), and the teleport spot \
                    dataset.
                    """,
                    link: ("ClueTrainer on GitHub",
                           URL(string: "https://github.com/Leridon/cluetrainer")!)
                )

                creditBlock(
                    title: "RuneScape Wiki",
                    subtitle: "CC BY-NC-SA 3.0 — © RuneScape Wiki contributors",
                    body: """
                    World-map tiles and teleport icons bundled with Opt1 are \
                    sourced from the RuneScape Wiki and shipped unmodified in \
                    their own folders, each with a co-located LICENSE.txt that \
                    preserves the share-alike clause without propagating it to \
                    Opt1's Swift code.
                    """,
                    link: ("RuneScape Wiki",
                           URL(string: "https://runescape.wiki")!)
                )

                creditBlock(
                    title: "Jagex Ltd.",
                    subtitle: "RuneScape © Jagex Ltd.",
                    body: """
                    The art that ultimately appears in the wiki sprites and map \
                    tiles is Jagex's intellectual property. Opt1 references this \
                    art purely to help legitimate players solve clue scrolls — \
                    the same fan-tool posture taken by RuneLite, Alt1, and \
                    ClueTrainer. Opt1 is not affiliated with, endorsed by, or \
                    sponsored by Jagex Ltd.
                    """,
                    link: nil
                )

                fullLicensesDisclosure

                Rectangle()
                    .fill(OverlayTheme.goldBorder.opacity(0.20))
                    .frame(height: 0.5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appVersion)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OverlayTheme.textSecondary)
                    Text("© 2026 Jacob Healey")
                        .font(.caption2)
                        .foregroundStyle(OverlayTheme.textSecondary.opacity(0.6))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OverlayTheme.bgPrimary)
        .foregroundStyle(OverlayTheme.textPrimary)
        .navigationTitle("Credits & Licenses")
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Credits & Licenses")
                .font(.title2.bold())
                .foregroundStyle(OverlayTheme.textPrimary)
            Text("""
                 Opt1 is a free, non-commercial fan tool. It builds on three \
                 external bodies of work, each credited below.
                 """)
                .font(.callout)
                .foregroundStyle(OverlayTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func creditBlock(
        title: String,
        subtitle: String,
        body: String,
        link: (String, URL)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(OverlayTheme.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(OverlayTheme.gold)
            Text(body)
                .font(.callout)
                .foregroundStyle(OverlayTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if let link {
                Link(link.0, destination: link.1)
                    .font(.callout)
                    .foregroundStyle(OverlayTheme.gold)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .fill(OverlayTheme.bgDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                        .strokeBorder(OverlayTheme.goldBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var fullLicensesDisclosure: some View {
        DisclosureGroup("View full licenses") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ClueTrainer — MIT License")
                        .font(.subheadline.bold())
                        .foregroundStyle(OverlayTheme.textPrimary)
                    Text(Self.mitLicenseText)
                        .font(.caption.monospaced())
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle()
                    .fill(OverlayTheme.goldBorder.opacity(0.20))
                    .frame(height: 0.5)

                VStack(alignment: .leading, spacing: 4) {
                    Text("RuneScape Wiki — CC BY-NC-SA 3.0")
                        .font(.subheadline.bold())
                        .foregroundStyle(OverlayTheme.textPrimary)
                    Text(Self.ccBySaSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(OverlayTheme.textSecondary)
        .padding(.vertical, 6)
    }
}

#Preview {
    NavigationStack {
        CreditsView()
    }
    .frame(width: 460, height: 600)
}
