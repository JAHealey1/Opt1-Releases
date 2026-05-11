import SwiftUI

// MARK: - Teleport overlay layer

/// Sibling layer to `RSWorldMapView`'s tile composite that paints a sprite
/// per visible teleport spot. Pulled into its own type so the world-map
/// drawing code stays focused on tiles + pins, and so the sprite-sizing
/// heuristics live next to the iconography they govern.
///
/// All drawing happens inside a SwiftUI `Canvas` closure on the main thread,
/// so the sprite cache lookup is unsynchronised by design (see
/// `TeleportSpriteCache`).
enum TeleportLayer {

    // MARK: Sizing

    /// Logical (1:1 zoom) sprite edge length in points. ClueTrainer uses
    /// 28 px in its source data; we mirror that as the upper anchor of the
    /// scale ramp below.
    static let baseSpriteSize: CGFloat = 28
    /// Lower clamp on rendered sprite size — at very low zooms we shrink
    /// toward this floor so the world map stays readable.
    static let minSpriteSize:  CGFloat = 14
    /// Upper clamp — keeps high-zoom views from blowing the icons up to
    /// pixel-art-blurry sizes.
    static let maxSpriteSize:  CGFloat = 32

    /// Below this map scale the layer is suppressed entirely. Hundreds of
    /// 14-pt sprites scattered across an at-a-glance world view become
    /// visual noise; the user should zoom in (or just run scan/clue
    /// solving) to see them.
    static let visibilityScaleThreshold: CGFloat = 0.18

    /// Below this scale the per-sprite code badge (fairy ring code,
    /// lodestone keybind, jewellery menu number) is suppressed. Sprites
    /// still render — we just don't try to cram 9-pt text onto a 14-pt
    /// icon when the user is panning a continent at a glance.
    static let codeVisibilityScaleThreshold: CGFloat = 0.35

    // MARK: Draw

