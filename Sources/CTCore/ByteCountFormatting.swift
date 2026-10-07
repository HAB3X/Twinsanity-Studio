import Foundation

/// Shared byte-count formatting, was reimplemented identically in three
/// separate view files (`SidebarView`, `WOCSoundBrowserView`,
/// `WOCCharacterArchiveBrowserView`), each a one-line wrapper around
/// `ByteCountFormatter`. Works for any integer size (`UInt32`, `Int`, ...)
/// so every call site can share this one implementation.
public extension BinaryInteger {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
