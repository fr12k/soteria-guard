const std = @import("std");
const types = @import("types.zig");
const git_log = @import("git_log.zig");

/// Compute evolutionary metrics from git log data.
/// Takes the per-file time series and produces EvolutionMetrics for each file.
pub fn computeEvolutionMetrics(
    a: std.mem.Allocator,
    time_series_list: []git_log.PerFileTimeSeries,
    verbose: bool,
) !std.ArrayList(types.EvolutionMetrics) {
    var results = std.ArrayList(types.EvolutionMetrics).empty;
    errdefer results.deinit(a);

    // First pass: compute total churn across all files for entity_effort
    var total_churn: u64 = 0;
    for (time_series_list) |ts| {
        total_churn += ts.churn;
    }

    for (time_series_list) |ts| {
        var max_author_commits: u32 = 0;
        var author_iter = ts.author_counts.iterator();
        while (author_iter.next()) |entry| {
            if (entry.value_ptr.* > max_author_commits) {
                max_author_commits = entry.value_ptr.*;
            }
        }

        const main_dev_pct: f64 = if (ts.revisions > 0)
            @as(f64, @floatFromInt(max_author_commits)) / @as(f64, @floatFromInt(ts.revisions))
        else
            0.0;

        const entity_effort: f64 = if (total_churn > 0)
            @as(f64, @floatFromInt(ts.churn)) / @as(f64, @floatFromInt(total_churn))
        else
            0.0;

        try results.append(a, .{
            .revisions = ts.revisions,
            .authors = @as(u32, @intCast(ts.author_counts.count())),
            .churn = ts.churn,
            .entity_effort = entity_effort,
            .main_dev_pct = main_dev_pct,
        });

        if (verbose) {
            std.debug.print("  churn {s}: revisions={d}, authors={d}, churn={d}, main_dev={d:.2}\n", .{
                ts.path, ts.revisions, ts.author_counts.count(), ts.churn, main_dev_pct,
            });
        }
    }

    return results;
}

test "computeEvolutionMetrics basic" {
    const a = std.testing.allocator;

    // Build a minimal time series list
    var ts_list = std.ArrayList(git_log.PerFileTimeSeries).empty;
    defer {
        for (ts_list.items) |*item| item.deinit(a);
        ts_list.deinit(a);
    }

    // File with 5 revisions, 2 authors
    {
        var author_counts = std.StringHashMap(u32).init(a);
        try author_counts.put("Alice", 3);
        try author_counts.put("Bob", 2);

        try ts_list.append(a, .{
            .path = "src/main.zig",
            .revisions = 5,
            .author_counts = author_counts,
            .churn = 200,
            .complexity_series = std.ArrayList(f64).empty,
            .timestamps = std.ArrayList([]const u8).empty,
            .last_commit_hash = null,
        });
    }

    // File with 2 revisions, 1 author
    {
        var author_counts = std.StringHashMap(u32).init(a);
        try author_counts.put("Alice", 2);

        try ts_list.append(a, .{
            .path = "src/utils.zig",
            .revisions = 2,
            .author_counts = author_counts,
            .churn = 50,
            .complexity_series = std.ArrayList(f64).empty,
            .timestamps = std.ArrayList([]const u8).empty,
            .last_commit_hash = null,
        });
    }

    const results = try computeEvolutionMetrics(a, ts_list.items, false);
    defer results.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);

    // main.zig
    try std.testing.expectEqual(@as(u32, 5), results.items[0].revisions);
    try std.testing.expectEqual(@as(u32, 2), results.items[0].authors);
    try std.testing.expectEqual(@as(u32, 200), results.items[0].churn);
    try std.testing.expectEqual(@as(f64, 0.6), results.items[0].main_dev_pct); // Alice 3/5
    try std.testing.expect(results.items[0].entity_effort > 0.75); // 200/250

    // utils.zig
    try std.testing.expectEqual(@as(u32, 2), results.items[1].revisions);
    try std.testing.expectEqual(@as(u32, 1), results.items[1].authors);
    try std.testing.expectEqual(@as(u32, 50), results.items[1].churn);
    try std.testing.expectEqual(@as(f64, 1.0), results.items[1].main_dev_pct); // Alice 2/2
}

test "computeEvolutionMetrics empty" {
    const a = std.testing.allocator;
    const results = try computeEvolutionMetrics(a, &.{}, false);
    defer results.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}
