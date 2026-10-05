//! Bounded selection movement shared by lists and tables.
pub const Direction = enum { next, previous };

pub fn move(selected: ?usize, count: usize, comptime direction: Direction) ?usize {
    if (count == 0) return null;
    const last = count - 1;
    return if (selected) |index| switch (direction) {
        .next => @min(index +| 1, last),
        .previous => @min(index -| 1, last),
    } else switch (direction) {
        .next => 0,
        .previous => last,
    };
}
