const std = @import("std");
const types = @import("types.zig");
const git_log = @import("git_log.zig");

// ── Packed pair-key helpers ──

/// Pack two file indices into a single u64 key (always sorted so a < b).
inline fn packPairKey(a: usize, b: usize) u64 {
    const min = @min(a, b);
    const max = @max(a, b);
    return (@as(u64, @intCast(min)) << 32) | @as(u64, @intCast(max));
}

inline fn unpackPairKey(key: u64) struct { min: usize, max: usize } {
    const min = @as(usize, @intCast(key >> 32));
    const max = @as(usize, @intCast(key & 0xFFFFFFFF));
    return .{ .min = min, .max = max };
}

/// Determine trend direction from split-window shared-commit counts.
fn coupleTrend(
    half: usize,
    total_commits: usize,
    first_shared: u32,
    second_shared: u32,
) types.TrendDirection {
    if (half == 0 or total_commits - half == 0) return .stable;

    const first_degree = @as(f64, @floatFromInt(first_shared)) / @as(f64, @floatFromInt(half));
    const second_degree = @as(f64, @floatFromInt(second_shared)) / @as(f64, @floatFromInt(total_commits - half));
    const ratio = if (first_degree > 0) second_degree / first_degree else if (second_degree > 0) @as(f64, 2.0) else @as(f64, 1.0);

    if (ratio > 1.3) return .rising;
    if (ratio < 0.7) return .falling;
    return .stable;
}

/// Returns coupling degree if the pair passes minimum thresholds, else null.
fn computeDegree(shared: u32, total_a: u32, total_b: u32) ?f64 {
    if (shared < 3) return null;
    if (total_a == 0 or total_b == 0) return null;

    const degree_ab = @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(total_a));
    const degree_ba = @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(total_b));
    const degree = @max(degree_ab, degree_ba);

    return if (degree >= 0.15) degree else null;
}

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

    // Single pass: index files, count totals/shared, and split per half for trend.
    const half = commit_files_list.len / 2;
    var first_half = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80).init(a);
    defer first_half.deinit();
    var second_half = std.HashMap(u64, u32, std.hash_map.AutoContext(u64), 80).init(a);
    defer second_half.deinit();

    for (commit_files_list, 0..) |cf, commit_idx| {
        if (cf.files.len < 2) continue;

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

        for (file_idxs.items) |fidx| {
            const t_gop = try total_commits_map.getOrPut(fidx);
            t_gop.value_ptr.* = if (t_gop.found_existing) t_gop.value_ptr.* + 1 else 1;
        }

        const target_map = if (commit_idx < half) &first_half else &second_half;

        for (file_idxs.items, 0..) |fidx_a, i| {
            for (file_idxs.items[i + 1 ..]) |fidx_b| {
                const key = packPairKey(fidx_a, fidx_b);

                const s_gop = try shared_map.getOrPut(key);
                s_gop.value_ptr.* = if (s_gop.found_existing) s_gop.value_ptr.* + 1 else 1;

                const h_gop = try target_map.getOrPut(key);
                h_gop.value_ptr.* = if (h_gop.found_existing) h_gop.value_ptr.* + 1 else 1;
            }
        }
    }

    if (verbose) {
        std.debug.print("  coupling: {d} files, {d} candidate pairs\n", .{ path_table.items.len, shared_map.count() });
    }

    // Build output
    var pair_count: usize = 0;
    var iter = shared_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const shared = entry.value_ptr.*;
        const unpacked = unpackPairKey(key);

        const total_a = total_commits_map.get(unpacked.min) orelse 0;
        const total_b = total_commits_map.get(unpacked.max) orelse 0;

        const degree = computeDegree(shared, total_a, total_b) orelse continue;
        const trend = coupleTrend(
            half,
            commit_files_list.len,
            first_half.get(key) orelse 0,
            second_half.get(key) orelse 0,
        );

        try results.append(a, .{
            .file_a = path_table.items[unpacked.min],
            .file_b = path_table.items[unpacked.max],
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

test "packPairKey unpackPairKey roundtrip" {
    const pairs = [_]struct { a: usize, b: usize }{
        .{ .a = 0, .b = 1 },
        .{ .a = 5, .b = 3 },
        .{ .a = 100, .b = 200 },
        .{ .a = 0xFFFFFFFF, .b = 0 },
    };

    for (pairs) |p| {
        const key = packPairKey(p.a, p.b);
        const unpacked = unpackPairKey(key);
        // pack sorts, so min/max may swap
        const expected_min = @min(p.a, p.b);
        const expected_max = @max(p.a, p.b);
        try std.testing.expectEqual(expected_min, unpacked.min);
        try std.testing.expectEqual(expected_max, unpacked.max);
    }
}
