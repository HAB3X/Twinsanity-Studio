import Foundation
import CTCore
import CTModels

/// Decodes a `Model` record (`SectionType.model`, rigid multi-submodel
/// geometry), ported from `Twinsanity/Items/Graphics/Model.cs`.
///
/// On disk, each submodel is just a VU microcode blob (`VifCode`); there is no
/// stored vertex buffer. Decoding means running that microcode through
/// ``VIFInterpreter`` and then walking the resulting VU-memory blocks by their
/// recorded write addresses (0x3 = position, 0x4 = UV + packed vertex color +
/// strip-connectivity flag, 0x5 = normal, 0x6 = emissive color).
public enum ModelParser {
    private struct FieldsPresent: OptionSet {
        let rawValue: Int
        static let vertex = FieldsPresent(rawValue: 1 << 0)
        static let uvColor = FieldsPresent(rawValue: 1 << 1)
        static let normals = FieldsPresent(rawValue: 1 << 2)
        static let emitColors = FieldsPresent(rawValue: 1 << 3)
    }

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> MeshAsset {
        let subModelCount = try cursor.readInt32()
        var submeshes: [MeshSubmesh] = []
        submeshes.reserveCapacity(cursor.safeReserveCount(subModelCount, elementSize: 12)) // vertex count + vifCodeLength + unusedBlobLength, minimum

        for _ in 0..<max(0, subModelCount) {
            _ = try cursor.readUInt32() // declared vertex count; the decoded count is authoritative
            let vifCodeLength = Int(try cursor.readInt32())
            let vifCode = try cursor.readBytes(vifCodeLength)
            let unusedBlobLength = Int(try cursor.readInt32())
            _ = try cursor.readBytes(unusedBlobLength)

            let submesh = try decodeSubModel(vifCode: vifCode)
            submeshes.append(submesh)
        }

        return MeshAsset(id: recordID, isSkinned: false, submeshes: submeshes)
    }

