# Zig MCP Server ("bruce")

MCP Stdio Server providing Zig 0.16 tools and resources for AI coding assistants.

## Quick Test Commands

To test if the MCP server is working:

```bash
# Test initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test tools/list
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce

# Test zig_version tool
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_version","arguments":{}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce
```

## Workflow for Adding/Fixing Resources

### Step 1: Edit the source

Edit `src/main.zig`:
1. **Add resource URI** to `buildResourcesListResponse` (around line 174)
2. **Add content** to `getResourceContent` function (around line 248)

### Step 2: Build

```bash
zig build
```

### Step 3: Test

```bash
# List resources
echo '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' | ./zig-out/bin/bruce

# Read specific resource
echo '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"zig://patterns/json"}}' | ./zig-out/bin/bruce
```

### Step 4: Commit

```bash
git add src/main.zig && git commit -m "Description of changes"
```

## Running

```bash
./zig-out/bin/bruce
```

## Adding/Fixing Resources

Resources are defined in `src/main.zig`:

1. **Add resource URI** to `buildResourcesListResponse` (around line 174)
2. **Add content** to `getResourceContent` function (around line 248)

### Example: Adding a new resource

```zig
// 1. Add to resources/list response (line ~174):
try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/myset\",\"name\":\"My Patterns\",\"description\":\"My custom patterns\",\"mimeType\":\"text/zig\"},");

// 2. Add content handler in getResourceContent (line ~248):
} else if (std.mem.eql(u8, uri, "zig://patterns/myset")) {
    return 
    \\// My patterns content here
    \\
    ;
}
```

### Testing

```bash
# List resources
echo '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' | ./zig-out/bin/bruce

# Read specific resource
echo '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"zig://patterns/json"}}' | ./zig-out/bin/bruce
```

### Building

```bash
zig build
```

## Adding/Fixing Tools

Tools are defined in `handleToolsCall` function. Search for `executeTool` to see implementation.
