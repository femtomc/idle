const std = @import("std");

pub const LoopState = struct {
    run_id: []const u8,
    mode: []const u8,
    iter: u32,
    max: u32,
    worktree_path: []const u8,
    updated_at: []const u8,
    branch: []const u8,
};


pub fn printJson(allocator: std.mem.Allocator) !void {
    // Run: jwz read loop:current --json and extract body using jq
    // Output the last element's body which contains the loop state
    var child = std.process.Child.init(&.{ "sh", "-c", "jwz read loop:current --json 2>/dev/null | jq -r '.[-1].body' 2>/dev/null" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    if (child.stdout) |stdout| {
        var buf: [65536]u8 = undefined;
        const n = try stdout.readAll(&buf);

        _ = try child.wait();

        if (n == 0) {
            _ = try std.posix.write(1, "{\"loops\":[],\"worktrees\":[]}\n");
            return;
        }

        // The body is valid JSON, let's parse it and extract loops
        const body_json = std.mem.trim(u8, buf[0..n], " \t\n\r");
        var output: [65536]u8 = undefined;
        var output_pos: usize = 0;

        const header = "{\"loops\":[";
        @memcpy(output[output_pos..output_pos + header.len], header);
        output_pos += header.len;

        var first = true;
        parseAndPrintJsonToBuffer(body_json, &first, output[0..], &output_pos);

        const footer = "],\"worktrees\":[]}\n";
        @memcpy(output[output_pos..output_pos + footer.len], footer);
        output_pos += footer.len;

        _ = try std.posix.write(1, output[0..output_pos]);
    } else {
        _ = try child.wait();
        _ = try std.posix.write(1, "{\"loops\":[],\"worktrees\":[]}\n");
    }
}

fn parseAndPrintJsonToBuffer(json_str: []const u8, first: *bool, output: []u8, output_pos: *usize) void {
    // Extract top-level run_id for compatibility, but focus on stack
    var run_id: []const u8 = "";
    if (extractJsonString(json_str, "\"run_id\"")) |val| {
        run_id = val;
    }

    // Find "stack" array
    const stack_start = std.mem.indexOf(u8, json_str, "\"stack\"") orelse {
        return;
    };
    const array_start = std.mem.indexOf(u8, json_str[stack_start..], "[") orelse {
        return;
    };
    const array_offset = stack_start + array_start;

    // Find each object in the array (iterating from the first [ to end])
    var search_start = array_offset + 1; // skip the [
    while (search_start < json_str.len) {
        // Find next {
        while (search_start < json_str.len and json_str[search_start] != '{') {
            search_start += 1;
        }

        if (search_start >= json_str.len) break;

        const obj_start = search_start;
        var obj_end = search_start;
        var brace_depth: i32 = 0;
        var in_string = false;
        var escape_next = false;

        while (search_start < json_str.len) {
            const ch = json_str[search_start];

            if (escape_next) {
                escape_next = false;
            } else if (ch == '\\') {
                escape_next = true;
            } else if (ch == '"') {
                in_string = !in_string;
            } else if (!in_string) {
                if (ch == '{') {
                    if (brace_depth == 0) {
                        // This is the start of our object
                    }
                    brace_depth += 1;
                } else if (ch == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        obj_end = search_start + 1;
                        search_start += 1;
                        break;
                    }
                }
            }

            search_start += 1;
        }

        if (obj_end > obj_start) {
            const obj_str = json_str[obj_start..obj_end];

            // Extract fields from stack item
            var item_id: []const u8 = "";
            var mode: []const u8 = "";
            var iter: u32 = 0;
            var max: u32 = 0;

            if (extractJsonString(obj_str, "\"id\"")) |val| {
                item_id = val;
            }
            if (extractJsonString(obj_str, "\"mode\"")) |val| {
                mode = val;
            }
            if (extractJsonNumber(obj_str, "\"iter\"")) |val| {
                iter = val;
            }
            if (extractJsonNumber(obj_str, "\"max\"")) |val| {
                max = val;
            }

            if (item_id.len > 0) {
                if (!first.*) {
                    if (output_pos.* < output.len) {
                        output[output_pos.*] = ',';
                        output_pos.* += 1;
                    }
                }
                first.* = false;
                var buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{{\"run_id\":\"{s}\",\"mode\":\"{s}\",\"iteration\":{},\"max\":{},\"updated_at\":\"\"}}", .{ item_id, mode, iter, max })) |formatted| {
                    if (output_pos.* + formatted.len <= output.len) {
                        @memcpy(output[output_pos.*..output_pos.* + formatted.len], formatted);
                        output_pos.* += formatted.len;
                    }
                } else |_| {}
            }
        }
    }
}

fn extractJsonString(json_str: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json_str, key) orelse return null;
    const colon_pos = std.mem.indexOf(u8, json_str[key_pos..], ":") orelse return null;
    const quote_start = std.mem.indexOf(u8, json_str[key_pos + colon_pos..], "\"") orelse return null;

    const search_start = key_pos + colon_pos + quote_start + 1;
    const quote_end = std.mem.indexOf(u8, json_str[search_start..], "\"") orelse return null;

    return json_str[search_start .. search_start + quote_end];
}

