import AppKit
import WebKit

/// Whether an extension that must be set up before it does anything is set
/// up in its profile (`EngineExtensionSummary.isSetUp`). Only iCloud
/// Passwords is: it is paired with the Passwords app or it is not.
///
/// Its worker shows the pairing only through the toolbar icon it sets
/// (`ICloudPasswordsExtension.pairedIconFiles`), and WebKit gives the app the
/// icon only as an image, never the path the worker named. So the icon is
/// matched against the extension's own image files, byte for byte as WebKit
/// renders them: WebKit decodes the file the worker named and hands that
/// image back unchanged, so the TIFF of the action's icon equals the TIFF of
/// that file's image. Nothing the extension sends or receives is read.
@available(macOS 15.4, *)
@MainActor
enum WebKitExtensionSetupState {
    /// The extension's icon files, keyed by package path, as WebKit would
    /// render them.
    private static var renderedFiles: [String: [String: Data]] = [:]

    /// The icon is asked for at this size, so WebKit picks the 32-point files.
    private static let iconSize = CGSize(width: 32, height: 32)

    /// Nil for an extension with nothing to set up.
    static func isSetUp(_ context: WKWebExtensionContext?, id: String, package: URL) -> Bool? {
        guard id == ICloudPasswordsExtension.storeID else { return nil }
        guard let context, context.isLoaded else { return false }
        let helperRunning = !WebKitNativeMessaging.hostProcessIdentifiers(for: context).isEmpty
        guard helperRunning else { return false }
        return ICloudPasswordsExtension.isPaired(iconFile: iconFile(of: context, package: package), helperRunning: helperRunning)
    }

    /// Which of the extension's known icon files the default action's icon
    /// is, if any.
    private static func iconFile(of context: WKWebExtensionContext, package: URL) -> String? {
        guard let icon = context.action(for: nil)?.icon(for: iconSize)?.tiffRepresentation else { return nil }
        let files = rendered(package)
        return (ICloudPasswordsExtension.pairedIconFiles + ICloudPasswordsExtension.unpairedIconFiles)
            .first { files[$0] == icon }
    }

    private static func rendered(_ package: URL) -> [String: Data] {
        if let known = renderedFiles[package.path] { return known }
        var files: [String: Data] = [:]
        for path in ICloudPasswordsExtension.pairedIconFiles + ICloudPasswordsExtension.unpairedIconFiles {
            if let data = NSImage(contentsOf: package.appendingPathComponent(path))?.tiffRepresentation {
                files[path] = data
            }
        }
        renderedFiles[package.path] = files
        return files
    }

    /// A package folder whose files changed (an update) is read again.
    static func forget(_ package: URL) {
        renderedFiles[package.path] = nil
    }
}
