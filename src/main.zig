const std = @import("std");
const Io = std.Io;

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

    while (true) {
        const line = stdin_reader.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            try stderr_writer.print("Error reading line: {}\n", .{err});
            break;
        };

        if (line.len == 0) continue;

        try stderr_writer.print("Received: {s}\n", .{line});

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            try stderr_writer.print("Error parsing JSON: {}\n", .{err});
            continue;
        };
        defer parsed.deinit();

        const value = parsed.value;

        const method = if (value.object.get("method")) |m| m.string else continue;
        const id = value.object.get("id");

        if (std.mem.eql(u8, method, "initialize")) {
            const response = try buildInitializeResponse(allocator, id);
            defer allocator.free(response);

            try stderr_writer.print("Sending: {s}\n", .{response});
            try stdout_writer.writeAll(response);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
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
        } else if (std.mem.eql(u8, method, "initialized")) {
            // Notification, no response needed
        } else {
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

    try list.appendSlice(allocator, ",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"resources\":{}},\"serverInfo\":{\"name\":\"bruce\",\"version\":\"0.1.0\"}}}");

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
    try list.appendSlice(allocator, "{\"name\":\"zig_run\",\"description\":\"Run a Zig file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"Path to .zig file to run\"}},\"required\":[\"file\"]}}");

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

    try list.appendSlice(allocator, "{\"uri\":\"zig://guidelines/0.16\",\"name\":\"Zig 0.16 Guidelines\",\"description\":\"Complete guide to Zig 0.16 patterns, breaking changes, and best practices\",\"mimeType\":\"text/markdown\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/arraylist\",\"name\":\"ArrayList Patterns\",\"description\":\"Correct ArrayList usage in Zig 0.16 - stateless APIs\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/hashmap\",\"name\":\"HashMap Patterns\",\"description\":\"Correct HashMap/StringHashMap usage in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/io\",\"name\":\"I/O Patterns\",\"description\":\"std.io, Io.Reader, Io.Writer patterns in Zig 0.16\",\"mimeType\":\"text/zig\"},");
    try list.appendSlice(allocator, "{\"uri\":\"zig://patterns/allocator\",\"name\":\"Allocator Patterns\",\"description\":\"When to pass allocators, stored allocators, and arena allocators\",\"mimeType\":\"text/zig\"},");
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
        try list.appendSlice(allocator, ",\"contents\":[{\"uri\":\"");
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

        try list.appendSlice(allocator, "\"}]");
    } else {
        try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"Missing uri\"}");
    }

    try list.appendSlice(allocator, "}");

    return list.toOwnedSlice(allocator);
}

