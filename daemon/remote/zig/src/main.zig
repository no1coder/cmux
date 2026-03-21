const std = @import("std");
const serve_stdio = @import("serve_stdio.zig");
const json_rpc = @import("json_rpc.zig");

pub fn main() !void {
    _ = json_rpc;
    try serve_stdio.serve();
}
