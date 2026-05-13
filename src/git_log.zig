const std = @import("std");
const types = @import("types.zig");

/// Parsed commit info from git log.
pub const ParsedCommit = struct {
    hash: []const u8,
    date: []const u8,
    author: []const u8,
    email: []const u8,
};

/// Single numstat line: added/deleted/path.
pub const FileEntry = struct {
    added: u32,
    deleted: u32,
    path: []const u8,
};

/// Per-file time series accumulated from git history.
pub const PerFileTimeSeries = struct {
    path: []const u8,
    revisions: u32,
    /// HashMap from author name string (arena-owned) → commit count
    author_counts: std.StringHashMap(u32),
    churn: u32,
    /// Per-revision mean indentation (filled in later by trend analysis)
    complexity_series: std.ArrayList(f64),
    /// ISO date strings per revision
    timestamps: std.ArrayList([]const u8),
    /// Last commit hash seen for this file (to avoid overcounting within a commit)
    last_commit_hash: ?[]const u8,

    pub fn deinit(self: *PerFileTimeSeries, allocator: std.mem.Allocator) void {
        self.author_counts.deinit();
        self.complexity_series.deinit(allocator);
        self.timestamps.deinit(allocator);
    }
};

/// Parse a single numstat line: `<added>\t<deleted>\t<path>`.
/// Returns null for binary or rename lines (indicated by `-` or `=>`).
pub fn parseNumstatLine(line: []const u8, a: std.mem.Allocator) !?FileEntry {
    // Skip binary/rename lines
    if (std.mem.indexOf(u8, line, "-\t-") != null) return null;
    if (std.mem.indexOf(u8, line, "=>") != null) return null;

    var iter = std.mem.splitScalar(u8, line, '\t');
    const added_str = iter.next() orelse return null;
    const deleted_str = iter.next() orelse return null;
    const path = iter.next() orelse return null;

    // Parse added/deleted (may be "-" for binary files)
    const added = std.fmt.parseInt(u32, added_str, 10) catch return null;
    const deleted = std.fmt.parseInt(u32, deleted_str, 10) catch return null;

    const path_owned = try a.dupe(u8, path);
    return FileEntry{
        .added = added,
        .deleted = deleted,
        .path = path_owned,
    };
}

/// Per-commit file set entry for coupling analysis.
pub const CommitFiles = struct {
    hash: []const u8,
    files: []const []const u8,
};

/// Shared helper: spawn git with the given argv, capture stdout/stderr, check exit code.
fn runGitAndCapture(
    a: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    verbose: bool,
) !struct { stdout: []u8, stderr: []u8 } {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_output = std.ArrayList(u8).empty;
    errdefer stdout_output.deinit(a);
    if (child.stdout) |child_stdout| {
        var read_buf: [8192]u8 = undefined;
        var reader = child_stdout.reader(io, &read_buf);
        try reader.interface.appendRemaining(a, &stdout_output, std.Io.Limit.limited(1024 * 1024 * 10));
    }

    var stderr_output = std.ArrayList(u8).empty;
    errdefer stderr_output.deinit(a);
    if (child.stderr) |child_stderr| {
        var read_buf: [4096]u8 = undefined;
        var reader = child_stderr.reader(io, &read_buf);
        reader.interface.appendRemaining(a, &stderr_output, std.Io.Limit.limited(4096)) catch {};
    }

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                if (verbose) {
                    std.debug.print("  git exited with code {d}\n", .{code});
                    std.debug.print("  stderr: {s}\n", .{stderr_output.items});
                }
                return error.GitLogFailed;
            }
        },
        else => return error.GitLogFailed,
    }

    return .{
        .stdout = try stdout_output.toOwnedSlice(a),
        .stderr = try stderr_output.toOwnedSlice(a),
    };
}

/// Run `git log --name-only` to extract per-commit file sets for coupling.
/// This is a separate pass from `runGitLog` because coupling needs commit→set
/// structure rather than file→time-series structure.
///
/// Git command:
///   git -C <repo_path> log --name-only --format="COMMIT%n%H" --after="<after>" --no-renames
pub fn runGitLogNameOnly(
    a: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    after: []const u8,
    verbose: bool,
) !std.ArrayList(CommitFiles) {
    if (verbose) {
        std.debug.print("  running git log --name-only --after=\"{s}\" in {s}\n", .{ after, repo_path });
    }

    const after_arg = try std.fmt.allocPrint(a, "--after={s}", .{after});
    const argv = &[_][]const u8{
        "git",
        "-C",
        repo_path,
        "log",
        "--name-only",
        "--format=COMMIT%n%H",
        after_arg,
        "--no-renames",
    };

    const output = try runGitAndCapture(a, io, argv, verbose);
    defer a.free(output.stdout);
    defer a.free(output.stderr);

    return parseGitNameOnlyOutput(a, output.stdout, verbose);
}

