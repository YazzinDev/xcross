// Source bundled into the CLI so a published xcross installation can build its
// own pinned resource tool without depending on a repository checkout.
const assetKitRevision = 'e763558b55fcbb5a443b1d7b2c6f0972d8bd14f7';
const assetKitPackage =
    // Swift requires the tools-version directive on the first line.
    // ignore: leading_newlines_in_multiline_strings
    '''// swift-tools-version: 6.3
import PackageDescription
let package = Package(
 name: "XcrossAssetCompiler",
 platforms: [.macOS(.v13)],
 products: [.executable(name: "xcross-assets", targets: ["XcrossAssetCompiler"])],
 dependencies: [
  .package(path: "Dependencies/AssetKit"),
  .package(url: "https://github.com/tayloraswift/swift-png", exact: "4.5.1"),
  .package(url: "https://github.com/rarestype/h", exact: "1.0.1")
 ],
 targets: [.executableTarget(name: "XcrossAssetCompiler", dependencies: [.product(name: "AssetKit", package: "AssetKit")])]
)
''';
const assetKitMain = '''
import Foundation
import AssetKit

struct Request: Decodable {
 let catalog: String
 let output: String
 let deploymentTarget: String
 let svgRasterizer: String?
}

// resvg provides a native Windows executable. Files keep large SVG/PNG data
// out of process pipes, while the owned directory isolates every invocation.
struct WindowsSVGRasterizer: SVGRasterizer {
 let executablePath: String
 func rasterize(svgData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data {
  let directory = FileManager.default.temporaryDirectory
   .appendingPathComponent("xcross-svg-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let input = directory.appendingPathComponent("input.svg")
  let output = directory.appendingPathComponent("output.png")
  let log = directory.appendingPathComponent("renderer.log")
  try svgData.write(to: input)
  try Data().write(to: log)
  let diagnostics = try FileHandle(forWritingTo: log)
  defer { try? diagnostics.close() }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executablePath)
  process.arguments = ["--width", String(pixelWidth), "--height", String(pixelHeight), input.path, output.path]
  process.standardOutput = diagnostics
  process.standardError = diagnostics
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
   throw NSError(domain: "xcross-svg", code: Int(process.terminationStatus),
    userInfo: [NSLocalizedDescriptionKey: try String(contentsOf: log, encoding: .utf8)])
  }
  return try Data(contentsOf: output)
 }
}

@main struct Main {
 static func main() async throws {
  guard CommandLine.arguments.count == 2 else {
   throw NSError(domain: "xcross-assets", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Expected a JSON request file"])
  }
  let request = try JSONDecoder().decode(Request.self,
   from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
  let rasterizer: any SVGRasterizer
  #if os(Windows)
  rasterizer = WindowsSVGRasterizer(executablePath: request.svgRasterizer ?? "")
  #else
  rasterizer = RsvgConvertRasterizer(executablePath: request.svgRasterizer ?? "/usr/bin/env")
  #endif
  let result = try await XCAssetCompiler(deploymentTarget: request.deploymentTarget, svgRasterizer: rasterizer)
   .compile(catalog: URL(fileURLWithPath: request.catalog))
  let output = URL(fileURLWithPath: request.output)
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  try result.carData.write(to: output.appendingPathComponent("Assets.car"))
  if let icons = result.appIconBundle {
   for file in icons.looseFiles {
    try file.data.write(to: output.appendingPathComponent(file.name))
   }
   let plist = try PropertyListSerialization.data(fromPropertyList: icons.infoPlistAdditions,
    format: .xml, options: 0)
   try plist.write(to: output.appendingPathComponent("asset-info.plist"))
  }
 }
}
''';

// Retained in compiled CLI binaries as well as the published source package.
const assetKitLicense = '''
MIT License

Copyright (c) 2026 the AssetKit contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Third-party code

This repository vendors Apple's LZFSE reference implementation under
`Sources/CLZFSE/`, distributed under the BSD 3-Clause License. The original
license text and provenance are recorded at `Sources/CLZFSE/LICENSE` and
`Sources/CLZFSE/UPSTREAM.md`.
''';
