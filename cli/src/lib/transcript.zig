const std = @import("std");

/// Unescape JSON string escape sequences
/// Converts \n, \r, \t, \\, \", etc. to their actual characters
fn unescapeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Output can only be same size or smaller
    var result = try allocator.alloc(u8, input.len);
    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    result[out_pos] = '\n';
                    out_pos += 1;
                    i += 2;
                },
                'r' => {
                    result[out_pos] = '\r';
                    out_pos += 1;
                    i += 2;
                },
                't' => {
                    result[out_pos] = '\t';
                    out_pos += 1;
                    i += 2;
                },
                '\\' => {
                    result[out_pos] = '\\';
                    out_pos += 1;
                    i += 2;
                },
                '"' => {
                    result[out_pos] = '"';
                    out_pos += 1;
                    i += 2;
                },
                '/' => {
                    result[out_pos] = '/';
                    out_pos += 1;
                    i += 2;
                },
                'u' => {
                    // Unicode escape \uXXXX - for now just skip it (4 hex digits)
                    if (i + 5 < input.len) {
                        // Simple handling: replace with '?' for non-ASCII
                        result[out_pos] = '?';
                        out_pos += 1;
                        i += 6;
                    } else {
                        result[out_pos] = input[i];
                        out_pos += 1;
                        i += 1;
                    }
                },
                else => {
                    // Unknown escape, keep as-is
                    result[out_pos] = input[i];
                    out_pos += 1;
                    i += 1;
                },
            }
        } else {
            result[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    // Resize to actual length
    return allocator.realloc(result, out_pos) catch result[0..out_pos];
}

/// Extract the last assistant message text from a Claude transcript (NDJSON format)
pub fn extractLastAssistantText(allocator: std.mem.Allocator, transcript_path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(transcript_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return null;

    // Read last 64KB (should contain last message)
    const read_size: usize = @min(stat.size, 65536);
    const offset: u64 = stat.size - read_size;

    try file.seekTo(offset);

    var buf: [65536]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n == 0) return null;

    const content = buf[0..n];

    // Find last assistant message by scanning for "type":"assistant"
    // Then extract the text content from it
    var last_text_start: ?usize = null;
    var last_text_end: usize = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOf(u8, content[search_pos..], "\"type\":\"assistant\"")) |pos| {
        const abs_pos = search_pos + pos;

        // Look for text content after this
        if (std.mem.indexOf(u8, content[abs_pos..], "\"text\":\"")) |text_pos| {
            const text_start = abs_pos + text_pos + 8; // Skip past "text":"

            // Find end of text string (handle escapes)
            var text_end = text_start;
            var escape_next = false;
            while (text_end < content.len) {
                if (escape_next) {
                    escape_next = false;
                } else if (content[text_end] == '\\') {
                    escape_next = true;
                } else if (content[text_end] == '"') {
                    break;
                }
                text_end += 1;
            }

            last_text_start = text_start;
            last_text_end = text_end;
        }
        search_pos = abs_pos + 1;
    }

    // Return a copy of the last text we found, with JSON escapes decoded
    if (last_text_start) |start| {
        const raw_text = content[start..last_text_end];
        return try unescapeJson(allocator, raw_text);
    }

    return null;
}

/// Check if text contains alice output patterns
pub fn isAliceOutput(text: []const u8) bool {
    // Alice MUST output "## Result" with status and confidence
    if (std.mem.indexOf(u8, text, "**Status**: RESOLVED") != null) return true;
    if (std.mem.indexOf(u8, text, "**Status**: NEEDS_INPUT") != null) return true;
    if (std.mem.indexOf(u8, text, "**Status**: UNRESOLVED") != null) return true;

    // Also check for alice's structured sections
    if (std.mem.indexOf(u8, text, "## Hypotheses") != null and
        std.mem.indexOf(u8, text, "## Recommendation") != null) return true;

    // Check for quality gate mode
    if (std.mem.indexOf(u8, text, "Verdict: PASS") != null) return true;
    if (std.mem.indexOf(u8, text, "Verdict: REVISE") != null) return true;

    return false;
}

