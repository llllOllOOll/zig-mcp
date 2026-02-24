const std = @import("std");
const Io = std.Io;

// Server state tracking for better protocol compliance
const ServerState = enum {
    uninitialized,
    initializing,
    ready,
};

var server_state: ServerState = .uninitialized;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(Io.File.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(Io.File.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(Io.File.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stderr_writer.writeAll("[bruce] MCP Server starting (Zig 0.16 compatible)\n");
    try stderr_writer.flush();

    while (true) {
        const line = stdin_reader.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) {
                try stderr_writer.writeAll("[bruce] End of stream, shutting down\n");
                try stderr_writer.flush();
                break;
            }
            try stderr_writer.print("[bruce] Error reading line: {}\n", .{err});
            try stderr_writer.flush();
            break;
        };

        if (line.len == 0) continue;

        try stderr_writer.print("[bruce] Received: {s}\n", .{line});
        try stderr_writer.flush();

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            try stderr_writer.print("[bruce] Error parsing JSON: {}\n", .{err});
            try stderr_writer.flush();
            // Send parse error response
            const error_response = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32700,\"message\":\"Parse error\"}}}}", .{});
            defer allocator.free(error_response);
            try stdout_writer.writeAll(error_response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
            continue;
        };
        defer parsed.deinit();

        const value = parsed.value;

        const method = if (value.object.get("method")) |m| m.string else continue;
        const id = value.object.get("id");

        // Check if it's a notification (no id)
        const is_notification = id == null;

        try stderr_writer.print("[bruce] Method: {s}, Is notification: {}\n", .{ method, is_notification });
        try stderr_writer.flush();

        if (std.mem.eql(u8, method, "initialize")) {
            server_state = .initializing;
            const response = try buildInitializeResponse(allocator, id);
            defer allocator.free(response);

            try stderr_writer.print("[bruce] Sending initialize response: {s}\n", .{response});
            try stderr_writer.flush();
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
            try stderr_writer.writeAll("[bruce] Initialize response sent and flushed\n");
            try stderr_writer.flush();
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const response = try buildToolsListResponse(allocator, id);
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const response = try handleToolsCall(init, allocator, id, value.object.get("params"));
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else if (std.mem.eql(u8, method, "resources/list")) {
            const response = try buildResourcesListResponse(allocator, id);
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else if (std.mem.eql(u8, method, "resources/read")) {
            const response = try handleResourcesRead(allocator, id, value.object.get("params"));
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else if (std.mem.eql(u8, method, "prompts/list")) {
            const response = try buildPromptsListResponse(allocator, id);
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else if (std.mem.eql(u8, method, "prompts/get")) {
            const response = try handlePromptsGet(allocator, id, value.object.get("params"));
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else if (std.mem.eql(u8, method, "initialized") or std.mem.eql(u8, method, "notifications/initialized")) {
            // Client confirms initialization - now we can mark as ready
            server_state = .ready;
            try stderr_writer.writeAll("[bruce] Server initialized and ready\n");
            try stderr_writer.flush();
            // Notifications don't need responses
        } else {
            // Check if server is initialized (except for initialize request)
            if (server_state != .ready and !std.mem.eql(u8, method, "initialize")) {
                try stderr_writer.print("[bruce] Server not initialized, rejecting method: {s}\n", .{method});
                try stderr_writer.flush();
                const error_response = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32002,\"message\":\"Server not initialized\"}}}}", .{});
                defer allocator.free(error_response);
                try stdout_writer.writeAll(error_response);
                try stdout_writer.writeAll("\n");
                try stdout_writer.flush();
                continue;
            }
            try stderr_writer.print("Unknown method: {s}\n", .{method});
        }
    }
}

fn buildInitializeResponse(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    try list.appendSlice(allocator, ",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"resources\":{\"listChanged\":true,\"subscribe\":false},\"prompts\":{\"listChanged\":true},\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"bruce\",\"version\":\"0.2.0\"},\"instructions\":\"Zig 0.16 MCP Server with tools (zig_version, zig_build, zig_run, zig_patterns, zig_help), resources (zig://patterns/*, zig://templates/*), and prompts (zig_*). Use zig_patterns for documentation.\"}}");

    return list.toOwnedSlice(allocator);
}

fn buildToolsListResponse(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    try list.appendSlice(allocator, ",\"result\":{\"tools\":[");

    try list.appendSlice(allocator, "{\"name\":\"zig_version\",\"description\":\"Show installed Zig version\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_build\",\"description\":\"Build the Zig project\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_run\",\"description\":\"Run a Zig file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"Path to .zig file to run\"}},\"required\":[\"file\"]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_test\",\"description\":\"Run Zig tests\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_fetch\",\"description\":\"Fetch Zig dependencies\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_fmt\",\"description\":\"Format Zig source files\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to file or directory (default: .)\"}},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_patterns\",\"description\":\"Get Zig 0.16 patterns and examples (ArrayList, HashMap, JSON, I/O, Error Handling, Package, StaticLib, DynamicLib, MultiModule)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Pattern name: arraylist, hashmap, json, io, allocator, error_handling, build_template, zon_template, package, static_lib, dynamic_lib, multimodule, guidelines, or list\"}},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_resources\",\"description\":\"List all available MCP resources (patterns, templates, guidelines)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},");
    try list.appendSlice(allocator, "{\"name\":\"zig_help\",\"description\":\"Show help and bash fallback commands when MCP client fails\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}");

    try list.appendSlice(allocator, "]}}");

    return list.toOwnedSlice(allocator);
}

fn buildResourcesListResponse(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    try list.appendSlice(allocator, ",\"result\":{\"resources\":[");

    try list.appendSlice(allocator, "{\"uri\":\"zig://guidelines/0.16\",\"name\":\"Zig 0.16 Guidelines\",\"description\":\"Complete guide to Zig 0.16 patterns\",\"mimeType\":\"text/markdown\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/arraylist\",\"name\":\"ArrayList Patterns\",\"description\":\"Correct ArrayList usage in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/hashmap\",\"name\":\"HashMap Patterns\",\"description\":\"Correct HashMap/StringHashMap usage in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/io\",\"name\":\"I/O Patterns\",\"description\":\"std.Io, Reader, Writer patterns in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/allocator\",\"name\":\"Allocator Patterns\",\"description\":\"When and how to use allocators in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/json\",\"name\":\"JSON Patterns\",\"description\":\"Parse and stringify JSON in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/package\",\"name\":\"Package ZON Patterns\",\"description\":\"ZON package manifest with enum literals\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/static_lib\",\"name\":\"Static Library Patterns\",\"description\":\"Build static libraries with b.addLibrary\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/dynamic_lib\",\"name\":\"Dynamic Library Patterns\",\"description\":\"Build dynamic libraries with b.addLibrary\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/multimodule\",\"name\":\"Multi-Module Patterns\",\"description\":\"Multiple modules in one project\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/file_io\",\"name\":\"File I/O Patterns\",\"description\":\"File operations + async computation with std.Io\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/time\",\"name\":\"Time APIs\",\"description\":\"Instant, Timer, Clock.now() for timing and timestamps\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/json_complete\",\"name\":\"JSON Complete\",\"description\":\"Full JSON parsing with all options and file I/O\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/threads\",\"name\":\"Threading & Sync\",\"description\":\"std.Io.Mutex, std.Io.Condition, thread spawning\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://templates/build.zig\",\"name\":\"build.zig Template\",\"description\":\"Modern build.zig template for Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://templates/build.zig.zon\",\"name\":\"build.zig.zon Template\",\"description\":\"Package manifest structure for Zig 0.16\",\"mimeType\":\"text/zon\"}");

    try list.appendSlice(allocator, "]}}");

    return list.toOwnedSlice(allocator);
}

fn handleResourcesRead(allocator: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    var uri: ?[]const u8 = null;
    if (params) |p| {
        if (p.object.get("uri")) |u| {
            uri = u.string;
        }
    }

    if (uri) |u| {
        const content = getResourceContent(u);

        // Check if resource not found
        if (std.mem.eql(u8, content, "Unknown resource")) {
            try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"Resource not found: ");
            try list.appendSlice(allocator, u);
            try list.appendSlice(allocator, "\"}");
        } else {
            try list.appendSlice(allocator, ",\"result\":{\"contents\":[{\"uri\":\"");
            try list.appendSlice(allocator, u);
            try list.appendSlice(allocator, "\",\"mimeType\":\"text/plain\",\"text\":\"");

            for (content) |byte| {
                switch (byte) {
                    '"' => try list.appendSlice(allocator, "\\\""),
                    '\\' => try list.appendSlice(allocator, "\\\\"),
                    '\n' => try list.appendSlice(allocator, "\\n"),
                    '\r' => try list.appendSlice(allocator, "\\r"),
                    '\t' => try list.appendSlice(allocator, "\\t"),
                    else => try list.append(allocator, byte),
                }
            }

            try list.appendSlice(allocator, "\"}]}");
        }
    } else {
        try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"Missing uri\"}");
    }

    try list.appendSlice(allocator, "}");

    return list.toOwnedSlice(allocator);
}

fn getResourceContent(uri: []const u8) []const u8 {
    if (std.mem.eql(u8, uri, "zig://guidelines/0.16")) {
        return 
        \\# Zig 0.16 Guidelines
        \\
        \\## ArrayList
        \\```zig
        \\var list: std.ArrayList(u32) = .empty;
        \\try list.append(allocator, item); // COM allocator!
        \\list.deinit(allocator); // COM allocator!
        \\```
        \\
        \\## StringHashMap
        \\```zig
        \\var map: std.StringHashMap(u32) = .empty;
        \\try map.put(allocator, key, value); // COM allocator!
        \\map.deinit(allocator); // COM allocator!
        \\```
        \\
        \\## Arena Allocator (main)
        \\```zig
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\}
        \\```
        \\
        \\## Fonte da verdade: stdlib em /home/seven/zig/lib/std/array_list.zig
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/arraylist")) {
        return 
        \\// ArrayList Patterns in Zig 0.16
        \\
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    const allocator = std.heap.page_allocator;
        \\    
        \\    // ========================================
        \\    // SIMPLEST: .empty (recommended for most cases)
        \\    // Clean syntax, works for any size
        \\    // ========================================
        \\    var list: std.ArrayList(u32) = .empty;
        \\    defer list.deinit(allocator);
        \\    
        \\    // Performance: initCapacity (when size is known)
        \\    // var list = try std.ArrayList(u32).initCapacity(allocator, 100);
        \\    // defer list.deinit(allocator);
        \\    
        \\    // ========================================
        \\    // ADDING ITEMS - ALWAYS pass allocator!
        \\    // ========================================
        \\    
        \\    // Add single items
        \\    try list.append(allocator, 10);
        \\    try list.append(allocator, 20);
        \\    
        \\    // Add multiple items at once
        \\    try list.appendSlice(allocator, &[_]u32{ 30, 40, 50 });
        \\    
        \\    // ========================================
        \\    // ACCESSING ITEMS
        \\    // ========================================
        \\    const first = list.items[0];           // Direct index
        \\    const len = list.items.len;             // Get length
        \\    const last = list.getLast();            // Get last item
        \\    
        \\    // ========================================
        \\    // ITERATING
        \\    // ========================================
        \\    for (list.items) |item| {
        \\        std.debug.print("{d}\\n", .{item});
        \\    }
        \\    
        \\    // With index
        \\    for (list.items, 0..) |item, i| {
        \\        std.debug.print("[{d}] = {d}\\n", .{ i, item });
        \\    }
        \\    
        \\    // ========================================
        \\    // REMOVING ITEMS
        \\    // ========================================
        \\    const removed = list.pop();             // Remove and return last
        \\    list.clearRetainingCapacity();          // Clear but keep memory
        \\    list.clearAndFree(allocator);           // Clear and free memory
        \\}
        \\
        \\## Initialization Options:
        \\//
        \\// SIMPLEST (Recommended): .empty
        \\//   var list: std.ArrayList(u32) = .empty;
        \\//   defer list.deinit(allocator);
        \\//   - Cleanest syntax
        \\//   - Works for any size
        \\//   - Grows automatically
        \\//
        \\// PERFORMANCE: initCapacity(allocator, size)
        \\//   var list = try std.ArrayList(u32).initCapacity(allocator, 100);
        \\//   defer list.deinit(allocator);
        \\//   - Pre-allocates memory
        \\//   - Better performance when size is known
        \\//   - Avoids reallocations
        \\//   Example: var lines = try std.ArrayList([]const u8).initCapacity(allocator, line_count);
        \\//
        \\// BASIC: init(allocator)
        \\//   var list = std.ArrayList(u32).init(allocator);
        \\//   defer list.deinit(allocator);
        \\//   - Starts with capacity 0
        \\//   - Explicit initialization
        \\
        \\## Key Points:
        \\// 1. .empty - Simplest, recommended for most cases
        \\// 2. initCapacity() - Use when performance matters and size is known
        \\// 3. append(allocator, item) - Add single item
        \\// 4. appendSlice(allocator, slice) - Add multiple items
        \\// 5. deinit(allocator) - Cleanup (always required!)
        \\// 6. Access items via list.items array
        \\// 7. Use defer list.deinit(allocator) immediately after init!
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/hashmap")) {
        return 
        \\// HashMap Patterns em Zig 0.16
        \\
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    const allocator = std.heap.page_allocator;
        \\    
        \\    var map: std.StringHashMap(u32) = .empty;
        \\    
        \\    // put(allocator, key, value) - COM allocator!
        \\    try map.put(allocator, "answer", 42);
        \\    try map.put(allocator, "count", 100);
        \\    
        \\    // Get
        \\    if (map.get("answer")) |value| {
        \\        std.debug.print("Answer: {}\n", .{value});
        \\    }
        \\    
        \\    // Delete
        \\    _ = map.remove("key");
        \\    
        \\    // deinit(allocator) - COM allocator!
        \\    map.deinit(allocator);
        \\}
        \\
        \\// StringHashMap:
        \\// - .empty - inicializa
        \\// - put(allocator, key, value) - COM allocator!
        \\// - get(key) - retorna ?V
        \\// - contains(key) - bool
        \\// - remove(key) - ?V
        \\// - iterator() - percorre
        \\// - deinit(allocator) - COM allocator!
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/io")) {
        return 
        \\// I/O Patterns in Zig 0.16
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\    const allocator = init.arena.allocator();
        \\
        \\    // Reading from stdin
        \\    var stdin_buffer: [4096]u8 = undefined;
        \\    var stdin_reader: Io.File.Reader = .init(Io.File.stdin(), io, &stdin_buffer);
        \\    const reader = &stdin_reader.interface;
        \\
        \\    // Read line
        \\    const line = reader.takeDelimiterInclusive('\n') catch break;
        \\
        \\    // Writing to stdout
        \\    var stdout_buffer: [4096]u8 = undefined;
        \\    var stdout_writer: Io.File.Writer = .init(Io.File.stdout(), io, &stdout_buffer);
        \\    const writer = &stdout_writer.interface;
        \\
        \\    try writer.writeAll("Hello, world!\n");
        \\    try writer.flush(); // Important!
        \\
        \\    // Writing to stderr (for logging)
        \\    var stderr_buffer: [4096]u8 = undefined;
        \\    var stderr_writer: Io.File.Writer = .init(Io.File.stderr(), io, &stderr_buffer);
        \\    const stderr = &stderr_writer.interface;
        \\
        \\    try stderr.print("Debug info: {}\n", .{42});
        \\}
        \\
        \\## Key Points
        \\// - All I/O needs `io` from `init.io`
        \\// - Need buffer for Reader/Writer
        \\// - Always flush after writing to stdout
        \\// - stderr is good for logging (doesn't interfere with protocol)
        \\// - OLD API DEPRECATED: std.fs.cwd().readFileAlloc() - use std.Io.Dir.cwd() instead!
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/allocator")) {
        return 
        \\// Allocator Patterns em Zig 0.16
        \\
        \\## Arena Allocator (main)
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\}
        \\
        \\## ArrayList - .empty + allocator em tudo!
        \\var list: std.ArrayList(u32) = .empty;
        \\try list.append(allocator, item);
        \\list.deinit(allocator);
        \\
        \\## StringHashMap - .empty + allocator em tudo!
        \\var map: std.StringHashMap(u32) = .empty;
        \\try map.put(allocator, key, value);
        \\map.deinit(allocator);
        \\
        \\## Resumo
        \\- Use .empty para inicializar
        \\- Passe allocator para TODOS os métodos
        \\- Fonte: stdlib (array_list.zig, hash_map.zig)
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/json")) {
        return 
        \\// JSON Patterns in Zig 0.16
        \\
        \\const std = @import("std");
        \\
        \\// Define your struct
        \\const Person = struct {
        \\    name: []const u8,
        \\    age: u32,
        \\};
        \\
        \\pub fn main() !void {
        \\    const allocator = std.heap.page_allocator;
        \\
        \\    // Parse JSON string to struct
        \\    const json_str = "{\"name\":\"Alice\",\"age\":30}";
        \\    var parsed = try std.json.parseFromSlice(Person, allocator, json_str, .{});
        \\    defer parsed.deinit();
        \\
        \\    std.debug.print("Name: {s}, Age: {}\n", .{ parsed.value.name, parsed.value.age });
        \\
        \\    // Stringify struct to JSON string
        \\    const person = Person{ .name = "Bob", .age = 25 };
        \\    const json_output = try std.json.stringifyAlloc(allocator, person, .{});
        \\    defer allocator.free(json_output);
        \\
        \\    std.debug.print("JSON: {s}\n", .{json_output});
        \\}
        \\
        \\// Key Points:
        \\// - parseFromSlice(Type, allocator, json_str, .{}) returns ParseOptions
        \\// - parsed.value contains the parsed struct
        \\// - ALWAYS call parsed.deinit() to free memory
        \\// - stringifyAlloc(allocator, value, .{}) returns allocated string
        \\// - ALWAYS free the returned string with allocator.free()
        \\
        \\// For nested objects, use std.json.Value:
        \\// var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        \\// defer parsed.deinit();
        \\// const name = parsed.value.object.get("name").?.string;
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://templates/build.zig")) {
        return 
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = \"my-app\",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path(\"src/main.zig\"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\
        \\    const run_step = b.step(\"run\", \"Run the app\");
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_step.dependOn(&run_cmd.step);
        \\}
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://templates/build.zig.zon")) {
        return 
        \\.{
        \\    .name = "my-project",
        \\    .version = "0.1.0",
        \\    .dependencies = .{
        \\        // Add dependencies here
        \\    },
        \\}
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/package")) {
        return 
        \\// ZON Package Manifest (build.zig.zon)
        \\// IMPORTANT: Use enum literals (.name) not strings ("name")!
        \\.{
        \\    .name = .my_project,           // Enum literal, NOT string!
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    
        \\    // Dependencies
        \\    .dependencies = .{
        \\        // .dependency_name = .{
        \\        //     .url = "https://github.com/user/repo/archive/refs/tags/v1.0.0.tar.gz",
        \\        //     .hash = "1220...",  // Get with: zig fetch --save <url>
        \\        // },
        \\    },
        \\    
        \\    // Package paths (included files)
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        // "LICENSE",  // Optional
        \\    },
        \\}
        \\
        \\// Get hash after adding URL:
        \\// zig fetch --save https://github.com/user/repo/archive/refs/tags/v1.0.0.tar.gz
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/static_lib")) {
        return 
        \\// Static Library Build (build.zig)
        \\// Zig 0.16 uses b.addLibrary, NOT b.addStaticLibrary
        \\
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    // Create static library
        \\    const lib = b.addLibrary(.{
        \\        .name = "mylib",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/lib.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\        .linkage = .static,  // NOT "static_library"!
        \\    });
        \\
        \\    b.installArtifact(lib);
        \\    
        \\    // Header-only or with source:
        \\    // For header-only, use .header_export only
        \\    // For with source, use .static
        \\}
        \\
        \\// Key points:
        \\// - b.addLibrary (NOT b.addStaticLibrary)
        \\// - .linkage = .static (NOT "static_library")
        \\// - Access module via lib.root_module (NOT lib.module)
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/dynamic_lib")) {
        return 
        \\// Dynamic Library Build (build.zig)
        \\// Zig 0.16 uses b.addLibrary with .dynamic linkage
        \\
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    // Create dynamic library
        \\    const lib = b.addLibrary(.{
        \\        .name = "mylib",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/lib.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\        .linkage = .dynamic,
        \\    });
        \\    
        \\    // Add system libraries to link against
        \\    lib.linkSystemLibrary("ssl");
        \\    lib.linkSystemLibrary("crypto");
        \\
        \\    b.installArtifact(lib);
        \\}
        \\
        \\// Key points:
        \\// - b.addLibrary with .linkage = .dynamic
        \\// - lib.linkSystemLibrary("name") for system libs
        \\// - Output: libmylib.so (Linux), libmylib.dylib (macOS), libmylib.dll (Windows)
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/multimodule")) {
        return 
        \\// Multi-Module Project (build.zig)
        \\// Multiple modules in one project
        \\
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    // Module 1: Core library
        \\    const core_module = b.createModule(.{
        \\        .root_source_file = b.path("src/core.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    // Module 2: Utils that depends on core
        \\    const utils_module = b.createModule(.{
        \\        .root_source_file = b.path("src/utils.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{
        \\            .{ .name = "core", .module = core_module },
        \\        },
        \\    });
        \\
        \\    // Executable using utils (which imports core)
        \\    const exe = b.addExecutable(.{
        \\        .name = "myapp",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\            .imports = &.{
        \\                .{ .name = "utils", .module = utils_module },
        \\                .{ .name = "core", .module = core_module },
        \\            },
        \\        }),
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\}
        \\
        \\// In main.zig:
        \\// const utils = @import("utils");
        \\// const core = @import("core");
        \\
        \\// Key points:
        \\// - b.createModule() for each module
        \\// - .imports to specify dependencies
        \\// - .name is how you import in @import()
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/file_io")) {
        return 
        \\// File I/O Patterns in Zig 0.16
        \\// Complete guide with std.Io.Dir and std.Io.File
        \\
        \\const std = @import("std");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\    const allocator = init.arena.allocator();
        \\
        \\    // ========================================
        \\    // BASIC FILE OPERATIONS
        \\    // ========================================
        \\
        \\    // READ entire file
        \\    const contents = try std.Io.Dir.cwd().readFileAlloc(
        \\        io,                    // io context (REQUIRED)
        \\        "data.txt",           // file path
        \\        allocator,            // allocator
        \\        .limited(1024 * 1024) // max size
        \\    );
        \\    defer allocator.free(contents);
        \\
        \\    // WRITE file (create or overwrite)
        \\    const file = try std.Io.Dir.cwd().createFile(io, "output.txt", .{});
        \\    defer file.close(io);  // NOTE: requires io parameter!
        \\    try file.writeStreamingAll(io, "Hello, Zig!");
        \\
        \\    // OPEN existing file
        \\    const existing = try std.Io.Dir.cwd().openFile(
        \\        io, "data.txt", .{ .mode = .read_only }
        \\    );
        \\    defer existing.close(io);
        \\
        \\    // READ with Reader (line by line)
        \\    var buffer: [4096]u8 = undefined;
        \\    var file_reader = existing.reader(io, &buffer);
        \\    const line = try file_reader.interface.takeDelimiterInclusive('\n');
        \\
        \\    // FILE INFO (stat)
        \\    const stat = try file.stat(io);
        \\    _ = stat.size;      // file size in bytes
        \\    _ = stat.mtime;    // modification time
        \\    _ = stat.atime;    // access time
        \\    _ = stat.ctime;    // change time
        \\
        \\    // DELETE file
        \\    try std.Io.Dir.cwd().deleteFile(io, "temp.txt");
        \\
        \\    // ========================================
        \\    // DIRECTORY OPERATIONS
        \\    // ========================================
        \\
        \\    // Create directory
        \\    try std.Io.Dir.cwd().createDir(io, "my_folder", .default_dir);
        \\
        \\    // Open directory
        \\    var dir = try std.Io.Dir.cwd().openDir(io, "my_folder", .{});
        \\    defer dir.close(io);
        \\
        \\    // Check if exists
        \\    const exists = std.Io.Dir.cwd().openDir(io, "maybe", .{}) catch null;
        \\    if (exists) |d| d.close(io);
        \\}
        \\
        \\## File I/O Key Points
        \\// All file operations require 'io' parameter
        \\// std.Io.Dir.cwd() - current working directory
        \\// file.close(io) - NOTE: requires io parameter (not like old API)
        \\// readFileAlloc(io, path, allocator, .limited(max)) - read entire file
        \\// createFile(io, path, .{}) - create or overwrite
        \\// openFile(io, path, .{ .mode = .read_only }) - open existing
        \\// writeStreamingAll(io, data) - write all bytes
        \\// file.reader(io, buffer) - create reader for streaming
        \\// deleteFile(io, path) - delete file
        \\// createDir(io, path, .default_dir) - create directory
        \\// openDir(io, path, .{}) - open directory
        \\
        \\## Async Operations
        \\// File I/O in std.Io is SYNCHRONOUS by default
        \\// For async computation, use Io.async():
        \\
        \\fn compute-heavy(n: u32) u64 {
        \\    var sum: u64 = 0;
        \\    for (0..n) |i| sum += i;
        \\    return sum;
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\
        \\    // ASYNC computation (not file I/O)
        \\    var future1 = io.async(compute-heavy, .{100_000});
        \\    var future2 = io.async(compute-heavy, .{100_000});
        \\
        \\    const r1 = future1.await(io);
        \\    const r2 = future2.await(io);
        \\    _ = r1 + r2;
        \\}
        \\
        \\## Sync vs Async Summary
        \\| Operation | Type | Notes |
        \\|-----------|------|-------|
        \\| readFileAlloc | Sync | Blocks until complete |
        \\| writeStreamingAll | Sync | Blocks until complete |
        \\| file.reader | Sync | Streaming read |
        \\| io.async() | Async | For computation |
        \\| future.await() | Async | Wait for async result |
        \\
        \\## API Differences (OLD vs NEW)
        \\// OLD (DEPRECATED):
        \\//   std.fs.cwd().readFileAlloc(allocator, path, max)
        \\//   file.close()
        \\//   std.fs.cwd().createFile(path, .{})
        \\//
        \\// NEW (use this):
        \\//   std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max))
        \\//   file.close(io)
        \\//   std.Io.Dir.cwd().createFile(io, path, .{})
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/time")) {
        return 
        \\// Time APIs in Zig 0.16
        \\// Complete guide with std.Io.Timestamp and std.Io.Duration
        \\
        \\const std = @import("std");
        \\const c = @cImport({
        \\    @cInclude("time.h");
        \\});
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\    
        \\    // ========================================
        \\    // CLOCK - Get current timestamp
        \\    // ========================================
        \\    const timestamp = std.Io.Clock.now(.real, io);
        \\    const seconds = timestamp.toSeconds();      // i64
        \\    const millis = timestamp.toMilliseconds();  // i64
        \\    const nanos = timestamp.toNanoseconds();    // i96
        \\
        \\    // ========================================
        \\    // TIMESTAMP OPERATIONS
        \\    // ========================================
        \\    const ts_from_ns = std.Io.Timestamp.fromNanoseconds(1_000_000_000);
        \\    const duration = timestamp.durationTo(ts_from_ns);
        \\    const later = timestamp.addDuration(duration);
        \\    const earlier = timestamp.subDuration(duration);
        \\
        \\    // ========================================
        \\    // DURATION - Time intervals
        \\    // ========================================
        \\    const one_second = std.Io.Duration.fromSeconds(1);
        \\    const one_milli = std.Io.Duration.fromMilliseconds(1000);
        \\    const one_nano = std.Io.Duration.fromNanoseconds(1_000_000_000);
        \\    const zero_duration = std.Io.Duration.zero;
        \\    const max_duration = std.Io.Duration.max;
        \\
        \\    // ========================================
        \\    // SLEEP & DELAY (3 ways)
        \\    // ========================================
        \\    // Way 1: Io.sleep() - recommended
        \\    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real);
        \\
        \\    // Way 2: Clock.Timestamp.wait() - wait until specific time
        \\    const target = timestamp.addDuration(std.Io.Duration.fromMilliseconds(300));
        \\    try target.withClock(.real).wait(io);
        \\
        \\    // Way 3: POSIX nanosleep
        \\    var timespec: std.posix.timespec = .{ .sec = 0, .nsec = 200_000_000 };
        \\    _ = std.posix.system.nanosleep(&timespec, &timespec);
        \\    
        \\    // ========================================
        \\    // CLOCK TYPES
        \\    // ========================================
        \\    const real_ts = std.Io.Clock.now(.real, io);
        \\    const awake_ts = std.Io.Clock.now(.awake, io);
        \\    const boot_ts = std.Io.Clock.now(.boot, io);
        \\    const cpu_proc_ts = std.Io.Clock.now(.cpu_process, io);
        \\    const cpu_thread_ts = std.Io.Clock.now(.cpu_thread, io);
        \\    
        \\    // ========================================
        \\    // CLOCK-SPECIFIC TIMESTAMP
        \\    // ========================================
        \\    const clock_ts = std.Io.Clock.Timestamp.now(io, .real);
        \\    const time_remaining = clock_ts.durationFromNow(io);
        \\    const time_elapsed = clock_ts.untilNow(io);
        \\    
        \\    // ========================================
        \\    // C FALLBACK
        \\    // ========================================
        \\    const c_time = c.time(null);
        \\    var ts: c.timespec = undefined;
        \\    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        \\    const nanos_c = @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
        \\}
        \\
        \\## Key Types
        \\// std.Io.Timestamp - Raw timestamp (nanoseconds since epoch)
        \\//   .now(io, clock)              - Get current time
        \\//   .fromNanoseconds(ns)         - Create from nanoseconds
        \\//   .toSeconds()                 - Convert to seconds (i64)
        \\//   .toMilliseconds()            - Convert to milliseconds (i64)
        \\//   .toNanoseconds()             - Convert to nanoseconds (i96)
        \\//   .durationTo(other)           - Duration between timestamps
        \\//   .addDuration(d)              - Add duration to timestamp
        \\//   .subDuration(d)              - Subtract duration
        \\//   .withClock(clock)            - Add clock context
        \\//   .zero                        - Zero timestamp constant
        \\//
        \\// std.Io.Clock.Timestamp - Clock-aware timestamp
        \\//   .now(io, clock)              - Get current time with clock context
        \\//   .wait(io)                    - Sleep until this time
        \\//   .toClock(io, clock)          - Convert to different clock
        \\//   .durationFromNow(io)         - Time until this timestamp
        \\//   .untilNow(io)                - Time since this timestamp
        \\//   .addDuration(d)              - Add duration
        \\//   .subDuration(d)              - Subtract duration
        \\//   .durationTo(other)           - Duration to another timestamp
        \\//
        \\// std.Io.Duration - Time intervals
        \\//   .fromSeconds(s)              - Create from seconds
        \\//   .fromMilliseconds(ms)        - Create from milliseconds
        \\//   .fromNanoseconds(ns)         - Create from nanoseconds
        \\//   .toSeconds()                 - Convert to seconds
        \\//   .toMilliseconds()            - Convert to milliseconds
        \\//   .zero                        - Zero duration
        \\//   .max                         - Maximum duration
        \\//
        \\// std.Io.Clock.Duration - Clock-aware duration
        \\//   .sleep(io)                   - Sleep on specific clock
        \\//
        \\// Clock Types:
        \\//   .real         - Wall clock (Unix epoch, affected by NTP)
        \\//   .awake        - Monotonic, excludes suspend time
        \\//   .boot         - Monotonic, includes suspend time
        \\//   .cpu_process  - CPU time for process
        \\//   .cpu_thread   - CPU time for thread
        \\
        \\## Sleep & Delay Methods
        \\// Method 1: Io.sleep() - recommended
        \\try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real);
        \\
        \\// Method 2: Clock.Timestamp.wait()
        \\const target = timestamp.addDuration(std.Io.Duration.fromMilliseconds(300));
        \\try target.withClock(.real).wait(io);
        \\
        \\// Method 3: POSIX nanosleep
        \\var ts: std.posix.timespec = .{ .sec = 0, .nsec = 200_000_000 };
        \\_ = std.posix.system.nanosleep(&ts, &ts);
        \\
        \\## Complete Benchmark Example
        \\// Measure execution time with different clock types
        \\fn doWork() void {
        \\    var sum: u64 = 0;
        \\    for (0..1_000_000) |i| sum += i;
        \\    _ = sum;
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\    
        \\    // Warmup - run once before measuring
        \\    doWork();
        \\    
        \\    // Measure with different clocks
        \\    const real_start = std.Io.Clock.now(.real, io);
        \\    const cpu_start = std.Io.Clock.now(.cpu_process, io);
        \\    
        \\    doWork();
        \\    
        \\    const real_elapsed = real_start.durationTo(std.Io.Clock.now(.real, io));
        \\    const cpu_elapsed = cpu_start.durationTo(std.Io.Clock.now(.cpu_process, io));
        \\    
        \\    std.debug.print("Real time: {} ms\n", .{real_elapsed.toMilliseconds()});
        \\    std.debug.print("CPU time:  {} ms\n", .{cpu_elapsed.toMilliseconds()});
        \\}
        \\
        \\## Clock Selection Guide
        \\| Clock        | Use Case                                        |
        \\|--------------|------------------------------------------------|
        \\| `.real`      | Total elapsed time (wall-clock)                |
        \\| `.awake`     | Timeouts, rate limiting (not affected by NTP) |
        \\| `.boot`      | Time since system boot (includes suspend)       |
        \\| `.cpu_process` | Benchmark CPU usage (entire process)         |
        \\| `.cpu_thread`  | Benchmark CPU usage (single thread)        |
        \\
        \\## Key Points
        \\1. std.Io.Clock.now(clock, io) - Get current timestamp
        \\2. std.Io.Duration for time intervals (fromSeconds, fromMilliseconds)
        \\3. timestamp.toSeconds/Milliseconds/Nanoseconds() - conversions
        \\4. timestamp.durationTo(other) - time difference
        \\5. timestamp.addDuration/subDuration() - time arithmetic
        \\6. std.Io.sleep(io, duration, clock) - sleep (recommended)
        \\7. target.withClock(clock).wait(io) - wait until timestamp
        \\8. std.posix.system.nanosleep() - POSIX sleep
        \\9. Clock types: .real, .awake, .boot, .cpu_process, .cpu_thread
        \\10. Always warmup before benchmarking
        \\11. Compare .real vs .cpu_process to detect I/O wait time
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/json_complete")) {
        return 
        \\// JSON Parsing Complete Guide - Zig 0.16
        \\// REAL EXAMPLES with all options
        \\
        \\const std = @import("std");
        \\
        \\// Define your structs
        \\const Person = struct {
        \\    name: []const u8,
        \\    age: u32,
        \\};
        \\
        \\const Config = struct {
        \\    port: u16,
        \\    host: []const u8,
        \\    debug: bool,
        \\};
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\
        \\    // ========================================
        \\    // BASIC PARSING
        \\    // ========================================
        \\    const json_str = "{\"name\":\"Alice\",\"age\":30}";
        \\    var parsed = try std.json.parseFromSlice(
        \\        Person,           // target type
        \\        allocator,
        \\        json_str,
        \\        .{}               // default options
        \\    );
        \\    defer parsed.deinit();
        \\    std.debug.print("Name: {s}\n", .{parsed.value.name});
        \\
        \\    // ========================================
        \\    // PARSING WITH OPTIONS
        \\    // ========================================
        \\    const json_with_extra = "{\"name\":\"Bob\",\"age\":25,\"extra\":\"field\"}";
        \\    var parsed2 = try std.json.parseFromSlice(
        \\        Person,
        \\        allocator,
        \\        json_with_extra,
        \\        .{
        \\            .ignore_unknown_fields = true,  // Ignore extra fields
        \\            .allocate = .alloc_always,      // Always allocate strings
        \\        }
        \\    );
        \\    defer parsed2.deinit();
        \\
        \\    // ========================================
        \\    // DYNAMIC PARSING (unknown structure)
        \\    // ========================================
        \\    var dynamic = try std.json.parseFromSlice(
        \\        std.json.Value,
        \\        allocator,
        \\        json_str,
        \\        .{}
        \\    );
        \\    defer dynamic.deinit();
        \\    
        \\    // Access fields
        \\    const name = dynamic.value.object.get("name").?.string;
        \\    const age = dynamic.value.object.get("age").?.integer;
        \\
        \\    // ========================================
        \\    // STRINGIFY (struct to JSON)
        \\    // ========================================
        \\    const person = Person{ .name = "Charlie", .age = 35 };
        \\    
        \\    // Compact JSON
        \\    const compact = try std.json.stringifyAlloc(allocator, person, .{});
        \\    defer allocator.free(compact);
        \\    
        \\    // Pretty printed JSON
        \\    const pretty = try std.json.stringifyAlloc(allocator, person, .{
        \\        .whitespace = .indent_2,
        \\    });
        \\    defer allocator.free(pretty);
        \\
        \\    // ========================================
        \\    // NEW API: std.json.Stringify.valueAlloc
        \\    // ========================================
        \\    const json_output = try std.json.Stringify.valueAlloc(
        \\        allocator,
        \\        person,
        \\        .{ .whitespace = .indent_2 }
        \\    );
        \\    defer allocator.free(json_output);
        \\
        \\    // ========================================
        \\    // PARSING FROM FILE (common pattern)
        \\    // ========================================
        \\    const config = try parseConfigFile(init, "config.json");
        \\    defer config.parsed.deinit();
        \\    defer init.arena.allocator().free(config.data);
        \\}
        \\
        \\fn parseConfigFile(init: std.process.Init, path: []const u8) !struct {
        \\    parsed: std.json.Parsed(Config),
        \\    data: []u8,
        \\} {
        \\    const io = init.io;
        \\    const allocator = init.arena.allocator();
        \\    
        \\    const contents = try std.Io.Dir.cwd().readFileAlloc(
        \\        io, path, allocator, .limited(1024 * 1024 * 50)
        \\    );
        \\    errdefer allocator.free(contents);
        \\    
        \\    const parsed = try std.json.parseFromSlice(
        \\        Config, allocator, contents,
        \\        .{ .ignore_unknown_fields = true }
        \\    );
        \\    
        \\    return .{
        \\        .parsed = parsed,
        \\        .data = contents,
        \\    };
        \\}
        \\
        \\## Common Options
        \\// .ignore_unknown_fields = true  - Skip unknown JSON fields
        \\// .allocate = .alloc_always     - Always allocate strings
        \\// .allocate = .alloc_if_needed  - Only allocate if necessary
        \\// .max_value_len = N            - Limit string length
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/threads")) {
        return 
        \\// Threading & Synchronization - Zig 0.16
        \\// IMPORTANT API CHANGES in 0.16.0-dev.2565+
        \\
        \\const std = @import("std");
        \\
        \\// ========================================
        \\// WHAT DOES NOT EXIST in Zig 0.16
        \\// ========================================
        \\// std.Thread.Mutex — does not exist
        \\// std.Thread.Condition — does not exist  
        \\// std.ThreadPool — does not exist
        \\
        \\// ========================================
        \\// WHAT EXISTS (requires Io context)
        \\// ========================================
        \\// std.Io.Mutex — requires Io parameter
        \\// std.Io.Condition — requires Io parameter
        \\// std.os.linux.futex — raw syscall, no Io needed
        \\// Thread.yield() — cooperative yield
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\    const allocator = init.arena.allocator();
        \\
        \\    // ========================================
        \\    // std.Io.Mutex API
        \\    // ========================================
        \\    var mutex = std.Io.Mutex{};
        \\    
        \\    // Lock with Io context
        \\    try mutex.lock(io);
        \\    defer mutex.unlock(io);
        \\    
        \\    // Critical section here
        \\    // ...
        \\
        \\    // ========================================
        \\    // std.Io.Condition API
        \\    // ========================================
        \\    var condition = std.Io.Condition{};
        \\    
        \\    // Wait for condition (releases mutex while waiting)
        \\    try condition.wait(io, &mutex);
        \\    
        \\    // Or uncancelable wait
        \\    condition.waitUncancelable(io, &mutex);
        \\    
        \\    // Signal one waiting thread
        \\    condition.signal(io);
        \\    
        \\    // Broadcast to all waiting threads
        \\    condition.broadcast(io);
        \\
        \\    // ========================================
        \\    // Spawning Threads
        \\    // ========================================
        \\    const thread = try std.Thread.spawn(.{}, workerFn, .{io, &mutex});
        \\    defer thread.join();
        \\}
        \\
        \\fn workerFn(io: std.Io, mutex: *std.Io.Mutex) !void {
        \\    // Each worker needs Io context passed from parent
        \\    try mutex.lock(io);
        \\    defer mutex.unlock(io);
        \\    
        \\    // Do work...
        \\}
        \\
        \\// ========================================
        \\// Thread-safe counter example
        \\// ========================================
        \\const ThreadSafeCounter = struct {
        \\    mutex: std.Io.Mutex = .{},
        \\    value: u64 = 0,
        \\    
        \\    pub fn increment(self: *ThreadSafeCounter, io: std.Io) !void {
        \\        try self.mutex.lock(io);
        \\        defer self.mutex.unlock(io);
        \\        self.value += 1;
        \\    }
        \\    
        \\    pub fn get(self: *ThreadSafeCounter, io: std.Io) !u64 {
        \\        try self.mutex.lock(io);
        \\        defer self.mutex.unlock(io);
        \\        return self.value;
        \\    }
        \\};
        \\
        \\## Key Points
        \\// - std.Thread.Mutex DOES NOT EXIST in Zig 0.16
        \\// - Use std.Io.Mutex with Io parameter
        \\// - Pass Io context to worker threads
        \\// - std.Io.Condition for thread signaling
        \\// - Investigate if Io is safe to share across threads
        \\
        ;
    }
    return "Unknown resource";
}

