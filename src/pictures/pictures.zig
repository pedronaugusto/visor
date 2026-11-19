//! Pictures in the form a terminal's picture protocol takes, made by aperture
//! from an image of any pixel format: a sixel's palette and registers,
//! quantized, and an iTerm2 inline image, a PNG file. The kitty protocol
//! takes pixels as they are (`Layers.transmit`) and cells take none, so
//! neither needs a codec.
//!
//! The image is aperture's own borrowed one, `aperture.View`: what decoded
//! it, or a caller's pixels described in place.
const std = @import("std");
const aegis = @import("aegis");
const aperture = @import("aperture");
const visor = @import("visor");
const Allocator = std.mem.Allocator;

/// `image` as the sixel picture `id`, its colours quantized by `options`
/// into at most 256 registers. A pixel whose register is less than half
/// opaque is not drawn. `gpa` holds the quantized image while the layers
/// copy it.
pub fn storeSixel(gpa: Allocator, layers: *visor.Layers, id: visor.ImageId, image: aperture.View, options: aperture.QuantizeOptions) visor.Layers.StoreSixelError!void {
    var indexed = try aperture.quantize(gpa, image, options);
    defer indexed.deinit();
    const entries = indexed.palette orelse aegis.assert.never("a quantized image has its palette");
    // A register a pixel, a row of them `rowBytes` long: counted in bytes, by aegis's checked
    // multiplication. quantize allocated as many for its pixels, so the count fits.
    const row_bytes = indexed.format.rowBytes(indexed.width.raw());
    const count = row_bytes.mul(indexed.height.raw()) catch aegis.assert.never("the registers fit, as the quantized pixels did");
    const registers = try gpa.alloc(u8, count.raw());
    defer gpa.free(registers);
    const transparent = drawn(indexed.view(), entries, registers);
    const palette = try gpa.alloc(visor.morse.Rgb, entries.len);
    defer gpa.free(palette);
    for (entries, palette) |entry, *colour| colour.* = .{ .r = entry[0], .g = entry[1], .b = entry[2] };
    try layers.storeSixel(id, .{
        .width = indexed.width.raw(),
        .height = indexed.height.raw(),
        .pixels = .{ .indexed = registers },
        .palette = palette,
        .transparent = transparent,
    });
}

/// `image` as the iTerm2 picture `id`: a PNG file, sent in parts of
/// `part_bytes` (zero, whole), as `Layers.storeIterm` takes it.
pub fn storeIterm(gpa: Allocator, layers: *visor.Layers, id: visor.ImageId, image: aperture.View, part_bytes: usize) Allocator.Error!void {
    const file = try png(gpa, image);
    defer gpa.free(file);
    try layers.storeIterm(id, file, part_bytes);
}

/// `image` as a PNG file, owned by the caller.
fn png(gpa: Allocator, image: aperture.View) Allocator.Error![]u8 {
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    aperture.png.encode(gpa, &file.writer, image, .{}) catch |err| switch (err) {
        // An allocating writer fails only when it cannot grow.
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return file.toOwnedSlice();
}

/// The registers of `indexed` packed row after row into `registers`, every
/// pixel whose entry is less than half opaque moved to one such register,
/// which is returned: the one a sixel leaves undrawn. Null when every entry
/// is drawn.
fn drawn(indexed: aperture.View, entries: []const [4]u8, registers: []u8) ?u8 {
    var transparent: ?u8 = null;
    for (entries, 0..) |entry, i| if (entry[3] < 128) {
        transparent = @intCast(i);
        break;
    };
    const row_bytes = indexed.format.rowBytes(indexed.width.raw());
    for (0..indexed.height.raw()) |y| {
        const start = row_bytes.mul(y) catch aegis.assert.never("a row of the registers starts within them");
        for (indexed.row(y), registers[start.raw()..][0..row_bytes.raw()]) |register, *out| {
            out.* = if (transparent != null and entries[register][3] < 128) transparent.? else register;
        }
    }
    return transparent;
}

const testing = std.testing;

/// A 3x2 RGBA image, a pixel a line.
const sample = [_]u8{
    255, 0, 0, 255, // red
    0, 255, 0, 255, // green
    9, 9, 9, 0, // hidden
    0, 0, 255, 255, // blue
    255, 0, 0, 255, // red
    7, 7, 7, 40, // hidden
};

fn sampleView() aperture.View {
    return .{ .width = .literal(3), .height = .literal(2), .format = .rgba8, .stride = .fromRaw(3 * 4), .pixels = &sample };
}

test "a sixel picture keeps one register for the pixels it leaves out" {
    var indexed = try aperture.quantize(testing.allocator, sampleView(), .{});
    defer indexed.deinit();
    var registers: [6]u8 = undefined;
    const transparent = drawn(indexed.view(), indexed.palette.?, &registers).?;
    try testing.expectEqual(transparent, registers[2]);
    try testing.expectEqual(transparent, registers[5]);
    for ([_]usize{ 0, 1, 3, 4 }) |i| try testing.expect(registers[i] != transparent);
    try testing.expectEqual(registers[0], registers[4]);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, indexed.palette.?[registers[0]]);

    var layers: visor.Layers = .init(testing.allocator);
    defer layers.deinit();
    const id: visor.ImageId = .fromRaw(7);
    try storeSixel(testing.allocator, &layers, id, sampleView(), .{});
    const stored = layers.image(id).?;
    try testing.expectEqual(visor.Caps.Pictures.sixel, stored.protocol);
    try testing.expectEqual(@as(u32, 3), stored.width.raw());
    try testing.expectEqual(@as(u32, 2), stored.height.raw());
}

test "an opaque picture has no undrawn register" {
    const opaque_pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    const view: aperture.View = .{ .width = .literal(2), .height = .literal(1), .format = .rgba8, .stride = .fromRaw(8), .pixels = &opaque_pixels };
    var indexed = try aperture.quantize(testing.allocator, view, .{});
    defer indexed.deinit();
    var registers: [2]u8 = undefined;
    try testing.expectEqual(@as(?u8, null), drawn(indexed.view(), indexed.palette.?, &registers));
}

test "an iTerm2 picture is a PNG of the image's pixels" {
    const file = try png(testing.allocator, sampleView());
    defer testing.allocator.free(file);
    var reader: std.Io.Reader = .fixed(file);
    var back = try aperture.decode(testing.allocator, testing.io, &reader, .rgba8, .{});
    defer back.deinit();
    try testing.expectEqualSlices(u8, &sample, back.pixels);

    var layers: visor.Layers = .init(testing.allocator);
    defer layers.deinit();
    const id: visor.ImageId = .fromRaw(9);
    try storeIterm(testing.allocator, &layers, id, sampleView(), 0);
    try testing.expectEqual(visor.Caps.Pictures.iterm, layers.image(id).?.protocol);
}

test "the layers release every allocation when storing a picture fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn store(a: Allocator) !void {
            var layers: visor.Layers = .init(a);
            defer layers.deinit();
            try storeSixel(a, &layers, .fromRaw(1), sampleView(), .{});
            try storeIterm(a, &layers, .fromRaw(2), sampleView(), 0);
        }
    }.store, .{});
}
