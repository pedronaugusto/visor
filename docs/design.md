# Visor design

The base module owns cell storage, pools, terminal input and rendering. Widgets
import the base; the base never imports widgets. `src/dependencies.zig` is the
single seam to morse, conduit, uucode and aegis. The allocator belongs to each
allocating owner; blocking operations receive the caller's `std.Io`.

## Pool identities and bytes

A screen stores 32-byte cells and exports 48-byte checked cells. The packed text
encoding remains a four-byte offset and two-byte byte length, little-endian;
a checked text carries its issuing pool identity in six additional bytes.
Links encode a table position plus one, with zero reserved for no link, and
carry the same issuing identity in their upper 48 bits.

Aegis scalar domains distinguish `PoolGeneration`, `GraphemeOffset`, `LinkOffset`,
`LinkIndex` and `ByteLength`. The public Text and Link accessors return these
domains; indexing and encoding extract `raw()` explicitly. Scalars have the
same size and alignment as their representations. A generation is an identity
of an entire screen pool. Compaction and resize prepare replacement pools,
rewrite live cells, then issue a fresh generation. Reset also invalidates pooled
handles. This is not slot removal or a slot-map generation.

An atomic issuer reserves pool identities process-wide. It validates the 48-bit
ceiling before each compare/exchange and refuses exhaustion. That safe-type
internal remains raw because reservation is atomic; a serial aegis Counter
would change its concurrency contract. Packed cell bytes and composite Link
handles also remain safe-type internals. Identity and bounds are checked when
resolving imported cells, independently of the build's runtime safety setting.

Interning validates the complete 32-bit-addressable byte extent with aegis byte
counts before allocation or mutation. Link URI and parameter offsets are both
prepared before appending either field. Allocation failure preserves the owner;
borrowed substrings are saved as local offsets across potential reallocation.
Those local pointer comparisons carry a no-danger reason: they never import an
identity or dereference a reconstructed pointer.

Hashing, equality and rendering use raw slice indices only after the pool or
screen boundary has established their bounds. The byte layout, inline tier,
whole-cell comparison and borrow lifetimes remain part of the design. Growth,
compaction, resize and destruction can invalidate borrowed pool slices even
when a checked handle's scalar value is unchanged.