fn extractJsonNumber(json_str: []const u8, key: []const u8) ?u32 {
    const key_pos = std.mem.indexOf(u8, json_str, key) orelse return null;
    const colon_pos = std.mem.indexOf(u8, json_str[key_pos..], ":") orelse return null;

    // Skip whitespace after colon
    var num_start = key_pos + colon_pos + 1;
    while (num_start < json_str.len and (json_str[num_start] == ' ' or json_str[num_start] == '\t' or json_str[num_start] == '\n' or json_str[num_start] == '\r')) {
        num_start += 1;
    }

    var num_end = num_start;
    while (num_end < json_str.len and json_str[num_end] >= '0' and json_str[num_end] <= '9') {
        num_end += 1;
    }

    if (num_end == num_start) return null;
    const num_str = json_str[num_start..num_end];
    return std.fmt.parseInt(u32, num_str, 10) catch null;
}

pub fn runTui(allocator: std.mem.Allocator) !void {
    // Minimal TUI - just display status once
    // Full interactive mode would require proper terminal control
    std.debug.print("\x1B[2J\x1B[H", .{});
    std.debug.print("\x1B[?25l", .{});

    try displayStatus(allocator);

    std.debug.print("\n(Press Ctrl+C to quit)\n", .{});

    // Show cursor and clear screen
    std.debug.print("\x1B[?25h", .{});
}

fn displayStatus(allocator: std.mem.Allocator) !void {
    // Clear screen and move to home
    std.debug.print("\x1B[2J\x1B[H", .{});

    // Run: jwz read loop:current --json and extract body using jq
    var child = std.process.Child.init(&.{ "sh", "-c", "jwz read loop:current --json 2>/dev/null | jq -r '.[-1].body' 2>/dev/null" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        std.debug.print("idle status                                    [q]uit  [r]efresh\n\n", .{});
        std.debug.print("ACTIVE LOOPS\n", .{});
        std.debug.print("────────────────────────────────────────────────────────────────\n\n", .{});
        std.debug.print("(no active loops)\n", .{});
        return;
    };

    std.debug.print("idle status                                    [q]uit  [r]efresh\n\n", .{});
    std.debug.print("ACTIVE LOOPS\n", .{});
    std.debug.print("────────────────────────────────────────────────────────────────\n\n", .{});

    if (child.stdout) |stdout| {
        var buf: [16384]u8 = undefined;
        const n = stdout.readAll(&buf) catch 0;

        _ = child.wait() catch 0;

        if (n == 0) {
            std.debug.print("(no active loops)\n", .{});
            return;
        }

        // Parse the body JSON
        const body_json = std.mem.trim(u8, buf[0..n], " \t\n\r");
        var loop_count: u32 = 0;

        if (displayLoopFromJson(body_json)) {
            loop_count += 1;
        }

        if (loop_count == 0) {
            std.debug.print("(no active loops)\n", .{});
        }
    } else {
        _ = child.wait() catch 0;
        std.debug.print("(no active loops)\n", .{});
    }
}

fn displayLoopFromJson(json_str: []const u8) bool {
    // Find "stack" array
    const stack_start = std.mem.indexOf(u8, json_str, "\"stack\"") orelse return false;
    const array_start = std.mem.indexOf(u8, json_str[stack_start..], "[") orelse return false;
    const array_offset = stack_start + array_start;

    // Find each object in the array (iterating from the first [ to end)
    var search_start = array_offset + 1; // skip the [
    var displayed = false;
    while (search_start < json_str.len) {
        // Find next {
        while (search_start < json_str.len and json_str[search_start] != '{') {
            search_start += 1;
        }

        if (search_start >= json_str.len) break;

        const obj_start = search_start;
        var obj_end = search_start;
        var brace_depth: i32 = 0;
        var in_string = false;
        var escape_next = false;

        while (search_start < json_str.len) {
            const ch = json_str[search_start];

            if (escape_next) {
                escape_next = false;
            } else if (ch == '\\') {
                escape_next = true;
            } else if (ch == '"') {
                in_string = !in_string;
            } else if (!in_string) {
                if (ch == '{') {
                    if (brace_depth == 0) {
                        // This is the start of our object
                    }
                    brace_depth += 1;
                } else if (ch == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        obj_end = search_start + 1;
                        search_start += 1;
                        break;
                    }
                }
            }

            search_start += 1;
        }

        if (obj_end > obj_start) {
            const obj_str = json_str[obj_start..obj_end];

            // Extract fields
            var run_id: []const u8 = "";
            var mode: []const u8 = "";
            var iter: u32 = 0;
            var max: u32 = 0;
            var worktree_path: []const u8 = "";

            if (extractJsonString(obj_str, "\"id\"")) |val| {
                run_id = val;
            }
            if (extractJsonString(obj_str, "\"mode\"")) |val| {
                mode = val;
            }
            if (extractJsonNumber(obj_str, "\"iter\"")) |val| {
                iter = val;
            }
            if (extractJsonNumber(obj_str, "\"max\"")) |val| {
                max = val;
            }
            if (extractJsonString(obj_str, "\"worktree_path\"")) |val| {
                worktree_path = val;
            }

            if (run_id.len > 0) {
                std.debug.print("  {s:<20} {s:<8} iter {}/{}\n", .{
                    run_id,
                    mode,
                    iter,
                    max,
                });
                std.debug.print("  └─ worktree: {s}\n", .{worktree_path});
                std.debug.print("\n", .{});
                displayed = true;
            }
        }
    }

    return displayed;
}
