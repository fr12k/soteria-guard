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
/// Returns (p60, p85, p95). Propagates allocation errors.
pub fn computeThresholds(a: std.mem.Allocator, values: []f64) !struct { f64, f64, f64 } {
    if (values.len == 0) return .{ 0.0, 0.0, 0.0 };

    // Sort a copy
    var sorted = std.ArrayList(f64).empty;
    defer sorted.deinit(a);
    for (values) |v| {
        try sorted.append(a, v);
    }
    std.mem.sort(f64, sorted.items, {}, struct {
        fn lessThan(_: void, x: f64, y: f64) bool {
            return x < y;
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

pub const Calibration = struct {
    thresholds: types.Thresholds,
    method: CalibrationMethod,
    mature_file_count: u32,

    pub const CalibrationMethod = enum { percentile, fallback };
};

/// Build the full Thresholds struct by computing percentiles from file results.
/// If fewer than `min_files` files have >= `min_revisions` revisions,
/// percentile calibration is skipped and conservative fallback thresholds are used.
/// Only files meeting the revision threshold are used for percentile computation.
pub fn calibrateThresholds(
    a: std.mem.Allocator,
    files: []types.FileResult,
    min_files: u32,
    min_revisions: u32,
) !Calibration {
    if (files.len == 0) return .{ .thresholds = fallbackThresholds(), .method = .fallback, .mature_file_count = 0 };

    // Count files with enough revisions for meaningful calibration.
    var mature_files: u32 = 0;
    for (files) |f| {
        if (f.evolution.revisions >= min_revisions) {
            mature_files += 1;
        }
    }
    if (mature_files < min_files) return .{ .thresholds = fallbackThresholds(), .method = .fallback, .mature_file_count = mature_files };

    // Collect metric values from mature files only.
    var hotspot_scores = std.ArrayList(f64).empty;
    defer hotspot_scores.deinit(a);
    var complexity_vals = std.ArrayList(f64).empty;
    defer complexity_vals.deinit(a);
    var revisions_vals = std.ArrayList(f64).empty;
    defer revisions_vals.deinit(a);
    var authors_vals = std.ArrayList(f64).empty;
    defer authors_vals.deinit(a);
    var congestion_vals = std.ArrayList(f64).empty;
    defer congestion_vals.deinit(a);
    var risk_vals = std.ArrayList(f64).empty;
    defer risk_vals.deinit(a);

    for (files) |f| {
        if (f.evolution.revisions < min_revisions) continue;
        try hotspot_scores.append(a, f.signals.hotspot_score);
        try complexity_vals.append(a, f.metrics.indent_mean);
        try revisions_vals.append(a, @floatFromInt(f.evolution.revisions));
        try authors_vals.append(a, @floatFromInt(f.evolution.authors));
        try congestion_vals.append(a, f.signals.developer_congestion);
        try risk_vals.append(a, f.signals.knowledge_loss_risk);
    }

    const h = try computeThresholds(a, hotspot_scores.items);
    const c = try computeThresholds(a, complexity_vals.items);
    const r = try computeThresholds(a, revisions_vals.items);
    const aa = try computeThresholds(a, authors_vals.items);
    const cong = try computeThresholds(a, congestion_vals.items);
    const risk = try computeThresholds(a, risk_vals.items);

    return .{
        .thresholds = .{
            .p60_hotspot = h[0], .p85_hotspot = h[1], .p95_hotspot = h[2],
            .p60_complexity = c[0], .p85_complexity = c[1], .p95_complexity = c[2],
            .p60_revisions = r[0], .p85_revisions = r[1], .p95_revisions = r[2],
            .p60_authors = aa[0], .p85_authors = aa[1], .p95_authors = aa[2],
            .p60_congestion = cong[0], .p85_congestion = cong[1], .p95_congestion = cong[2],
            .p60_risk = risk[0], .p85_risk = risk[1], .p95_risk = risk[2],
        },
        .method = .percentile,
        .mature_file_count = mature_files,
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

test "calibrateThresholds fallback when not enough mature files" {
    const a = std.testing.allocator;

    // Only 1 file with >=5 revisions (need 5 files with >=5 revs by default)
    var files: [3]types.FileResult = undefined;
    files[0] = types.FileResult{
        .metrics = .{ .path = "a.zig", .loc = 100, .indent_mean = 2.0, .indent_max = 4, .indent_std = 1.0, .comment_ratio = 0.1 },
        .evolution = .{ .revisions = 10, .authors = 2, .churn = 100, .entity_effort = 0.1, .main_dev_pct = 0.5 },
        .signals = .{ .hotspot_score = 20.0, .knowledge_loss_risk = 1.0, .developer_congestion = 0.2, .complexity_trend = 0.0 },
        .hotspot_zone = .green, .complexity_zone = .green, .revisions_zone = .green, .authors_zone = .green, .congestion_zone = .green, .risk_zone = .green,
    };
    files[1] = types.FileResult{
        .metrics = .{ .path = "b.zig", .loc = 50, .indent_mean = 1.5, .indent_max = 3, .indent_std = 0.5, .comment_ratio = 0.2 },
        .evolution = .{ .revisions = 1, .authors = 1, .churn = 10, .entity_effort = 0.01, .main_dev_pct = 1.0 },
        .signals = .{ .hotspot_score = 1.5, .knowledge_loss_risk = 0.0, .developer_congestion = 1.0, .complexity_trend = 0.0 },
        .hotspot_zone = .green, .complexity_zone = .green, .revisions_zone = .green, .authors_zone = .green, .congestion_zone = .green, .risk_zone = .green,
    };
    files[2] = types.FileResult{
        .metrics = .{ .path = "c.zig", .loc = 200, .indent_mean = 4.0, .indent_max = 12, .indent_std = 2.0, .comment_ratio = 0.05 },
        .evolution = .{ .revisions = 2, .authors = 2, .churn = 50, .entity_effort = 0.05, .main_dev_pct = 0.7 },
        .signals = .{ .hotspot_score = 8.0, .knowledge_loss_risk = 1.2, .developer_congestion = 1.0, .complexity_trend = 0.0 },
        .hotspot_zone = .green, .complexity_zone = .green, .revisions_zone = .green, .authors_zone = .green, .congestion_zone = .green, .risk_zone = .green,
    };

    const cal = try calibrateThresholds(a, &files, 5, 5);
    try std.testing.expectEqual(@as(Calibration.CalibrationMethod, .fallback), cal.method);
    try std.testing.expectEqual(@as(u32, 1), cal.mature_file_count);
    try std.testing.expectEqual(@as(f64, 10), cal.thresholds.p60_hotspot);
    try std.testing.expectEqual(@as(f64, 30), cal.thresholds.p85_hotspot);
    try std.testing.expectEqual(@as(f64, 50), cal.thresholds.p95_hotspot);
}

test "calibrateThresholds percentile when enough mature files" {
    const a = std.testing.allocator;

    // 6 files, all with >=5 revisions — passes default gate (5 files, 5 revisions)
    var files: [6]types.FileResult = undefined;
    for (&files, 0..) |*f, i| {
        f.* = types.FileResult{
            .metrics = .{ .path = "f.zig", .loc = 100, .indent_mean = @floatFromInt(i + 1), .indent_max = 4, .indent_std = 1.0, .comment_ratio = 0.1 },
            .evolution = .{ .revisions = 5 + @as(u32, @intCast(i)), .authors = 1, .churn = 10, .entity_effort = 0.01, .main_dev_pct = 1.0 },
            .signals = .{ .hotspot_score = @floatFromInt(10 * (i + 1)), .knowledge_loss_risk = 0.0, .developer_congestion = 0.1, .complexity_trend = 0.0 },
            .hotspot_zone = .green, .complexity_zone = .green, .revisions_zone = .green, .authors_zone = .green, .congestion_zone = .green, .risk_zone = .green,
        };
    }

    const cal = try calibrateThresholds(a, &files, 5, 5);
    try std.testing.expectEqual(@as(Calibration.CalibrationMethod, .percentile), cal.method);
    try std.testing.expectEqual(@as(u32, 6), cal.mature_file_count);
    // With 6 files, hotspot scores 10,20,30,40,50,60:
    // p60 index = floor(0.60 * 5) = 3 → 40.0
    // p85 index = floor(0.85 * 5) = 4 → 50.0
    // p95 index = floor(0.95 * 5) = 4 → 50.0
    try std.testing.expectEqual(@as(f64, 40.0), cal.thresholds.p60_hotspot);
    try std.testing.expectEqual(@as(f64, 50.0), cal.thresholds.p85_hotspot);
}
