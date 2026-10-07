import XCTest
import Foundation
@testable import CTParsers

final class SST0AnalysisTests: XCTestCase {
    
    private let discLevelsRoot = "/Volumes/CRASH/LEVELS"
    
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "\(self.discLevelsRoot)/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(self.discLevelsRoot)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }
    
    // Function to print hex dump of data
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
    
    // Function to analyze SST0 blob for patterns
    func analyzeSST0Blob(_ blob: Data, fileName:String) {
        print("\n=== Analyzing SST0 blob for \(fileName) ===")
        print("Blob size: \(blob.count) bytes")
        
        // Print first 64 bytes as hex
        print("\nFirst 64 bytes:")
        hexDump(blob.prefix(min(64, blob.count)))
        
        // Look for potential patterns
        let bytes = [UInt8](blob)
        
        // Check if it starts with a magic number or version
        if blob.count >= 4 {
            let firstUInt32 = UInt32(littleEndian: 
                UInt32(bytes[0]) | 
                UInt32(bytes[1]) << 8 | 
                UInt32(bytes[2]) << 16 | 
                UInt32(bytes[3]) << 24)
            print("\nFirst 4 bytes as UInt32 (little-endian): 0x\(String(format: "%08x", firstUInt32))")
        }
        
        // Look for repeated patterns (potential command opcodes)
        print("\nChecking for potential 4-byte patterns...")
        var patternCounts: [UInt32: Int] = [:]
        for i in stride(from: 0, to: blob.count - 3, by: 4) {
            let pattern = UInt32(littleEndian: 
                UInt32(bytes[i]) | 
                UInt32(bytes[i+1]) << 8 | 
                UInt32(bytes[i+2]) << 16 | 
                UInt32(bytes[i+3]) << 24)
            patternCounts[pattern, default: 0] += 1
        }
        
        // Show top 5 most common patterns
        let topPatterns = patternCounts.sorted { $0.1 > $1.1 }.prefix(5)
        print("Top 5 most common 4-byte patterns:")
        for (pattern, count) in topPatterns {
            print("  0x\(String(format: "%08x", pattern)): \(count) times")
        }
        
        // Check if the blob looks like it contains text or strings
        let printableCount = bytes.filter { 
            let c = Character(UnicodeScalar($0))
            return c.isASCII && (c.isLetter || c.isNumber || c.isPunctuation || c == " " || c == "\n" || c == "\r")
        }.count
        let printableRatio = Double(printableCount) / Double(blob.count)
        print("\nPrintable ASCII ratio: \(String(format: "%.2f%%", printableRatio * 100))")
        
        // Look for null-terminated strings
        print("\nLooking for null-terminated strings (min length 4)...")
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
        
        // Check if blob might be structured as records
        if blob.count >= 8 {
            print("\nChecking if blob might be record-based...")
            // Try interpreting as array of uint32
            let uint32Count = blob.count / 4
            if uint32Count > 0 {
                var uint32s: [UInt32] = []
                for i in stride(from: 0, to: uint32Count * 4, by: 4) {
                    let val = UInt32(littleEndian: 
                        UInt32(bytes[i]) | 
                        UInt32(bytes[i+1]) << 8 | 
                        UInt32(bytes[i+2]) << 16 | 
                        UInt32(bytes[i+3]) << 24)
                    uint32s.append(val)
                }
                
                // Check if values are small (likely offsets or counts)
                let smallValues = uint32s.filter { $0 < 1000 }.count
                print("  \(smallValues)/\(uint32s.count) uint32 values are < 1000")
                
                // Check if values are within blob size (likely pointers/offsets)
                let validOffsets = uint32s.filter { $0 < UInt32(blob.count) }.count
                print("  \(validOffsets)/\(uint32s.count) uint32 values are valid offsets within blob")
            }
        }
        
        print("=== End analysis for \(fileName) ===\n")
    }
    
    func testAnalyzeSST0BlobsFromMultipleLevels() throws {
        // Test files to analyze - let's start with a few different ones
        let testFiles = [
            "A/AIRSHIP/AIRSHIP.GSC",
            "A/FARM/FARM.GSC", 
            "A/CASTLE_C/CASTLE_C.GSC",
            "A/JUNGLE_A/JUNGLE_A.GSC",
            "A/DROID/DROID.GSC"
        ]
        
        for filePath in testFiles {
            do {
                print("\nProcessing \(filePath)...")
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
                }
                
                // Analyze the blob
                analyzeSST0Blob(blob, fileName: filePath)
                
            } catch {
                print("  Error processing \(filePath): \(error)")
            }
        }
        
        print("\n=== Analysis complete ===")
    }
}
