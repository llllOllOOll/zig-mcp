# Zig MCP Server ("bruce")

MCP Stdio Server providing Zig 0.16 tools, resources, and prompts for AI coding assistants.

## Features

- **9 Tools**: zig_version, zig_build, zig_run, zig_test, zig_fetch, zig_fmt, zig_patterns, zig_resources, zig_help
- **12 Resources**: patterns (ArrayList, HashMap, JSON, I/O, Allocator, Package, StaticLib, DynamicLib, MultiModule), templates, guidelines
- **5 Prompts**: zig_arraylist, zig_hashmap, zig_json, zig_error_handling, zig_io

## Quick Test Commands

To test if the MCP server is working:

```bash
# Test initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test tools/list
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test resources/list
echo '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test prompts/list
echo '{"jsonrpc":"2.0","id":1,"method":"prompts/list"}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test zig_version tool
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_version","arguments":{}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test zig_patterns tool
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"arraylist"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test resources/read
echo '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"zig://patterns/arraylist"}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test prompts/get
echo '{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"zig_arraylist"}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce
```

## Running

```bash
./zig-out/bin/bruce
```

## MCP Protocol Compliance

This server implements the full MCP protocol with proper JSON-RPC 2.0 responses:

- **initialize**: Returns protocol version, capabilities, and server info
- **tools/list**: Returns 5 tools with input schemas
- **tools/call**: Executes tools and returns results in `result.content` format
- **resources/list**: Returns 8 resources with URIs and MIME types
- **resources/read**: Returns resource content in `result.contents` format
- **prompts/list**: Returns 5 prompts
- **prompts/get**: Returns prompt messages in `result.messages` format
- **Error handling**: Proper JSON-RPC error responses with codes (-32602, -32603, etc.)

## Building

```bash
zig build
```

## Adding/Fixing Tools, Resources, and Prompts

Edit `src/main.zig`:

1. **Tools**: Define in `executeTool` function (line ~1548)
2. **Resources**: Add URI in `buildResourcesListResponse`, content in `getResourceContent` (line ~316)
3. **Prompts**: Add in `buildPromptsListResponse` and content in `getPromptContent`

## Test Results

- 10/10 tests passing
- Compatible with Gemini CLI, OpenCode, and other MCP clients
- Works with Zig 0.16
