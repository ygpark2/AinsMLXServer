import Compression
import Foundation
import Vapor

enum EmbeddedAssets {
    private struct DecodedPayload {
        let notFoundHTML: String
        let defaultConfigYAML: String
        let files: [String: (type: String, data: Data)]
    }

    private static let payloadFileName = "embedded_assets_payload.zlib"
    private static let decodedPayload: DecodedPayload = loadPayload()

    static let defaultConfigYAML: String = decodedPayload.defaultConfigYAML

    static func serve(_ req: Request) -> Response? {
        let path = req.url.path
        let lookupPath = path == "/" ? "/" : path

        guard let asset = decodedPayload.files[lookupPath] else {
            return nil
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: asset.type)
        return Response(status: .ok, headers: headers, body: .init(data: asset.data))
    }

    static func notFoundResponse() -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .notFound, headers: headers, body: .init(string: decodedPayload.notFoundHTML))
    }

    private static func loadPayload() -> DecodedPayload {
        guard let payloadPath = locatePayloadPath() else {
            fatalError("Missing embedded assets payload file: \(payloadFileName)")
        }

        guard let compressed = try? Data(contentsOf: payloadPath) else {
            fatalError("Failed to read embedded payload file: \(payloadPath.path)")
        }

        guard let payloadData = compressed.zlibDecompressed() else {
            fatalError("Failed to decompress embedded payload")
        }

        guard let raw = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            fatalError("Failed to parse embedded payload JSON")
        }

        func decodeUTF8(_ key: String) -> String {
            guard let b64 = raw[key] as? String,
                  let data = Data(base64Encoded: b64),
                  let text = String(data: data, encoding: .utf8) else {
                fatalError("Invalid payload field: \(key)")
            }
            return text
        }

        let notFoundHTML = decodeUTF8("not_found_html_b64")
        let defaultConfigYAML = decodeUTF8("default_config_yaml_b64")

        var files: [String: (type: String, data: Data)] = [:]
        if let fileEntries = raw["files"] as? [[String: Any]] {
            files.reserveCapacity(fileEntries.count)
            for entry in fileEntries {
                guard let path = entry["path"] as? String,
                      let mime = entry["type"] as? String,
                      let dataB64 = entry["data_b64"] as? String,
                      let data = Data(base64Encoded: dataB64) else {
                    continue
                }
                files[path] = (type: mime, data: data)
            }
        }

        return DecodedPayload(
            notFoundHTML: notFoundHTML,
            defaultConfigYAML: defaultConfigYAML,
            files: files
        )
    }

    private static func locatePayloadPath() -> URL? {
        let fileManager = FileManager.default
        let cwd = fileManager.currentDirectoryPath
        let cwdResources = URL(fileURLWithPath: cwd).appendingPathComponent("Resources/\(payloadFileName)")
        if fileManager.fileExists(atPath: cwdResources.path) {
            return cwdResources
        }

        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let exeDir = exeURL.deletingLastPathComponent()
        let exeResources = exeDir.appendingPathComponent("Resources/\(payloadFileName)")
        if fileManager.fileExists(atPath: exeResources.path) {
            return exeResources
        }

        let exeSibling = exeDir.appendingPathComponent(payloadFileName)
        if fileManager.fileExists(atPath: exeSibling.path) {
            return exeSibling
        }

        return nil
    }
}

private extension Data {
    func zlibDecompressed(initialCapacity: Int = 65536) -> Data? {
        if self.isEmpty { return Data() }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!,
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        return self.withUnsafeBytes { (srcRawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcRawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }

            var dst = Data()
            dst.reserveCapacity(initialCapacity)

            stream.src_ptr = srcBase
            stream.src_size = self.count

            let dstBufferSize = 64 * 1024
            let dstPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
            defer { dstPointer.deallocate() }

            repeat {
                stream.dst_ptr = dstPointer
                stream.dst_size = dstBufferSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                if status == COMPRESSION_STATUS_ERROR {
                    return nil
                }

                let produced = dstBufferSize - stream.dst_size
                if produced > 0 {
                    dst.append(dstPointer, count: produced)
                }
            } while status == COMPRESSION_STATUS_OK

            return status == COMPRESSION_STATUS_END ? dst : nil
        }
    }
}
