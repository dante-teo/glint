import AppKit
import CoreText
import SwiftUI

enum AppFonts {
    static let defaultTerminalFamily = "DepartureMono Nerd Font"
    static let terminalFallbackFamily = "Menlo"

    static let terminalFontFamilies = [
        defaultTerminalFamily,
        "SF Mono",
        terminalFallbackFamily,
        "Monaco",
        "Courier New",
        "JetBrains Mono",
        "Fira Code",
        "IBM Plex Mono",
    ]

    enum Barlow {
        static let regular = "Barlow-Regular"
        static let medium = "Barlow-Medium"
        static let semiBold = "Barlow-SemiBold"
        static let bold = "Barlow-Bold"
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(barlowPostScriptName(for: weight), size: size)
    }

    static func nsUI(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: barlowPostScriptName(for: weight), size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func barlowPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            return Barlow.bold
        case .semibold:
            return Barlow.semiBold
        case .medium:
            return Barlow.medium
        default:
            return Barlow.regular
        }
    }

    private static func barlowPostScriptName(for weight: NSFont.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            return Barlow.bold
        case .semibold:
            return Barlow.semiBold
        case .medium:
            return Barlow.medium
        default:
            return Barlow.regular
        }
    }
}

enum BundledFontRegistrar {
    static let fontResourceNames = [
        "DepartureMonoNerdFont-Regular",
        "Barlow-Regular",
        "Barlow-Medium",
        "Barlow-SemiBold",
        "Barlow-Bold",
    ]

    @discardableResult
    static func registerBundledFonts(bundle: Bundle = .main) -> Bool {
        fontResourceNames.reduce(true) { allSucceeded, name in
            guard let url = fontURL(forResource: name, bundle: bundle) else {
                NSLog("[glint] bundled font missing: \(name).otf")
                return false
            }

            var unmanagedError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
            guard registered else {
                if let error = unmanagedError?.takeRetainedValue() {
                    if isAlreadyRegistered(error) {
                        return allSucceeded
                    }
                    NSLog("[glint] couldn't register bundled font \(name): \(error)")
                } else {
                    NSLog("[glint] couldn't register bundled font \(name)")
                }
                return false
            }
            return allSucceeded
        }
    }

    static func fontURL(forResource name: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: "otf", subdirectory: "Fonts")
            ?? bundle.url(forResource: name, withExtension: "otf")
    }

    private static func isAlreadyRegistered(_ error: CFError) -> Bool {
        CFErrorGetDomain(error) == kCTFontManagerErrorDomain
            && CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
    }
}
