import base64
import json
import mimetypes
import os
import textwrap
import zlib


def normalize_url_path(public_dir: str, file_path: str) -> str:
    rel_path = os.path.relpath(file_path, public_dir)
    url_path = "/" + rel_path.replace(os.sep, "/")
    if url_path == "/index.html":
        return "/"
    return url_path


def read_text_if_exists(path: str, fallback: str = "") -> str:
    if not os.path.exists(path):
        return fallback
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def collect_assets(public_dir: str) -> list[dict[str, str]]:
    assets: list[dict[str, str]] = []
    if not os.path.exists(public_dir):
        return assets

    for root, _, files in os.walk(public_dir):
        for file_name in files:
            abs_path = os.path.join(root, file_name)
            url_path = normalize_url_path(public_dir, abs_path)
            mime_type = mimetypes.guess_type(abs_path)[0] or "application/octet-stream"
            with open(abs_path, "rb") as f:
                data_b64 = base64.b64encode(f.read()).decode("ascii")
            assets.append({"path": url_path, "type": mime_type, "data_b64": data_b64})

    assets.sort(key=lambda x: x["path"])
    return assets


def build_payload(public_dir: str) -> tuple[bytes, int]:
    not_found_html = read_text_if_exists(
        "Resources/not_found.html",
        fallback=textwrap.dedent(
            """\
            <!doctype html>
            <html lang="en">
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>404 - Not Found</title>
            </head>
            <body>
                <h1>404 - Not Found</h1>
                <p>The page you requested does not exist.</p>
            </body>
            </html>
            """
        ).strip()
    )

    default_config_yaml = read_text_if_exists("config.yaml", fallback="")

    payload = {
        "not_found_html_b64": base64.b64encode(not_found_html.encode("utf-8")).decode("ascii"),
        "default_config_yaml_b64": base64.b64encode(default_config_yaml.encode("utf-8")).decode("ascii"),
        "files": collect_assets(public_dir),
    }

    payload_json = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    compressed = zlib.compress(payload_json, level=9)
    return compressed, len(payload["files"])


def generate_swift_assets(public_dir: str, output_file: str, payload_binary_file: str) -> None:
    compressed_payload, file_count = build_payload(public_dir)
    payload_file_name = os.path.basename(payload_binary_file)

    swift_content = f'''import Compression
import Foundation
import Vapor

enum EmbeddedAssets {{
    private struct DecodedPayload {{
        let notFoundHTML: String
        let defaultConfigYAML: String
        let files: [String: (type: String, data: Data)]
    }}

    private static let payloadFileName = "{payload_file_name}"
    private static let decodedPayload: DecodedPayload = loadPayload()

    static let defaultConfigYAML: String = decodedPayload.defaultConfigYAML

    static func serve(_ req: Request) -> Response? {{
        let path = req.url.path
        let lookupPath = path == "/" ? "/" : path

        guard let asset = decodedPayload.files[lookupPath] else {{
            return nil
        }}

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: asset.type)
        return Response(status: .ok, headers: headers, body: .init(data: asset.data))
    }}

    static func notFoundResponse() -> Response {{
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .notFound, headers: headers, body: .init(string: decodedPayload.notFoundHTML))
    }}

    private static func loadPayload() -> DecodedPayload {{
        guard let payloadPath = locatePayloadPath() else {{
            fatalError("Missing embedded assets payload file: \\(payloadFileName)")
        }}

        guard let compressed = try? Data(contentsOf: payloadPath) else {{
            fatalError("Failed to read embedded payload file: \\(payloadPath.path)")
        }}

        guard let payloadData = compressed.zlibDecompressed() else {{
            fatalError("Failed to decompress embedded payload")
        }}

        guard let raw = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {{
            fatalError("Failed to parse embedded payload JSON")
        }}

        func decodeUTF8(_ key: String) -> String {{
            guard let b64 = raw[key] as? String,
                  let data = Data(base64Encoded: b64),
                  let text = String(data: data, encoding: .utf8) else {{
                fatalError("Invalid payload field: \\(key)")
            }}
            return text
        }}

        let notFoundHTML = decodeUTF8("not_found_html_b64")
        let defaultConfigYAML = decodeUTF8("default_config_yaml_b64")

        var files: [String: (type: String, data: Data)] = [:]
        if let fileEntries = raw["files"] as? [[String: Any]] {{
            files.reserveCapacity(fileEntries.count)
            for entry in fileEntries {{
                guard let path = entry["path"] as? String,
                      let mime = entry["type"] as? String,
                      let dataB64 = entry["data_b64"] as? String,
                      let data = Data(base64Encoded: dataB64) else {{
                    continue
                }}
                files[path] = (type: mime, data: data)
            }}
        }}

        return DecodedPayload(
            notFoundHTML: notFoundHTML,
            defaultConfigYAML: defaultConfigYAML,
            files: files
        )
    }}

    private static func locatePayloadPath() -> URL? {{
        let fileManager = FileManager.default
        let cwd = fileManager.currentDirectoryPath
        let cwdResources = URL(fileURLWithPath: cwd).appendingPathComponent("Resources/\\(payloadFileName)")
        if fileManager.fileExists(atPath: cwdResources.path) {{
            return cwdResources
        }}

        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let exeDir = exeURL.deletingLastPathComponent()
        let exeResources = exeDir.appendingPathComponent("Resources/\\(payloadFileName)")
        if fileManager.fileExists(atPath: exeResources.path) {{
            return exeResources
        }}

        let exeSibling = exeDir.appendingPathComponent(payloadFileName)
        if fileManager.fileExists(atPath: exeSibling.path) {{
            return exeSibling
        }}

        return nil
    }}
}}

private extension Data {{
    func zlibDecompressed(initialCapacity: Int = 65536) -> Data? {{
        if self.isEmpty {{ return Data() }}

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!,
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {{
            return nil
        }}
        defer {{ compression_stream_destroy(&stream) }}

        return self.withUnsafeBytes {{ (srcRawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcRawBuffer.bindMemory(to: UInt8.self).baseAddress else {{
                return nil
            }}

            var dst = Data()
            dst.reserveCapacity(initialCapacity)

            stream.src_ptr = srcBase
            stream.src_size = self.count

            let dstBufferSize = 64 * 1024
            let dstPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
            defer {{ dstPointer.deallocate() }}

            repeat {{
                stream.dst_ptr = dstPointer
                stream.dst_size = dstBufferSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                if status == COMPRESSION_STATUS_ERROR {{
                    return nil
                }}

                let produced = dstBufferSize - stream.dst_size
                if produced > 0 {{
                    dst.append(dstPointer, count: produced)
                }}
            }} while status == COMPRESSION_STATUS_OK

            return status == COMPRESSION_STATUS_END ? dst : nil
        }}
    }}
}}
'''

    existing = None
    if os.path.exists(output_file):
        with open(output_file, "r", encoding="utf-8") as f:
            existing = f.read()

    payload_existing = None
    if os.path.exists(payload_binary_file):
        with open(payload_binary_file, "rb") as f:
            payload_existing = f.read()

    if existing == swift_content and payload_existing == compressed_payload:
        print(f"✅ Embedded assets unchanged: {output_file}, {payload_binary_file} ({file_count} files)")
        return

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(swift_content)
    with open(payload_binary_file, "wb") as f:
        f.write(compressed_payload)

    print(f"✅ Embedded assets files generated: {output_file}, {payload_binary_file} ({file_count} files)")


if __name__ == "__main__":
    generate_swift_assets(
        "Public",
        "Sources/AinsMLXServer/EmbeddedAssets.swift",
        "Resources/embedded_assets_payload.zlib"
    )
