import SwiftUI

/// "Batch Editing, Scripting": a small, ordered list of transform
/// operations the user builds up and runs against every currently-picked
/// object in one pass, see `LevelViewerRenderer.BatchScriptOperation`'s
/// own doc comment for why this is a fixed set of operation kinds rather
/// than a general-purpose scripting language.
struct BatchScriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pickedCount: Int
    let onApply: ([LevelViewerRenderer.BatchScriptOperation]) -> Void

    private enum OperationKind: String, CaseIterable, Identifiable {
        case translate = "Move"
        case rotateY = "Rotate (Y)"
        case scaleUniform = "Scale"
        var id: String { rawValue }
    }

    private struct Step: Identifiable {
        let id = UUID()
        var kind: OperationKind = .translate
        var x: String = "0"
        var y: String = "0"
        var z: String = "0"
        var degrees: String = "0"
        var factor: String = "1"
    }

    @State private var steps: [Step] = [Step()]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Batch Script").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Runs each step below, in order, against every one of the \(pickedCount) picked object(s), one Undo step for the whole run.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($steps) { $step in
                    HStack {
                        Picker("", selection: $step.kind) {
                            ForEach(OperationKind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)

                        switch step.kind {
                        case .translate:
                            TextField("X", text: $step.x).frame(width: 56)
                            TextField("Y", text: $step.y).frame(width: 56)
                            TextField("Z", text: $step.z).frame(width: 56)
                        case .rotateY:
                            TextField("Degrees", text: $step.degrees).frame(width: 70)
                            Text("°").foregroundStyle(.secondary)
                        case .scaleUniform:
                            TextField("Factor", text: $step.factor).frame(width: 70)
                            Text("×").foregroundStyle(.secondary)
                        }

                        Spacer()
                        Button {
                            steps.removeAll { $0.id == step.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(steps.count <= 1)
                        .accessibilityLabel("Remove Step")
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 260)

            Button {
                steps.append(Step())
            } label: {
                Label("Add Step", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)

            HStack {
                Spacer()
                Button("Apply to \(pickedCount) Object\(pickedCount == 1 ? "" : "s")") {
                    onApply(steps.compactMap(operation(from:)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pickedCount == 0 || steps.compactMap(operation(from:)).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 340)
    }

    private func operation(from step: Step) -> LevelViewerRenderer.BatchScriptOperation? {
        switch step.kind {
        case .translate:
            guard let x = Float(step.x), let y = Float(step.y), let z = Float(step.z) else { return nil }
            guard x != 0 || y != 0 || z != 0 else { return nil }
            return .translate(SIMD3(x, y, z))
        case .rotateY:
            guard let degrees = Float(step.degrees), degrees != 0 else { return nil }
            return .rotateY(degrees: degrees)
        case .scaleUniform:
            guard let factor = Float(step.factor), factor != 1 else { return nil }
            return .scaleUniform(factor: factor)
        }
    }
}
