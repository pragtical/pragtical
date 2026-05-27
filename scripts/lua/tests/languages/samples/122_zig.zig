const std = @import("std");

const Error = error{Empty};

const Widget = struct {
    name: []const u8,

    pub fn render(self: Widget, writer: anytype, items: []const []const u8) !void {
        if (items.len == 0) return Error.Empty;
        for (items) |item| {
            switch (item.len) {
                0 => continue,
                else => try writer.print("{s}:{s}\n", .{ self.name, item }),
            }
        }
    }
};

fn Pair(comptime T: type) type {
    return struct {
        left: T,
        right: T,
    };
}

pub fn main() !void {
    var out = std.io.getStdOut().writer();
    const pair = Pair(u8){ .left = 1, .right = 2 };
    _ = pair;
    try (Widget{ .name = "demo" }).render(out, &.{ "alpha", "beta" });
}
