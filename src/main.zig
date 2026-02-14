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
        \\// ArrayList Patterns em Zig 0.16
        \\
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    const allocator = std.heap.page_allocator;
        \\    
        \\    // initCapacity(allocator, size) - inicializa com capacidade
        \\    var list = try std.ArrayList(u32).initCapacity(allocator, 100);
        \\    
        \\    // append(allocator, item) - COM allocator!
        \\    try list.append(allocator, 10);
        \\    try list.append(allocator, 20);
        \\    
        \\    for (list.items) |item| {
        \\        std.debug.print("{d}\n", .{item});
        \\    }
        \\    
        \\    // deinit(allocator) - SEMPRE com allocator!
        \\    list.deinit(allocator);
        \\}
        \\
        \\// Ou com .empty:
        \\// var list: std.ArrayList(u32) = .empty;
        \\// try list.append(allocator, item);
        \\// list.deinit(allocator);
        \\
        \\// Resumo:
        \\// - init(allocator) ou initCapacity(allocator, size)
        \\// - append(allocator, item) - COM allocator!
        \\// - deinit(allocator) - COM allocator!
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
        \\- All I/O needs `io` from `init.io`
        \\- Need buffer for Reader/Writer
        \\- Always flush after writing to stdout
        \\- stderr is good for logging (doesn't interfere with protocol)
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
