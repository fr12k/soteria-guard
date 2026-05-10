const std = @import("std");
const types = @import("types.zig");

/// Compute fallback (bootstrap) thresholds when no history DB exists.
/// These are conservative hard-coded values from the design doc.
pub fn fallbackThresholds() types.Thresholds {
    return .{
        .p60_hotspot = 10,
        .p85_hotspot = 30,
        .p95_hotspot = 50,
        .p60_complexity = 3.0,
        .p85_complexity = 5.0,
        .p95_complexity = 8.0,
        .p60_revisions = 3,
        .p85_revisions = 8,
        .p95_revisions = 15,
        .p60_authors = 1,
        .p85_authors = 3,
        .p95_authors = 5,
        .p60_congestion = 0.2,
        .p85_congestion = 0.5,
        .p95_congestion = 0.8,
        .p60_risk = 1.0,
        .p85_risk = 3.0,
        .p95_risk = 6.0,
    };
}

/// Compute a percentile value from a sorted slice of f64 values.
/// p should be in range 0.0 – 1.0.
pub fn percentile(sorted_values: []f64, p: f64) f64 {
    if (sorted_values.len == 0) return 0.0;
    if (p <= 0.0) return sorted_values[0];
    if (p >= 1.0) return sorted_values[sorted_values.len - 1];

    const index = @as(usize, @intFromFloat(@floor(p * @as(f64, @floatFromInt(sorted_values.len - 1)))));
    return sorted_values[index];
}

