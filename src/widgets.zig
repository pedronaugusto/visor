//! Widgets on `visor`.
//!
//! Empty, deliberately, until the base is finished and has a user. The
//! module exists now so that the shape is settled: a second module in the
//! same repository, fetched with the base and imported separately, which the
//! base never imports. A widget set that the layer under it depends on is
//! not a layer any more.
//!
//! What goes here when it is time: values, not objects. A widget is a struct
//! built at the call site, drawn into a `Window` in one call, and consumed;
//! anything that has to survive the frame is a second struct the caller owns
//! and passes by pointer. There is no retained tree, no callback, no focus
//! model and no loop — those belong to the program, which already has them.

const std = @import("std");

/// The version of this module, which is the version of the package.
pub const version = @import("visor.zig").version;

test {
    std.testing.refAllDecls(@This());
}
