const std = @import("std");

/// Match a path against a single glob pattern.
/// Supports `*` (non-separator), `**` (any path), `?` (single non-separator).
fn matchesGlob(path: []const u8, pattern: []const u8) bool {
    const p = path;
    const pat = pattern;

    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: ?usize = null;

    while (si < p.len) {
        // Case 1: literal or ? match (no backtrack state change)
        if (tryLiteralMatch(&pi, &si, p, pat)) continue;

        // Case 2: * or ** — consume and set backtrack state
        if (tryConsumeStar(&pi, si, pat, &star_pi, &star_si)) {
            if (pi >= pat.len) return true; // `*` or `**` at end matches everything
            continue;
        }

        // Case 3: mismatch — try backtracking over previously consumed star
        if (tryStarBacktrack(&si, p, pat, star_pi, &star_si, &pi)) continue;

        return false;
    }

    return consumeTrailingStars(&pi, pat);
}

/// Try matching a literal character or `?` at current positions. Advances pi, si on success.
fn tryLiteralMatch(pi: *usize, si: *usize, p: []const u8, pat: []const u8) bool {
    if (pi.* >= pat.len) return false;
    if (pat[pi.*] != p[si.*] and pat[pi.*] != '?') return false;
    if (pat[pi.*] == '?' and p[si.*] == '/') return false;
    pi.* += 1;
    si.* += 1;
    return true;
}

/// Consume `*` or `**` at current pattern position. Sets backtrack state on success.
fn tryConsumeStar(pi: *usize, si: usize, pat: []const u8, star_pi: *?usize, star_si: *?usize) bool {
    if (pi.* >= pat.len) return false;
    if (pat[pi.*] != '*') return false;

    const step: usize = if (pi.* + 1 < pat.len and pat[pi.* + 1] == '*') @as(usize, 2) else 1;
    star_pi.* = pi.* + step;
    star_si.* = si;
    pi.* = star_pi.*.?;
    return true;
}

/// Skip trailing `*` / `**` that remain after the path is exhausted.
fn consumeTrailingStars(pi: *usize, pat: []const u8) bool {
    while (pi.* < pat.len) : (pi.* += 1) {
        if (pat[pi.*] == '*' and pi.* + 1 < pat.len and pat[pi.* + 1] == '*') pi.* += 1;
        if (pat[pi.*] != '*') return false;
    }
    return true;
}

/// Backtrack from a star match. Resets si past separator for single-`*` stars.
fn tryStarBacktrack(si: *usize, p: []const u8, pat: []const u8, star_pi: ?usize, star_si: *?usize, pi: *usize) bool {
    if (star_pi == null) return false;
    const sp = star_pi.?;

    // Single `*` cannot cross directory separator
    if (startsWithSingleStar(pat, sp)) {
        if (nextPastSeparator(si.*, p, star_si.*.?)) |new_si| {
            star_si.* = new_si;
            si.* = new_si;
            pi.* = sp;
            return true;
        }
    }

    star_si.* = star_si.*.? + 1;
    si.* = star_si.*.?;
    pi.* = sp;
    return true;
}

/// Check whether the star at position sp in pattern is a single `*` (not `**`).
fn startsWithSingleStar(pat: []const u8, sp: usize) bool {
    if (sp == 0) return pat[0] == '*';
    if (pat[sp - 1] != '*') return true;
    if (sp > 1 and pat[sp - 2] == '*') return false; // `**`
    return false; // sp points past a `*`, and it's part of `**`
}

/// Find the next `/` separator in p[start..si_end], return index just past it.
fn nextPastSeparator(si_end: usize, p: []const u8, start: usize) ?usize {
    var j: usize = start;
    while (j < si_end) : (j += 1) {
        if (p[j] == '/') return j + 1;
    }
    return null;
}

/// Returns true if `path` matches any of the ignore patterns.
pub fn shouldIgnore(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pat| {
        if (matchesGlob(path, pat)) return true;
    }
    return false;
}

/// Parse a `.guardrailignore` file content into a slice of pattern strings.
/// Lines starting with `#` are comments. Blank lines are skipped.
pub fn parseIgnoreContent(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var patterns = std.ArrayList([]const u8).empty;
    errdefer patterns.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try patterns.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return patterns.toOwnedSlice(allocator);
}

