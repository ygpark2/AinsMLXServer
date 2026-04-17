import Foundation

private struct ParsedToolCall {
    let name: String
    let arguments: String
}

private func serializeJSONObject(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}

private func normalizeJSONString(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(object),
          let normalized = serializeJSONObject(object) else {
        return nil
    }
    return normalized
}

private func stripCodeFence(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }

    var lines = trimmed.components(separatedBy: .newlines)
    guard !lines.isEmpty else { return trimmed }
    lines.removeFirst()
    if lines.last == "```" {
        lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseScalarValue(_ rawValue: String) -> Any {
    let trimmed = rawValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ","))
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
        let inner = String(trimmed.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
    }
    if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
        return String(trimmed.dropFirst().dropLast())
    }

    switch trimmed.lowercased() {
    case "true":
        return true
    case "false":
        return false
    case "null":
        return NSNull()
    default:
        break
    }

    if let intValue = Int(trimmed) {
        return intValue
    }
    if let doubleValue = Double(trimmed) {
        return doubleValue
    }
    if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
    }

    return trimmed
}

private func parseKeyValueAssignments(from text: String) -> [String: Any] {
    let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:\\.|[^"])*"|'(?:\\.|[^'])*'|\[[\s\S]*?\]|\{[\s\S]*?\}|[^,\n]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return [:]
    }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    var arguments = [String: Any]()
    for match in regex.matches(in: text, options: [], range: fullRange) {
        guard let keyRange = Range(match.range(at: 1), in: text),
              let valueRange = Range(match.range(at: 2), in: text) else {
            continue
        }
        let key = String(text[keyRange])
        let value = String(text[valueRange])
        arguments[key] = parseScalarValue(value)
    }
    return arguments
}

private func parseJSONToolCalls(from text: String, allowedToolNames: Set<String>?) -> [ParsedToolCall] {
    let trimmed = stripCodeFence(from: text)
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        return []
    }

    func parseCall(_ rawCall: Any) -> ParsedToolCall? {
        guard let dictionary = rawCall as? [String: Any] else { return nil }

        let functionObject = dictionary["function"] as? [String: Any]
        let name = (functionObject?["name"] as? String) ?? (dictionary["name"] as? String)
        guard let name, !name.isEmpty else { return nil }
        if let allowedToolNames, !allowedToolNames.contains(name) {
            return nil
        }

        let rawArguments = (functionObject?["arguments"]) ?? dictionary["arguments"] ?? dictionary["parameters"] ?? [:]
        let arguments: String
        if let argumentString = rawArguments as? String {
            arguments = normalizeJSONString(argumentString) ?? argumentString
        } else if let normalized = serializeJSONObject(rawArguments) {
            arguments = normalized
        } else {
            return nil
        }

        return ParsedToolCall(name: name, arguments: arguments)
    }

    if let dictionary = object as? [String: Any] {
        if let rawCalls = dictionary["tool_calls"] as? [Any] {
            return rawCalls.compactMap(parseCall)
        }
        return parseCall(dictionary).map { [$0] } ?? []
    }

    if let array = object as? [Any] {
        return array.compactMap(parseCall)
    }

    return []
}

private func parseXMLToolCalls(from text: String, allowedToolNames: Set<String>?) -> [ParsedToolCall] {
    let scopedText: String
    if let start = text.range(of: "<tool_calls>"),
       let end = text.range(of: "</tool_calls>") {
        scopedText = String(text[start.upperBound..<end.lowerBound])
    } else {
        scopedText = text
    }

    let pattern = #"<([A-Za-z_][A-Za-z0-9_-]*)\b([^>]*)>([\s\S]*?)</\1>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return []
    }

    let fullRange = NSRange(scopedText.startIndex..<scopedText.endIndex, in: scopedText)
    var parsedCalls = [ParsedToolCall]()

    for match in regex.matches(in: scopedText, options: [], range: fullRange) {
        guard let nameRange = Range(match.range(at: 1), in: scopedText),
              let attributesRange = Range(match.range(at: 2), in: scopedText),
              let bodyRange = Range(match.range(at: 3), in: scopedText) else {
            continue
        }

        let name = String(scopedText[nameRange])
        if name == "tool_calls" {
            continue
        }
        if let allowedToolNames, !allowedToolNames.contains(name) {
            continue
        }

        var arguments = parseKeyValueAssignments(from: String(scopedText[attributesRange]))
        let body = String(scopedText[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyAssignments = parseKeyValueAssignments(from: body)
        for (key, value) in bodyAssignments {
            arguments[key] = value
        }

        if arguments.isEmpty, !body.isEmpty {
            arguments[name == "task" ? "prompt" : "input"] = body
        }

        guard !arguments.isEmpty, let argumentsJSON = serializeJSONObject(arguments) else {
            continue
        }
        parsedCalls.append(ParsedToolCall(name: name, arguments: argumentsJSON))
    }

    return parsedCalls
}

private func parseFunctionLikeToolCalls(from text: String, allowedToolNames: Set<String>?) -> [ParsedToolCall] {
    let pattern = #"(?m)^([A-Za-z_][A-Za-z0-9_]*)\(([\s\S]*?)\)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return []
    }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    var parsedCalls = [ParsedToolCall]()

    for match in regex.matches(in: text, options: [], range: fullRange) {
        guard let nameRange = Range(match.range(at: 1), in: text),
              let argsRange = Range(match.range(at: 2), in: text) else {
            continue
        }

        let name = String(text[nameRange])
        if let allowedToolNames, !allowedToolNames.contains(name) {
            continue
        }

        let argsText = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = parseKeyValueAssignments(from: argsText)
        guard !arguments.isEmpty, let argumentsJSON = serializeJSONObject(arguments) else {
            continue
        }

        parsedCalls.append(ParsedToolCall(name: name, arguments: argumentsJSON))
    }

    return parsedCalls
}

func fallbackToolCalls(from output: String, allowedTools: [RawTool]? = nil) -> [OpenAIToolCall] {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let allowedToolNames = allowedTools.map { Set($0.map(\.function.name)) }
    let parsedCalls = parseJSONToolCalls(from: trimmed, allowedToolNames: allowedToolNames)
        + parseXMLToolCalls(from: trimmed, allowedToolNames: allowedToolNames)
        + parseFunctionLikeToolCalls(from: trimmed, allowedToolNames: allowedToolNames)

    guard !parsedCalls.isEmpty else { return [] }

    return parsedCalls.enumerated().map { index, call in
        OpenAIToolCall(
            index: index,
            id: "call_fallback_\(index)_\(UUID().uuidString.lowercased())",
            function: OpenAIFunctionCall(name: call.name, arguments: call.arguments)
        )
    }
}
