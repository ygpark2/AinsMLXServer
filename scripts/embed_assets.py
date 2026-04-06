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
    static let notFoundHTML = \"\"\"
<!doctype html>
<html lang=\"en\">
<head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <title>404 - Not Found</title>
    <style>
        :root { color-scheme: light dark; }
        body {
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;
            background: linear-gradient(135deg, #f7f7f7 0%, #ededed 100%);
            color: #111;
        }
        .card {
            max-width: 520px;
            padding: 32px 28px;
            border: 1px solid rgba(0, 0, 0, 0.08);
            border-radius: 18px;
            background: rgba(255, 255, 255, 0.9);
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.08);
        }
        .code {
            font-size: 56px;
            font-weight: 800;
            letter-spacing: -0.04em;
            line-height: 1;
            margin: 0 0 12px;
        }
        h1 {
            font-size: 24px;
            margin: 0 0 10px;
        }
        p {
            margin: 0;
            line-height: 1.6;
            color: rgba(17, 17, 17, 0.75);
        }
    </style>
</head>
<body>
    <main class=\"card\">
        <div class=\"code\">404</div>
        <h1>Page not found</h1>
        <p>The page you requested does not exist.</p>
    </main>
</body>
</html>
\"\"\"

    static let defaultConfigYAML = \"\"\"
"""
    # Embed config.yaml
    if os.path.exists("config.yaml"):
        with open("config.yaml", "r") as f:
            swift_content += f.read()
    
    swift_content += """\"\"\"

    static let files: [String: (type: String, data: Data)] = """
    if assets:
        swift_content += "[\n"
        for url, mime, data in assets:
            swift_content += f'        "{url}": ("{mime}", Data(base64Encoded: "{data}")!),\n'
        swift_content += """    ]
"""
    else:
        swift_content += """[:]
"""

    swift_content += """
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

    static func notFoundResponse() -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .notFound, headers: headers, body: .init(string: notFoundHTML))
    }
}
"""
    existing = None
    if os.path.exists(output_file):
        with open(output_file, "r") as f:
            existing = f.read()

    if existing == swift_content:
        print(f"✅ Embedded assets unchanged: {output_file} ({len(assets)} files)")
        return

    with open(output_file, "w") as f:
        f.write(swift_content)
    print(f"✅ Embedded assets file generated: {output_file} ({len(assets)} files)")

if __name__ == "__main__":
    generate_swift_assets("Public", "Sources/AinsMLXServer/EmbeddedAssets.swift")