fn buildPromptsListResponse(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    try list.appendSlice(allocator, ",\"result\":{\"prompts\":[");

    try list.appendSlice(allocator, "{\"name\":\"zig_arraylist\",\"description\":\"How to create and use ArrayList in Zig 0.16\"},");
    try list.appendSlice(allocator, "{\"name\":\"zig_hashmap\",\"description\":\"How to create and use HashMap in Zig 0.16\"},");
    try list.appendSlice(allocator, "{\"name\":\"zig_json\",\"description\":\"How to parse and stringify JSON in Zig 0.16\"},");
    try list.appendSlice(allocator, "{\"name\":\"zig_error_handling\",\"description\":\"How to handle errors in Zig 0.16\"},");
    try list.appendSlice(allocator, "{\"name\":\"zig_io\",\"description\":\"I/O patterns for reading and writing in Zig 0.16\"}");

    try list.appendSlice(allocator, "]}}");

    return list.toOwnedSlice(allocator);
}

fn handlePromptsGet(allocator: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    var prompt_name: ?[]const u8 = null;
    if (params) |p| {
        if (p.object.get("name")) |n| {
            prompt_name = n.string;
        }
    }

    if (prompt_name) |name| {
        const content = getPromptContent(name);
        try list.appendSlice(allocator, ",\"result\":{\"description\":\"Zig 0.16 Pattern\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"");

        for (content) |byte| {
            switch (byte) {
                '"' => try list.appendSlice(allocator, "\\\""),
                '\\' => try list.appendSlice(allocator, "\\\\"),
                '\n' => try list.appendSlice(allocator, "\\n"),
                '\r' => try list.appendSlice(allocator, "\\r"),
                '\t' => try list.appendSlice(allocator, "\\t"),
                else => try list.append(allocator, byte),
            }
        }

        try list.appendSlice(allocator, "\"}}]}");
    } else {
        try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"Missing prompt name\"}");
    }

    try list.appendSlice(allocator, "}");

    return list.toOwnedSlice(allocator);
}

