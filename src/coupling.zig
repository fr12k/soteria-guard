const std = @import("std");
const types = @import("types.zig");
const git_log = @import("git_log.zig");

/// Build a sparse co-change (coupling) matrix from git log commit→files data.
///
/// Algorithm (§8.2 of design):
///   For each commit, take its set of files modified.
///   For each pair (a, b) in that set (a ≠ b):
///     increment shared_commits[a][b]
///     increment total_commits[a]
///     increment total_commits[b]
///
/// Only pairs with shared_commits ≥ 3 and coupling_degree ≥ 0.15 are kept.
///
/// Trend annotation (§8.4): split history into two equal windows,
/// compare the coupling degree in each to determine if coupling is
/// getting stronger (rising), weaker (falling), or stable.
pub fn computeCoupling(
    a: std.mem.Allocator,
    commit_files_list: []const git_log.CommitFiles,
    verbose: bool,
) !std.ArrayList(types.CouplingPair) {
    var results = std.ArrayList(types.CouplingPair).empty;
    errdefer results.deinit(a);

    if (commit_files_list.len < 2) {
        if (verbose) std.debug.print("  coupling: need at least 2 commits, got {d}\n", .{commit_files_list.len});
        return results;
    }

    // Index paths to avoid string-keyed maps everywhere
    var path_to_idx = std.StringHashMap(usize).init(a);
    defer path_to_idx.deinit();
    var path_table = std.ArrayList([]const u8).empty;
    defer path_table.deinit(a);

    // We store the matrix sparsely: only pairs that pass thresholds.
    // But first we need to count shared_commits and total_commits.
    // Strategy: build a packed u64 key from (path_index_a, path_index_b)
    // and store shared_commits in a HashMap.
    //
    // Key encoding: (min_idx << 32) | max_idx  (always sorted so a < b)
    var shared_map = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80).init(a);
    defer shared_map.deinit();
    var total_commits_map = std.HashMap(usize, u32, std.hash_map.AutoContext(usize), 80).init(a);
    defer total_commits_map.deinit();

    // First pass: count total_commits per file (across commits, not per pair)
    // and shared_commits per pair.
    // We also need the halfway split for trend analysis.
    const half = commit_files_list.len / 2;

    for (commit_files_list, 0..) |cf, commit_idx| {
        if (cf.files.len < 2) continue;

        // Index each file in this commit
        var file_idxs = std.ArrayList(usize).empty;
        defer file_idxs.deinit(a);

        for (cf.files) |file_path| {
            const gop = try path_to_idx.getOrPut(file_path);
            if (!gop.found_existing) {
                gop.value_ptr.* = path_table.items.len;
                try path_table.append(a, file_path);
            }
            try file_idxs.append(a, gop.value_ptr.*);
        }

        // Increment total_commits for each file in this commit
        for (file_idxs.items) |fidx| {
            const t_gop = try total_commits_map.getOrPut(fidx);
            if (t_gop.found_existing) {
                t_gop.value_ptr.* += 1;
            } else {
                t_gop.value_ptr.* = 1;
            }
        }

        // Increment shared_commits for all pairs in this commit
        for (file_idxs.items, 0..) |fidx_a, i| {
            for (file_idxs.items[i + 1 ..]) |fidx_b| {
                const min = @min(fidx_a, fidx_b);
                const max = @max(fidx_a, fidx_b);
                const key = (@as(u64, @intCast(min)) << 32) | @as(u64, @intCast(max));

                const s_gop = try shared_map.getOrPut(key);
                if (s_gop.found_existing) {
                    s_gop.value_ptr.* += 1;
                } else {
                    s_gop.value_ptr.* = 1;

                    // Also store the commit index range start (for trend)
                    // We need two-pass: store first_half / second_half
                }
            }
        }

        _ = commit_idx;
    }

    if (verbose) {
        std.debug.print("  coupling: {d} files, {d} candidate pairs\n", .{ path_table.items.len, shared_map.count() });
    }

    // We need per-pair half counts for trend analysis.
    // Simpler approach: re-do the counting splitting into two halves.
    var first_half = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80).init(a);
    defer first_half.deinit();
    var second_half = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80).init(a);
    defer second_half.deinit();

    for (commit_files_list, 0..) |cf, commit_idx| {
        if (cf.files.len < 2) continue;

        var file_idxs = std.ArrayList(usize).empty;
        defer file_idxs.deinit(a);

        for (cf.files) |file_path| {
            if (path_to_idx.get(file_path)) |fidx| {
                try file_idxs.append(a, fidx);
            }
        }

        const target_map = if (commit_idx < half) &first_half else &second_half;

        for (file_idxs.items, 0..) |fidx_a, i| {
            for (file_idxs.items[i + 1 ..]) |fidx_b| {
                const min = @min(fidx_a, fidx_b);
                const max = @max(fidx_a, fidx_b);
                const key = (@as(u64, @intCast(min)) << 32) | @as(u64, @intCast(max));

                const gop = try target_map.getOrPut(key);
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }
    }

    // Build output: iterate shared_map, compute degree, filter by thresholds
    var pair_count: usize = 0;
    var iter = shared_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const shared = entry.value_ptr.*;
        const min = @as(usize, @intCast(key >> 32));
        const max = @as(usize, @intCast(key & 0xFFFFFFFF));

        if (shared < 3) continue;

        const total_a = total_commits_map.get(min) orelse 0;
        const total_b = total_commits_map.get(max) orelse 0;
        if (total_a == 0 or total_b == 0) continue;

        const degree_ab = @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(total_a));
        const degree_ba = @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(total_b));
        const degree = @max(degree_ab, degree_ba);

        if (degree < 0.15) continue;

        // Trend: compare first_half degree vs second_half degree
        const first_shared = first_half.get(key) orelse 0;
        const second_shared = second_half.get(key) orelse 0;

        // Total per half may differ; compute degree per half
        // For simplicity, use rough comparison of shared count normalized
        var trend: types.TrendDirection = .stable;
        if (half > 0 and (commit_files_list.len - half) > 0) {
            const first_degree = @as(f64, @floatFromInt(first_shared)) / @as(f64, @floatFromInt(half));
            const second_degree = @as(f64, @floatFromInt(second_shared)) / @as(f64, @floatFromInt(commit_files_list.len - half));
            const ratio = if (first_degree > 0) second_degree / first_degree else if (second_degree > 0) @as(f64, 2.0) else @as(f64, 1.0);

            if (ratio > 1.3) {
                trend = .rising;
            } else if (ratio < 0.7) {
                trend = .falling;
            }
        }

        const file_a = path_table.items[min];
        const file_b = path_table.items[max];

        try results.append(a, .{
            .file_a = file_a,
            .file_b = file_b,
            .shared_commits = shared,
            .total_commits_a = total_a,
            .total_commits_b = total_b,
            .degree = degree,
            .trend = trend,
        });
        pair_count += 1;
    }

    if (verbose) {
        std.debug.print("  coupling: {d} pairs after filtering\n", .{pair_count});
    }

    return results;
}

