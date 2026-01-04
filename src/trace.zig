//! Trace construction from tissue and zawinski stores
//!
//! Traces capture sequences of events from Claude Code sessions,
//! enabling post-hoc analysis and explanation of agent behavior.

const std = @import("std");
const zawinski = @import("zawinski");

/// Event types that can appear in a trace
pub const EventType = enum {
    session_start,
    prompt_received,
    tool_called,
    tool_completed,
    file_modified,
    issue_created,
    issue_updated,
    subagent_started,
    subagent_completed,
    alice_decision,
    session_end,

    pub fn fromString(s: []const u8) ?EventType {
        const map = std.StaticStringMap(EventType).initComptime(.{
            .{ "session_start", .session_start },
            .{ "prompt_received", .prompt_received },
            .{ "tool_called", .tool_called },
            .{ "tool_completed", .tool_completed },
            .{ "file_modified", .file_modified },
            .{ "issue_created", .issue_created },
            .{ "issue_updated", .issue_updated },
            .{ "subagent_started", .subagent_started },
            .{ "subagent_completed", .subagent_completed },
            .{ "alice_decision", .alice_decision },
            .{ "session_end", .session_end },
        });
        return map.get(s);
    }
};

/// A single event in a trace
pub const TraceEvent = struct {
    id: []const u8,
    session_id: []const u8,
    timestamp: i64,
    event_type: EventType,
    payload_json: []const u8,
};