fn getPromptContent(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zig_arraylist")) {
        return 
        \\You are working with Zig 0.16 ArrayList. Follow these patterns:
        \\
        \\1. Initialization:
        \\   var list: std.ArrayList(T) = .empty;
        \\
        \\2. Adding items (requires allocator):
        \\   try list.append(allocator, item);
        \\
        \\3. Accessing items:
        \\   for (list.items) |item| { ... }
        \\   const item = list.items[index];
        \\
        \\4. Cleanup (requires allocator):
        \\   list.deinit(allocator);
        \\
        \\Important: Always pass allocator to append() and deinit()!
        \\Use initCapacity(allocator, size) if you know the size upfront.
        ;
    } else if (std.mem.eql(u8, name, "zig_hashmap")) {
        return 
        \\You are working with Zig 0.16 HashMap. Follow these patterns:
        \\
        \\1. Initialization:
        \\   var map: std.StringHashMap(V) = .empty;
        \\
        \\2. Inserting (requires allocator):
        \\   try map.put(allocator, key, value);
        \\
        \\3. Getting values:
        \\   if (map.get(key)) |value| { ... }
        \\
        \\4. Checking existence:
        \\   if (map.contains(key)) { ... }
        \\
        \\5. Removing:
        \\   _ = map.remove(key);
        \\
        \\6. Iteration:
        \\   var iter = map.iterator();
        \\   while (iter.next()) |entry| {
        \\       const key = entry.key_ptr.*;
        \\       const value = entry.value_ptr.*;
        \\   }
        \\
        \\7. Cleanup (requires allocator):
        \\   map.deinit(allocator);
        \\
        \\Important: Always pass allocator to put() and deinit()!
        ;
    } else if (std.mem.eql(u8, name, "zig_json")) {
        return 
        \\You are working with Zig 0.16 JSON. Follow these patterns:
        \\
        \\1. Define a struct matching your JSON structure:
        \\   const Person = struct {
        \\       name: []const u8,
        \\       age: u32,
        \\   };
        \\
        \\2. Parse JSON string to struct:
        \\   var parsed = try std.json.parseFromSlice(Person, allocator, json_str, .{});
        \\   defer parsed.deinit();
        \\   const person = parsed.value;
        \\
        \\3. For dynamic/nested JSON, use std.json.Value:
        \\   var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        \\   defer parsed.deinit();
        \\   const name = parsed.value.object.get("name").?.string;
        \\
        \\4. Stringify struct to JSON:
        \\   const output = try std.json.stringifyAlloc(allocator, person, .{});
        \\   defer allocator.free(output);
        \\
        \\Important: Always call parsed.deinit() and free allocated strings!
        ;
    } else if (std.mem.eql(u8, name, "zig_error_handling")) {
        return 
        \\You are handling errors in Zig 0.16. Follow these patterns:
        \\
        \\1. Try-catch pattern:
        \\   const result = functionThatMayFail() catch |err| {
        \\       std.log.err("Error: {}", .{err});
        \\       return err;
        \\   };
        \\
        \\2. If-else with error:
        \\   if (functionThatMayFail()) |value| {
        \\       // Success
        \\   } else |err| {
        \\       // Handle error
        \\   }
        \\
        \\3. Optional unwrapping:
        \\   if (optional_value) |value| {
        \\       // value is not null
        \\   } else {
        \\       // value is null
        \\   }
        \\
        \\4. Common errors with ArrayList/HashMap:
        \\   - OutOfMemory: allocator failed
        \\   - Missing allocator parameter: check if you passed allocator to method
        \\   - Use-after-free: make sure not to use after deinit()
        \\
        \\5. Error return trace:
        \\   Run with `zig build` to see full error trace
        \\   Check stderr output for detailed messages
        ;
    } else if (std.mem.eql(u8, name, "zig_io")) {
        return 
        \\You are working with I/O in Zig 0.16. Follow these patterns:
        \\
        \\1. Main function signature:
        \\   pub fn main(init: std.process.Init) !void {
        \\       const io = init.io;
        \\       const allocator = init.arena.allocator();
        \\   }
        \\
        \\2. Reading from stdin:
        \\   var stdin_buffer: [4096]u8 = undefined;
        \\   var stdin_reader: Io.File.Reader = .init(Io.File.stdin(), io, &stdin_buffer);
        \\   const reader = &stdin_reader.interface;
        \\   const line = reader.takeDelimiterInclusive('\\n') catch break;
        \\
        \\3. Writing to stdout:
        \\   var stdout_buffer: [4096]u8 = undefined;
        \\   var stdout_writer: Io.File.Writer = .init(Io.File.stdout(), io, &stdout_buffer);
        \\   const writer = &stdout_writer.interface;
        \\   try writer.writeAll("Hello\\n");
        \\   try writer.flush(); // Always flush!
        \\
        \\4. Writing to stderr (for logging):
        \\   var stderr_buffer: [4096]u8 = undefined;
        \\   var stderr_writer: Io.File.Writer = .init(Io.File.stderr(), io, &stderr_buffer);
        \\   const stderr = &stderr_writer.interface;
        \\   try stderr.print("Debug: {}\\n", .{value});
        \\
        \\Important: Always flush stdout after writing, especially in servers!
        ;
    }
    return "Unknown prompt";
}