test "computeCoupling empty" {
    const a = std.testing.allocator;
    const results = try computeCoupling(a, &.{}, false);
    defer results.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "computeCoupling single commit" {
    const a = std.testing.allocator;
    const commits = try a.alloc(git_log.CommitFiles, 1);
    defer a.free(commits);
    commits[0] = .{
        .hash = "abc123",
        .files = try a.dupe([]const u8, &[_][]const u8{ "a.zig", "b.zig" }),
    };
    defer a.free(commits[0].files);

    const results = try computeCoupling(a, commits, false);
    defer results.deinit(a);
    // Need at least 2 commits
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "computeCoupling basic pair" {
    const a = std.testing.allocator;

    // Create 4 commits, each touching a.zig + b.zig together
    var commits = std.ArrayList(git_log.CommitFiles).empty;
    defer commits.deinit(a);

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const files = try a.alloc([]const u8, 2);
        files[0] = try a.dupe(u8, "a.zig");
        files[1] = try a.dupe(u8, "b.zig");
        try commits.append(a, .{
            .hash = try a.dupe(u8, "hash_placeholder"),
            .files = files,
        });
    }

    const results = try computeCoupling(a, commits.items, false);
    defer {
        for (results.items) |*r| {
            _ = r;
        }
        results.deinit(a);
    }

    // Should find one pair: a.zig ↔ b.zig with degree 1.0
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(f64, 1.0), results.items[0].degree);
    try std.testing.expect(results.items[0].shared_commits >= 3);
}
