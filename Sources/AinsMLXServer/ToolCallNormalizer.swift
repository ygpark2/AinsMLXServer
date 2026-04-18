import Foundation

struct ToolSchema {
    let name: String
    let required: Set<String>
    let properties: [String: APIJSONValue]
}

struct ToolNormalizationContext {
    let prefersBackgroundTasks: Bool
}

func toolNormalizationContext(from messages: [ChatMessage]) -> ToolNormalizationContext {
    let userText = messages
        .filter { $0.normalizedRole == "user" }
        .map(\.textForModel)
        .joined(separator: "\n")
        .lowercased()

    let prefersBackgroundTasks =
        userText.contains("[search-mode]") ||
        userText.contains("launch multiple background agents") ||
        userText.contains("in parallel")

    return ToolNormalizationContext(prefersBackgroundTasks: prefersBackgroundTasks)
}

func toolSchemas(from tools: [RawTool]?) -> [String: ToolSchema] {
    guard let tools else { return [:] }

    return Dictionary(uniqueKeysWithValues: tools.map { tool in
        let parameterObject = tool.function.parameters?.objectValue ?? [:]
        let required = Set(parameterObject["required"]?.stringArrayValue ?? [])
        let properties = parameterObject["properties"]?.objectValue ?? [:]
        return (
            tool.function.name,
            ToolSchema(
                name: tool.function.name,
                required: required,
                properties: properties
            )
        )
    })
}

private func parseJSONObject(from text: String) -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return [:]
    }
    return dictionary
}

private func serializeJSONObject(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

private func applyAlias(into arguments: inout [String: Any], canonicalKey: String, aliases: [String]) {
    if arguments[canonicalKey] != nil {
        return
    }

    for alias in aliases {
        if let value = arguments.removeValue(forKey: alias) {
            arguments[canonicalKey] = value
            return
        }
    }
}

private func heuristicDefaultValue(for key: String, toolName: String, arguments: [String: Any]) -> Any? {
    switch (toolName, key) {
    case ("task", "run_in_background"):
        if let subagentType = arguments["subagent_type"] as? String {
            let lowered = subagentType.lowercased()
            if lowered.contains("explore") || lowered.contains("librarian") {
                return true
            }
        }
        return false
    case ("read", "filePath"):
        if let path = arguments["path"] ?? arguments["file_path"] ?? arguments["filepath"] ?? arguments["pathname"] ?? arguments["file"] {
            return path
        }
        if let input = arguments["input"] as? String, !input.isEmpty {
            return input
        }
        return nil
    default:
        return nil
    }
}

private func applySchemaDefaults(into arguments: inout [String: Any], schema: ToolSchema) {
    for (key, property) in schema.properties {
        guard arguments[key] == nil else { continue }
        if let defaultValue = property.objectValue?["default"]?.foundationValue {
            arguments[key] = defaultValue
        }
    }

    for key in schema.required where arguments[key] == nil {
        if let defaultValue = heuristicDefaultValue(for: key, toolName: schema.name, arguments: arguments) {
            arguments[key] = defaultValue
        }
    }
}

private func normalizeArguments(
    _ rawArguments: String,
    for schema: ToolSchema?,
    context: ToolNormalizationContext?
) -> String {
    var arguments = parseJSONObject(from: rawArguments)
    guard !arguments.isEmpty || schema != nil else {
        return rawArguments
    }

    if let schema {
        switch schema.name {
        case "read":
            applyAlias(into: &arguments, canonicalKey: "filePath", aliases: ["path", "file_path", "filepath", "pathname", "file"])
        case "task":
            applyAlias(into: &arguments, canonicalKey: "run_in_background", aliases: ["runInBackground"])
            if context?.prefersBackgroundTasks == true {
                arguments["run_in_background"] = true
            }
        default:
            break
        }

        applySchemaDefaults(into: &arguments, schema: schema)
    }

    return serializeJSONObject(arguments)
}

func normalizeToolCalls(
    _ toolCalls: [OpenAIToolCall],
    allowedTools: [RawTool]?,
    context: ToolNormalizationContext? = nil
) -> [OpenAIToolCall] {
    guard !toolCalls.isEmpty else { return toolCalls }

    let schemas = toolSchemas(from: allowedTools)
    return toolCalls.map { toolCall in
        let schema = schemas[toolCall.function.name]
        let normalizedArguments = normalizeArguments(toolCall.function.arguments, for: schema, context: context)
        guard normalizedArguments != toolCall.function.arguments else {
            return toolCall
        }

        return OpenAIToolCall(
            index: toolCall.index,
            id: toolCall.id,
            type: toolCall.type,
            function: OpenAIFunctionCall(
                name: toolCall.function.name,
                arguments: normalizedArguments
            )
        )
    }
}

func validateToolCalls(_ toolCalls: [OpenAIToolCall], allowedTools: [RawTool]?) -> [String] {
    guard !toolCalls.isEmpty else { return [] }

    let schemas = toolSchemas(from: allowedTools)
    var errors = [String]()

    for toolCall in toolCalls {
        guard let schema = schemas[toolCall.function.name] else { continue }
        let arguments = parseJSONObject(from: toolCall.function.arguments)

        for key in schema.required {
            let value = arguments[key]
            let missing: Bool

            switch value {
            case nil:
                missing = true
            case let string as String:
                missing = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case _ as NSNull:
                missing = true
            default:
                missing = false
            }

            if missing {
                errors.append("\(toolCall.function.name).\(key) is required")
            }
        }
    }

    return errors
}

struct ToolCallValidationResult {
    let valid: [OpenAIToolCall]
    let invalid: [OpenAIToolCall]
    let errors: [String]
}

func partitionToolCalls(_ toolCalls: [OpenAIToolCall], allowedTools: [RawTool]?) -> ToolCallValidationResult {
    guard !toolCalls.isEmpty else {
        return ToolCallValidationResult(valid: [], invalid: [], errors: [])
    }

    let schemas = toolSchemas(from: allowedTools)
    var valid = [OpenAIToolCall]()
    var invalid = [OpenAIToolCall]()
    var errors = [String]()

    for toolCall in toolCalls {
        guard let schema = schemas[toolCall.function.name] else {
            valid.append(toolCall)
            continue
        }

        let arguments = parseJSONObject(from: toolCall.function.arguments)
        var toolErrors = [String]()

        for key in schema.required {
            let value = arguments[key]
            let missing: Bool

            switch value {
            case nil:
                missing = true
            case let string as String:
                missing = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case _ as NSNull:
                missing = true
            default:
                missing = false
            }

            if missing {
                toolErrors.append("\(toolCall.function.name).\(key) is required")
            }
        }

        if toolErrors.isEmpty {
            valid.append(toolCall)
        } else {
            invalid.append(toolCall)
            errors.append(contentsOf: toolErrors)
        }
    }

    return ToolCallValidationResult(valid: valid, invalid: invalid, errors: errors)
}