fn handleToolsCall(init: std.process.Init, allocator: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (id) |id_val| {
        try list.appendSlice(allocator, ",\"id\":");
        switch (id_val) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{}", .{i}) catch unreachable;
                try list.appendSlice(allocator, str);
            },
            .string => |s| {
                try list.append(allocator, '"');
                try list.appendSlice(allocator, s);
                try list.append(allocator, '"');
            },
            else => try list.appendSlice(allocator, "null"),
        }
    }

    var tool_name: ?[]const u8 = null;
    var tool_args: ?std.json.Value = null;

    if (params) |p| {
        if (p.object.get("name")) |n| {
            tool_name = n.string;
        }
        if (p.object.get("arguments")) |a| {
            tool_args = a;
        }
    }

    if (tool_name) |name| {
        const result = executeTool(init, allocator, name, tool_args) catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "Tool error: {}", .{err});
            defer allocator.free(err_msg);
            try list.appendSlice(allocator, ",\"error\":{\"code\":-32603,\"message\":\"");
            try list.appendSlice(allocator, err_msg);
            try list.appendSlice(allocator, "\"}");
            try list.appendSlice(allocator, "}");
            return list.toOwnedSlice(allocator);
        };
        defer allocator.free(result);

        // Check if result is an error message
        if (result.len > 6 and std.mem.eql(u8, result[0..6], "Error:") or (result.len > 8 and std.mem.eql(u8, result[0..8], "Unknown "))) {
            try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"");
            for (result) |byte| {
                switch (byte) {
                    '"' => try list.appendSlice(allocator, "\\\""),
                    '\\' => try list.appendSlice(allocator, "\\\\"),
                    '\n' => try list.appendSlice(allocator, "\\n"),
                    '\r' => try list.appendSlice(allocator, "\\r"),
                    '\t' => try list.appendSlice(allocator, "\\t"),
                    else => try list.append(allocator, byte),
                }
            }
            try list.appendSlice(allocator, "\"}");
        } else {
            try list.appendSlice(allocator, ",\"result\":{\"content\":[");
            try list.appendSlice(allocator, "{\"type\":\"text\",\"text\":\"");

            for (result) |byte| {
                switch (byte) {
                    '"' => try list.appendSlice(allocator, "\\\""),
                    '\\' => try list.appendSlice(allocator, "\\\\"),
                    '\n' => try list.appendSlice(allocator, "\\n"),
                    '\r' => try list.appendSlice(allocator, "\\r"),
                    '\t' => try list.appendSlice(allocator, "\\t"),
                    else => try list.append(allocator, byte),
                }
            }

            try list.appendSlice(allocator, "\"}]}");
        }
    } else {
        try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"Missing tool name\"}");
    }

    try list.appendSlice(allocator, "}");

    return list.toOwnedSlice(allocator);
}

