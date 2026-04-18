import Testing
@testable import AinsMLXServer

@Test func parsesJSONFallbackToolCall() async throws {
    let tools = [
        RawTool(
            type: "function",
            function: RawFunction(
                name: "task",
                description: "Run a delegated task",
                parameters: nil
            )
        )
    ]

    let output = """
    {
      "tool_calls": [
        {
          "function": {
            "name": "task",
            "arguments": {
              "subagent_type": "explore",
              "run_in_background": true
            }
          }
        }
      ]
    }
    """

    let parsed = fallbackToolCalls(from: output, allowedTools: tools)
    #expect(parsed.count == 1)
    #expect(parsed[0].function.name == "task")
    #expect(parsed[0].function.arguments.contains("\"subagent_type\":\"explore\""))
 }

@Test func parsesXMLFallbackToolCall() async throws {
    let tools = [
        RawTool(
            type: "function",
            function: RawFunction(
                name: "task",
                description: "Run a delegated task",
                parameters: nil
            )
        )
    ]

    let output = """
    <tool_calls>
    <task>
      subagent_type="explore",
      run_in_background=true,
      description="프로젝트 구조 파악",
      prompt="README와 설정 파일을 분석"
    </task>
    </tool_calls>
    """

    let parsed = fallbackToolCalls(from: output, allowedTools: tools)
    #expect(parsed.count == 1)
    #expect(parsed[0].function.name == "task")
    #expect(parsed[0].function.arguments.contains("\"run_in_background\":true"))
}

@Test func parsesFunctionLikeFallbackToolCalls() async throws {
    let tools = [
        RawTool(
            type: "function",
            function: RawFunction(
                name: "task",
                description: "Run a delegated task",
                parameters: nil
            )
        ),
        RawTool(
            type: "function",
            function: RawFunction(
                name: "read_file",
                description: "Read a file",
                parameters: nil
            )
        ),
        RawTool(
            type: "function",
            function: RawFunction(
                name: "list_directory",
                description: "List a directory",
                parameters: nil
            )
        )
    ]

    let output = """
    task(subagent_type="explore", run_in_background=true, description="Project structure", prompt="Analyze README")
    read_file(path="README.md", fallback_to_markdown=true)
    list_directory(path=".")
    """

    let parsed = fallbackToolCalls(from: output, allowedTools: tools)
    #expect(parsed.count == 3)
    #expect(parsed[0].function.name == "task")
    #expect(parsed[0].function.arguments.contains("\"subagent_type\":\"explore\""))
    #expect(parsed[1].function.name == "read_file")
    #expect(parsed[1].function.arguments.contains("\"fallback_to_markdown\":true"))
    #expect(parsed[2].function.name == "list_directory")
    #expect(parsed[2].function.arguments.contains("\"path\":\".\""))
}

@Test func normalizesReadAliasesFromFallbackToolCalls() async throws {
    let tools = [
        RawTool(
            type: "function",
            function: RawFunction(
                name: "read",
                description: "Read a file",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("filePath")]),
                    "properties": .object([
                        "filePath": .object(["type": .string("string")])
                    ])
                ])
            )
        )
    ]

    let output = #"read(path=".opencode")"#
    let parsed = fallbackToolCalls(from: output, allowedTools: tools)
    #expect(parsed.count == 1)
    #expect(parsed[0].function.arguments.contains(#""filePath":".opencode""#))
}

@Test func normalizesTaskRunInBackgroundDefault() async throws {
    let tools = [
        RawTool(
            type: "function",
            function: RawFunction(
                name: "task",
                description: "Run a delegated task",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("subagent_type"), .string("run_in_background")]),
                    "properties": .object([
                        "subagent_type": .object(["type": .string("string")]),
                        "run_in_background": .object(["type": .string("boolean")])
                    ])
                ])
            )
        )
    ]

    let toolCalls = [
        OpenAIToolCall(
            id: "call_test",
            function: OpenAIFunctionCall(
                name: "task",
                arguments: #"{"subagent_type":"explore","prompt":"scan repo"}"#
            )
        )
    ]

    let normalized = normalizeToolCalls(toolCalls, allowedTools: tools)
    #expect(normalized.count == 1)
    #expect(normalized[0].function.arguments.contains(#""run_in_background":true"#))
}
