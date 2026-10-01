// AssetKit MIT-licensed compatibility patch; see third_party/assetkit/LICENSE.
// Generated from the pinned upstream checkout; includes its regression tests.
const assetKitPatchSha256 =
    '2017e5c7b0de2c767a32666c97d297930491f4d8b9798998e9459974da2de45e';
const assetKitCompatibilityPatch = r'''
--- a/Sources/AssetKit/CAR/BitmapKeys.swift
+++ b/Sources/AssetKit/CAR/BitmapKeys.swift
@@ -3,80 +3,24 @@
 /// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
 /// UIImage(named:) resolution for `.imageset` (and analogous) assets.
 ///
-/// Structure (verified against actool's reference Assets.car, Xcode 26 /
-/// CoreUI 970):
-/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
-/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
-///   block pointer like other trees).
-/// - Each value is a 52-byte descriptor block.
-///
-/// Without this tree present, `UIImage(named:)` returns nil on device even
-/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
-/// resolve correctly. SpringBoard's appicon-render path does NOT depend on
-/// BITMAPKEYS (the home icon still renders via the loose-PNG fallback).
+/// The tree uses inline u32 NameIdentifier keys and 1024-byte BOM pages.
+/// Each descriptor contains a four-u32 header followed by one availability
+/// bitmask per KEYFORMAT attribute. With nine attributes this is 52 bytes.
+/// Missing or inaccurate availability masks can hide physically present
+/// renditions even though assetutil still parses their CSI records.
 enum BitmapKeys {
-    /// The 52-byte descriptor. Layout was derived by diffing actool's outputs
-    /// for `.appiconset` vs `.imageset` (bitmap) vs `.imageset` (vector)
-    /// renditions. The first 7 u32s are header-like; only slot 6 varies
-    /// across asset kinds. The remaining 6 vary by asset kind.
     struct Descriptor {
-        var kind: Kind
-        /// Number of distinct (idiom, subtype) tuples this asset is keyed on.
-        var idiomSubtypeCount: UInt32
-
-        enum Kind {
-            case appIcon
-            /// PNG and JPEG `.imageset` assets — bitmap source.
-            case image
-            /// SVG `.imageset` assets — vector source.
-            case vector
-        }
-
-        /// Slot 6 of the header (the only header u32 that varies by kind).
-        /// `0x04` for bitmap-source assets (PNG, JPG); `0x0e` for vector
-        /// sources (SVG). AppIcon keeps `0x0e` -- we have no reference dump
-        /// for appicon-only catalogs to confirm which value it expects, and
-        /// the current value is verified end-to-end on device.
-        private var assetKindMarker: UInt32 {
-            switch kind {
-            case .image: return 0x04
-            case .vector, .appIcon: return 0x0e
-            }
-        }
+        var masks: [UInt32]
 
         func encode() -> Data {
             var w = ByteWriter()
             w.writeLE(UInt32(1))
             w.writeLE(UInt32(0))
-            w.writeLE(UInt32(0x28))
-            w.writeLE(UInt32(9))
-            w.writeLE(UInt32(0xFFFFFFFF))
-            w.writeLE(UInt32(1))
-            w.writeLE(assetKindMarker)
-            // Variable section. Values come from the actool reference.
-            //   AppIcon  : [u32=2, u16=1, u16=1, u32=7]
-            //   Image    : [u32=1, u16=1, u16=0, u32=1]
-            //   Vector   : [u32=1, u16=1, u16=0, u32=1]   (same shape as Image)
-            // The exact semantics aren't fully reverse-engineered yet, so for
-            // v1 we hardcode the templates per kind and pass through the
-            // discovered (idiom, subtype) count. Field 7 in particular seems
-            // to track that count.
-            w.writeLE(idiomSubtypeCount)
-            switch kind {
-            case .appIcon:
-                w.writeLE(UInt16(1))            // (u16, u16) tuple
-                w.writeLE(UInt16(1))
-                w.writeLE(UInt32(7))
-            case .image, .vector:
-                w.writeLE(UInt16(1))
-                w.writeLE(UInt16(0))
-                w.writeLE(UInt32(1))
+            w.writeLE(UInt32(4 + masks.count * 4))
+            w.writeLE(UInt32(masks.count))
+            for mask in masks {
+                w.writeLE(mask)
             }
-            // Three trailing -1 sentinels.
-            w.writeLE(UInt32(0xFFFFFFFF))
-            w.writeLE(UInt32(0xFFFFFFFF))
-            w.writeLE(UInt32(0xFFFFFFFF))
-            precondition(w.offset == 52, "BITMAPKEYS descriptor must be 52 bytes; got \(w.offset)")
             return w.data
         }
     }
@@ -91,12 +35,9 @@
         }
     }
 
-    /// Derive the BITMAPKEYS descriptor for one asset from its rendition list.
-    /// Returns `nil` for color-only assets, which produce no BITMAPKEYS row.
-    ///
-    /// `renditions` is the per-asset slice -- only the renditions whose
-    /// `name` equals this asset's name. Caller is responsible for the
-    /// grouping; this function does not re-filter.
+    /// Derive availability from the same packed keys emitted to RENDITIONS.
+    /// `renditions` is the caller's per-asset slice. Color-only assets retain
+    /// their existing behavior: no BITMAPKEYS row is emitted for them.
     static func descriptor(forAsset name: String, renditions: [Rendition]) -> Descriptor? {
         let hasBitmapOrPreservedSource = renditions.contains { rendition in
             switch rendition.body {
@@ -106,42 +47,24 @@
         }
         guard hasBitmapOrPreservedSource else { return nil }
 
-        let kind = inferKind(from: renditions)
-
-        // (idiom << 16) | subtype packs each (idiom, subtype) pair into a
-        // single UInt32 for Set uniqueness. Subtype is always 0 today; the
-        // packing exists to match how CoreUI would distinguish (e.g.) iPhone
-        // 60pt vs iPhone 76pt if subtype were ever non-zero.
-        let idiomSubtypes = Set(renditions.map { rendition -> UInt32 in
-            let idiom = UInt32(rendition.idiom.rawValueByte)
-            let subtype: UInt32 = 0
-            return (idiom << 16) | subtype
-        })
-
-        return Descriptor(kind: kind, idiomSubtypeCount: UInt32(idiomSubtypes.count))
-    }
-
-    /// AppIcon takes precedence over Vector takes precedence over Image:
-    /// an .appiconset is a distinct CoreUI category, and a vector source
-    /// outranks plain bitmap because the rasterised PNG fallbacks coexist
-    /// with the preserved SVG body. Mixed PNG/JPEG imagesets fall through
-    /// to `.image`.
-    ///
-    /// The AppIcon arm relies on `ImageRenderer.appIconRenditions` only
-    /// producing `.bitmap(.appIcon)` renditions (PNG-only at that entry
-    /// point). If that invariant slips, an appiconset whose source was
-    /// (say) preserved JPG would be misclassified as `.image` here.
-    private static func inferKind(from renditions: [Rendition]) -> Descriptor.Kind {
-        for rendition in renditions {
-            if case .bitmap(let body) = rendition.body, body.kind == .appIcon {
-                return .appIcon
+        let keys = renditions.map { [UInt8](RenditionKey(rendition: $0).encode()) }
+        let masks = v1KeyFormat.enumerated().map { index, attribute -> UInt32 in
+            switch attribute {
+            // Identity/category tokens are matched by FACETKEYS, not a
+            // 32-value availability mask; their descriptor slots are wildcards.
+            case .identifier, .element, .part: return UInt32.max
+            default: break
             }
+            var mask: UInt32 = 0
+            for key in keys {
+                let value = UInt16(key[index * 2]) | UInt16(key[index * 2 + 1]) << 8
+                // A value outside the bitset cannot be represented narrowly.
+                // Keep it eligible instead of dropping or truncating the bit.
+                guard value < 32 else { return UInt32.max }
+                mask |= UInt32(1) << value
+            }
+            return mask
         }
-        for rendition in renditions {
-            if case .preservedSource(let body) = rendition.body, case .svg = body.format {
-                return .vector
-            }
-        }
-        return .image
+        return Descriptor(masks: masks)
     }
 }
--- /dev/null
+++ b/Sources/AssetKit/CAR/BitmapRowLayout.swift
@@ -0,0 +1,7 @@
+/// Shared row contract for CSI metadata and decompressed BGRA payloads.
+enum BitmapRowLayout {
+    static func bytesPerRow(width: UInt32) -> UInt32 {
+        let exact = width * 4
+        return (exact + 15) & ~15
+    }
+}
--- a/Sources/AssetKit/CAR/MLECBody.swift
+++ b/Sources/AssetKit/CAR/MLECBody.swift
@@ -5,8 +5,8 @@
 /// Layout verified against actool's reference Assets.car:
 ///
 ///   MLEC magic        4 bytes
-///   compressionType   u32  (0 = raw, 3 = LZFSE)
-///   bytesPerPixel     u32  (4 for BGRA8)
+///   bitmap flags      u32  (bit 0 = chunked, bit 1 = opaque)
+///   compressionType   u32  (4 = KCBC/LZFSE)
 ///   chunkCount        u32  (1 or 3)
 ///   then chunkCount * KCBC chunks
 ///
@@ -24,7 +24,22 @@
 /// rather than a correctness requirement: CoreUI accepts both layouts.
 enum MLECBody {
     static func encode(width: UInt32, height: UInt32, pixelsBGRA: [UInt8]) -> Data {
-        let bytesPerRow = Int(width) * 4
+        let sourceBytesPerRow = Int(width) * 4
+        let bytesPerRow = Int(BitmapRowLayout.bytesPerRow(width: width))
+        precondition(pixelsBGRA.count == sourceBytesPerRow * Int(height))
+        // CoreUI consumes the stride declared in TVL 1007, including padding.
+        // Pad each row before chunking so later rows retain their pixel offsets.
+        var storedPixels = pixelsBGRA
+        if bytesPerRow != sourceBytesPerRow {
+            storedPixels = [UInt8](repeating: 0, count: bytesPerRow * Int(height))
+            for row in 0..<Int(height) {
+                let sourceStart = row * sourceBytesPerRow
+                let destinationStart = row * bytesPerRow
+                storedPixels.replaceSubrange(
+                    destinationStart..<(destinationStart + sourceBytesPerRow),
+                    with: pixelsBGRA[sourceStart..<(sourceStart + sourceBytesPerRow)])
+            }
+        }
         let canChunkInThree = height % 3 == 0
         let chunkCount: UInt32 = canChunkInThree ? 3 : 1
         let rowsPerChunk = height / chunkCount
@@ -33,14 +48,18 @@
         for i in 0..<Int(chunkCount) {
             let start = i * Int(rowsPerChunk) * bytesPerRow
             let end = start + Int(rowsPerChunk) * bytesPerRow
-            let slice = Array(pixelsBGRA[start..<end])
+            let slice = Array(storedPixels[start..<end])
             chunks.append((rows: rowsPerChunk, payload: LZFSE.encode(slice)))
         }
 
+        // CoreUI ignores stored alpha when the opaque bit is set. Inspect
+        // source pixels, not padded rows (whose padding is always zero).
+        let isOpaque = stride(from: 3, to: pixelsBGRA.count, by: 4)
+            .allSatisfy { pixelsBGRA[$0] == 255 }
         var w = ByteWriter()
         w.writeFourCC("MLEC")
-        w.writeLE(UInt32(3))                    // compressionType = 3 (LZFSE)
-        w.writeLE(UInt32(4))                    // bytesPerPixel (BGRA8 = 4)
+        w.writeLE(UInt32(isOpaque ? 3 : 1))     // chunked; opaque only when all alpha is 255
+        w.writeLE(UInt32(4))                    // KCBC/LZFSE compression
         w.writeLE(chunkCount)
 
         for chunk in chunks {
--- a/Sources/AssetKit/CAR/TVLEntry.swift
+++ b/Sources/AssetKit/CAR/TVLEntry.swift
@@ -5,8 +5,8 @@
 /// CoreUI consumes a small fixed set of TVL types between the 184-byte CSI
 /// header and the rendition body. Closed enum + exhaustive switch keeps the
 /// type IDs and value layouts in one place; the alignment rule for
-/// `.bytesPerRow` lives inside the enum (callers pass width, encoding
-/// computes the 16-byte-aligned stride).
+/// `.bytesPerRow` is shared with the pixel encoder through BitmapRowLayout
+/// so metadata and decompressed rows cannot disagree.
 ///
 /// Type IDs and value layouts derived from actool's reference Assets.car
 /// (Xcode 26 / CoreUI 970). Without these entries, CoreUI can parse the
@@ -67,9 +67,7 @@
         case .bytesPerRow(let width):
             w.writeLE(UInt32(1007))
             w.writeLE(UInt32(4))
-            let bytesPerRow = width * 4
-            let aligned = (bytesPerRow + 15) & ~15
-            w.writeLE(aligned)
+            w.writeLE(BitmapRowLayout.bytesPerRow(width: width))
         }
     }
 }
--- /dev/null
+++ b/Tests/AssetKitTests/BitmapKeysTests.swift
@@ -0,0 +1,92 @@
+import Foundation
+import Testing
+@testable import AssetKit
+
+@Suite("Bitmap lookup availability")
+struct BitmapKeysTests {
+    // Synthetic 1x1 opaque red PNG. No application assets or Apple binaries.
+    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4I2f0HwAFMgIsjP5jlwAAAABJRU5ErkJggg==")!
+
+    private func u32(_ bytes: [UInt8], _ offset: Int, big: Bool = false) -> UInt32 {
+        let offsets = big ? [3, 2, 1, 0] : [0, 1, 2, 3]
+        return offsets.enumerated().reduce(UInt32(0)) { result, item in
+            result | UInt32(bytes[offset + item.element]) << (item.offset * 8)
+        }
+    }
+
+    // Independently walk the serialized BOM instead of calling Descriptor.encode.
+    private func masks(_ data: Data) throws -> [UInt32: UInt32] {
+        let bytes = [UInt8](data)
+        let index = Int(u32(bytes, 16, big: true))
+        func block(_ id: UInt32) -> [UInt8] {
+            let entry = index + 4 + Int(id) * 8
+            let start = Int(u32(bytes, entry, big: true))
+            let size = Int(u32(bytes, entry + 4, big: true))
+            return Array(bytes[start..<start + size])
+        }
+        var pos = Int(u32(bytes, 24, big: true))
+        let count = Int(u32(bytes, pos, big: true))
+        pos += 4
+        var variables: [String: UInt32] = [:]
+        for _ in 0..<count {
+            let id = u32(bytes, pos, big: true)
+            let size = Int(bytes[pos + 4])
+            variables[String(decoding: bytes[pos + 5..<pos + 5 + size], as: UTF8.self)] = id
+            pos += 5 + size
+        }
+        let keyFormat = block(try #require(variables["KEYFORMAT"]))
+        let tree = block(try #require(variables["BITMAPKEYS"]))
+        let leaf = block(u32(tree, 8, big: true))
+        let descriptor = block(u32(leaf, 12, big: true))
+        let attributes = Int(u32(keyFormat, 8))
+        #expect(u32(descriptor, 12) == UInt32(attributes))
+        #expect(u32(descriptor, 8) == UInt32(4 + attributes * 4))
+        #expect(descriptor.count == 16 + attributes * 4)
+        return Dictionary(uniqueKeysWithValues: (0..<attributes).map {
+            (u32(keyFormat, 12 + $0 * 4), u32(descriptor, 16 + $0 * 4))
+        })
+    }
+
+    private func compile(_ images: [[String: Any]], icon: Bool = false) async throws -> Data {
+        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lookup-\(UUID()).xcassets")
+        let set = root.appendingPathComponent(icon ? "Test.appiconset" : "Test.imageset")
+        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
+        defer { try? FileManager.default.removeItem(at: root) }
+        let info: [String: Any] = ["version": 1, "author": "test"]
+        try JSONSerialization.data(withJSONObject: ["info": info]).write(to: root.appendingPathComponent("Contents.json"))
+        try JSONSerialization.data(withJSONObject: ["info": info, "images": images]).write(to: set.appendingPathComponent("Contents.json"))
+        try png.write(to: set.appendingPathComponent("pixel.png"))
+        return try await XCAssetCompiler(deploymentTarget: "16.0").compile(catalog: root).carData
+    }
+
+    @Test("A single scale advertises only its actual value", arguments: [1, 2, 3])
+    func singleScale(_ scale: Int) async throws {
+        let data = try await compile([["filename": "pixel.png", "idiom": "universal", "scale": "\(scale)x"]])
+        let values = try masks(data)
+        #expect(values[12] == UInt32(1 << scale))
+        #expect(values[15] == 1)
+    }
+
+    @Test("All three scales remain selectable")
+    func allScales() async throws {
+        let data = try await compile((1...3).map { ["filename": "pixel.png", "idiom": "universal", "scale": "\($0)x"] })
+        #expect(try masks(data)[12] == 0x0e)
+    }
+
+    @Test("Device idioms are values, not the count of variants")
+    func deviceIdioms() async throws {
+        let data = try await compile(["iphone", "ipad"].map { ["filename": "pixel.png", "idiom": $0, "scale": "2x"] })
+        #expect(try masks(data)[15] == 0x06)
+    }
+
+    @Test("Appearance mask describes the available variants")
+    func appearances() async throws {
+        let images: [[String: Any]] = [
+            ["filename": "pixel.png", "idiom": "universal", "scale": "2x"],
+            ["filename": "pixel.png", "idiom": "universal", "scale": "2x",
+             "appearances": [["appearance": "luminosity", "value": "dark"]]],
+        ]
+        let data = try await compile(images)
+        #expect(try masks(data)[7] == 3)
+    }
+}
--- /dev/null
+++ b/Tests/AssetKitTests/RowLayoutTests.swift
@@ -0,0 +1,53 @@
+import Foundation
+import Testing
+import CLZFSE
+@testable import AssetKit
+
+@Suite("Serialized row contract")
+struct RowLayoutTests {
+    @Test("Decoded rows match the stride declared in the same CSI record",
+          arguments: [1, 2, 3, 4, 5, 7, 8, 9, 29, 58, 87, 167], [1, 2, 3, 4, 6, 7])
+    func rowContract(width: Int, height: Int) throws {
+        // Different bytes in every row expose missing padding between rows.
+        let pixels = (0..<(width * height * 4)).map { UInt8(($0 * 37 + 11) % 251) }
+        let body = BitmapBody(width: UInt32(width), height: UInt32(height),
+                              pixelsBGRA: pixels, colorSpaceID: 1,
+                              kind: .image, renditionName: "row-contract.png")
+        let bytes = [UInt8](CSIWriter.bitmap(name: "Rows", body: body, scaleFactor: 100))
+        func u32(_ offset: Int) -> Int {
+            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
+        }
+        let bodyOffset = 184 + u32(168)
+        var pos = 184
+        var stride = 0
+        while pos < bodyOffset {
+            if u32(pos) == 1007 { stride = u32(pos + 8) }
+            pos += 8 + u32(pos + 4)
+        }
+        try #require(stride >= width * 4)
+        pos = bodyOffset + 16
+        var row = 0
+        while pos < bytes.count {
+            let rows = u32(pos + 12), size = u32(pos + 16)
+            let payload = Array(bytes[(pos + 20)..<(pos + 20 + size)])
+            var output = [UInt8](repeating: 0xCC, count: stride * rows + 1)
+            let capacity = output.count
+            let decoded = payload.withUnsafeBufferPointer { src in
+                output.withUnsafeMutableBufferPointer { dst in
+                    lzfse_decode_buffer(dst.baseAddress!, capacity, src.baseAddress!, payload.count, nil)
+                }
+            }
+            try #require(decoded == stride * rows,
+                         "width=\(width), height=\(height), declared stride=\(stride), chunk rows=\(rows), decoded=\(decoded)")
+            for chunkRow in 0..<rows {
+                let start = chunkRow * stride
+                #expect(output[(start + width * 4)..<(start + stride)].allSatisfy { $0 == 0 })
+                let originalStart = (row + chunkRow) * width * 4
+                #expect(Array(output[start..<(start + width * 4)]) == Array(pixels[originalStart..<(originalStart + width * 4)]))
+            }
+            row += rows
+            pos += 20 + size
+        }
+        #expect(row == height)
+    }
+}
--- /dev/null
+++ b/Tests/AssetKitTests/BitmapAlphaTests.swift
@@ -0,0 +1,18 @@
+import Foundation
+import Testing
+@testable import AssetKit
+
+@Suite("Bitmap alpha flags")
+struct BitmapAlphaTests {
+    @Test("Opaque metadata follows source alpha, ignoring row padding",
+          arguments: [(1, 1), (3, 1), (4, 1), (7, 1), (1, 3), (7, 3)], [UInt8(0), UInt8(128), UInt8(255)])
+    func alphaFlags(size: (Int, Int), alpha: UInt8) {
+        let (width, height) = size
+        var pixels = [UInt8](repeating: 255, count: width * height * 4)
+        // Put the only transparent pixel last, including in a later chunk.
+        pixels[pixels.count - 1] = alpha
+        let bytes = [UInt8](MLECBody.encode(width: UInt32(width), height: UInt32(height), pixelsBGRA: pixels))
+        #expect(bytes[4] == (alpha == 255 ? 3 : 1))
+        #expect(bytes[8] == 4) // LZFSE remains unchanged.
+    }
+}
''';
