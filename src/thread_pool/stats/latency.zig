const std = @import("std");
const types = @import("../types.zig");

pub const LatencyHistogram = struct {
    const bucket_count = 64;

    counts: [bucket_count]u64 = [_]u64{0} ** bucket_count,
    count: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    sum_ns: u128 = 0,

    pub fn observe(self: *LatencyHistogram, value_ns: u64) void {
        const bucket = bucketIndex(value_ns);
        self.counts[bucket] += 1;
        self.count += 1;
        self.sum_ns += value_ns;
        if (value_ns < self.min_ns) self.min_ns = value_ns;
        if (value_ns > self.max_ns) self.max_ns = value_ns;
    }

    pub fn merge(self: *LatencyHistogram, other: LatencyHistogram) void {
        for (&self.counts, other.counts) |*dst, src| {
            dst.* += src;
        }
        self.count += other.count;
        self.sum_ns += other.sum_ns;
        if (other.count > 0) {
            if (other.min_ns < self.min_ns) self.min_ns = other.min_ns;
            if (other.max_ns > self.max_ns) self.max_ns = other.max_ns;
        }
    }

    pub fn summary(self: LatencyHistogram) types.LatencySummary {
        if (self.count == 0) return .{};
        return .{
            .count = self.count,
            .min_ns = self.min_ns,
            .mean_ns = @as(u64, @intCast(self.sum_ns / self.count)),
            .p50_ns = quantile(self, 50),
            .p95_ns = quantile(self, 95),
            .p99_ns = quantile(self, 99),
            .max_ns = self.max_ns,
        };
    }

    fn bucketIndex(value_ns: u64) usize {
        if (value_ns <= 1) return 0;
        var idx: usize = 0;
        var value = value_ns;
        while (value > 1 and idx < bucket_count - 1) : (idx += 1) {
            value >>= 1;
        }
        return idx;
    }

    fn bucketUpperBound(index: usize) u64 {
        if (index == 0) return 1;
        if (index >= bucket_count - 1) return std.math.maxInt(u64);
        return @as(u64, 1) << @as(u6, @intCast(index));
    }

    fn quantile(self: LatencyHistogram, percentile: u8) u64 {
        const target = @max((self.count * percentile + 99) / 100, 1);
        var seen: u64 = 0;
        for (self.counts, 0..) |bucket_count_value, idx| {
            seen += bucket_count_value;
            if (seen >= target) return bucketUpperBound(idx);
        }
        return self.max_ns;
    }
};

test "latency histogram records quantiles" {
    var histogram = LatencyHistogram{};
    histogram.observe(10);
    histogram.observe(20);
    histogram.observe(30);
    const summary = histogram.summary();
    try std.testing.expectEqual(@as(u64, 3), summary.count);
    try std.testing.expect(summary.p50_ns >= 10);
    try std.testing.expect(summary.max_ns >= 30);
}
