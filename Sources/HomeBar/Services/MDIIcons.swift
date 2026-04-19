import Foundation
import AppKit
import CoreText
import SwiftUI

/// Material Design Icons font registration and name→glyph lookup.
///
/// HA's `icon` attribute uses MDI names like `mdi:chair`. We ship the MDI font
/// and a `name → codepoint (hex)` map in the app bundle, register the font at
/// launch, and render icons as `Text("\u{F1026}")` with the MDI font.
@MainActor
enum MDIIcons {
    static let fontName = "Material Design Icons"
    static let fontFile = "materialdesignicons"
    static let mapFile = "mdi-map"

    private static var nameToCodepoint: [String: String] = [:]
    private static var registered = false

    /// Call once at app launch. Registers the MDI font with the system and
    /// loads the name→codepoint map from the app bundle.
    static func bootstrap() {
        guard !registered else { return }
        registered = true
        registerFont()
        loadMap()
    }

    /// Returns the Unicode scalar for the given MDI name (without the `mdi:`
    /// prefix), or nil if the name isn't in the map.
    static func character(for name: String) -> Character? {
        let cleaned = name.hasPrefix("mdi:") ? String(name.dropFirst(4)) : name
        guard let hex = nameToCodepoint[cleaned],
              let scalarValue = UInt32(hex, radix: 16),
              let scalar = Unicode.Scalar(scalarValue) else { return nil }
        return Character(scalar)
    }

    static func hasMapping(_ name: String) -> Bool {
        let cleaned = name.hasPrefix("mdi:") ? String(name.dropFirst(4)) : name
        return nameToCodepoint[cleaned] != nil
    }

    // MARK: - Private

    private static func registerFont() {
        guard let url = Bundle.main.url(forResource: fontFile, withExtension: "ttf") else {
            fputs("MDIIcons: font file not found in bundle\n", stderr)
            return
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok, let err = error?.takeRetainedValue() {
            fputs("MDIIcons: font registration failed: \(err)\n", stderr)
        }
    }

    private static func loadMap() {
        guard let url = Bundle.main.url(forResource: mapFile, withExtension: "json") else {
            fputs("MDIIcons: map file not found in bundle\n", stderr)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                nameToCodepoint = dict
            }
        } catch {
            fputs("MDIIcons: failed to load map: \(error)\n", stderr)
        }
    }
}

/// SwiftUI view that renders an MDI icon. Falls back to an SF Symbol if the
/// name isn't in our map so new/unknown icons still render something.
struct MDIIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        let ch = MainActor.assumeIsolated { MDIIcons.character(for: name) }
        if let ch {
            Text(String(ch))
                .font(.custom(MDIIcons.fontName, size: size))
        } else {
            Image(systemName: "circle")
                .font(.system(size: size * 0.85))
        }
    }
}
