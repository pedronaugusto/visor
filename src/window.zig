//! A clipped, offset view of a screen: the only thing drawing code holds.
//!
//! A window is a rectangle and a pointer, copied by value and made fresh
//! every frame. Everything written through one is clipped to it, so a widget
//! that draws past its edge writes nothing rather than over its neighbour.
//! Measurement allocates nothing; committed printing can grow the screen's
//! pool for an unseen grapheme longer than six bytes. The screen owns that
//! storage.
//!
//! What this file will never hold: a retained tree, a parent pointer, an
//! event, a focus model, or state that survives the frame. A window is a
//! value; if something must be remembered between frames, the caller
//! remembers it.

const api = @import("screen.zig").window_api;
pub const Rect = api.Rect;
pub const Point = api.Point;
pub const Size = api.Size;
pub const Window = api.Window;
