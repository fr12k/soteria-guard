const std = @import("std");

/// Compute the slope of a linear regression over a series of (x, y) values.
/// x values are treated as indices (0, 1, 2, ...) since we care about direction, not magnitude.
/// Returns the slope. Positive = rising complexity (deteriorating).
pub fn computeTrend(values: []const f64) f64 {
    const n = values.len;
    if (n < 2) return 0.0;

    // Use least-squares linear regression: y = a + bx
    // x is the index (0-based), y is the complexity value
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xy: f64 = 0;
    var sum_xx: f64 = 0;

    for (values, 0..) |y, i| {
        const x = @as(f64, @floatFromInt(i));
        sum_x += x;
        sum_y += y;
        sum_xy += x * y;
        sum_xx += x * x;
    }

    const nf = @as(f64, @floatFromInt(n));
    const denominator = nf * sum_xx - sum_x * sum_x;

    // Avoid division by zero (all x values are the same, which can't happen with indices)
    if (@abs(denominator) < 1e-12) return 0.0;

    const slope = (nf * sum_xy - sum_x * sum_y) / denominator;
    return slope;
}

/// Update the complexity series in each time series by matching file paths
/// against the scanned FileMetrics. This bridges git log data with static analysis.
///
/// For each time series entry, we look up the corresponding FileMetrics and
/// fill the complexity_series array. Since we only have one static snapshot,
/// we use the current indent_mean for all revisions in the trend window.
/// In a full implementation, historical snapshots would give per-revision values.
pub fn fillComplexitySeries(
    time_series: anytype, // slice of *PerFileTimeSeries or similar
    file_metrics_slice: anytype, // slice of FileMetrics
    a: std.mem.Allocator,
) !void {
    // Build a lookup from path -> indent_mean
    var path_to_complexity = std.StringHashMap(f64).init(a);
    defer path_to_complexity.deinit();

    for (file_metrics_slice) |fm| {
        try path_to_complexity.put(fm.path, fm.indent_mean);
    }

    for (time_series) |*ts| {
        if (path_to_complexity.get(ts.path)) |mean| {
            // Fill all revision slots with the current complexity value
            for (ts.complexity_series.items, 0..) |*val, i| {
                _ = i;
                val.* = mean;
            }
        }
        // If file not found in static scan (e.g., deleted), keep zeros
    }
}

test "computeTrend flat" {
    const values = [_]f64{ 2.0, 2.0, 2.0, 2.0 };
    const slope = computeTrend(&values);
    try std.testing.expect(@abs(slope) < 1e-10);
}

test "computeTrend rising" {
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const slope = computeTrend(&values);
    try std.testing.expect(slope > 0.9);
    try std.testing.expect(slope < 1.1);
}

test "computeTrend falling" {
    const values = [_]f64{ 5.0, 4.0, 3.0, 2.0, 1.0 };
    const slope = computeTrend(&values);
    try std.testing.expect(slope < -0.9);
    try std.testing.expect(slope > -1.1);
}

test "computeTrend single value" {
    try std.testing.expectEqual(@as(f64, 0.0), computeTrend(&.{ 3.14 }));
}

test "computeTrend empty" {
    try std.testing.expectEqual(@as(f64, 0.0), computeTrend(&.{}));
}

test "computeTrend two values" {
    // Two values: slope = y1 - y0
    try std.testing.expectEqual(@as(f64, 2.0), computeTrend(&.{ 1.0, 3.0 }));
    try std.testing.expectEqual(@as(f64, -2.0), computeTrend(&.{ 3.0, 1.0 }));
}
