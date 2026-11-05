/// Candidate ordering only: the caller must bind the real listener before committing a port.
/// A separate availability probe would leave a race between probing and binding.
public enum AutomaticPortPolicy {
    public static let range: ClosedRange<UInt16> = 49_152...65_535

    /// Each candidate appears once. Reuse a committed port on later launches so its Origin stays stable.
    public static func candidates(excluding excluded: Set<UInt16> = [], limit: Int = 128) -> [UInt16] {
        var generator = SystemRandomNumberGenerator()
        return candidates(excluding: excluded, limit: limit, using: &generator)
    }

    static func candidates<R: RandomNumberGenerator>(excluding excluded: Set<UInt16> = [], limit: Int = 128, using generator: inout R) -> [UInt16] {
        guard limit > 0 else { return [] }
        return Array(range.filter { !excluded.contains($0) }.shuffled(using: &generator).prefix(limit))
    }
}