/// Parse git log --name-only output into a list of CommitFiles.
fn parseGitNameOnlyOutput(
    a: std.mem.Allocator,
    output: []const u8,
    verbose: bool,
) !std.ArrayList(CommitFiles) {
    var results = std.ArrayList(CommitFiles).empty;
    errdefer results.deinit(a);

    var lines = std.mem.splitScalar(u8, output, '\n');
    var current_hash: ?[]const u8 = null;
    var current_files = std.ArrayList([]const u8).empty;
    defer current_files.deinit(a);
    var total_commits: usize = 0;

    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "COMMIT")) {
            // Save previous commit's data
            if (current_hash) |hash| {
                const files = try current_files.toOwnedSlice(a);
                try results.append(a, .{ .hash = hash, .files = files });
                current_files = std.ArrayList([]const u8).empty;
                total_commits += 1;
            }
            current_hash = null;
            continue;
        }

        if (current_hash == null) {
            if (line.len == 40) {
                current_hash = try a.dupe(u8, line);
            }
            continue;
        }

        // Skip empty lines
        if (line.len == 0) continue;

        // This is a file path
        const path_owned = try a.dupe(u8, line);
        try current_files.append(a, path_owned);
    }

    // Save last commit
    if (current_hash) |hash| {
        const files = try current_files.toOwnedSlice(a);
        try results.append(a, .{ .hash = hash, .files = files });
        total_commits += 1;
    }

    if (verbose) {
        std.debug.print("  parsed {d} commits for coupling\n", .{total_commits});
    }

    return results;
}

/// Run `git log` in the given repo path and aggregate per-file time series.
///
/// Git command:
///   git -C <repo_path> log --numstat --format="COMMIT%n%H%n%ai%n%an%n%ae"
///       --after="<after>" --no-renames
pub fn runGitLog(
    a: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    after: []const u8,
    verbose: bool,
) !std.ArrayList(PerFileTimeSeries) {
    if (verbose) {
        std.debug.print("  running git log --after=\"{s}\" in {s}\n", .{ after, repo_path });
    }

    // Build argv
    const after_arg = try std.fmt.allocPrint(a, "--after={s}", .{after});
    const argv = &[_][]const u8{
        "git",
        "-C",
        repo_path,
        "log",
        "--numstat",
        "--format=COMMIT%n%H%n%ai%n%an%n%ae",
        after_arg,
        "--no-renames",
    };

    const output = try runGitAndCapture(a, io, argv, verbose);
    defer a.free(output.stdout);
    defer a.free(output.stderr);

    return parseGitLogOutput(a, output.stdout, verbose);
}

/// Record one numstat hit for `fe` against `commit` in the results list.
fn recordNumstatHit(
    results: *std.ArrayList(PerFileTimeSeries),
    path_to_idx: *std.StringHashMap(usize),
    fe: FileEntry,
    commit: ParsedCommit,
    a: std.mem.Allocator,
) !void {
    const gop = try path_to_idx.getOrPut(fe.path);
    if (!gop.found_existing) {
        gop.value_ptr.* = results.items.len;
        try results.append(a, newFileSeries(a, fe.path));
    }

    const idx = gop.value_ptr.*;
    const pf = &results.items[idx];
    pf.churn += fe.added + fe.deleted;

    // Deduplicate: only count a file once per commit
    const is_new_revision = if (pf.last_commit_hash) |last|
        !std.mem.eql(u8, last, commit.hash)
    else
        true;

    if (!is_new_revision) return;

    pf.revisions += 1;
    pf.last_commit_hash = commit.hash;
    try pf.timestamps.append(a, try a.dupe(u8, commit.date));
    try pf.complexity_series.append(a, 0.0);

    const author_gop = try pf.author_counts.getOrPut(commit.author);
    author_gop.value_ptr.* = if (author_gop.found_existing)
        author_gop.value_ptr.* + 1
    else
        1;
}

fn newFileSeries(a: std.mem.Allocator, path: []const u8) PerFileTimeSeries {
    return .{
        .path = path,
        .revisions = 0,
        .author_counts = std.StringHashMap(u32).init(a),
        .churn = 0,
        .complexity_series = std.ArrayList(f64).empty,
        .timestamps = std.ArrayList([]const u8).empty,
        .last_commit_hash = null,
    };
}

