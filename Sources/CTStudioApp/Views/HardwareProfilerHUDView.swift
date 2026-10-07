import SwiftUI

/// "Target Hardware Performance Profiler" (roadmap 9.4): a real-time HUD
/// showing this render's actual triangle count, draw call count, and GPU
/// memory footprint against the real, well-documented memory capacities
/// PS2 and the original Xbox actually shipped with.
///
/// Deliberately doesn't show an estimated frame rate or a "polygons/sec"
/// budget: the PS2-era marketing figures for that (Sony's own "66 million
/// polygons/sec," etc.) are theoretical peaks under ideal conditions
/// (unlit, untextured, zero overdraw) no shipping game ever hit, and this
/// codebase has no verified per-game figure to compare against instead , 
/// presenting a specific number here would be dressing up a disputed
/// marketing claim as decoded fact, the same discipline
/// `ModelViewerRenderer.color(forSurfaceID:)`/`GameRegion`/every other
/// "real vs. guessed" boundary in this codebase already holds to. What's
/// actually verifiable and shown instead: real counts against real,
/// undisputed VRAM capacities.
struct HardwareProfilerHUDView: View {
    let triangleCount: Int
    let drawCallCount: Int
    let gpuMemoryBytes: Int

    /// PS2 Graphics Synthesizer: 4MB of embedded DRAM, shared by the frame
    /// buffer, Z-buffer, and every currently-resident texture, one of the
    /// most consistently documented PS2 hardware facts there is.
    private static let ps2GSVRAMBytes = 4 * 1024 * 1024
    /// Original Xbox (2001): 64MB unified RAM, shared between CPU and GPU
    ///, equally well documented.
    private static let xboxUnifiedRAMBytes = 64 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hardware Profiler", systemImage: "speedometer")
                .font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 4) {
                statRow("Triangles", "\(triangleCount)")
                statRow("Draw Calls", "\(drawCallCount)")
                statRow("GPU Memory", ByteCountFormatter.string(fromByteCount: Int64(gpuMemoryBytes), countStyle: .memory))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                budgetBar(label: "PS2 GS VRAM (4 MB)", used: gpuMemoryBytes, budget: Self.ps2GSVRAMBytes)
                budgetBar(label: "Xbox Unified RAM (64 MB)", used: gpuMemoryBytes, budget: Self.xboxUnifiedRAMBytes)
            }

            Text("GPU memory vs. each console's real, documented capacity. Not a guessed polygon-throughput budget, since no verified per-game figure for that exists in this build's reference material.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().bold()
        }
        .font(.caption)
    }

    private func budgetBar(label: String, used: Int, budget: Int) -> some View {
        let fraction = min(1.0, Double(used) / Double(budget))
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fraction * 100))%").font(.caption2).monospacedDigit()
            }
            ProgressView(value: fraction)
                .tint(fraction > 0.9 ? .red : (fraction > 0.6 ? .orange : .green))
        }
    }
}
