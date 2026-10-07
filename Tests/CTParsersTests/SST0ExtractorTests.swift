import XCTest
import Foundation
@testable import CTParsers

final class SST0ExtractorTests: XCTestCase {
    
    private let discLevelsRoot = "/Volumes/CRASH/LEVELS"
    
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "\(self.discLevelsRoot)/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(self.discLevelsRoot)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }
    
    // Hex dump function
    func hexDump(_ data: Data, bytesPerLine: Int = 16) {
        let bytes = [UInt8](data)
        for i in stride(from: 0, to: bytes.count, by: bytesPerLine) {
            let chunk = bytes[i..<min(i + bytesPerLine, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { 
                let c = Character(UnicodeScalar($0))
                return c.isASCII && (c == "\n" || c == "\r" || c.isLetter || c.isNumber || c.isPunctuation || c == " ") ? String(c) : "."
            }.joined()
            print(String(format: "%04x: %-48s |%s|", i, hex, ascii))
        }
    }
    
    // Analyze SST0 blob for patterns
    func analyzeSST0Blob(_ blob: Data, fileName: String) {
        print("\n=== Analyzing SST0 blob for \(fileName) ===")
        print("Blob size: \(blob.count) bytes")
        
        // Print first 64 bytes as hex
        print("\nFirst 64 bytes:")
        hexDump(blob.prefix(min(64, blob.count)))
        
        // Look for patterns in 4-byte chunks
        print("\nAnalyzing 4-byte patterns...")
        let bytes = [UInt8](blob)
        var patternCounts: [UInt32: Int] = [:]
        
        for i in stride(from: 0, to: blob.count - 3, by: 4) {
            let pattern = UInt32(bytes[i]) | 
                          UInt32(bytes[i+1]) << 8 | 
                          UInt32(bytes[i+2]) << 16 | 
                          UInt32(bytes[i+3]) << 24
            patternCounts[pattern, default: 0] += 1
        }
        
        // Show top 10 most common patterns
        let topPatterns = patternCounts.sorted { $0.1 > $1.1 }.prefix(10)
        print("Top 10 most common 4-byte patterns:")
        for (pattern, count) in topPatterns {
            print("  0x\(String(format: "%08x", pattern)): \(count) times")
        }
        
        // Look for potential GS PACKET patterns (NCYCLE + ADDR)
        print("\nChecking for GS PACKET-like patterns...")
        var potentialPackets = 0
        var i = 0
        while i < bytes.count - 1 {
            // Look for sequences where first byte is reasonable NCYCLE value (1-50)
            // followed by 3 bytes that could be an address
            if i < bytes.count {
                let ncyle = bytes[i]
                if ncyle > 0 && ncyle < 50 && i + 3 < bytes.count {
                    // This could be a GS PACKET: NCYCLE (1 byte) + ADDR (3 bytes)
                    potentialPackets += 1
                    i += 4  // Skip potential packet
                    continue
                }
            }
            i += 1
        }
        if potentialPackets > 0 {
            print("  Found approximately \(potentialPackets) potential GS packet-like sequences")
        }
        
        // Check if blob might be structured as records
        if blob.count >= 8 {
            print("\nChecking if blob might be record-based...")
            // Try different stride lengths
            for stride in [4, 8, 12, 16, 20, 24, 32, 64] {
                if blob.count % stride == 0 && blob.count / stride >= 2 {
                    let recordCount = blob.count / stride
                    print("  Could be \(recordCount) records of \(stride) bytes each")
                    
                    // Check first few records for similarity
                    if recordCount >= 2 {
                        let firstRecord = Data(bytes[0..<stride])
                        let secondRecord = Data(bytes[stride..<min(stride*2, blob.count)])
                        
                        // Count matching bytes
                        var matches = 0
                        for j in 0..<min(firstRecord.count, secondRecord.count) {
                            if firstRecord[j] == secondRecord[j] {
                                matches += 1
                            }
                        }
                        let matchPercent = Double(matches) / Double(stride) * 100
                        print("    First two records match \(matches)/\(stride) bytes (\(String(format: "%.1f%%", matchPercent)))")
                    }
                }
            }
        }
        
        // Look for zero-terminated strings
        print("\nLooking for zero-terminated strings (min length 4)...")
        var stringsFound: [String] = []
        var currentStringBytes: [UInt8] = []
        
        for byte in bytes {
            if byte == 0 {
                if currentStringBytes.count >= 4 {
                    let str = String(bytes: currentStringBytes, encoding: .ascii) ?? ""
                    if !str.isEmpty && str.rangeOfCharacter(from: .letters) != nil {
                        stringsFound.append(str)
                    }
                }
                currentStringBytes = []
            } else {
                currentStringBytes.append(byte)
            }
        }
        
        if !stringsFound.isEmpty {
            print("Found \(stringsFound.count) potential strings:")
            for (index, str) in stringsFound.enumerated().prefix(10) {
                print("  [\(index)]: \"\(str)\"")
            }
            if stringsFound.count > 10 {
                print("  ... and \(stringsFound.count - 10) more")
            }
        } else {
            print("No null-terminated strings found.")
        }
        
        print("=== End analysis for \(fileName) ===\n")
    }
    
    func testExtractAndAnalyzeSST0Blobs() throws {
        // Test files to analyze
        let testFiles: [(String, String)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", "Airship"),
            ("A/FARM/FARM.GSC", "Farm"), 
            ("A/CASTLE_C/CASTLE_C.GSC", "Castle_C")
        ]
        
        for (filePath, displayName) in testFiles {
            do {
                print("\n\(String(repeating: "=", count: 60))")
                print("Processing \(displayName): \(filePath)")
                print(String(repeating: "=", count: 60))
                
                let decoded = try loadAndDecompressRealGSC(filePath)
                let file = try WOCContainerParser.parse(decoded)
                
                // Find SST0 section
                guard let sst0Section = file.sections.first(where: { $0.tag == "SST0" }) else {
                    print("  No SST0 section found in \(filePath)")
                    continue
                }
                
                print("  Found SST0 section: length = \(sst0Section.length)")
                
                // Parse the footer header to get the blob
                let (firstField, blob, trailer) = try WOCContainerParser.parseFooterHeader(sst0Section.payload)
                print("  Parsed SST0 footer:")
                print("    firstField: 0x\(String(format: "%08x", firstField))")
                print("    blob length: \(blob.count) bytes")
                print("    trailer length: \(trailer.count) bytes")
                
                if !trailer.isEmpty {
                    print("    trailer (hex): ", terminator: "")
                    for byte in trailer {
                        print(String(format: "%02x", byte), terminator: " ")
                    }
                    print()
                    
                    // Check if trailer echoes section length
                    if trailer.count >= 4 {
                        let echoedLength = trailer.suffix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
                        print("    echoed length in trailer: 0x\(String(format: "%08x", echoedLength))")
                        print("    matches section length: \(echoedLength == sst0Section.length)")
                    }
                }
                
                // Analyze the blob
                analyzeSST0Blob(blob, fileName: displayName)
                
            } catch {
                print("  Error processing \(filePath): \(error)")
            }
        }
        
        print("\n=== Analysis complete ===")
    }
}
