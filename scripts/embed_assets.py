import os
import base64
import mimetypes

def generate_swift_assets(public_dir, output_file):
    if not os.path.exists(public_dir):
        print(f"⚠️ {public_dir} not found. Skipping.")
        return

    assets = []
    for root, dirs, files in os.walk(public_dir):
        for file in files:
            path = os.path.join(root, file)
            rel_path = os.path.relpath(path, public_dir)
            # URL paths always use forward slash (/)
            url_path = "/" + rel_path.replace(os.sep, "/")
            if url_path == "/index.html":
                url_path = "/"
            
            with open(path, "rb") as f:
                content = base64.b64encode(f.read()).decode("utf-8")
            
            mime_type = mimetypes.guess_type(path)[0] or "application/octet-stream"
            assets.append((url_path, mime_type, content))

    swift_content = """import Foundation
import Vapor

enum EmbeddedAssets {
    static let defaultConfigYAML = \"\"\"
"""
    # Embed config.yaml
    if os.path.exists("config.yaml"):
        with open("config.yaml", "r") as f:
            swift_content += f.read()
    
    swift_content += """\"\"\"

    static let files: [String: (type: String, data: Data)] = [
"""
    for url, mime, data in assets:
        swift_content += f'        "{url}": ("{mime}", Data(base64Encoded: "{data}")!),\n'
    
    swift_content += """    ]

    static func serve(_ req: Request) -> Response? {
        let path = req.url.path
        // Map / to /index.html
        let lookupPath = path == "/" ? "/" : path
        
        if let asset = files[lookupPath] {
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: asset.type)
            return Response(status: .ok, headers: headers, body: .init(data: asset.data))
        }
        return nil
    }
}
"""
    with open(output_file, "w") as f:
        f.write(swift_content)
    print(f"✅ Embedded assets file generated: {output_file} ({len(assets)} files)")

if __name__ == "__main__":
    generate_swift_assets("Public", "Sources/AinsMLXServer/EmbeddedAssets.swift")
