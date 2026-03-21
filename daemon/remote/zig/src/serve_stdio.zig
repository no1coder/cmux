const std = @import("std");
const json_rpc = @import("json_rpc.zig");

pub fn serve() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdin = std.fs.File.stdin();
    var output_buf: [64 * 1024]u8 = undefined;
    var output_writer = std.fs.File.stdout().writer(&output_buf);
    const output = &output_writer.interface;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);

    var read_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try stdin.read(&read_buf);
        if (n == 0) break;

        try pending.appendSlice(alloc, read_buf[0..n]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
            try handleLine(alloc, output, pending.items[0..newline_index]);

            const remaining = pending.items[newline_index + 1 ..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
    }

    if (pending.items.len > 0) {
        try handleLine(alloc, output, pending.items);
    }
}

fn handleLine(alloc: std.mem.Allocator, output: anytype, raw_line: []const u8) !void {
    const trimmed = std.mem.trimRight(u8, raw_line, "\r");
    if (trimmed.len == 0) return;

    var req = json_rpc.decodeRequest(alloc, trimmed) catch {
        const payload = try json_rpc.encodeResponse(alloc, .{
            .ok = false,
            .@"error" = .{
                .code = "invalid_request",
                .message = "invalid JSON request",
            },
        });
        defer alloc.free(payload);
        try output.print("{s}\n", .{payload});
        try output.flush();
        return;
    };
    defer req.deinit(alloc);

    const response = if (std.mem.eql(u8, req.method, "hello"))
        try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{
                .name = "cmuxd-remote",
                .version = "dev",
                .capabilities = .{
                    "session.basic",
                    "session.resize.min",
                    "terminal.stream",
                    "proxy.http_connect",
                    "proxy.socks5",
                    "proxy.stream",
                },
            },
        })
    else if (std.mem.eql(u8, req.method, "ping"))
        try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{
                .pong = true,
            },
        })
    else
        try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = false,
            .@"error" = .{
                .code = "method_not_found",
                .message = "unknown method",
            },
        });
    defer alloc.free(response);

    try output.print("{s}\n", .{response});
    try output.flush();
}