    private static func decodeSubModel(vifCode: Data) throws -> MeshSubmesh {
        let interpreter = try VIFInterpreter.interpretCode(vifCode)
        let data = interpreter.getMem()
        let outputAddr = interpreter.getAddressOutput()

        var positions: [VIFVector4] = []
        var uvw: [VIFVector4] = []
        var emitColor: [VIFVector4] = []
        var colors: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = []
        var normals: [VIFVector4] = []
        var connection: [Bool] = []

        var groupIndex = 0
        var i = 0
        while i < data.count {
            guard let headerVec = data[i].first, let header = headerVec else {
                break // malformed stream: header slot never written
            }
            _ = UInt32(header.binaryX) & 0xFF // verts count (informational only; loop uses positional blocks below)

            var fieldsPresent: FieldsPresent = []
            var fields = 0
            if groupIndex < outputAddr.count {
                for addr in outputAddr[groupIndex] {
                    switch addr {
                    case 0x3: fieldsPresent.insert(.vertex); fields += 1
                    case 0x4: fieldsPresent.insert(.uvColor); fields += 1
                    case 0x5: fieldsPresent.insert(.normals); fields += 1
                    case 0x6: fieldsPresent.insert(.emitColors); fields += 1
                    default: break
                    }
                    if i + fields + 2 >= data.count { break }
                }
            }
            groupIndex += 1

            if i + 2 < data.count {
                // Equivalent to `data[i + 2].compactMap { $0 }` but without
                // allocating and immediately discarding a full intermediate
                // array on every group, `data[i + 2]` is always a 1024-slot
                // block (see `VIFInterpreter.vuMem`), and this loop runs once
                // per submodel per group, so that add-up is real across a
                // file with many submodels.
                positions.reserveCapacity(positions.count + data[i + 2].count)
                for optional in data[i + 2] {
                    if let v = optional { positions.append(v) }
                }
            }

            if fieldsPresent.contains(.uvColor), i + 3 < data.count {
                for e in data[i + 3] {
                    guard let e else { continue }
                    let connRaw = (e.binaryW & 0xFF00) >> 8
                    connection.append(connRaw != 128)
                    let r = min(e.binaryX & 0xFF, 255)
                    let g = min(e.binaryY & 0xFF, 255)
                    let b = min(e.binaryZ & 0xFF, 255)
                    let a = (e.binaryW & 0xFF) << 1
                    colors.append((UInt8(r), UInt8(g), UInt8(b), UInt8(min(a, 255))))

                    var uv = VIFVector4(copy: e)
                    uv.binaryX = uv.binaryX & 0xFFFF_FF00
                    uv.binaryY = uv.binaryY & 0xFFFF_FF00
                    uv.binaryZ = uv.binaryZ & 0xFFFF_FF00
                    uv.y = 1 - uv.y
                    uvw.append(uv)
                }
            }

            if fieldsPresent.contains(.normals), i + 4 < data.count {
                for e in data[i + 4] {
                    guard let e else { break }
                    normals.append(VIFVector4(e.x, e.y, e.z, 1.0))
                }
            }

            if fieldsPresent.contains(.emitColors), i + fields + 1 < data.count {
                for e in data[i + fields + 1] {
                    guard let e else { break }
                    var emit = VIFVector4(copy: e)
                    emit.x = Float(emit.binaryX & 0xFF)
                    emit.y = Float(emit.binaryY & 0xFF)
                    emit.z = Float(emit.binaryZ & 0xFF)
                    emit.w = Float(emit.binaryW & 0xFF)
                    emitColor.append(emit)
                }
            }

            i += fields + 2
            trim(&uvw, to: positions.count)
            trim(&emitColor, to: positions.count)
            trim(&normals, to: positions.count, default: VIFVector4(0, 0, 0, 1))
        }

        var vertices: [StaticVertex] = []
        vertices.reserveCapacity(positions.count)
        for idx in 0..<positions.count {
            let color = idx < colors.count ? colors[idx] : (r: UInt8(255), g: UInt8(255), b: UInt8(255), a: UInt8(255))
            let uv = idx < uvw.count ? uvw[idx] : VIFVector4()
            let normal = idx < normals.count ? normals[idx] : VIFVector4(0, 0, 0, 1)
            let emit = idx < emitColor.count ? emitColor[idx] : VIFVector4()
            // "Mesh-local X mirror": ported from `ModelController.
            // LoadMeshData` (`new Vector3(-model.Vertexes[j].X, ...)`,
            // `new Vector3(-model.Vertexes[j].NX, ...)`) -- a *separate*
            // mirror from the placement-level world-space X mirror this
            // codebase already applies (`SceneryModelPlacement.
            // worldTransform`, `ModelViewerRenderer.mirroredWorldPosition`).
            // This one flips each mesh's own local vertex/normal X before
            // any placement transform is applied at all. Symmetric meshes
            // (a square floor tile) look identical either way, which is
            // exactly why this was missed for as long as it was: it's
            // invisible until a genuinely asymmetric mesh (a curved pipe
            // segment, which mirrors into curving the *opposite* direction)
            // is placed next to a neighbor it's supposed to connect to.
            vertices.append(StaticVertex(
                position: SIMD3(-positions[idx].x, positions[idx].y, positions[idx].z),
                normal: SIMD3(-normal.x, normal.y, normal.z),
                uv: SIMD2(uv.x, uv.y),
                color: SIMD4(color.r, color.g, color.b, color.a),
                emissive: SIMD4(UInt8(clamping: Int(emit.x)), UInt8(clamping: Int(emit.y)), UInt8(clamping: Int(emit.z)), UInt8(clamping: Int(emit.w)))
            ))
        }
        let conn = (0..<vertices.count).map { $0 < connection.count ? connection[$0] : false }
        return MeshSubmesh(vertices: vertices, connectivity: conn)
    }

    private static func trim(_ list: inout [VIFVector4], to desiredLength: Int, default defaultValue: VIFVector4 = VIFVector4()) {
        if list.count > desiredLength {
            list.removeLast(list.count - desiredLength)
        }
        while list.count < desiredLength {
            list.append(defaultValue)
        }
    }
}