    /// Renders each teleport spot whose sprite would land inside the
    /// viewport at the current pan/zoom.
    ///
    /// - Parameters:
    ///   - ctx: the Canvas graphics context owned by `RSWorldMapView`.
    ///   - spots: pre-filtered list of spots (by mapId/plane/setting toggle).
    ///   - spriteLookup: returns a decoded CGImage for a given filename, or
    ///     nil if it's missing/un-decodable. The caller (and not this
    ///     function) owns the cache so we can stay free of side-effects.
    ///   - size: viewport size in points.
    ///   - s: effective map scale (committed × gesture).
    ///   - focal: effective focal point in map-pixel coordinates.
    ///   - toScreenFn: same projection helper used by tiles + pins.
    ///   - toMapPxFn: game-tile coordinate → map-pixel coordinate.
    static func draw(_ ctx: inout GraphicsContext,
                     spots: [TeleportSpot],
                     spriteLookup: (String) -> CGImage?,
                     size: CGSize,
                     s: CGFloat,
                     focal: CGPoint,
                     toScreenFn: (CGFloat, CGFloat, CGSize, CGFloat, CGPoint) -> CGPoint,
                     toMapPxFn: (Int) -> CGFloat) {
        guard s >= visibilityScaleThreshold, !spots.isEmpty else { return }

        // Linear ramp: at the low end of the visibility window the sprites
        // sit on the floor; near 1× and above they top out at the cap. The
        // exact curve isn't critical — it just keeps icons proportional to
        // the surrounding map detail without exploding at high zooms.
        let raw   = baseSpriteSize * s
        let edge  = max(minSpriteSize, min(maxSpriteSize, raw))
        let half  = edge / 2

        let drawCodes = s >= codeVisibilityScaleThreshold

        for spot in spots {
            let sp = toScreenFn(toMapPxFn(spot.x), toMapPxFn(spot.y),
                                size, s, focal)

            // Cheap viewport reject — sprite fully off-screen.
            if sp.x < -half || sp.x > size.width  + half ||
               sp.y < -half || sp.y > size.height + half {
                continue
            }

            let rect = CGRect(x: sp.x - half, y: sp.y - half,
                              width: edge, height: edge)

            guard let filename = spot.resolvedIcon,
                  let img = spriteLookup(filename) else {
                // Fallback marker so a missing sprite is still locatable
                // in-app — small dim square, easy to tell apart from a pin.
                ctx.fill(
                    Path(CGRect(x: sp.x - 3, y: sp.y - 3, width: 6, height: 6)),
                    with: .color(Color.purple.opacity(0.55))
                )
                continue
            }

            // Subtle 1-pt dark outline boosts contrast against the
            // browned-out map tiles without distracting from clue pins.
            ctx.stroke(
                Path(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5),
                     cornerRadius: 3),
                with: .color(.black.opacity(0.45)),
                lineWidth: 1
            )
            ctx.draw(Image(decorative: img, scale: 1.0), in: rect)

            // Code badge (fairy ring code, lodestone keybind, multi-spot
            // menu number). ClueTrainer paints these directly on the
            // sprite; matching that convention so users carrying muscle
            // memory from there read the same iconography on Opt1's map.
            if drawCodes, let code = displayCode(for: spot.code) {
                drawCodeBadge(&ctx, code: code, anchor: rect, spriteEdge: edge)
            }
        }
    }

    // MARK: Code badge

    /// Picks the substring shown on the sprite. ClueTrainer's data stores
    /// short keybinds verbatim ("A", "Opt+M", "1") and fairy ring codes as
    /// 3-letter clusters ("AIQ"). A handful of entries (e.g. Ork's Rift's
    /// "BIR DIP CLR ALP") cram several alternate codes into one string;
    /// we render only the first to keep the badge legible.
    private static func displayCode(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let firstToken = raw.split(separator: " ").first.map(String.init) ?? raw
        guard !firstToken.isEmpty else { return nil }
        // Cap absolute width — Lodestone modifier chords like "Shift+F"
        // (7 chars) must fit; fairy-ring first tokens stay ≤3 letters. Very
        // long single tokens are still clipped so runty multi-code blobs
        // do not overwhelm the badge.
        let maxChars = 10
        return firstToken.count <= maxChars ? firstToken
                                           : String(firstToken.prefix(maxChars))
    }

    private static func drawCodeBadge(_ ctx: inout GraphicsContext,
                                      code: String,
                                      anchor: CGRect,
                                      spriteEdge: CGFloat) {
        // Font size scales with the sprite so the badge stays readable
        // without dwarfing small icons or floating tiny on the big ones.
        let fontSize = max(7.5, min(11, spriteEdge * 0.40))
        let resolved = ctx.resolve(
            Text(code)
                .font(.system(size: fontSize, weight: .bold,
                              design: .monospaced))
                .foregroundStyle(.white)
        )
        let textSize = resolved.measure(in: CGSize(width: 200, height: 50))

        // Pill: padded around the resolved text, anchored to the sprite's
        // bottom-right and overhanging slightly so the badge doesn't
        // occlude the centre of the icon.
        let padX: CGFloat = 2.5
        let padY: CGFloat = 0.5
        let pillW = textSize.width + padX * 2
        let pillH = textSize.height + padY * 2
        let pillRect = CGRect(
            x: anchor.maxX - pillW * 0.85,
            y: anchor.maxY - pillH * 0.85,
            width: pillW,
            height: pillH
        )

        ctx.fill(
            Path(roundedRect: pillRect, cornerRadius: pillH * 0.35),
            with: .color(.black.opacity(0.78))
        )
        ctx.stroke(
            Path(roundedRect: pillRect, cornerRadius: pillH * 0.35),
            with: .color(.white.opacity(0.18)),
            lineWidth: 0.5
        )
        ctx.draw(
            resolved,
            at: CGPoint(x: pillRect.midX, y: pillRect.midY),
            anchor: .center
        )
    }
}