fn getResourceContent(uri: []const u8) []const u8 {
    if (std.mem.eql(u8, uri, "zig://guidelines/0.16")) {
        return 
        \\# Zig 0.16 Guidelines - Breaking Changes and Best Practices
        \\
        \\## Key Breaking Changes from 0.14.x
        \\
        \\### 1. std.io -> std.Io
        \\- Old: `std.io.Writer`, `std.io.Reader`
        \\- New: `std.Io.Writer`, `std.Io.Reader` (vtable-based interfaces)
        \\- Key difference: Requires explicit buffering and Io instance
        \\
        \\### 2. ArrayList/HashMap - Stateless Allocator
        \\- OLD (0.14): `list.append(allocator, item)` - no, wait - it was `list.append(item)` in 0.14
        \\- NEW (0.16): Methods store allocator internally
        \\- Usage: `list.append(item)` - NO allocator parameter in method calls!
        \\- Init: `var list: std.ArrayList(u8) = .empty;`
        \\- But for parsing: `std.json.parseFromSlice(std.json.Value, allocator, ...)`
        \\
        \\### 3. Child Process
        \\- Old: `std.process.Child.exec()` - removed
        \\- New: `std.process.spawn(io, .{ .argv = &.{...}, .stdout = .pipe })`
        \\- Requires `io` parameter from `init.io`
        \\
        \\### 4. File I/O
        \\- Old: `std.io.getStdIn()`, `getStdOut()`, `getStdErr()`
        \\- New: `Io.File.stdin()`, `Io.File.stdout()`, `Io.File.stderr()`
        \\- Reader/Writer require buffer and Io instance
        \\
        \\### 5. Error Handling
        \\- Method calls on optionals require careful handling
        \\- Always use null-safe patterns
        \\
        \\## Correct Patterns
        \\
        \\### Arena Allocator (preferred for short-lived programs)
        \\```zig
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\    // Use allocator for all allocations
        \\}
        \\```
        \\
        \\### ArrayList
        \\```zig
        \\var list: std.ArrayList(u8) = .empty;
        \\defer list.deinit(allocator);
        \\try list.append(allocator, byte);
        \\// NOT list.append(allocator, byte) - allocator already stored
        \\```
        \\
        \\### HashMap
        \\```zig
        \\var map: std.StringHashMap(u32) = .empty;
        \\defer map.deinit(allocator);
        \\try map.put(allocator, key, value);
        \\// Wait - check actual 0.16 API
        \\```
        \\
        \\### I/O
        \\```zig
        \\const io = init.io;
        \\var buffer: [4096]u8 = undefined;
        \\var reader = Io.File.stdin().reader(io, &buffer);
        \\// Use reader.interface methods
        \\```
        \\
        \\## Always Remember
        \\1. Pass `allocator` to init methods, NOT to method calls on collections
        \\2. Use `init.arena.allocator()` for simple programs
        \\3. Use `init.io` for all I/O operations
        \\4. Remember to flush writers!
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/arraylist")) {
        return 
        \\// ArrayList Patterns in Zig 0.16
        \\
        \\// CORRECT: Initialize empty (no allocator yet)
        \\var list: std.ArrayList(u8) = .empty;
        \\
        \\// Use the allocator for operations that require it
        \\// (not for append - that's stored internally now!)
        \\
        \\// WRONG: This doesn't compile in 0.16
        \\// try list.append(allocator, item);
        \\
        \\// CORRECT: append takes item directly
        \\try list.append(allocator, 'h');
        \\try list.append(allocator, 'e');
        \\try list.append(allocator, 'l');
        \\try list.append(allocator, 'l');
        \\try list.append(allocator, 'o');
        \\
        \\// But deinit requires allocator!
        \\defer list.deinit(allocator);
        \\
        \\// For parsing JSON, still need allocator
        \\const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        \\
        \\// Converting to slice needs allocator
        \\const result = try list.toOwnedSlice(allocator);
        \\defer allocator.free(result);
        \\
        \\// With arena allocator (recommended for main)
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\    
        \\    var list: std.ArrayList(u32) = .empty;
        \\    defer list.deinit(allocator);
        \\    
        \\    try list.append(allocator, 42);
        \\    try list.append(allocator, 100);
        \\    
        \\    for (list.items) |item| {
        \\        std.debug.print("{}\n", .{item});
        \\    }
        \\}
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/hashmap")) {
        return 
        \\// HashMap Patterns in Zig 0.16
        \\
        \\// StringHashMap - most common choice
        \\var map: std.StringHashMap(u32) = .empty;
        \\defer map.deinit(allocator);
        \\
        \\// Put with allocator
        \\try map.put(allocator, "answer", 42);
        \\try map.put(allocator, "count", 100);
        \\
        \\// Get
        \\if (map.get("answer")) |value| {
        \\    std.debug.print("Answer: {}\n", .{value});
        \\}
        \\
        \\// Check existence
        \\if (map.contains("missing")) {}
        \\
        \\// Delete
        \\_ = map.remove("key");
        \\
        \\// Iteration
        \\var iterator = map.iterator();
        \\while (iterator.next()) |entry| {
        \\    std.debug.print("{s} = {}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        \\}
        \\
        \\// AutoHashMap - when you need integer keys
        \\var auto_map: std.AutoHashMap(u32, []const u8) = .empty;
        \\defer auto_map.deinit(allocator);
        \\
        \\try auto_map.put(allocator, 1, "one");
        \\try auto_map.put(allocator, 2, "two");
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
        \\- All I/O needs `io` from `init.io`
        \\- Need buffer for Reader/Writer
        \\- Always flush after writing to stdout
        \\- stderr is good for logging (doesn't interfere with protocol)
        \\
        ;
    } else if (std.mem.eql(u8, uri, "zig://patterns/allocator")) {
        return 
        \\// Allocator Patterns in Zig 0.16
        \\
        \\## When Allocator is Stored vs Passed
        \\
        \\### Arena Allocator (RECOMMENDED for main)
        \\pub fn main(init: std.process.Init) !void {
        \\    // Arena allocator - automatically cleans up at end
        \\    const allocator = init.arena.allocator();
        \\    
        \\    // No need to free individual allocations
        \\    const slice = try allocator.alloc(u8, 100);
        \\    // But you can if you want
        \\    allocator.free(slice);
        \\}
        \\
        \\### General Purpose Allocator (GPA)
        \\// NOT recommended for simple programs - requires manual cleanup
        \\const gpa = std.heap.general_purpose_allocator(.{});
        \\defer gpa.deinit();
        \\const allocator = gpa.allocator();
        \\
        \\### ArrayList/HashMap - Allocator is Stored!
        \\var list: std.ArrayList(u8) = .empty;
        \\defer list.deinit(allocator); // Must provide allocator to deinit
        \\try list.append(allocator, item); // But append doesn't take allocator
        \\
        \\### String format with allocator
        \\const formatted = try std.fmt.allocPrint(allocator, "Value: {}", .{value});
        \\defer allocator.free(formatted);
        \\
        \\## Summary
        \\- In main(): use `init.arena.allocator()`
        \\- Collections store allocator, pass to deinit()
        \\- For one-off allocations: pass allocator to function
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
        \\    .name = \"my-project\",
        \\    .version = \"0.1.0\",
        \\    .dependencies = .{
        \\        // Add dependencies here
        \\    },
        \\}
        \\
        ;
    }
    return "Unknown resource";
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
        const result = try executeTool(init, allocator, name, tool_args);
        defer allocator.free(result);

        try list.appendSlice(allocator, ",\"content\":[");
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

        try list.appendSlice(allocator, "\"}]");
    } else {
        try list.appendSlice(allocator, ",\"error\":{\"code\":-32602,\"message\":\"Missing tool name\"}");
    }

    try list.appendSlice(allocator, "}");

    return list.toOwnedSlice(allocator);
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

    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    try child.collectOutput(allocator, &stdout_list, &stderr_list, std.math.maxInt(usize));
    _ = try child.wait(io);

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
