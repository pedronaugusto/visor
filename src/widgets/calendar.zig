//! One month, as weeks in rows.
//!
//! Dates are three numbers and the arithmetic on them is the proleptic
//! Gregorian calendar and nothing else: no time zone, no clock, no locale.
//! A program that knows what day it is passes it in; this one only knows
//! which column a day falls in.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Style = visor.Style;
const Window = visor.Window;

/// A day, as a calendar counts them.
pub const Date = struct {
    /// The year, in the proleptic Gregorian calendar.
    year: i32,
    /// The month, one to twelve.
    month: u8,
    /// The day, one to however many the month has.
    day: u8,

    /// Whether two dates are the same day.
    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// The days of the week, counted from Monday as the calendar draws them.
pub const Weekday = enum(u3) {
    monday = 0,
    tuesday = 1,
    wednesday = 2,
    thursday = 3,
    friday = 4,
    saturday = 5,
    sunday = 6,
};

/// How many days a month has, leap years included.
pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Whether a year has a twenty-ninth of February in it.
pub fn isLeapYear(year: i32) bool {
    if (@rem(year, 400) == 0) return true;
    if (@rem(year, 100) == 0) return false;
    return @rem(year, 4) == 0;
}

/// Which day of the week a date falls on.
///
/// Sakamoto's method, which is a table and two divisions and is exact for
/// every year the proleptic Gregorian calendar covers.
pub fn weekdayOf(d: Date) Weekday {
    const shift = [12]i64{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i64 = d.year;
    if (d.month < 3) y -= 1;
    const era = @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
    const sunday_based = @mod(y + era + shift[d.month - 1] + @as(i64, d.day), 7);
    // Sakamoto counts from Sunday; this calendar counts from Monday.
    return @enumFromInt(@as(u3, @intCast(@mod(sunday_based + 6, 7))));
}

/// One month, as weeks in rows.
pub const Calendar = struct {
    /// The year shown.
    year: i32,
    /// The month shown, one to twelve.
    month: u8,
    /// The day drawn as today, or none.
    today: ?Date = null,
    /// Days drawn as chosen.
    selected: []const Date = &.{},
    /// Which day the weeks start on.
    starts_on: Weekday = .monday,
    /// Whether the month and year are named above the weeks.
    show_header: bool = true,
    /// Whether the weekday names are drawn above the days.
    show_weekdays: bool = true,
    /// The style the days draw in.
    style: Style = .{},
    /// The style the month and year draw in.
    header_style: Style = .{ .bold = true },
    /// The style the weekday names draw in.
    weekday_style: Style = .{ .dim = true },
    /// The style today draws in.
    today_style: Style = .{ .reverse = true },
    /// The style a chosen day draws in.
    selected_style: Style = .{ .underline = .single },

    /// How many columns a month takes: seven days of two columns with a
    /// space between them.
    pub const columns: u16 = 7 * 3 - 1;

    /// The names of the months, January first.
    pub const month_names = [12][]const u8{
        "January", "February", "March",     "April",   "May",      "June",
        "July",    "August",   "September", "October", "November", "December",
    };

    /// The names of the days, Monday first.
    pub const weekday_names = [7][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

    /// How many rows this month needs.
    pub fn rowsNeeded(c: Calendar) u16 {
        var rows: u16 = weeksIn(c);
        if (c.show_header) rows += 1;
        if (c.show_weekdays) rows += 1;
        return rows;
    }

    /// Draws the month.
    pub fn draw(c: Calendar, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty() or c.month < 1 or c.month > 12) return;
        var row: u16 = 0;

        if (c.show_header) {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} {d}", .{
                month_names[c.month - 1],
                c.year,
            }) catch return;
            const taken = @min(win.width(text), win.cols());
            _ = try win.printSegment(
                .{ .text = text, .style = c.header_style },
                .{
                    .col = layout.offset(@min(columns, win.cols()), taken, .center),
                    .row = row,
                    .wrap = .none,
                },
            );
            row += 1;
        }

        if (c.show_weekdays) {
            for (0..7) |i| {
                const name = weekday_names[(i + @intFromEnum(c.starts_on)) % 7];
                _ = try win.printSegment(
                    .{ .text = name, .style = c.weekday_style },
                    .{ .col = @intCast(i * 3), .row = row, .wrap = .none },
                );
            }
            row += 1;
        }

        const first_column = c.firstColumn();
        var day: u8 = 1;
        const last = daysInMonth(c.year, c.month);
        var column: u16 = first_column;
        while (day <= last) : (day += 1) {
            if (row >= win.rows()) return;
            const date: Date = .{ .year = c.year, .month = c.month, .day = day };
            var buf: [2]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d:>2}", .{day}) catch unreachable;
            _ = try win.printSegment(
                .{ .text = text, .style = c.styleOf(date) },
                .{ .col = @intCast(column * 3), .row = row, .wrap = .none },
            );
            column += 1;
            if (column == 7) {
                column = 0;
                row += 1;
            }
        }
    }

    /// Which column of the first week the first of the month falls in.
    fn firstColumn(c: Calendar) u16 {
        const first: Date = .{ .year = c.year, .month = c.month, .day = 1 };
        const weekday = @intFromEnum(weekdayOf(first));
        return (@as(u16, weekday) + 7 - @intFromEnum(c.starts_on)) % 7;
    }

    /// How many rows of days the month takes.
    fn weeksIn(c: Calendar) u16 {
        const days = daysInMonth(c.year, c.month);
        if (days == 0) return 0;
        return (c.firstColumn() + days + 6) / 7;
    }

    /// The style one day draws in: chosen over today over plain.
    fn styleOf(c: Calendar, date: Date) Style {
        for (c.selected) |s| {
            if (s.eql(date)) return c.selected_style;
        }
        if (c.today) |t| {
            if (t.eql(date)) return c.today_style;
        }
        return c.style;
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "weekday calculation covers the extreme i32 years" {
    const cases = [_]Date{
        .{ .year = std.math.minInt(i32), .month = 1, .day = 1 },
        .{ .year = std.math.maxInt(i32), .month = 12, .day = 31 },
    };
    for (cases) |date| {
        var equivalent = date;
        equivalent.year = @intCast(2000 + @mod(@as(i64, date.year), 400));
        try testing.expectEqual(weekdayOf(equivalent), weekdayOf(date));
    }
}

test "a month starts in the column its first day falls in" {
    var h: Harness = try .init(testing.allocator, 20, 8);
    defer h.deinit();
    try (Calendar{ .year = 2026, .month = 9 }).draw(h.window());
    try h.expectFrame(
        \\   September 2026
        \\Mo Tu We Th Fr Sa Su
        \\    1  2  3  4  5  6
        \\ 7  8  9 10 11 12 13
        \\14 15 16 17 18 19 20
        \\21 22 23 24 25 26 27
        \\28 29 30
        \\
        \\
    );
}

test "weeks can start on Sunday instead" {
    var h: Harness = try .init(testing.allocator, 20, 3);
    defer h.deinit();
    try (Calendar{
        .year = 2026,
        .month = 9,
        .starts_on = .sunday,
        .show_header = false,
    }).draw(h.window());
    try h.expectFrame(
        \\Su Mo Tu We Th Fr Sa
        \\       1  2  3  4  5
        \\ 6  7  8  9 10 11 12
        \\
    );
}

test "today and the chosen days are drawn in their own styles" {
    var h: Harness = try .init(testing.allocator, 20, 3);
    defer h.deinit();
    try (Calendar{
        .year = 2026,
        .month = 9,
        .show_header = false,
        .show_weekdays = false,
        .today = .{ .year = 2026, .month = 9, .day = 3 },
        .selected = &.{.{ .year = 2026, .month = 9, .day = 5 }},
    }).draw(h.window());
    // The first falls on a Tuesday, so the third is the fourth column and
    // the fifth is the sixth.
    _ = try h.frame();
    try testing.expect(h.styleAt(10, 0).reverse);
    try testing.expectEqual(visor.Underline.single, h.styleAt(16, 0).underline);
    try testing.expect(!h.styleAt(4, 0).reverse);
}

test "the days of the week are the ones the calendar really has" {
    try testing.expectEqual(Weekday.thursday, weekdayOf(.{ .year = 1970, .month = 1, .day = 1 }));
    try testing.expectEqual(Weekday.saturday, weekdayOf(.{ .year = 2000, .month = 1, .day = 1 }));
    try testing.expectEqual(Weekday.tuesday, weekdayOf(.{ .year = 2026, .month = 9, .day = 1 }));
    try testing.expectEqual(Weekday.monday, weekdayOf(.{ .year = 1900, .month = 1, .day = 1 }));
}

test "February knows about leap years" {
    try testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try testing.expectEqual(@as(u8, 28), daysInMonth(2025, 2));
    try testing.expectEqual(@as(u8, 29), daysInMonth(2000, 2));
    try testing.expectEqual(@as(u8, 28), daysInMonth(1900, 2));
    try testing.expect(!isLeapYear(1900));
    try testing.expect(isLeapYear(2000));
}

test "a month knows how many rows it needs" {
    try testing.expectEqual(@as(u16, 7), (Calendar{ .year = 2026, .month = 9 }).rowsNeeded());
    // August 2026 starts on a Saturday, so it runs into a sixth week.
    try testing.expectEqual(@as(u16, 8), (Calendar{ .year = 2026, .month = 8 }).rowsNeeded());
}

test "every day of every month is drawn once and only once" {
    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        for ([_]Weekday{ .monday, .sunday }) |starts_on| {
            const c: Calendar = .{
                .year = 2026,
                .month = month,
                .starts_on = starts_on,
                .show_header = false,
                .show_weekdays = false,
            };
            var h: Harness = try .init(testing.allocator, Calendar.columns, c.rowsNeeded());
            defer h.deinit();
            try c.draw(h.window());
            const grid = try h.frame();

            var seen: [32]u8 = @splat(0);
            var it = std.mem.tokenizeAny(u8, grid, " \n");
            while (it.next()) |word| {
                const day = try std.fmt.parseInt(u8, word, 10);
                seen[day] += 1;
            }
            var day: u8 = 1;
            while (day <= daysInMonth(2026, month)) : (day += 1) {
                try testing.expectEqual(@as(u8, 1), seen[day]);
            }
            var beyond: u8 = daysInMonth(2026, month) + 1;
            while (beyond < seen.len) : (beyond += 1) {
                try testing.expectEqual(@as(u8, 0), seen[beyond]);
            }
        }
    }
}
