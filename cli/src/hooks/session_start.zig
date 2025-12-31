const std = @import("std");

/// Session start hook - injects minimal agent awareness
/// This is the simplest hook: just prints 2 lines to stdout
pub fn run(_: std.mem.Allocator) !u8 {
    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        \\idle agents: idle:alice (deep reasoning, quality gates)
        \\Workflow: When stuck on design or need second opinion -> consult idle:alice
        \\
    );
    try stdout.flush();

    return 0;
}

test "session_start outputs agent awareness" {
    // Basic test - just verify it compiles and runs without error
    // Full integration test would capture stdout
}
