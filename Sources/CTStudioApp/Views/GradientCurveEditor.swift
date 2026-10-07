import SwiftUI

/// "Particle Curve Graph Editor" (roadmap 10.1): a real, direct-manipulation
/// editor for one of `ParticleSystemDefinition`'s real 8-entry gradient
/// curves (`alphaGradientTime`/`Value`, `sizeWidthTime`/`Value`,
/// `sizeHeightTime`/`Value`, `rotationTime`/`Value`,
/// `collisionTime`/`Value`, every one a real, confirmed field name from
/// this codebase's own decoded model, not invented). Time is always 0...1
/// (the real on-disk convention, per `ParticleData.cs`); drag a point to
/// change both its time (X) and value (Y) at once.
///
/// `fixedRange` is used when this codebase has a *confirmed* real value
/// range for the curve (alpha 0–255, rotation's raw 0–65535 encoding);
/// `nil` auto-fits the Y axis to whatever's actually in the data instead
/// of asserting a range this build has no verified source for.
struct GradientCurveEditor: View {
    @Binding var times: [Float]
    @Binding var values: [Float]
    let valueLabel: String
    let lineColor: Color
    var fixedRange: ClosedRange<Float>?
    var valueFormatter: (Float) -> String = { String(format: "%.1f", $0) }

    @State private var draggedIndex: Int?

    private static let graphHeight: CGFloat = 120

    private var valueRange: ClosedRange<Float> {
        if let fixedRange { return fixedRange }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        guard hi > lo else { return (lo - 1)...(lo + 1) }
        let padding = (hi - lo) * 0.15
        return (lo - padding)...(hi + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(valueLabel).font(.caption.bold())
                Spacer()
                if let draggedIndex, times.indices.contains(draggedIndex) {
                    Text("t=\(String(format: "%.2f", times[draggedIndex]))  v=\(valueFormatter(values[draggedIndex]))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    gridLines(in: geo.size)
                    curvePath(in: geo.size).stroke(lineColor, lineWidth: 2)
                    ForEach(times.indices, id: \.self) { index in
                        pointHandle(index: index, in: geo.size)
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separatorColor)))
            }
            .frame(height: Self.graphHeight)
        }
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        let t = CGFloat(times.indices.contains(index) ? times[index] : 0)
        let v = CGFloat(values.indices.contains(index) ? values[index] : 0)
        let span = CGFloat(valueRange.upperBound - valueRange.lowerBound)
        let normalizedV = span > 0 ? (v - CGFloat(valueRange.lowerBound)) / span : 0.5
        return CGPoint(x: min(max(t, 0), 1) * size.width, y: size.height - (min(max(normalizedV, 0), 1) * size.height))
    }

    private func curvePath(in size: CGSize) -> Path {
        var path = Path()
        let sortedIndices = times.indices.sorted { times[$0] < times[$1] }
        guard let first = sortedIndices.first else { return path }
        path.move(to: position(for: first, in: size))
        for index in sortedIndices.dropFirst() {
            path.addLine(to: position(for: index, in: size))
        }
        return path
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            for i in 0...4 {
                let y = size.height * CGFloat(i) / 4
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
    }

    private func pointHandle(index: Int, in size: CGSize) -> some View {
        Circle()
            .fill(lineColor)
            .frame(width: 10, height: 10)
            .position(position(for: index, in: size))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        draggedIndex = index
                        let clampedX = min(max(drag.location.x, 0), size.width)
                        let clampedY = min(max(drag.location.y, 0), size.height)
                        let newTime = size.width > 0 ? Float(clampedX / size.width) : 0
                        let normalizedV = size.height > 0 ? Float(1 - (clampedY / size.height)) : 0.5
                        let newValue = valueRange.lowerBound + normalizedV * (valueRange.upperBound - valueRange.lowerBound)
                        guard times.indices.contains(index), values.indices.contains(index) else { return }
                        times[index] = newTime
                        values[index] = newValue
                    }
                    .onEnded { _ in draggedIndex = nil }
            )
    }
}

/// The `colorGradient` curve's own editor, 8 `(time, R, G, B)` entries
/// (`SIMD4<Float>`, RGB 0–255) rather than parallel time/value arrays, so
/// it needs its own control rather than reusing `GradientCurveEditor`.
struct ColorGradientEditor: View {
    @Binding var colorGradient: [SIMD4<Float>]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.caption.bold())
            gradientBar
            HStack(spacing: 10) {
                ForEach(colorGradient.indices, id: \.self) { index in
                    stopControl(index: index)
                }
            }
        }
    }

    private var gradientBar: some View {
        let sortedIndices = colorGradient.indices.sorted { colorGradient[$0].x < colorGradient[$1].x }
        return LinearGradient(
            stops: sortedIndices.map { index in
                Gradient.Stop(color: color(for: colorGradient[index]), location: CGFloat(min(max(colorGradient[index].x, 0), 1)))
            },
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separatorColor)))
    }

    private func stopControl(index: Int) -> some View {
        VStack(spacing: 2) {
            ColorPicker("", selection: Binding(
                get: { color(for: colorGradient[index]) },
                set: { newColor in
                    let (r, g, b) = components(of: newColor)
                    colorGradient[index].y = r
                    colorGradient[index].z = g
                    colorGradient[index].w = b
                }
            ))
            .labelsHidden()
            Text(String(format: "%.2f", colorGradient[index].x))
                .font(.caption2.monospacedDigit())
        }
    }

    private func color(for entry: SIMD4<Float>) -> Color {
        Color(red: Double(entry.y) / 255, green: Double(entry.z) / 255, blue: Double(entry.w) / 255)
    }

    private func components(of color: Color) -> (Float, Float, Float) {
        let nsColor = (NSColor(color).usingColorSpace(.deviceRGB)) ?? NSColor(color)
        return (Float(nsColor.redComponent * 255), Float(nsColor.greenComponent * 255), Float(nsColor.blueComponent * 255))
    }
}
