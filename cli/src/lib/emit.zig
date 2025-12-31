const std = @import("std");
const zawinski = @import("zawinski");

/// Agent roles for message formatting
pub const Role = enum {
    alice,
    loop,

    pub fn fromString(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "alice")) return .alice;
        if (std.mem.eql(u8, s, "loop")) return .loop;
        return null;
    }
};

/// Standard actions for message formatting
pub const Action = enum {
    // Common actions
    STARTED,
    COMPLETE,
    FAILED,
    PARTIAL,

    // alice actions
    ANALYSIS,
    RESOLVED,
    NEEDS_INPUT,
    UNRESOLVED,

    // loop actions
    LANDED,
    AUTO_LAND_FAILED,

    pub fn fromString(s: []const u8) ?Action {
        inline for (std.meta.fields(Action)) |field| {
            if (std.mem.eql(u8, s, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

/// Status for alice outputs
pub const Status = enum {
    RESOLVED,
    NEEDS_INPUT,
    UNRESOLVED,

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "RESOLVED")) return .RESOLVED;
        if (std.mem.eql(u8, s, "NEEDS_INPUT")) return .NEEDS_INPUT;
        if (std.mem.eql(u8, s, "UNRESOLVED")) return .UNRESOLVED;
        return null;
    }
};

/// Confidence level
pub const Confidence = enum {
    HIGH,
    MEDIUM,
    LOW,

    pub fn fromString(s: []const u8) ?Confidence {
        if (std.mem.eql(u8, s, "HIGH")) return .HIGH;
        if (std.mem.eql(u8, s, "MEDIUM")) return .MEDIUM;
        if (std.mem.eql(u8, s, "LOW")) return .LOW;
        return null;
    }
};

/// Message builder
pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,
    role: Role,
    action: Action,
    task_id: ?[]const u8 = null,
    status: ?Status = null,
    confidence: ?Confidence = null,
    summary: ?[]const u8 = null,
    details: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, role: Role, action: Action) MessageBuilder {
        return .{
            .allocator = allocator,
            .role = role,
            .action = action,
        };
    }

    pub fn withTaskId(self: *MessageBuilder, task_id: []const u8) *MessageBuilder {
        self.task_id = task_id;
        return self;
    }

    pub fn withStatus(self: *MessageBuilder, status: Status) *MessageBuilder {
        self.status = status;
        return self;
    }

    pub fn withConfidence(self: *MessageBuilder, confidence: Confidence) *MessageBuilder {
        self.confidence = confidence;
        return self;
    }

    pub fn withSummary(self: *MessageBuilder, summary: []const u8) *MessageBuilder {
        self.summary = summary;
        return self;
    }

    pub fn withDetails(self: *MessageBuilder, details: []const u8) *MessageBuilder {
        self.details = details;
        return self;
    }

    /// Build the formatted message
    pub fn build(self: *const MessageBuilder) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        // Header: [role] ACTION: task_id
        try writer.print("[{s}] {s}", .{ @tagName(self.role), @tagName(self.action) });
        if (self.task_id) |tid| {
            try writer.print(": {s}", .{tid});
        }
        try writer.writeByte('\n');

        // Status and confidence (for alice)
        if (self.status) |s| {
            try writer.print("Status: {s}\n", .{@tagName(s)});
        }
        if (self.confidence) |c| {
            try writer.print("Confidence: {s}\n", .{@tagName(c)});
        }

        // Summary
        if (self.summary) |s| {
            try writer.writeByte('\n');
            try writer.writeAll(s);
            try writer.writeByte('\n');
        }

        // Details
        if (self.details) |d| {
            try writer.writeByte('\n');
            try writer.writeAll(d);
            try writer.writeByte('\n');
        }

        return buf.toOwnedSlice(self.allocator);
    }
};

/// Post a message to jwz using the zawinski API directly
pub fn postMessage(
    allocator: std.mem.Allocator,
    topic: []const u8,
    role: Role,
    message: []const u8,
) !void {
    // Discover and open the store
    const store_dir = zawinski.store.discoverStoreDir(allocator) catch {
        // Fall back to .zawinski in current directory
        return error.StoreNotFound;
    };
    defer allocator.free(store_dir);

    var store = try zawinski.store.Store.open(allocator, store_dir);
    defer store.deinit();

    // Ensure topic exists (create if needed)
    _ = store.fetchTopic(topic) catch |err| {
        if (err == zawinski.store.StoreError.TopicNotFound) {
            const topic_id = try store.createTopic(topic, "");
            allocator.free(topic_id);
        } else {
            return err;
        }
    };

    // Create sender identity
    const sender = zawinski.store.Sender{
        .id = "idle",
        .name = "idle",
        .model = null,
        .role = @tagName(role),
    };

    // Post the message
    const msg_id = try store.createMessage(topic, null, message, .{ .sender = sender });
    allocator.free(msg_id);
}

/// Emit a structured message to jwz
pub fn emit(
    allocator: std.mem.Allocator,
    topic: []const u8,
    role: Role,
    action: Action,
    task_id: ?[]const u8,
    status: ?Status,
    confidence: ?Confidence,
    summary: ?[]const u8,
) !void {
    var builder = MessageBuilder.init(allocator, role, action);
    if (task_id) |t| _ = builder.withTaskId(t);
    if (status) |s| _ = builder.withStatus(s);
    if (confidence) |c| _ = builder.withConfidence(c);
    if (summary) |s| _ = builder.withSummary(s);

    const message = try builder.build();
    defer allocator.free(message);

    try postMessage(allocator, topic, role, message);
}

// ============================================================================
// Tests
// ============================================================================

test "MessageBuilder: basic message" {
    const allocator = std.testing.allocator;
    var builder = MessageBuilder.init(allocator, .alice, .ANALYSIS);
    _ = builder.withTaskId("task-001");
    _ = builder.withStatus(.RESOLVED);
    _ = builder.withConfidence(.HIGH);
    _ = builder.withSummary("Found the issue.");

    const msg = try builder.build();
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "[alice] ANALYSIS: task-001") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Status: RESOLVED") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Confidence: HIGH") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Found the issue.") != null);
}

test "Role.fromString" {
    try std.testing.expectEqual(Role.alice, Role.fromString("alice").?);
    try std.testing.expectEqual(Role.loop, Role.fromString("loop").?);
    try std.testing.expect(Role.fromString("unknown") == null);
}

test "Action.fromString" {
    try std.testing.expectEqual(Action.ANALYSIS, Action.fromString("ANALYSIS").?);
    try std.testing.expectEqual(Action.LANDED, Action.fromString("LANDED").?);
    try std.testing.expect(Action.fromString("INVALID") == null);
}