fn getPatternDocumentation(allocator: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    if (std.mem.eql(u8, pattern, "list")) {
        try list.appendSlice(allocator,
            \\Available Zig 0.16 Patterns:
            \\========================
            \\Use zig_patterns tool with pattern parameter:
            \\n            \\  - arraylist      : ArrayList usage patterns
            \\  - hashmap        : HashMap usage patterns  
            \\  - json           : JSON parsing/stringifying (basic)
            \\  - json_complete  : JSON with all options + file I/O (NEW!)
            \\  - io             : I/O patterns (stdin/stdout/stderr) - DEPRECATED FILE API!
            \\  - file_io        : File operations with std.Io.Dir.cwd() (NEW!)
            \\  - allocator      : Memory allocator patterns
            \\  - error_handling : Error handling techniques
            \\  - time           : Time APIs - Instant, Timer, Clock.now() (NEW!)
            \\  - threads        : Threading & sync - std.Io.Mutex, std.Io.Condition (NEW!)
            \\  - build_template : build.zig template
            \\  - zon_template   : build.zig.zon template
            \\  - package        : ZON package manifest (NEW!)
            \\  - static_lib     : Static library build (NEW!)
            \\  - dynamic_lib    : Dynamic library build (NEW!)
            \\  - multimodule    : Multi-module project (NEW!)
            \\  - guidelines     : Complete Zig 0.16 guidelines
            \\  - iommi          : Simple game mode (see grape-mcp!)
            \\  - list           : Show this list
            \\n            \\Example: zig_patterns with pattern="arraylist"
            \\n            \\IMPORTANT NOTES:
            \\  - 'io' pattern shows OLD deprecated file API (std.fs.cwd())
            \\  - Use 'file_io' pattern for correct NEW API (std.Io.Dir.cwd())
            \\  - Use 'json_complete' for full JSON with file reading examples
            \\  - Use 'time' for timing, benchmarks, and timestamps
            \\  - Use 'threads' for std.Io.Mutex, std.Io.Condition (std.Thread.Mutex DOES NOT EXIST!)
        );
    } else if (std.mem.eql(u8, pattern, "file_io")) {
        return allocator.dupe(u8,
            \\// File I/O Patterns in Zig 0.16
            \\// Complete guide with std.Io.Dir and std.Io.File
            \\
            \\const std = @import("std");
            \\
            \\pub fn main(init: std.process.Init) !void {
            \\    const io = init.io;
            \\    const allocator = init.arena.allocator();
            \\
            \\    // ========================================
            \\    // BASIC FILE OPERATIONS
            \\    // ========================================
            \\
            \\    // READ entire file
            \\    const contents = try std.Io.Dir.cwd().readFileAlloc(
            \\        io,                    // io context (REQUIRED)
            \\        "data.txt",           // file path
            \\        allocator,            // allocator
            \\        .limited(1024 * 1024) // max size
            \\    );
            \\    defer allocator.free(contents);
            \\
            \\    // WRITE file (create or overwrite)
            \\    const file = try std.Io.Dir.cwd().createFile(io, "output.txt", .{});
            \\    defer file.close(io);  // NOTE: requires io parameter!
            \\    try file.writeStreamingAll(io, "Hello, Zig!");
            \\
            \\    // OPEN existing file
            \\    const existing = try std.Io.Dir.cwd().openFile(
            \\        io, "data.txt", .{ .mode = .read_only }
            \\    );
            \\    defer existing.close(io);
            \\
            \\    // READ with Reader (line by line)
            \\    var buffer: [4096]u8 = undefined;
            \\    var file_reader = existing.reader(io, &buffer);
            \\    const line = try file_reader.interface.takeDelimiterInclusive('\\n');
            \\
            \\    // FILE INFO (stat)
            \\    const stat = try file.stat(io);
            \\    _ = stat.size;      // file size in bytes
            \\    _ = stat.mtime;    // modification time
            \\    _ = stat.atime;    // access time
            \\    _ = stat.ctime;    // change time
            \\
            \\    // DELETE file
            \\    try std.Io.Dir.cwd().deleteFile(io, "temp.txt");
            \\
            \\    // ========================================
            \\    // DIRECTORY OPERATIONS
            \\    // ========================================
            \\
            \\    // Create directory
            \\    try std.Io.Dir.cwd().createDir(io, "my_folder", .default_dir);
            \\
            \\    // Open directory
            \\    var dir = try std.Io.Dir.cwd().openDir(io, "my_folder", .{});
            \\    defer dir.close(io);
            \\
            \\    // Check if exists
            \\    const exists = std.Io.Dir.cwd().openDir(io, "maybe", .{}) catch null;
            \\    if (exists) |d| d.close(io);
            \\}
            \\
            \\## File I/O Key Points
            \\// All file operations require 'io' parameter
            \\// std.Io.Dir.cwd() - current working directory
            \\// file.close(io) - NOTE: requires io parameter (not like old API)
            \\// readFileAlloc(io, path, allocator, .limited(max)) - read entire file
            \\// createFile(io, path, .{}) - create or overwrite
            \\// openFile(io, path, .{ .mode = .read_only }) - open existing
            \\// writeStreamingAll(io, data) - write all bytes
            \\// file.reader(io, buffer) - create reader for streaming
            \\// deleteFile(io, path) - delete file
            \\// createDir(io, path, .default_dir) - create directory
            \\// openDir(io, path, .{}) - open directory
            \\
            \\## Async Operations
            \\// File I/O in std.Io is SYNCHRONOUS by default
            \\// For async computation, use Io.async():
            \\
            \\fn compute-heavy(n: u32) u64 {
            \\    var sum: u64 = 0;
            \\    for (0..n) |i| sum += i;
            \\    return sum;
            \\}
            \\
            \\pub fn main(init: std.process.Init) !void {
            \\    const io = init.io;
            \\
            \\    // ASYNC computation (not file I/O)
            \\    var future1 = io.async(compute-heavy, .{100_000});
            \\    var future2 = io.async(compute-heavy, .{100_000});
            \\
            \\    const r1 = future1.await(io);
            \\    const r2 = future2.await(io);
            \\    _ = r1 + r2;
            \\}
            \\
            \\## Sync vs Async Summary
            \\| Operation | Type | Notes |
            \\|-----------|------|-------|
            \\| readFileAlloc | Sync | Blocks until complete |
            \\| writeStreamingAll | Sync | Blocks until complete |
            \\| file.reader | Sync | Streaming read |
            \\| io.async() | Async | For computation |
            \\| future.await() | Async | Wait for async result |
            \\
            \\## API Differences (OLD vs NEW)
            \\// OLD (DEPRECATED):
            \\//   std.fs.cwd().readFileAlloc(allocator, path, max)
            \\//   file.close()
            \\//   std.fs.cwd().createFile(path, .{})
            \\//
            \\// NEW (use this):
            \\//   std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max))
            \\//   file.close(io)
            \\//   std.Io.Dir.cwd().createFile(io, path, .{})
        );
    } else if (std.mem.eql(u8, pattern, "iommi")) {
        return allocator.dupe(u8,
            \\# IOMMI Mode - Simple Game Development
            \\
            \\For IOMMI mode (simple single-file games), use grape-mcp instead:
            \\- Tool: grape_patterns with pattern="iommi"
            \\- Resource: grape://patterns/iommi
            \\- Or: grape://patterns/territory for full game mode
            \\
            \\IOMMI is Grape Cake's simple game mode:
            \\- Single main.zig file, no dynamic library
            \\- Use grape.run() with .initIommi and .updateIommi
            \\- ctx.dt is a FIELD (not method!)
            \\- ctx.getAxis() DOES NOT EXIST
            \\
            \\Quick example:
            \\const grape = @import("grape_cake");
            \\
            \\pub fn main() !void {
            \\    try grape.run(.{
            \\        .title = "My Game",
            \\        .initIommi = init,
            \\        .updateIommi = update,
            \\    });
            \\}
            \\
            \\fn init(ctx: *grape.Iommi) !void {
            \\    try ctx.registerAction("jump", &.{grape.KEY_SPACE});
            \\}
            \\
            \\fn update(ctx: *grape.Iommi) void {
            \\    const dt = ctx.dt;
            \\    if (ctx.isDown("left")) player.x -= 100 * dt;
            \\    ctx.drawRect(x, y, w, h, grape.RED);  // f32 params!
            \\}
            \\
            \\# For full IOMMI documentation, use grape-mcp!
        );
    } else if (std.mem.eql(u8, pattern, "package")) {
        return allocator.dupe(u8,
            \\ZON Package Manifest (build.zig.zon)
            \\=====================================
            \\IMPORTANT: Use enum literals (.name) not strings ("name")!
            \\.{
            \\    .name = .my_project,           // Enum literal!
            \\    .version = "0.1.0",
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{
            \\        // .dep_name = .{
            \\        //     .url = "https://...",
            \\        //     .hash = "1220...",
            \\        // },
            \\    },
            \\    .paths = .{"src", "build.zig"},
            \\}
            \\Run: zig fetch --save <url> to get hash
        );
    } else if (std.mem.eql(u8, pattern, "static_lib")) {
        return allocator.dupe(u8,
            \\Static Library Build (Zig 0.16)
            \\===============================
            \\const lib = b.addLibrary(.{
            \\    .name = "mylib",
            \\    .root_module = b.createModule(.{
            \\        .root_source_file = b.path("src/lib.zig"),
            \\    }),
            \\    .linkage = .static,  // NOT "static_library"!
            \\});
            \\b.installArtifact(lib);
            \\Key: b.addLibrary (NOT b.addStaticLibrary)
        );
    } else if (std.mem.eql(u8, pattern, "dynamic_lib")) {
        return allocator.dupe(u8,
            \\Dynamic Library Build (Zig 0.16)
            \\================================
            \\const lib = b.addLibrary(.{
            \\    .name = "mylib",
            \\    .root_module = b.createModule(.{
            \\        .root_source_file = b.path("src/lib.zig"),
            \\    }),
            \\    .linkage = .dynamic,
            \\});
            \\lib.linkSystemLibrary("ssl");  // System libs
            \\b.installArtifact(lib);
        );
    } else if (std.mem.eql(u8, pattern, "multimodule")) {
        return allocator.dupe(u8,
            \\Multi-Module Project (Zig 0.16)
            \\=================================
            \\// Module 1
            \\const core = b.createModule(.{
            \\    .root_source_file = b.path("src/core.zig"),
            \\});
            \\// Module 2 (depends on core)
            \\const utils = b.createModule(.{
            \\    .root_source_file = b.path("src/utils.zig"),
            \\    .imports = &.{ .{ .name = "core", .module = core } },
            \\});
            \\// Executable
            \\const exe = b.addExecutable(.{
            \\    .root_module = b.createModule(.{
            \\        .imports = &.{ .{ .name = "utils", .module = utils } },
            \\    }),
            \\});
        );
    } else if (std.mem.eql(u8, pattern, "arraylist")) {
        try list.appendSlice(allocator,
            \\\n            \\ArrayList Patterns in Zig 0.16
            \\==============================
            \\n            \\const std = @import("std");
            \\n            \\pub fn main() !void {
            \\    const allocator = std.heap.page_allocator;
            \\    
            \\    // ========================================
            \\    // TWO WAYS TO INITIALIZE (both valid):
            \\    // ========================================
            \\    
            \\    // WAY 1: .empty (simple, grows dynamically)
            \\    var list: std.ArrayList(u32) = .empty;
            \\    
            \\    // WAY 2: initCapacity (pre-allocate, better performance)
            \\    // var list = try std.ArrayList(u32).initCapacity(allocator, 100);
            \\    
            \\    // ========================================
            \\    // ADDING ITEMS - ALWAYS pass allocator!
            \\    // ========================================
            \\    
            \\    // Add single items
            \\    try list.append(allocator, 10);
            \\    try list.append(allocator, 20);
            \\    
            \\    // Add multiple items at once
            \\    try list.appendSlice(allocator, &[_]u32{ 30, 40, 50 });
            \\    
            \\    // ========================================
            \\    // ACCESSING ITEMS
            \\    // ========================================
            \\    const first = list.items[0];           // Direct index
            \\    const len = list.items.len;             // Get length
            \\    const last = list.getLast();            // Get last item
            \\    
            \\    // ========================================
            \\    // ITERATING
            \\    // ========================================
            \\    for (list.items) |item| {
            \\        std.debug.print("{d}\\n", .{item});
            \\    }
            \\    
            \\    // With index
            \\    for (list.items, 0..) |item, i| {
            \\        std.debug.print("[{d}] = {d}\\n", .{ i, item });
            \\    }
            \\    
            \\    // ========================================
            \\    // REMOVING ITEMS
            \\    // ========================================
            \\    const removed = list.pop();             // Remove and return last
            \\    list.clearRetainingCapacity();          // Clear but keep memory
            \\    list.clearAndFree(allocator);           // Clear and free memory
            \\    
            \\    // ========================================
            \\    // CLEANUP - ALWAYS pass allocator!
            \\    // ========================================
            \\    list.deinit(allocator);
            \\}
            \\n            \\When to use each initialization:
            \\----------------------------------
            \\Use .empty when:
            \\  - You don't know the final size
            \\  - The list will be small
            \\  - Simplicity is preferred
            \\
            \\Use initCapacity(allocator, size) when:
            \\  - You know the approximate size
            \\  - Performance is critical
            \\  - Avoiding reallocations matters
            \\  Example: Reading a file with known line count
            \\  var lines = try std.ArrayList([]const u8).initCapacity(allocator, line_count);
            \\n            \\Key Points:
            \\-----------
            \\1. Both .empty and initCapacity() work - choose based on needs
            \\2. append(allocator, item) - Add single item
            \\3. appendSlice(allocator, slice) - Add multiple items at once
            \\4. deinit(allocator) - Cleanup (always required!)
            \\5. Access items via list.items array
        );
    } else if (std.mem.eql(u8, pattern, "hashmap")) {
        try list.appendSlice(allocator,
            \\\n            \\HashMap Patterns in Zig 0.16
            \\=============================
            \\n            \\const std = @import("std");
            \\n            \\pub fn main() !void {
            \\    const allocator = std.heap.page_allocator;
            \\    
            \\    // Initialize with .empty
            \\    var map: std.StringHashMap(u32) = .empty;
            \\    
            \\    // Insert items - ALWAYS pass allocator!
            \\    try map.put(allocator, "answer", 42);
            \\    try map.put(allocator, "count", 100);
            \\    
            \\    // Get values
            \\    if (map.get("answer")) |value| {
            \\        std.debug.print("Answer: {}\\n", .{value});
            \\    }
            \\    
            \\    // Check existence
            \\    if (map.contains("answer")) {
            \\        std.debug.print("Key exists!\\n", .{});
            \\    }
            \\    
            \\    // Get with default
            \\    const value = map.get("missing") orelse 0;
            \\    
            \\    // Remove
            \\    const removed = map.remove("answer");
            \\    
            \\    // Iteration
            \\    var iter = map.iterator();
            \\    while (iter.next()) |entry| {
            \\        const key = entry.key_ptr.*;
            \\        const val = entry.value_ptr.*;
            \\        std.debug.print("{s} = {}\\n", .{ key, val });
            \\    }
            \\    
            \\    // Count
            \\    const count = map.count();
            \\    
            \\    // Clear
            \\    map.clearRetainingCapacity();
            \\    map.clearAndFree(allocator);
            \\    
            \\    // Cleanup - ALWAYS pass allocator!
            \\    map.deinit(allocator);
            \\}
            \\n            \\Key Points:
            \\-----------
            \\1. Initialize with .empty
            \\2. put(allocator, key, value) - requires allocator parameter
            \\3. get(key) returns ?V (optional)
            \\4. contains(key) returns bool
            \\5. remove(key) returns ?V (removed value)
            \\6. Use iterator() to traverse all entries
            \\7. deinit(allocator) - requires allocator parameter
        );
    } else if (std.mem.eql(u8, pattern, "json")) {
        try list.appendSlice(allocator,
            \\\n            \\JSON Patterns in Zig 0.16
            \\==========================
            \\n            \\const std = @import("std");
            \\n            \\const Person = struct {
            \\    name: []const u8,
            \\    age: u32,
            \\};
            \\n            \\pub fn main() !void {
            \\    const allocator = std.heap.page_allocator;
            \\    
            \\    // ========================================
            \\    // Parsing JSON to Struct
            \\    // ========================================
            \\    const json_str = \\\"{\\\"name\\\":\\\"Alice\\\",\\\"age\\\":30}\\\";
            \\    
            \\    var parsed = try std.json.parseFromSlice(Person, allocator, json_str, .{});
            \\    defer parsed.deinit();  // ALWAYS deinit!
            \\    
            \\    const person = parsed.value;
            \\    std.debug.print("Name: {s}, Age: {}\\n", .{ person.name, person.age });
            \\    
            \\    // ========================================
            \\    // Parsing Dynamic JSON (nested objects)
            \\    // ========================================
            \\    const complex_json = \\\"{\\\"users\\\":[{\\\"name\\\":\\\"Bob\\\"}],\\\"count\\\":1}\\\";
            \\    
            \\    var dynamic = try std.json.parseFromSlice(std.json.Value, allocator, complex_json, .{});
            \\    defer dynamic.deinit();
            \\    
            \\    // Access nested data
            \\    const users = dynamic.value.object.get("users").?.array;
            \\    const count = dynamic.value.object.get("count").?.integer;
            \\    const first_user = users.items[0].object.get("name").?.string;
            \\    
            \\    // ========================================
            \\    // Stringify Struct to JSON
            \\    // ========================================
            \\    const new_person = Person{ .name = "Charlie", .age = 25 };
            \\    
            \\    const json_output = try std.json.stringifyAlloc(allocator, new_person, .{});
            \\    defer allocator.free(json_output);  // ALWAYS free!
            \\    
            \\    std.debug.print("JSON: {s}\\n", .{json_output});
            \\    
            \\    // With formatting
            \\    const pretty_json = try std.json.stringifyAlloc(allocator, new_person, .{ .whitespace = .indent_2 });
            \\    defer allocator.free(pretty_json);
            \\}
            \\n            \\Key Points:
            \\-----------
            \\1. Define struct matching your JSON structure
            \\2. parseFromSlice(Type, allocator, json_str, .{}) - parse to struct
            \\3. parseFromSlice(std.json.Value, ...) - parse to dynamic value
            \\4. ALWAYS call parsed.deinit() to free memory
            \\5. stringifyAlloc(allocator, value, .{}) - convert to JSON string
            \\6. ALWAYS free the returned string with allocator.free()
            \\7. Use .whitespace option for pretty printing
        );
    } else if (std.mem.eql(u8, pattern, "io")) {
        try list.appendSlice(allocator,
            \\\n            \\I/O Patterns in Zig 0.16
            \\========================
            \\n            \\const std = @import("std");
            \\const Io = std.Io;
            \\n            \\pub fn main(init: std.process.Init) !void {
            \\    const io = init.io;
            \\    const allocator = init.arena.allocator();
            \\    
            \\    // ========================================
            \\    // Reading from stdin
            \\    // ========================================
            \\    var stdin_buffer: [4096]u8 = undefined;
            \\    var stdin_reader: Io.File.Reader = .init(Io.File.stdin(), io, &stdin_buffer);
            \\    const reader = &stdin_reader.interface;
            \\    
            \\    // Read until newline
            \\    const line = reader.takeDelimiterInclusive('\\n') catch |err| {
            \\        if (err == error.EndOfStream) return;
            \\        return err;
            \\    };
            \\    std.debug.print("Read: {s}\\n", .{line});
            \\    
            \\    // Read exact number of bytes
            \\    var buf: [100]u8 = undefined;
            \\    const bytes_read = try reader.readAll(&buf);
            \\    
            \\    // ========================================
            \\    // Writing to stdout
            \\    // ========================================
            \\    var stdout_buffer: [4096]u8 = undefined;
            \\    var stdout_writer: Io.File.Writer = .init(Io.File.stdout(), io, &stdout_buffer);
            \\    const writer = &stdout_writer.interface;
            \\    
            \\    try writer.writeAll("Hello, world!\\n");
            \\    try writer.print("Number: {}\\n", .{42});
            \\    try writer.flush();  // IMPORTANT: Always flush!
            \\    
            \\    // ========================================
            \\    // Writing to stderr (for logging)
            \\    // ========================================
            \\    var stderr_buffer: [4096]u8 = undefined;
            \\    var stderr_writer: Io.File.Writer = .init(Io.File.stderr(), io, &stderr_buffer);
            \\    const stderr = &stderr_writer.interface;
            \\    
            \\    try stderr.print("[DEBUG] Value: {}\\n", .{42});
            \\    try stderr.flush();
            \\    
            \\    // ========================================
            \\    // File operations
            \\    // ========================================
            \\    // Read entire file
            \\    const file_content = try std.fs.cwd().readFileAlloc(allocator, "input.txt", 1024 * 1024);
            \\    defer allocator.free(file_content);
            \\    
            \\    // Write to file
            \\    const file = try std.fs.cwd().createFile("output.txt", .{});
            \\    defer file.close();
            \\    try file.writeAll("Hello, file!");
            \\}
            \\n            \\Key Points:
            \\-----------
            \\1. Main signature: pub fn main(init: std.process.Init) !void
            \\2. Get io from init.io
            \\3. Create Reader/Writer with buffer and io
            \\4. Always flush after writing to stdout
            \\5. Use stderr for logging (doesn't interfere with output)
            \\6. Use reader.takeDelimiterInclusive() for line-based input
            \\7. File operations use std.fs.cwd()
        );
    } else if (std.mem.eql(u8, pattern, "allocator")) {
        try list.appendSlice(allocator,
            \\\n            \\Allocator Patterns in Zig 0.16
            \\==============================
            \\n            \\const std = @import("std");
            \\n            \\pub fn main(init: std.process.Init) !void {
            \\    // ========================================
            \\    // Arena allocator (recommended for main)
            \\    // ========================================
            \\    const allocator = init.arena.allocator();
            \\    
            \\    // Allocate memory
            \\    const buf = try allocator.alloc(u8, 100);
            \\    defer allocator.free(buf);
            \\    
            \\    // Reallocate
            \\    const bigger_buf = try allocator.realloc(buf, 200);
            \\    defer allocator.free(bigger_buf);
            \\    
            \\    // ========================================
            \\    // Other allocators
            \\    // ========================================
            \\    
            \\    // Page allocator (simplest, slow)
            \\    const page_alloc = std.heap.page_allocator;
            \\    
            \\    // General purpose allocator (debugging features)
            \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            \\    const gpa_alloc = gpa.allocator();
            \\    defer _ = gpa.deinit();
            \\    
            \\    // Fixed buffer allocator (no heap, stack only)
            \\    var buffer: [1024]u8 = undefined;
            \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
            \\    const fba_alloc = fba.allocator();
            \\}
            \\n            \\// ========================================
            \\// Using allocators with data structures
            \\// ========================================
            \\fn exampleWithDataStructures(allocator: std.mem.Allocator) !void {
            \\    // ArrayList
            \\    var list: std.ArrayList(u32) = .empty;
            \\    try list.append(allocator, 10);  // Pass allocator!
            \\    list.deinit(allocator);           // Pass allocator!
            \\    
            \\    // HashMap
            \\    var map: std.StringHashMap(u32) = .empty;
            \\    try map.put(allocator, "key", 42);  // Pass allocator!
            \\    map.deinit(allocator);               // Pass allocator!
            \\    
            \\    // String
            \\    var str = try std.ArrayList(u8).initCapacity(allocator, 100);
            \\    try str.appendSlice(allocator, "Hello");
            \\    const final_str = try str.toOwnedSlice(allocator);
            \\    defer allocator.free(final_str);
            \\}
            \\n            \\Key Points:
            \\-----------
            \\1. Pass allocator to ALL data structure methods that allocate
            \\2. Always free memory with allocator.free() or deinit(allocator)
            \\3. Use defer to ensure cleanup happens
            \\4. init.arena.allocator() is best for main() functions
            \\5. GeneralPurposeAllocator helps detect memory leaks
            \\6. Page allocator is simplest but slower
        );
    } else if (std.mem.eql(u8, pattern, "error_handling")) {
        try list.appendSlice(allocator,
            \\\n            \\Error Handling in Zig 0.16
            \\=========================
            \\n            \\const std = @import("std");
            \\n            \\fn mayFail() !u32 {
            \\    return error.SomeError;
            \\}
            \\n            \\fn returnsOptional() ?u32 {
            \\    return null;
            \\}
            \\n            \\pub fn main() !void {
            \\    // ========================================
            \\    // Try-catch with catch
            \\    // ========================================
            \\    const result = mayFail() catch |err| {
            \\        std.log.err("Error occurred: {}", .{err});
            \\        return err;  // Re-throw
            \\    };
            \\    
            \\    // Catch with default value
            \\    const value = mayFail() catch 42;
            \\    
            \\    // ========================================
            \\    // If-else with error
            \\    // ========================================
            \\    if (mayFail()) |val| {
            \\        std.debug.print("Success: {}\\n", .{val});
            \\    } else |err| {
            \\        std.debug.print("Failed: {}\\n", .{err});
            \\    }
            \\    
            \\    // ========================================
            \\    // while with error
            \\    // ========================================
            \\    // while (condition) |val| {
            \\    //     // use val
            \\    // } else |err| {
            \\    //     // handle error
            \\    }
            \\    
            \\    // ========================================
            \\    // Optional unwrapping
            \\    // ========================================
            \\    if (returnsOptional()) |val| {
            \\        std.debug.print("Value: {}\\n", .{val});
            \\    } else {
            \\        std.debug.print("Value is null\\n", .{});
            \\    }
            \\    
            \\    // Orelse for default
            \\    const opt_val = returnsOptional() orelse 0;
            \\    
            \\    // Orelse with block
            \\    const block_val = returnsOptional() orelse blk: {
            \\        std.debug.print("Computing default...\\n", .{});
            \\        break :blk 42;
            \\    };
            \\    
            \\    // ========================================
            \\    // try shorthand
            \\    // ========================================
            \\    const tried = try mayFail();  // Returns error or unwraps
            \\    
            \\    // try with catch
            \\    const caught = try mayFail() catch |err| {
            \\        std.log.err("Caught: {}", .{err});
            \\        return err;
            \\    };
            \\}
            \\n            \\Key Points:
            \\-----------
            \\1. catch |err| - catch errors and handle them
            \\2. catch default - use default value on error
            \\3. if-else |err| - handle success and error cases
            \\4. orelse - unwrap optional or use default
            \\5. try - shorthand for error propagation
            \\6. defer - cleanup regardless of error
            \\7. errdefer - cleanup only on error
        );
    } else if (std.mem.eql(u8, pattern, "build_template")) {
        try list.appendSlice(allocator,
            \\\n            \\build.zig Template
            \\==================
            \\n            \\const std = @import("std");
            \\n            \\pub fn build(b: *std.Build) void {
            \\    // Standard target and optimization options
            \\    const target = b.standardTargetOptions(.{});
            \\    const optimize = b.standardOptimizeOption(.{});
            \\    
            \\    // ========================================
            \\    // Create executable
            \\    // ========================================
            \\    const exe = b.addExecutable(.{
            \\        .name = "my-app",
            \\        .root_module = b.createModule(.{
            \\            .root_source_file = b.path("src/main.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }),
            \\    });
            \\    
            \\    // Install the executable
            \\    b.installArtifact(exe);
            \\    
            \\    // ========================================
            \\    // Run command
            \\    // ========================================
            \\    const run_step = b.step("run", "Run the app");
            \\    const run_cmd = b.addRunArtifact(exe);
            \\    run_step.dependOn(&run_cmd.step);
            \\    
            \\    // Pass arguments to run
            \\    if (b.args) |args| {
            \\        run_cmd.addArgs(args);
            \\    }
            \\    
            \\    // ========================================
            \\    // Tests
            \\    // ========================================
            \\    const exe_unit_tests = b.addTest(.{
            \\        .root_module = exe.root_module,
            \\    });
            \\    
            \\    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
            \\    const test_step = b.step("test", "Run unit tests");
            \\    test_step.dependOn(&run_exe_unit_tests.step);
            \\}
        );
    } else if (std.mem.eql(u8, pattern, "zon_template")) {
        try list.appendSlice(allocator,
            \\\n            \\build.zig.zon Template
            \\=======================
            \\n            \\.{
            \\    .name = "my-project",
            \\    .version = "0.1.0",
            \\    .minimum_zig_version = "0.16.0",
            \\    
            \\    // Dependencies
            \\    .dependencies = .{
            \\        // Example dependency:
            \\        // .clap = .{
            \\        //     .url = "https://github.com/Hejsil/zig-clap/archive/refs/tags/0.10.0.tar.gz",
            \\        //     .hash = "1220...",
            \\        // },
            \\    },
            \\    
            \\    // Paths included in package
            \\    .paths = .{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "LICENSE",
            \\        "README.md",
            \\    },
            \\}
        );
    } else if (std.mem.eql(u8, pattern, "threads")) {
        try list.appendSlice(allocator,
            \\\n            \\Threading & Synchronization in Zig 0.16
            \\==========================================
            \\IMPORTANT: This covers BOTH std.Thread AND std.Io APIs
            \\n            \\const std = @import("std");
            \\
            \\pub fn main(init: std.process.Init) !void {
            \\    const io = init.io;
            \\    const allocator = init.arena.allocator();
            \\
            \\    // ========================================
            \\    // 1. THREAD.SPAWN + JOIN (basic threads)
            \\    // ========================================
            \\    fn minhaFuncao(param: u32) void {
            \\        std.debug.print("thread {} running\\n", .{param});
            \\    }
            \\
            \\    const t1 = try std.Thread.spawn(.{}, minhaFuncao, .{1});
            \\    defer t1.join();
            \\
            \\    const t2 = try std.Thread.spawn(.{}, minhaFuncao, .{2});
            \\    defer t2.join();
            \\    // join() blocks main until thread finishes
            \\
            \\    // ========================================
            \\    // 2. MUTEX - Mutual Exclusion
            \\    // ========================================
            \\    // std.Io.Mutex - Zig 0.16 API
            \\    // std.Thread.Mutex DOES NOT EXIST!
            \\    const ThreadSafeCounter = struct {
            \\        mutex: std.Io.Mutex = std.Io.Mutex.init,
            \\        value: u32 = 0,
            \\
            \\        pub fn increment(self: *@This(), io: std.Io) !void {
            \\            try self.mutex.lock(io);
            \\            defer self.mutex.unlock(io);
            \\            self.value += 1;
            \\        }
            \\    };
            \\
            \\    // ========================================
            \\    // 3. TRYLOCK vs LOCK
            \\    // ========================================
            \\    var mutex: std.Io.Mutex = .init;
            \\    defer mutex.deinit();
            \\
            \\    // lock() - blocks until acquired
            \\    try mutex.lock(io);
            \\    defer mutex.unlock(io);
            \\    // ... critical section ...
            \\
            \\    // tryLock() - non-blocking, returns bool
            \\    if (mutex.tryLock()) {
            \\        defer mutex.unlock(io);
            \\        // ... critical section ...
            \\    } else {
            \\        // could not acquire - do something else
            \\    }
            \\
            \\    // ========================================
            \\    // 4. IO.GROUP - Concurrency (replaces Thread.Pool)
            \\    // ========================================
            \\    // std.Thread.Pool DOES NOT EXIST in 0.16!
            \\    // std.Thread.WaitGroup DOES NOT EXIST in 0.16!
            \\    // Use std.Io.Group + group.concurrent()
            \\
            \\    fn tarefa(io: std.Io, id: u32) void {
            \\        _ = io;
            \\        std.debug.print("task {} running\\n", .{id});
            \\    }
            \\
            \\    var group: std.Io.Group = .init;
            \\    defer group.deinit();
            \\
            \\    try group.concurrent(io, tarefa, .{ io, 1 });
            \\    try group.concurrent(io, tarefa, .{ io, 2 });
            \\    try group.concurrent(io, tarefa, .{ io, 3 });
            \\
            \\    try group.await(io); // wait for all tasks
            \\
            \\    // ========================================
            \\    // 5. COMPLETE EXAMPLE - Thread-safe counter
            \\    // ========================================
            \\    const Counter = struct {
            \\        mutex: std.Io.Mutex = std.Io.Mutex.init,
            \\        value: u32 = 0,
            \\
            \\        pub fn inc(self: *@This(), io: std.Io) !void {
            \\            try self.mutex.lock(io);
            \\            defer self.mutex.unlock(io);
            \\            self.value += 1;
            \\        }
            \\    };
            \\
            \\    fn worker(counter: *Counter, io: std.Io, times: u32) void {
            \\        for (0..times) |_| {
            \\            counter.inc(io) catch return;
            \\        }
            \\    }
            \\
            \\    var counter = Counter{};
            \\    var group2: std.Io.Group = .init;
            \\    defer group2.deinit();
            \\
            \\    try group2.concurrent(io, worker, .{ &counter, io, 1000 });
            \\    try group2.concurrent(io, worker, .{ &counter, io, 2000 });
            \\    try group2.concurrent(io, worker, .{ &counter, io, 3000 });
            \\
            \\    try group2.await(io);
            \\
            \\    std.debug.print("Total: {}\\n", .{counter.value}); // should be 6000
            \\}
            \\n            \\## Migration Guide: 0.11/0.12 -> 0.16
            \\------------------------------------
            \\| Old (0.11/0.12)    | New (0.16)              |
            \\|-------------------|--------------------------|
            \\| std.Thread.Mutex  | std.Io.Mutex            |
            \\| Mutex{}           | std.Io.Mutex.init       |
            \\| mutex.lock()      | try mutex.lock(io)      |
            \\| std.Thread.Pool   | std.Io.Group            |
            \\| std.Thread.WaitGroup | std.Io.Group + await |
            \\| pub fn main() !void | pub fn main(init: std.process.Init) !void |
            \\n            \\## Key Concepts
            \\---------------
            \\- spawn: creates a thread
            \\- join: waits for thread to finish
            \\- lock/unlock: protects critical section (only one thread at a time)
            \\- tryLock: non-blocking attempt, returns bool
            \\- concurrent: spawns task in event loop
            \\- group.await: waits for all tasks in group to finish
            \\n            \\## Key Points:
            \\-----------
            \\1. std.Thread.spawn for basic thread creation
            \\2. std.Io.Group for managed task concurrency
            \\3. std.Io.Mutex for protecting shared state (NOT std.Thread.Mutex!)
            \\4. std.Io.Condition for wait/notify patterns
            \\5. tryLock() returns bool, lock() blocks
            \\6. Always unlock in defer or after critical section
            \\7. Pass Io context to all async operations
            \\8. main() signature: pub fn main(init: std.process.Init) !void
        );
    } else if (std.mem.eql(u8, pattern, "time")) {
        try list.appendSlice(allocator,
            \\\n            \\Time APIs in Zig 0.16 (std.Io)
            \\================================
            \\Complete guide with std.Io.Timestamp, std.Io.Duration, and std.Io.Clock
            \\n            \\const std = @import("std");
            \\n            \\pub fn main(init: std.process.Init) !void {
            \\    const io = init.io;
            \\    
            \\    // ========================================
            \\    // CLOCK - Get current timestamp
            \\    // ========================================
            \\    const timestamp = std.Io.Clock.now(.real, io);
            \\    const seconds = timestamp.toSeconds();      // i64
            \\    const millis = timestamp.toMilliseconds();  // i64
            \\    const nanos = timestamp.toNanoseconds();    // i96
            \\
            \\    // ========================================
            \\    // TIMESTAMP OPERATIONS
            \\    // ========================================
            \\    const ts_from_ns = std.Io.Timestamp.fromNanoseconds(1_000_000_000);
            \\    const duration = timestamp.durationTo(ts_from_ns);
            \\    const later = timestamp.addDuration(duration);
            \\    const earlier = timestamp.subDuration(duration);
            \\
            \\    // ========================================
            \\    // DURATION - Time intervals
            \\    // ========================================
            \\    const one_second = std.Io.Duration.fromSeconds(1);
            \\    const one_milli = std.Io.Duration.fromMilliseconds(1000);
            \\    const one_nano = std.Io.Duration.fromNanoseconds(1_000_000_000);
            \\    const zero_duration = std.Io.Duration.zero;
            \\    const max_duration = std.Io.Duration.max;
            \\
            \\    // ========================================
            \\    // SLEEP & DELAY (3 ways)
            \\    // ========================================
            \\    // Way 1: Io.sleep() - recommended
            \\    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real);
            \\
            \\    // Way 2: Clock.Timestamp.wait() - wait until specific time
            \\    const target = timestamp.addDuration(std.Io.Duration.fromMilliseconds(300));
            \\    try target.withClock(.real).wait(io);
            \\
            \\    // Way 3: POSIX nanosleep
            \\    var timespec: std.posix.timespec = .{ .sec = 0, .nsec = 200_000_000 };
            \\    _ = std.posix.system.nanosleep(&timespec, &timespec);
            \\    
            \\    // ========================================
            \\    // CLOCK TYPES
            \\    // ========================================
            \\    const real_ts = std.Io.Clock.now(.real, io);
            \\    const awake_ts = std.Io.Clock.now(.awake, io);
            \\    const boot_ts = std.Io.Clock.now(.boot, io);
            \\    const cpu_proc_ts = std.Io.Clock.now(.cpu_process, io);
            \\    const cpu_thread_ts = std.Io.Clock.now(.cpu_thread, io);
            \\    
            \\    // ========================================
            \\    // CLOCK-SPECIFIC TIMESTAMP
            \\    // ========================================
            \\    const clock_ts = std.Io.Clock.Timestamp.now(io, .real);
            \\    const time_remaining = clock_ts.durationFromNow(io);
            \\    const time_elapsed = clock_ts.untilNow(io);
            \\}
            \\n            \\## Key Types
            \\// std.Io.Timestamp - Raw timestamp (nanoseconds since epoch)
            \\//   .now(io, clock)              - Get current time
            \\//   .fromNanoseconds(ns)         - Create from nanoseconds
            \\//   .toSeconds()                 - Convert to seconds (i64)
            \\//   .toMilliseconds()            - Convert to milliseconds (i64)
            \\//   .toNanoseconds()             - Convert to nanoseconds (i96)
            \\//   .durationTo(other)           - Duration between timestamps
            \\//   .addDuration(d)              - Add duration to timestamp
            \\//   .subDuration(d)              - Subtract duration
            \\//   .withClock(clock)            - Add clock context
            \\//   .zero                        - Zero timestamp constant
            \\//
            \\// std.Io.Clock.Timestamp - Clock-aware timestamp
            \\//   .now(io, clock)              - Get current time with clock context
            \\//   .wait(io)                    - Sleep until this time
            \\//   .toClock(io, clock)          - Convert to different clock
            \\//   .durationFromNow(io)         - Time until this timestamp
            \\//   .untilNow(io)                - Time since this timestamp
            \\//   .addDuration(d)              - Add duration
            \\//   .subDuration(d)              - Subtract duration
            \\//   .durationTo(other)           - Duration to another timestamp
            \\//
            \\// std.Io.Duration - Time intervals
            \\//   .fromSeconds(s)              - Create from seconds
            \\//   .fromMilliseconds(ms)        - Create from milliseconds
            \\//   .fromNanoseconds(ns)         - Create from nanoseconds
            \\//   .toSeconds()                 - Convert to seconds
            \\//   .toMilliseconds()            - Convert to milliseconds
            \\//   .zero                        - Zero duration
            \\//   .max                         - Maximum duration
            \\//
            \\// std.Io.Clock.Duration - Clock-aware duration
            \\//   .sleep(io)                   - Sleep on specific clock
            \\//
            \\// Clock Types:
            \\//   .real         - Wall clock (Unix epoch, affected by NTP)
            \\//   .awake        - Monotonic, excludes suspend time
            \\//   .boot         - Monotonic, includes suspend time
            \\//   .cpu_process  - CPU time for process
            \\//   .cpu_thread   - CPU time for thread
            \\
            \\## Sleep & Delay Methods
            \\// Method 1: Io.sleep() - recommended
            \\try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real);
            \\
            \\// Method 2: Clock.Timestamp.wait()
            \\const target = timestamp.addDuration(std.Io.Duration.fromMilliseconds(300));
            \\try target.withClock(.real).wait(io);
            \\
            \\// Method 3: POSIX nanosleep
            \\var ts: std.posix.timespec = .{ .sec = 0, .nsec = 200_000_000 };
            \\_ = std.posix.system.nanosleep(&ts, &ts);
            \\
            \\## Complete Benchmark Example
            \\// Measure execution time with different clock types
            \\fn doWork() void {
            \\    var sum: u64 = 0;
            \\    for (0..1_000_000) |i| sum += i;
            \\    _ = sum;
            \\}
            \\
            \\pub fn main(init: std.process.Init) !void {
            \\    const io = init.io;
            \\    
            \\    // Warmup - run once before measuring
            \\    doWork();
            \\    
            \\    // Measure with different clocks
            \\    const real_start = std.Io.Clock.now(.real, io);
            \\    const cpu_start = std.Io.Clock.now(.cpu_process, io);
            \\    
            \\    doWork();
            \\    
            \\    const real_elapsed = real_start.durationTo(std.Io.Clock.now(.real, io));
            \\    const cpu_elapsed = cpu_start.durationTo(std.Io.Clock.now(.cpu_process, io));
            \\    
            \\    std.debug.print("Real time: {} ms\n", .{real_elapsed.toMilliseconds()});
            \\    std.debug.print("CPU time:  {} ms\n", .{cpu_elapsed.toMilliseconds()});
            \\}
            \\
            \\## Clock Selection Guide
            \\| Clock        | Use Case                                        |
            \\|--------------|------------------------------------------------|
            \\| `.real`      | Total elapsed time (wall-clock)                |
            \\| `.awake`     | Timeouts, rate limiting (not affected by NTP) |
            \\| `.boot`      | Time since system boot (includes suspend)       |
            \\| `.cpu_process` | Benchmark CPU usage (entire process)         |
            \\| `.cpu_thread`  | Benchmark CPU usage (single thread)        |
            \\
            \\## Key Points
            \\1. std.Io.Clock.now(clock, io) - Get current timestamp
            \\2. std.Io.Duration for time intervals (fromSeconds, fromMilliseconds)
            \\3. timestamp.toSeconds/Milliseconds/Nanoseconds() - conversions
            \\4. timestamp.durationTo(other) - time difference
            \\5. timestamp.addDuration/subDuration() - time arithmetic
            \\6. std.Io.sleep(io, duration, clock) - sleep (recommended)
            \\7. target.withClock(clock).wait(io) - wait until timestamp
            \\8. std.posix.system.nanosleep() - POSIX sleep
            \\9. Clock types: .real, .awake, .boot, .cpu_process, .cpu_thread
            \\10. Always warmup before benchmarking
            \\11. Compare .real vs .cpu_process to detect I/O wait time
        );
    } else {
        try list.appendSlice(allocator, "Unknown pattern. Use 'list' to see available patterns.");
    }

    return list.toOwnedSlice(allocator);
}

fn getResourcesDocumentation(allocator: std.mem.Allocator) ![]u8 {
    const resources_text =
        \\Zig MCP Server - Available Resources
        \\======================================
        \\
        \\This server provides the following MCP resources that you can read:
        \\
        \\PATTERNS (Code Examples):
        \\-------------------------
        \\zig://patterns/arraylist    - ArrayList usage with .empty, initCapacity, append
        \\zig://patterns/hashmap     - StringHashMap usage with put, get, iterator
        \\zig://patterns/json        - JSON parsing with parseFromSlice and stringifyAlloc
        \\zig://patterns/io          - I/O patterns with Reader, Writer, flush
        \\zig://patterns/allocator   - Arena, GPA, FixedBuffer allocators
        \\
        \\TEMPLATES:
        \\----------
        \\zig://templates/build.zig     - build.zig template for Zig 0.16
        \\zig://templates/build.zig.zon - Package manifest template
        \\
        \\GUIDELINES:
        \\-----------
        \\zig://guidelines/0.16    - Complete Zig 0.16 guidelines
        \\
        \\HOW TO USE RESOURCES:
        \\----------------------
        \\To read a resource, use the MCP resources/read method with the URI.
        \\Example: "Can you read zig://patterns/arraylist?"
        \\Or use tools: zig_patterns, zig_version, zig_build, zig_run
        \\
        \\AVAILABLE TOOLS:
        \\-----------------
        \\- zig_version     : Show Zig version
        \\- zig_build       : Build project
        \\- zig_run         : Run a .zig file
        \\- zig_patterns   : Get pattern documentation
        \\- zig_resources  : List all resources (this tool)
        \\- zig_help        : Show help and fallback commands
    ;
    return allocator.dupe(u8, resources_text);
}

fn getHelpDocumentation(allocator: std.mem.Allocator) ![]u8 {
    const help_text =
        \\Zig MCP Server - Help & Bash Fallback Commands
        \\================================================
        \\
        \\When MCP client fails or times out, use these bash commands:
        \\
        \\--------------------------------------------------
        \\1. LIST ALL AVAILABLE PATTERNS
        \\--------------------------------------------------
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"list"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -m json.tool
        \\
        \\--------------------------------------------------
        \\2. GET SPECIFIC PATTERN DOCUMENTATION
        \\--------------------------------------------------
        \\# ArrayList patterns
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"arraylist"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# HashMap patterns
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"hashmap"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# I/O patterns (stdin/stdout/stderr)
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"io"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# JSON patterns
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"json"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# Memory allocator patterns
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"allocator"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# Error handling patterns
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"error_handling"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# build.zig template
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"build_template"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# build.zig.zon template
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"zon_template"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\# Complete Zig 0.16 guidelines
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_patterns","arguments":{"pattern":"guidelines"}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\--------------------------------------------------
        \\3. LIST ALL TOOLS
        \\--------------------------------------------------
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -m json.tool
        \\
        \\--------------------------------------------------
        \\4. GET ZIG VERSION
        \\--------------------------------------------------
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_version","arguments":{}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\--------------------------------------------------
        \\5. BUILD ZIG PROJECT
        \\--------------------------------------------------
        \\echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zig_build","arguments":{}}}' | /home/seven/repos/zig/mcp/zig-out/bin/bruce 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
        \\
        \\--------------------------------------------------
        \\AVAILABLE PATTERNS:
        \\--------------------------------------------------
        \\  - arraylist      : ArrayList usage patterns
        \\  - hashmap        : HashMap usage patterns
        \\  - json           : JSON parsing/stringifying
        \\  - io             : I/O patterns (stdin/stdout/stderr)
        \\  - allocator      : Memory allocator patterns
        \\  - error_handling : Error handling techniques
        \\  - build_template : build.zig template
        \\  - zon_template   : build.zig.zon template
        \\  - guidelines     : Complete Zig 0.16 guidelines
        \\  - list           : Show all available patterns
        \\
        \\TIP: Save these commands to a script for easy access!
    ;
    return allocator.dupe(u8, help_text);
}

fn executeTool(init: std.process.Init, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ![]u8 {
    if (std.mem.eql(u8, name, "zig_version")) {
        return try runCommand(init, allocator, &.{ "zig", "version" });
    } else if (std.mem.eql(u8, name, "zig_build")) {
        return try runCommand(init, allocator, &.{ "zig", "build" });
    } else if (std.mem.eql(u8, name, "zig_run")) {
        const file = if (args) |a| a.object.get("file") else null;
        const file_str = if (file) |f| f.string else "";
        if (file_str.len == 0) {
            return try concatStrings(allocator, &.{"Error: No file provided"});
        }
        return try runCommand(init, allocator, &.{ "zig", "run", file_str });
    } else if (std.mem.eql(u8, name, "zig_test")) {
        return try runCommand(init, allocator, &.{ "zig", "test" });
    } else if (std.mem.eql(u8, name, "zig_fetch")) {
        return try runCommand(init, allocator, &.{ "zig", "fetch" });
    } else if (std.mem.eql(u8, name, "zig_fmt")) {
        const path = if (args) |a| a.object.get("path") else null;
        const path_str = if (path) |p| p.string else ".";
        return try runCommand(init, allocator, &.{ "zig", "fmt", path_str });
    } else if (std.mem.eql(u8, name, "zig_patterns")) {
        const pattern = if (args) |a| a.object.get("pattern") else null;
        const pattern_str = if (pattern) |p| p.string else "list";
        return try getPatternDocumentation(allocator, pattern_str);
    } else if (std.mem.eql(u8, name, "zig_resources")) {
        return try getResourcesDocumentation(allocator);
    } else if (std.mem.eql(u8, name, "zig_help")) {
        return try getHelpDocumentation(allocator);
    } else {
        return try concatStrings(allocator, &.{ "Unknown tool: ", name });
    }
}

fn runCommand(init: std.process.Init, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const io = init.io;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    _ = try child.wait(io);

    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    // Read stdout
    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        var reader = stdout_file.reader(io, &buf);
        const r = &reader.interface;
        r.appendRemainingUnlimited(allocator, &stdout_list) catch {};
        stdout_file.close(io);
    }

    // Read stderr
    if (child.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        var reader = stderr_file.reader(io, &buf);
        const r = &reader.interface;
        r.appendRemainingUnlimited(allocator, &stderr_list) catch {};
        stderr_file.close(io);
    }

    const stdout = try stdout_list.toOwnedSlice(allocator);
    defer allocator.free(stdout);
    const stderr = try stderr_list.toOwnedSlice(allocator);
    defer allocator.free(stderr);

    if (stdout.len > 0) {
        return try concatStrings(allocator, &.{ stdout, "\n", stderr });
    }
    return stderr;
}

fn concatStrings(allocator: std.mem.Allocator, slices: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (slices) |s| total_len += s.len;

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (slices) |s| {
        @memcpy(result[offset..][0..s.len], s);
        offset += s.len;
    }
    return result;
}
