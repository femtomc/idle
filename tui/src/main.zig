const std = @import("std");
const status = @import("status.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var json_mode = false;
    var help_mode = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_mode = true;
        }
    }

    if (help_mode) {
        printHelp();
        return;
    }

    if (json_mode) {
        try status.printJson(allocator);
    } else {
        try status.runTui(allocator);
    }
}

fn printHelp() void {
    std.debug.print(
        \\Usage: idle status [OPTIONS]
        \\
        \\Options:
        \\  --json              Output JSON snapshot of loop state
        \\  --help, -h          Show this help message
        \\
        \\Without options, runs an interactive TUI that refreshes every second.
        \\
        \\Key bindings (TUI mode):
        \\  q                   Quit
        \\  r                   Manual refresh
        \\
    , .{});
}
