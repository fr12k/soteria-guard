const std = @import("std");

/// Match a path against a single glob pattern.
/// Supports `*` (non-separator), `**` (any path), `?` (single non-separator).
fn matchesGlob(path: []const u8, pattern: []const u8) bool {
    const p = path;
    const pat = pattern;

    // Use two pointers — pi for pattern index, si for string index
    // with backtracking for `*` via saved positions.
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: ?usize = null;

    while (si < p.len) {
        if (pi < pat.len and (pat[pi] == p[si] or pat[pi] == '?')) {
            // Match single char (or literally)
            if (pat[pi] == '?' and p[si] == '/') {
                // `?` does NOT match separator
            } else {
                pi += 1;
                si += 1;
                continue;
            }
        }

        if (pi < pat.len and pat[pi] == '*') {
            // Handle `**` vs `*`
            if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                // `**` matches everything including separators
                // Try to match rest of pattern starting at current position
                // or skip characters
                star_pi = pi + 2; // past `**`
                star_si = si;
                pi = star_pi.?;
                // If pattern ends with `**`, it's a match
                if (pi >= pat.len) return true;
                continue;
            } else {
                // `*` matches any non-separator characters
                // Try to match rest of pattern at current position or skip
                // But `*` cannot cross separator boundaries
                star_pi = pi + 1;
                star_si = si;
                pi = star_pi.?;
                continue;
            }
        }

        // Mismatch: backtrack if we had a star
        if (star_pi) |sp| {
            // If the last star was `*` (not `**`), ensure no separator crossing
            // Check if we're crossing a separator since the star_si
            if (sp > 0 and sp < pat.len and pat[sp - 1] == '*' and !(sp > 1 and pat[sp - 2] == '*')) {
                // This was a single `*` — check if p[star_si..si] contains a separator
                var j = star_si.?;
                while (j < si) : (j += 1) {
                    if (p[j] == '/') {
                        // `*` can't cross separator, but try to resume after the separator
                        // Actually, `*` within the same component — if there's a separator
                        // we need to fail this branch.
                        // Reset: move past the separator
                        star_si = j + 1;
                        pi = sp;
                        si = star_si.?;
                        continue;
                    }
                }
            }
            star_si = star_si.? + 1;
            si = star_si.?;
            pi = sp;
            continue;
        }

        return false;
    }

    // Skip remaining `*` / `**` in pattern
    while (pi < pat.len) {
        if (pat[pi] == '*') {
            if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                pi += 2;
            } else {
                pi += 1;
            }
        } else {
            break;
        }
    }

    return pi >= pat.len;
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