/// Check if text contains a second opinion section with content
pub fn hasSecondOpinion(text: []const u8) bool {
    const section_start = std.mem.indexOf(u8, text, "## Second Opinion") orelse return false;

    // Find content after the header
    const after_header = text[section_start + 17 ..]; // Skip "## Second Opinion"

    // Skip to next line
    const newline = std.mem.indexOf(u8, after_header, "\n") orelse return false;
    const content_start = after_header[newline + 1 ..];

    // Find end of section (next ## or end of text)
    const section_end = std.mem.indexOf(u8, content_start, "\n## ") orelse content_start.len;
    const section_content = std.mem.trim(u8, content_start[0..section_end], " \t\n\r");

    // Check for empty or placeholder content
    if (section_content.len == 0) return false;

    // Check for common placeholders
    const lower = blk: {
        var buf: [256]u8 = undefined;
        const len = @min(section_content.len, 256);
        for (0..len) |i| {
            buf[i] = std.ascii.toLower(section_content[i]);
        }
        break :blk buf[0..len];
    };

    if (std.mem.startsWith(u8, lower, "todo")) return false;
    if (std.mem.startsWith(u8, lower, "tbd")) return false;
    if (std.mem.startsWith(u8, lower, "pending")) return false;
    if (std.mem.startsWith(u8, lower, "not yet")) return false;

    return true;
}

/// Check if transcript contains a codex or claude -p invocation
pub fn hasSecondOpinionInvocation(transcript_path: []const u8) !bool {
    const file = std.fs.openFileAbsolute(transcript_path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer file.close();

    var buf: [1024 * 1024]u8 = undefined; // 1MB should be enough
    const n = try file.readAll(&buf);
    if (n == 0) return false;

    const content = buf[0..n];

    // Look for codex exec or claude -p in Bash command content
    if (std.mem.indexOf(u8, content, "codex exec") != null) return true;
    if (std.mem.indexOf(u8, content, "claude -p") != null) return true;

    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "isAliceOutput: status RESOLVED" {
    const text = "## Result\n\n**Status**: RESOLVED\n**Confidence**: HIGH";
    try std.testing.expect(isAliceOutput(text));
}

test "isAliceOutput: hypothesis sections" {
    const text = "## Hypotheses\nsome content\n## Recommendation\ndo this";
    try std.testing.expect(isAliceOutput(text));
}

test "isAliceOutput: quality gate PASS" {
    const text = "## Review\nVerdict: PASS";
    try std.testing.expect(isAliceOutput(text));
}

test "isAliceOutput: not alice" {
    const text = "Just some random text without alice markers";
    try std.testing.expect(!isAliceOutput(text));
}

test "hasSecondOpinion: valid section" {
    const text = "## Second Opinion\n\nCodex says: I agree with hypothesis 1.\n\n## Recommendation";
    try std.testing.expect(hasSecondOpinion(text));
}

test "hasSecondOpinion: empty section" {
    const text = "## Second Opinion\n\n## Recommendation";
    try std.testing.expect(!hasSecondOpinion(text));
}

test "hasSecondOpinion: rejects TODO placeholder" {
    const text = "## Second Opinion\n\nTODO: add second opinion\n\n## Recommendation";
    try std.testing.expect(!hasSecondOpinion(text));
}

test "hasSecondOpinion: no section" {
    const text = "## Recommendation\ndo this";
    try std.testing.expect(!hasSecondOpinion(text));
}

test "unescapeJson: basic escapes" {
    const allocator = std.testing.allocator;
    const input = "Hello\\nWorld\\ttab\\\\slash\\\"quote";
    const result = try unescapeJson(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello\nWorld\ttab\\slash\"quote", result);
}

test "unescapeJson: loop-done tag" {
    const allocator = std.testing.allocator;
    const input = "<loop-done>COMPLETE</loop-done>";
    const result = try unescapeJson(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<loop-done>COMPLETE</loop-done>", result);
}