/// A complete trace for a session
/// Note: session_id is borrowed (not owned). Caller must ensure session_id
/// outlives the Trace object.
pub const Trace = struct {
    allocator: std.mem.Allocator,
    /// Borrowed reference - not freed by deinit()
    session_id: []const u8,
    events: []TraceEvent,

    pub fn init(allocator: std.mem.Allocator, session_id: []const u8) Trace {
        return .{
            .allocator = allocator,
            .session_id = session_id,
            .events = &[_]TraceEvent{},
        };
    }

    pub fn deinit(self: *Trace) void {
        for (self.events) |event| {
            self.allocator.free(event.id);
            self.allocator.free(event.payload_json);
        }
        if (self.events.len > 0) {
            self.allocator.free(self.events);
        }
    }

    /// Build a trace from jwz and tissue stores
    pub fn build(
        allocator: std.mem.Allocator,
        session_id: []const u8,
        jwz_store_path: ?[]const u8,
        tissue_store_path: ?[]const u8,
    ) !Trace {
        _ = tissue_store_path; // TODO: Also query tissue for issue events

        // Discover or use provided jwz store
        const store_dir = if (jwz_store_path) |path|
            path
        else
            zawinski.store.discoverStoreDir(allocator) catch {
                // No store found, return empty trace
                return Trace.init(allocator, session_id);
            };
        defer if (jwz_store_path == null) allocator.free(store_dir);

        // Open store
        var store = zawinski.store.Store.open(allocator, store_dir) catch {
            return Trace.init(allocator, session_id);
        };
        defer store.deinit();

        // Build topic name: trace:{session_id}
        const topic_name = try std.fmt.allocPrint(allocator, "trace:{s}", .{session_id});
        defer allocator.free(topic_name);

        // Fetch messages from trace topic (limit 1000 for now)
        const messages = store.listMessages(topic_name, 1000) catch {
            // Topic doesn't exist or other error
            return Trace.init(allocator, session_id);
        };
        defer {
            for (messages) |*m| m.deinit(allocator);
            allocator.free(messages);
        }

        if (messages.len == 0) {
            return Trace.init(allocator, session_id);
        }

        // Parse messages into events
        var events: std.ArrayList(TraceEvent) = .empty;
        defer events.deinit(allocator);

        for (messages) |msg| {
            const event = parseTraceEvent(allocator, session_id, msg) catch continue;
            try events.append(allocator, event);
        }

        // Sort by timestamp (ascending)
        std.mem.sort(TraceEvent, events.items, {}, struct {
            fn lessThan(_: void, a: TraceEvent, b: TraceEvent) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        // Move to owned slice
        const owned_events = try events.toOwnedSlice(allocator);

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .events = owned_events,
        };
    }

    /// Parse a jwz message into a TraceEvent
    fn parseTraceEvent(
        allocator: std.mem.Allocator,
        session_id: []const u8,
        msg: zawinski.store.Message,
    ) !TraceEvent {
        // Parse JSON body
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            msg.body,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract event_type
        const event_type_str = root.get("event_type") orelse return error.MissingEventType;
        const event_type = EventType.fromString(event_type_str.string) orelse return error.UnknownEventType;

        // Duplicate strings since message will be freed
        const id = try allocator.dupe(u8, msg.id);
        errdefer allocator.free(id);
        const payload = try allocator.dupe(u8, msg.body);

        // Use message created_at as the authoritative timestamp
        return .{
            .id = id,
            .session_id = session_id,
            .timestamp = msg.created_at,
            .event_type = event_type,
            .payload_json = payload,
        };
    }

    /// Render trace as text
    pub fn renderText(self: *const Trace, writer: anytype) !void {
        try writer.print("=== Session {s} ===\n\n", .{self.session_id});

        if (self.events.len == 0) {
            try writer.writeAll("No events found.\n");
        } else {
            for (self.events, 0..) |event, i| {
                // Format: [N] event_type (id_prefix)
                try writer.print("[{d}] {s}", .{ i + 1, @tagName(event.event_type) });

                // Show additional details based on event type
                if (event.event_type == .tool_completed or event.event_type == .tool_called) {
                    if (extractJsonField(event.payload_json, "tool_name")) |tool_name| {
                        try writer.print(": {s}", .{tool_name});
                    }
                } else if (event.event_type == .prompt_received) {
                    if (extractJsonField(event.payload_json, "prompt")) |prompt| {
                        // Truncate long prompts
                        const max_len: usize = 60;
                        const display = if (prompt.len > max_len) prompt[0..max_len] else prompt;
                        try writer.print(": \"{s}\"", .{display});
                        if (prompt.len > max_len) try writer.writeAll("...");
                    }
                }

                // Show message ID (first 8 chars)
                const id_preview = if (event.id.len > 8) event.id[0..8] else event.id;
                try writer.print(" ({s})\n", .{id_preview});
            }
        }

        try writer.print("\n{d} events total\n", .{self.events.len});
        try writer.writeAll("=== End Session ===\n");
    }

    /// Extract a string field from JSON payload (simple parser)
    /// Note: Does not handle escaped quotes within values. For display purposes only.
    fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
        // Look for "field":"value" pattern
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field}) catch return null;

        if (std.mem.indexOf(u8, json, search)) |start| {
            const value_start = start + search.len;
            // Find closing quote, skipping escaped quotes
            var i = value_start;
            while (i < json.len) : (i += 1) {
                if (json[i] == '"') {
                    // Check if escaped
                    if (i > 0 and json[i - 1] == '\\') continue;
                    return json[value_start..i];
                }
            }
        }
        return null;
    }

    /// Render trace as GraphViz DOT format
    pub fn renderDot(self: *const Trace, writer: anytype) !void {
        // Quote the graph name since session IDs contain hyphens
        try writer.print("digraph \"trace_{s}\" {{\n", .{self.session_id});
        try writer.writeAll("  rankdir=TB;\n\n");

        // Emit nodes
        for (self.events, 0..) |event, i| {
            try writer.print("  n{d} [label=\"{s}\\n{s}\"];\n", .{
                i,
                @tagName(event.event_type),
                event.id,
            });
        }

        // Emit edges (simple sequential for now)
        if (self.events.len > 1) {
            try writer.writeAll("\n");
            for (0..self.events.len - 1) |i| {
                try writer.print("  n{d} -> n{d};\n", .{ i, i + 1 });
            }
        }

        try writer.writeAll("}\n");
    }
};

test "trace init and deinit" {
    var trace_obj = Trace.init(std.testing.allocator, "test-session");
    defer trace_obj.deinit();

    try std.testing.expectEqualStrings("test-session", trace_obj.session_id);
    try std.testing.expectEqual(@as(usize, 0), trace_obj.events.len);
}
