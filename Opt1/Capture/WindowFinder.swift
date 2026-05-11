import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - SCWindow + AppKit global frame

extension SCWindow {

    /// Window frame in AppKit screen coordinates (origin bottom-left of primary, Y up).
    /// Uses `CGWindowListCopyWindowInfo` for the most reliable CG rect, then flips to AppKit.
    func appKitGlobalFrame(content: SCShareableContent) -> CGRect {
        let cgRect = Self.cgWindowBounds(windowID: CGWindowID(windowID)) ?? frame
        return PuzzleSnipDesktop.cgRectToAppKit(cgRect)
    }

    /// Sync API for call sites without `SCShareableContent` (fallback only).
    func globalFrameAppKit() -> CGRect {
        let cgRect = Self.cgWindowBounds(windowID: CGWindowID(windowID)) ?? frame
        return PuzzleSnipDesktop.cgRectToAppKit(cgRect)
    }

    private static func cgWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[CFString: Any]],
              let info = list.first else {
            print("[Opt1] CGWindowListCopyWindowInfo empty for id \(windowID)")
            return nil
        }
        let bounds: NSDictionary
        if let b = info[kCGWindowBounds as CFString] as? NSDictionary {
            bounds = b
        } else if let b = info["Bounds" as CFString] as? NSDictionary {
            bounds = b
        } else {
            print("[Opt1] CGWindow: no Bounds dict in window info")
            return nil
        }
        func num(_ keys: [String]) -> CGFloat? {
            for k in keys {
                if let n = bounds[k] as? NSNumber { return CGFloat(truncating: n) }
                if let n = bounds[k] as? Double { return CGFloat(n) }
            }
            return nil
        }
        guard let x = num(["X", "x"]),
              let y = num(["Y", "y"]),
              let w = num(["Width", "width"]),
              let h = num(["Height", "height"]) else {
            print("[Opt1] CGWindow bounds parse failed: \(bounds)")
            return nil
        }
        let r = CGRect(x: x, y: y, width: w, height: h)
        guard r.width > 20, r.height > 20 else { return nil }
        return r
    }
}

/// Shared desktop / coordinate helpers (also used by snip overlay).
enum PuzzleSnipDesktop {
    static func combinedScreensFrameStatic() -> CGRect {
        var u = CGRect.null
        for s in NSScreen.screens {
            u = u.union(s.frame)
        }
        if u.isNull || u.isEmpty { return NSScreen.main?.frame ?? .zero }
        return u
    }

    /// Convert CoreGraphics screen coordinates (origin top-left of primary, Y down) to AppKit screen coordinates (origin bottom-left of primary, Y up)
    static func cgRectToAppKit(_ r: CGRect) -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return r }
        return CGRect(
            x: r.origin.x,
            y: primaryHeight - r.origin.y - r.height,
            width: r.width,
            height: r.height
        )
    }
}

struct WindowFinder {

    // Known RuneScape application identifiers. Add extras here if needed.
    private static let knownAppNames     = ["runescape", "rs2client"]
    private static let knownBundleFragments = ["jagex", "runescape"]

    /// Returns the RuneScape game window, or nil if RS3 is not running.
    ///
    /// RS3 creates several windows (background service windows, zero-size helpers).
    /// We filter to windows with a meaningful on-screen area and pick the largest
    /// one, which is always the game window.
    static func findRuneScapeWindow() async throws -> SCWindow? {
        let content = try await SCShareableContent.current
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            // Require a visible, game-sized frame - ignore zero-size service windows.
            guard window.frame.width > 200 && window.frame.height > 200 else { return false }
            let name   = app.applicationName.lowercased()
            let bundle = app.bundleIdentifier.lowercased()
            return knownAppNames.contains(where: { name.contains($0) })
                || knownBundleFragments.contains(where: { bundle.contains($0) })
        }
        return candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        })
    }

    static func debugListWindows() async throws {
        let content = try await SCShareableContent.current
        print("[Opt1] --- Visible Windows ---")
        for window in content.windows {
            let app    = window.owningApplication
            let title  = window.title ?? "(no title)"
            let name   = app?.applicationName ?? "?"
            let bundle = app?.bundleIdentifier ?? "?"
            let frame  = window.frame
            print("[Opt1]  '\(title)' | app: \(name) | bundle: \(bundle) | frame: \(frame)")
        }
        print("[Opt1] --- End ---")
    }
}