/// Parse the full git log output into per-file time series.
fn parseGitLogOutput(
    a: std.mem.Allocator,
    output: []const u8,
    verbose: bool,
) !std.ArrayList(PerFileTimeSeries) {
    var path_to_idx = std.StringHashMap(usize).init(a);
    defer path_to_idx.deinit();

    var results = std.ArrayList(PerFileTimeSeries).empty;
    errdefer {
        for (results.items) |*item| item.deinit(a);
        results.deinit(a);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    var current_commit: ?ParsedCommit = null;
    var in_numstat = false;
    var total_entries: usize = 0;

    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "COMMIT")) {
            in_numstat = false;
            current_commit = null;
            continue;
        }

        if (current_commit == null) {
            if (line.len == 40) {
                current_commit = try parseCommitHeader(a, line, &lines);
            }
            in_numstat = current_commit != null;
            continue;
        }

        if (!in_numstat or line.len == 0) continue;

        const entry = parseNumstatLine(line, a) catch continue;
        const fe = entry orelse continue;
        total_entries += 1;

        try recordNumstatHit(&results, &path_to_idx, fe, current_commit.?, a);
    }

    if (verbose) {
        std.debug.print("  parsed {d} file entries, {d} unique files\n", .{ total_entries, results.items.len });
    }

    return results;
}

/// Parse the 4-line commit header that follows a "COMMIT" marker.
fn parseCommitHeader(a: std.mem.Allocator, hash: []const u8, lines: anytype) !?ParsedCommit {
    const date_line = lines.next() orelse return null;
    const author = lines.next() orelse return null;
    const email = lines.next() orelse return null;
    return ParsedCommit{
        .hash = try a.dupe(u8, hash),
        .date = try a.dupe(u8, date_line),
        .author = try a.dupe(u8, author),
        .email = try a.dupe(u8, email),
    };
}

test "parseNumstatLine basic" {
    const a = std.testing.allocator;
    const line = "10\t5\tsrc/main.zig";
    const entry = (try parseNumstatLine(line, a)).?;
    defer a.free(entry.path);
    try std.testing.expectEqual(@as(u32, 10), entry.added);
    try std.testing.expectEqual(@as(u32, 5), entry.deleted);
    try std.testing.expectEqualStrings("src/main.zig", entry.path);
}

test "parseNumstatLine binary" {
    const a = std.testing.allocator;
    const line = "-\t-\tsrc/image.png";
    try std.testing.expect((try parseNumstatLine(line, a)) == null);
}

test "parseNumstatLine rename" {
    const a = std.testing.allocator;
    const line = "0\t0\tsrc/old.zig => src/new.zig";
    try std.testing.expect((try parseNumstatLine(line, a)) == null);
}

test "parseGitLogOutput simple" {
    const a = std.testing.allocator;
    const output =
        \\COMMIT
        \\abc123def4567890123456789012345678901234
        \\2024-01-15 10:30:00 +0000
        \\Alice
        \\alice@example.com
        \\10\t5\tsrc/main.zig
        \\3\t1\tsrc/utils.zig
        \\
        \\COMMIT
        \\def456abc1237890123456789012345678901234
        \\2024-01-20 14:00:00 +0000
        \\Bob
        \\bob@example.com
        \\2\t2\tsrc/main.zig
        \\
    ;

    const results = try parseGitLogOutput(a, output, false);
    defer {
        for (results.items) |*item| item.deinit(a);
        results.deinit(a);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);

    // Find main.zig
    var main_idx: ?usize = null;
    var utils_idx: ?usize = null;
    for (results.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.path, "src/main.zig")) main_idx = i;
        if (std.mem.eql(u8, item.path, "src/utils.zig")) utils_idx = i;
    }
    try std.testing.expect(main_idx != null);
    try std.testing.expect(utils_idx != null);

    const main = results.items[main_idx.?];
    const utils = results.items[utils_idx.?];

    // main.zig touched by 2 commits
    try std.testing.expectEqual(@as(u32, 2), main.revisions);
    // utils.zig touched by 1 commit
    try std.testing.expectEqual(@as(u32, 1), utils.revisions);

    // main.zig has 2 authors, utils.zig has 1
    try std.testing.expectEqual(@as(u32, 2), main.author_counts.count());
    try std.testing.expectEqual(@as(u32, 1), utils.author_counts.count());

    // Churn for main.zig: 10+5 + 2+2 = 19
    try std.testing.expectEqual(@as(u32, 19), main.churn);
    // Churn for utils.zig: 3+1 = 4
    try std.testing.expectEqual(@as(u32, 4), utils.churn);

    // Timestamps and complexity series should match revision count
    try std.testing.expectEqual(@as(usize, 2), main.timestamps.items.len);
    try std.testing.expectEqual(@as(usize, 2), main.complexity_series.items.len);
    try std.testing.expectEqual(@as(usize, 1), utils.timestamps.items.len);
    try std.testing.expectEqual(@as(usize, 1), utils.complexity_series.items.len);
}
