const std = @import("std");

pub const ComplexityResult = struct {
    loc: u32,
    blank_lines: u32,
    comment_lines: u32,
    indent_mean: f64,
    indent_max: u32,
    indent_std: f64,
    comment_ratio: f64,
};

/// Count leading whitespace characters on a line, normalizing tabs to `tab_width`.
fn indentDepth(line: []const u8, tab_width: u8) u32 {
    var depth: u32 = 0;
    for (line) |ch| {
        switch (ch) {
            ' ' => depth += 1,
            '\t' => depth += tab_width,
            else => break,
        }
    }
    return depth;
}

/// Check if a line is a pure-comment line.
/// Recognized comment starters: // # -- /*
fn isCommentLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    const starters = [_][]const u8{ "//", "#", "--", "/*" };
    for (starters) |s| {
        if (std.mem.startsWith(u8, trimmed, s)) return true;
    }
    return false;
}

/// Check if a line is blank (empty or only whitespace).
fn isBlankLine(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return false;
    }
    return true;
}

/// Analyze source code content and return complexity metrics.
pub fn analyze(content: []const u8, tab_width: u8) ComplexityResult {
    var loc: u32 = 0;
    var blank_lines: u32 = 0;
    var comment_lines: u32 = 0;
    var indent_sum: u64 = 0;
    var indent_max: u32 = 0;
    var indent_values = std.ArrayList(u32).empty;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (isBlankLine(line)) {
            blank_lines += 1;
            continue;
        }
        if (isCommentLine(line)) {
            comment_lines += 1;
            continue;
        }
        // Count as code line
        loc += 1;
        const d = indentDepth(line, tab_width);
        indent_sum += d;
        if (d > indent_max) indent_max = d;
        indent_values.append(std.heap.page_allocator, d) catch {};
    }

    const total_lines = loc + blank_lines + comment_lines;
    const comment_ratio: f64 = if (total_lines > 0)
        @as(f64, @floatFromInt(comment_lines)) / @as(f64, @floatFromInt(total_lines))
    else
        0.0;

    const indent_mean: f64 = if (loc > 0)
        @as(f64, @floatFromInt(indent_sum)) / @as(f64, @floatFromInt(loc))
    else
        0.0;

    // Std dev
    var variance_sum: f64 = 0;
    for (indent_values.items) |v| {
        const diff = @as(f64, @floatFromInt(v)) - indent_mean;
        variance_sum += diff * diff;
    }
    const indent_std: f64 = if (loc > 1)
        @sqrt(variance_sum / @as(f64, @floatFromInt(loc - 1)))
    else
        0.0;

    return .{
        .loc = loc,
        .blank_lines = blank_lines,
        .comment_lines = comment_lines,
        .indent_mean = indent_mean,
        .indent_max = indent_max,
        .indent_std = indent_std,
        .comment_ratio = comment_ratio,
    };
}

test "analyze simple zig code" {
    const code =
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("hello\n", .{});
        \\}
    ;

    const r = analyze(code, 4);
    try std.testing.expectEqual(@as(u32, 4), r.loc);
    try std.testing.expect(r.indent_max >= 4);
    try std.testing.expect(r.indent_mean > 0);
}

test "blank and comment lines" {
    const code =
        \\// comment line
        \\# another style
        \\code
        \\
        \\/* block style */
        \\more code
    ;

    const r = analyze(code, 4);
    try std.testing.expectEqual(@as(u32, 2), r.loc);
    try std.testing.expectEqual(@as(u32, 1), r.blank_lines);
    try std.testing.expectEqual(@as(u32, 3), r.comment_lines);
}

test "empty content" {
    const r = analyze("", 4);
    try std.testing.expectEqual(@as(u32, 0), r.loc);
    try std.testing.expectEqual(@as(u32, 0), r.indent_max);
    try std.testing.expectEqual(@as(f64, 0.0), r.indent_mean);
}
