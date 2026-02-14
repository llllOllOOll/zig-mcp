# Zig MCP Server

MCP Stdio Server providing Zig 0.16 tools, resources, and prompts for AI coding assistants.

## Features

- **9 Tools**: zig_version, zig_build, zig_run, zig_test, zig_fetch, zig_fmt, zig_patterns, zig_resources, zig_help
- **12 Resources**: patterns (ArrayList, HashMap, JSON, I/O, Allocator, Package, StaticLib, DynamicLib, MultiModule), templates, guidelines
- **5 Prompts**: zig_arraylist, zig_hashmap, zig_json, zig_error_handling, zig_io

## Quick Start

```bash
# Build
zig build

# Run
./zig-out/bin/bruce

# Test
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./zig-out/bin/bruce
```

## Usage

```bash
# Get Zig version
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_version","arguments":{}}}' | ./zig-out/bin/bruce

# Get patterns
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"arraylist"}}}' | ./zig-out/bin/bruce

# List resources
echo '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' | ./zig-out/bin/bruce
```
