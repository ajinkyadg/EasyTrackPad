import AppKit

/// Thin wrapper around `NSWorkspace`'s frontmost-app query, used by each
/// device manager to check `CustomizationRule.applies(whileFrontmostAppIs:)`.
/// Kept separate from `CustomizationRule` so the model stays a pure,
/// AppKit-free, unit-testable data type.
enum ActiveApp {
    static var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