/// Read and parse a `.guardrailignore` file from the given directory.
pub fn parseIgnoreFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    ignore_path: []const u8,
) ![][]const u8 {
    const file = std.Io.Dir.openFile(dir, io, ignore_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer std.Io.File.close(file, io);

    // Read file content using the new API
    const content = try std.Io.Dir.readFileAlloc(dir, io, ignore_path, allocator, std.Io.Limit.limited(1024 * 64));
    defer allocator.free(content);

    return parseIgnoreContent(allocator, content);
}

test "matchesGlob literal" {
    try std.testing.expect(matchesGlob("src/main.zig", "src/main.zig"));
    try std.testing.expect(!matchesGlob("src/main.zig", "src/other.zig"));
}

test "matchesGlob star" {
    try std.testing.expect(matchesGlob("foo.zig", "*.zig"));
    try std.testing.expect(!matchesGlob("foo.go", "*.zig"));
    try std.testing.expect(matchesGlob("src/main.zig", "src/*.zig"));
    try std.testing.expect(!matchesGlob("src/sub/main.zig", "src/*.zig"));
}

test "matchesGlob double_star" {
    try std.testing.expect(matchesGlob("src/main.zig", "src/**"));
    try std.testing.expect(matchesGlob("src/sub/main.zig", "src/**"));
    try std.testing.expect(matchesGlob("vendor/lib/foo.zig", "vendor/**"));
    try std.testing.expect(!matchesGlob("src/main.zig", "vendor/**"));
}

test "matchesGlob question" {
    try std.testing.expect(matchesGlob("foo.zig", "foo.zi?"));
    try std.testing.expect(!matchesGlob("foo.zg", "foo.zi?"));
    try std.testing.expect(!matchesGlob("foo/zig", "foo.?ig"));
}

test "parseIgnoreContent comments and blanks" {
    const content =
        \\ # this is a comment
        \\vendor/**
        \\
        \\*.pb.go
        \\# another comment
        \\dist/**
    ;

    const a = std.testing.allocator;
    const patterns = try parseIgnoreContent(a, content);
    defer {
        for (patterns) |p| a.free(p);
        a.free(patterns);
    }
    try std.testing.expectEqual(@as(usize, 3), patterns.len);
    try std.testing.expectEqualStrings("vendor/**", patterns[0]);
    try std.testing.expectEqualStrings("*.pb.go", patterns[1]);
    try std.testing.expectEqualStrings("dist/**", patterns[2]);
}

test "shouldIgnore with patterns" {
    const patterns = [_][]const u8{ "vendor/**", "*.pb.go" };
    try std.testing.expect(shouldIgnore("vendor/lib/foo.zig", &patterns));
    try std.testing.expect(shouldIgnore("generated.pb.go", &patterns));
    try std.testing.expect(!shouldIgnore("src/main.zig", &patterns));
}

// ── Edge-case coverage for refactor plan Step F ──

test "matchesGlob double_star prefix" {
    // `**/` prefix — matches any depth directory
    try std.testing.expect(matchesGlob("src/main.zig", "**/main.zig"));
    try std.testing.expect(matchesGlob("deep/nested/main.zig", "**/main.zig"));
    try std.testing.expect(matchesGlob("main.zig", "**/main.zig"));
    try std.testing.expect(!matchesGlob("src/main.rs", "**/main.zig"));
}

test "matchesGlob trailing slash" {
    // Trailing `/` in pattern should be handled
    try std.testing.expect(matchesGlob("vendor/lib", "vendor/lib/"));
    try std.testing.expect(!matchesGlob("vendor/libx", "vendor/lib/"));
}

test "matchesGlob exact match literal" {
    try std.testing.expect(matchesGlob("foo/bar.zig", "foo/bar.zig"));
    try std.testing.expect(!matchesGlob("foo/baz.zig", "foo/bar.zig"));
}

test "matchesGlob star suffix and prefix" {
    try std.testing.expect(matchesGlob("main.zig", "*.zig"));
    try std.testing.expect(matchesGlob("test.zig", "test.*"));
    try std.testing.expect(matchesGlob("foo.bar.zig", "foo.*.zig"));
    try std.testing.expect(!matchesGlob("foo.bar.rs", "foo.*.zig"));
}

test "matchesGlob mixed star and double_star" {
    try std.testing.expect(matchesGlob("a/b/c/d.zig", "**/*.zig"));
    try std.testing.expect(matchesGlob("root.zig", "**/*.zig"));
    try std.testing.expect(!matchesGlob("a/b/c/d.rs", "**/*.zig"));
}

test "shouldIgnore empty patterns" {
    const empty = [_][]const u8{};
    try std.testing.expect(!shouldIgnore("anything.zig", &empty));
}

test "shouldIgnore no match" {
    const patterns = [_][]const u8{ "*.go", "vendor/**" };
    try std.testing.expect(!shouldIgnore("src/main.zig", &patterns));
    try std.testing.expect(!shouldIgnore("build.zig", &patterns));
}