/// Compute percentile thresholds from a slice of f64 values.
/// Returns (p60, p85, p95).
pub fn computeThresholds(values: []f64) struct { f64, f64, f64 } {
    if (values.len == 0) return .{ 0.0, 0.0, 0.0 };

    // Sort a copy
    var sorted = std.ArrayList(f64).empty;
    defer sorted.deinit(std.heap.page_allocator);
    for (values) |v| {
        sorted.append(std.heap.page_allocator, v) catch {};
    }
    std.mem.sort(f64, sorted.items, {}, struct {
        fn lessThan(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.lessThan);

    return .{
        percentile(sorted.items, 0.60),
        percentile(sorted.items, 0.85),
        percentile(sorted.items, 0.95),
    };
}

/// Assign a zone (1–4) to a value based on threshold cutoffs.
pub fn assignZone(value: f64, p60: f64, p85: f64, p95: f64) types.Zone {
    if (value > p95) return .red;
    if (value > p85) return .orange;
    if (value > p60) return .yellow;
    return .green;
}

/// Build the full Thresholds struct by computing percentiles from file results.
pub fn calibrateThresholds(files: []types.FileResult) types.Thresholds {
    if (files.len == 0) return fallbackThresholds();

    var hotspot_scores = std.ArrayList(f64).empty;
    defer hotspot_scores.deinit(std.heap.page_allocator);
    var complexity_vals = std.ArrayList(f64).empty;
    defer complexity_vals.deinit(std.heap.page_allocator);
    var revisions_vals = std.ArrayList(f64).empty;
    defer revisions_vals.deinit(std.heap.page_allocator);
    var authors_vals = std.ArrayList(f64).empty;
    defer authors_vals.deinit(std.heap.page_allocator);
    var congestion_vals = std.ArrayList(f64).empty;
    defer congestion_vals.deinit(std.heap.page_allocator);
    var risk_vals = std.ArrayList(f64).empty;
    defer risk_vals.deinit(std.heap.page_allocator);

    for (files) |f| {
        hotspot_scores.append(std.heap.page_allocator, f.signals.hotspot_score) catch {};
        complexity_vals.append(std.heap.page_allocator, f.metrics.indent_mean) catch {};
        revisions_vals.append(std.heap.page_allocator, @floatFromInt(f.evolution.revisions)) catch {};
        authors_vals.append(std.heap.page_allocator, @floatFromInt(f.evolution.authors)) catch {};
        congestion_vals.append(std.heap.page_allocator, f.signals.developer_congestion) catch {};
        risk_vals.append(std.heap.page_allocator, f.signals.knowledge_loss_risk) catch {};
    }

    const h = computeThresholds(hotspot_scores.items);
    const c = computeThresholds(complexity_vals.items);
    const r = computeThresholds(revisions_vals.items);
    const a = computeThresholds(authors_vals.items);
    const cong = computeThresholds(congestion_vals.items);
    const risk = computeThresholds(risk_vals.items);

    return .{
        .p60_hotspot = h[0], .p85_hotspot = h[1], .p95_hotspot = h[2],
        .p60_complexity = c[0], .p85_complexity = c[1], .p95_complexity = c[2],
        .p60_revisions = r[0], .p85_revisions = r[1], .p95_revisions = r[2],
        .p60_authors = a[0], .p85_authors = a[1], .p95_authors = a[2],
        .p60_congestion = cong[0], .p85_congestion = cong[1], .p95_congestion = cong[2],
        .p60_risk = risk[0], .p85_risk = risk[1], .p95_risk = risk[2],
    };
}

/// Assign zones to all files in a report given calibrated thresholds.
pub fn assignAllZones(files: []types.FileResult, t: types.Thresholds) void {
    for (files) |*f| {
        f.hotspot_zone = assignZone(f.signals.hotspot_score, t.p60_hotspot, t.p85_hotspot, t.p95_hotspot);
        f.complexity_zone = assignZone(f.metrics.indent_mean, t.p60_complexity, t.p85_complexity, t.p95_complexity);
        f.revisions_zone = assignZone(@floatFromInt(f.evolution.revisions), t.p60_revisions, t.p85_revisions, t.p95_revisions);
        f.authors_zone = assignZone(@floatFromInt(f.evolution.authors), t.p60_authors, t.p85_authors, t.p95_authors);
        f.congestion_zone = assignZone(f.signals.developer_congestion, t.p60_congestion, t.p85_congestion, t.p95_congestion);
        f.risk_zone = assignZone(f.signals.knowledge_loss_risk, t.p60_risk, t.p85_risk, t.p95_risk);
    }
}

test "percentile basics" {
    const vals = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };
    try std.testing.expectEqual(@as(f64, 6.0), percentile(&vals, 0.60));
    try std.testing.expectEqual(@as(f64, 8.0), percentile(&vals, 0.85));
    try std.testing.expectEqual(@as(f64, 9.0), percentile(&vals, 0.95));
}

test "percentile edges" {
    const vals = [_]f64{ 5.0 };
    try std.testing.expectEqual(@as(f64, 5.0), percentile(&vals, 0.5));
    try std.testing.expectEqual(@as(f64, 5.0), percentile(&vals, 0.0));
    try std.testing.expectEqual(@as(f64, 5.0), percentile(&vals, 1.0));
}

test "percentile empty" {
    try std.testing.expectEqual(@as(f64, 0.0), percentile(&.{}[0..], 0.5));
}

test "assignZone values" {
    const t = types.Thresholds{
        .p60_hotspot = 10,
        .p85_hotspot = 30,
        .p95_hotspot = 50,
    };

    try std.testing.expectEqual(types.Zone.green, assignZone(5.0, t.p60_hotspot, t.p85_hotspot, t.p95_hotspot));
    try std.testing.expectEqual(types.Zone.yellow, assignZone(15.0, t.p60_hotspot, t.p85_hotspot, t.p95_hotspot));
    try std.testing.expectEqual(types.Zone.orange, assignZone(35.0, t.p60_hotspot, t.p85_hotspot, t.p95_hotspot));
    try std.testing.expectEqual(types.Zone.red, assignZone(55.0, t.p60_hotspot, t.p85_hotspot, t.p95_hotspot));
}

test "fallback thresholds sanity" {
    const t = fallbackThresholds();
    try std.testing.expect(t.p60_hotspot < t.p85_hotspot);
    try std.testing.expect(t.p85_hotspot < t.p95_hotspot);
}
