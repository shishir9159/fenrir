const std = @import("std");
const Builder = @import("../gelgja/Builder.zig");
const geom = @import("../gelgja/geom.zig");
const raster = @import("raster.zig");
const replay = @import("replay.zig");

test "probe" {
    const gpa = std.testing.allocator;
    var b: Builder = .init(gpa, .fromRect(0, 0, 40, 40));
    defer b.deinit();

    // A filled rectangle, offset so its diagonal is unmistakable.
    try b.moveTo(.{ .x = 4, .y = 6 });
    try b.lineTo(.{ .x = 20, .y = 6 });
    try b.lineTo(.{ .x = 20, .y = 34 });
    try b.lineTo(.{ .x = 4, .y = 34 });
    try b.closePath();
    try b.fill(.nonzero, .{ .solid = .black });

    // A stroked one next to it.
    try b.moveTo(.{ .x = 24, .y = 6 });
    try b.lineTo(.{ .x = 36, .y = 6 });
    try b.lineTo(.{ .x = 36, .y = 34 });
    try b.lineTo(.{ .x = 24, .y = 34 });
    try b.closePath();
    try b.stroke(.{ .width = 1 }, .{ .solid = .black }, .identity);

    const list = try b.finish();
    var l = list;
    defer l.deinit(gpa);

    var c: raster.Canvas = try .init(gpa, 40, 40, .{ .samples = .four });
    defer c.deinit(gpa);
    c.fb.clear(.white);
    _ = try replay.render(gpa, &c, list, replay.pageTransform(list.page, 1), .{});

    var y: u32 = 0;
    while (y < 40) : (y += 1) {
        var line: [41]u8 = undefined;
        var x: u32 = 0;
        while (x < 40) : (x += 1) {
            const ink = 1.0 - c.fb.at(x, y).r;
            line[x] = if (ink > 0.98) '#' else if (ink > 0.6) 'o' else if (ink > 0.2) '+' else if (ink > 0.02) '-' else '.';
        }
        line[40] = 0;
        std.debug.print("{s}\n", .{line[0..40]});
    }
}
