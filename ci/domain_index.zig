const visor = @import("visor");
export fn rejectMixedIndex() visor.LinkIndex {
    return visor.GraphemeOffset.fromRaw(1);
}
