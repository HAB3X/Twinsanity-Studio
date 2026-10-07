import SwiftUI

/// "Memory-Mapped Hex Engine" (roadmap 5.2): the "synchronized Hex-Quick
/// View split pane" half of the blueprint, `HexViewerWindow` already
/// covers the other half (a real byte-level editor with undo/save), opened
/// as its own modal sheet. This is the read-only companion that sits
/// docked *alongside* `InspectorView`'s structured fields instead, so the
/// same node's raw bytes are visible at a glance without leaving the
/// inspector, always in sync with whatever's currently selected.
///
/// Deliberately read-only: `HexViewerWindow` already owns a real edit
/// buffer, undo stack, and save path for a node's bytes, a second,
/// independent editable buffer for the same bytes here would let the two
/// silently diverge on which edit is "current." "Quick View" means glance
/// reference, not a second editor; the "Open Full Hex Editor…" button
/// below routes to the one real editing surface.
struct HexQuickView: View {
    let bytes: Data
    let onOpenFullEditor: () -> Void

    private static let bytesPerRow = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Hex Quick View", systemImage: "number.square")
                    .font(.headline)
                Spacer()
                Text("\(bytes.count) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if bytes.isEmpty {
                ContentUnavailableView("No Bytes", systemImage: "number.square")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(0..<rowCount, id: \.self) { row in
                            HexQuickRow(rowStart: row * Self.bytesPerRow, bytes: bytes)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            Button("Open Full Hex Editor…", action: onOpenFullEditor)
                .padding(8)
        }
    }

    private var rowCount: Int {
        (bytes.count + Self.bytesPerRow - 1) / Self.bytesPerRow
    }
}

/// Same three-pane layout (offset / hex / ASCII) as `HexViewerWindow`'s own
/// `HexRow`, minus selection and edit state, this one has neither.
private struct HexQuickRow: View {
    let rowStart: Int
    let bytes: Data

    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%06X", rowStart))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(hexString)
                .frame(width: 118, alignment: .leading)
            Text(asciiString)
                .padding(.leading, 8)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var hexString: String {
        var result = ""
        result.reserveCapacity(48)
        for column in 0..<16 {
            let offset = rowStart + column
            guard offset < bytes.count else { break }
            result += String(format: "%02X ", bytes[bytes.startIndex + offset])
        }
        return result
    }

    private var asciiString: String {
        var result = ""
        result.reserveCapacity(16)
        for column in 0..<16 {
            let offset = rowStart + column
            guard offset < bytes.count else { break }
            let value = bytes[bytes.startIndex + offset]
            let scalar = (value >= 0x20 && value < 0x7F) ? Character(UnicodeScalar(value)) : "."
            result.append(scalar)
        }
        return result
    }
}
