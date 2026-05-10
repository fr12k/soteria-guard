const std = @import("std");
const types = @import("types.zig");
const complexity = @import("complexity.zig");
const ignore_mod = @import("ignore.zig");

/// Walk a directory tree and scan all source files.
/// Returns an ArrayList of FileMetrics for every scanned file.
pub fn scanFiles(
    a: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    ignore_patterns: []const []const u8,
    verbose: bool,
) !std.ArrayList(types.FileMetrics) {
    var results = std.ArrayList(types.FileMetrics).empty;
    errdefer results.deinit(a);

    const dir = if (std.fs.path.isAbsolute(repo_path)) d: {
        break :d try std.Io.Dir.openDirAbsolute(io, repo_path, .{ .iterate = true });
    } else d: {
        break :d try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, repo_path, .{ .iterate = true });
    };
    defer std.Io.Dir.close(dir, io);

    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Check extension whitelist
        if (!types.hasSourceExtension(entry.path)) continue;

        // Check ignore patterns
        if (ignore_mod.shouldIgnore(entry.path, ignore_patterns)) continue;

        // Read the file
        const content = try entry.dir.readFileAlloc(io, entry.basename, a, std.Io.Limit.limited(1024 * 1024));
        defer a.free(content);

        // Analyze complexity
        const cr = complexity.analyze(content, 4);

        // Duplicate path into arena
        const path_owned = try a.dupe(u8, entry.path);

        try results.append(a, .{
            .path = path_owned,
            .loc = cr.loc,
            .indent_mean = cr.indent_mean,
            .indent_max = cr.indent_max,
            .indent_std = cr.indent_std,
            .comment_ratio = cr.comment_ratio,
        });

        if (verbose) {
            std.debug.print("  scanned {s}: LOC={d}, indent_mean={d:.1}\n", .{
                entry.path, cr.loc, cr.indent_mean,
            });
        }
    }

    return results;
}

test "scanFiles empty directory" {
    const a = std.testing.allocator;

    // Create a temp dir with no source files
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const abs_path = try tmp_dir.dir.realpathAlloc(a, ".");
    defer a.free(abs_path);

    const results = try scanFiles(a, abs_path, &.{}, false);
    defer results.deinit(a);

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "scanFiles with a source file" {
    const a = std.testing.allocator;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write a simple .zig file
    try tmp_dir.dir.writeFile("test.zig", "pub fn main() !void {\n    return;\n}\n");
    try tmp_dir.dir.writeFile("ignored.txt", "not source\n");

    const abs_path = try tmp_dir.dir.realpathAlloc(a, ".");
    defer a.free(abs_path);

    const results = try scanFiles(a, abs_path, &.{}, false);
    defer results.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("test.zig", results.items[0].path);
}

test "scanFiles respects ignore patterns" {
    const a = std.testing.allocator;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile("src/main.zig", "pub fn main() !void {}\n");
    try tmp_dir.dir.writeFile("vendor/lib.zig", "pub fn helper() void {}\n");
    try tmp_dir.dir.writeFile("src/normal.rs", "fn main() {}\n");

    const abs_path = try tmp_dir.dir.realpathAlloc(a, ".");
    defer a.free(abs_path);

    const ignore = [_][]const u8{ "vendor/**" };
    const results = try scanFiles(a, abs_path, &ignore, false);
    defer results.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    // Should NOT include vendor/lib.zig
    for (results.items) |item| {
        try std.testing.expect(!std.mem.startsWith(u8, item.path, "vendor"));
    }
}
