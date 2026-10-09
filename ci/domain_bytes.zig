const visor = @import("visor");
export fn rejectMixedBytes() visor.LinkIndex {
    return visor.ByteLength.fromRaw(1);
}
