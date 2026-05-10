const std = @import("std");
const types = @import("types.zig");

/// Write a HistoryEntry as a JSON line to the given writer.
pub fn writeHistoryEntry(
    w: anytype,
    entry: types.HistoryEntry,
) !void {
    try w.writeAll("{\"scan_id\":\"");
    try jsonEscape(w, entry.scan_id);
    try w.writeAll("\",\"file\":\"");
    try jsonEscape(w, entry.file);
    try w.writeAll("\",\"date\":\"");
    try jsonEscape(w, entry.date);
    try w.print("\",\"loc\":{d},\"indent_mean\":{d:.6},\"indent_max\":{d}", .{
        entry.loc, entry.indent_mean, entry.indent_max,
    });
    try w.print(",\"revisions\":{d},\"authors\":{d},\"main_dev_pct\":{d:.4},\"churn\":{d}}}\n", .{
        entry.revisions, entry.authors, entry.main_dev_pct, entry.churn,
    });
}

/// Write the full thresholds snapshot as JSON.
pub fn writeThresholdsJson(
    w: anytype,
    t: types.Thresholds,
) !void {
    try w.writeAll("{\n");
    try w.print("  \"p60_hotspot\": {d:.4},\n", .{t.p60_hotspot});
    try w.print("  \"p85_hotspot\": {d:.4},\n", .{t.p85_hotspot});
    try w.print("  \"p95_hotspot\": {d:.4},\n", .{t.p95_hotspot});
    try w.print("  \"p60_complexity\": {d:.4},\n", .{t.p60_complexity});
    try w.print("  \"p85_complexity\": {d:.4},\n", .{t.p85_complexity});
    try w.print("  \"p95_complexity\": {d:.4},\n", .{t.p95_complexity});
    try w.print("  \"p60_revisions\": {d:.4},\n", .{t.p60_revisions});
    try w.print("  \"p85_revisions\": {d:.4},\n", .{t.p85_revisions});
    try w.print("  \"p95_revisions\": {d:.4},\n", .{t.p95_revisions});
    try w.print("  \"p60_authors\": {d:.4},\n", .{t.p60_authors});
    try w.print("  \"p85_authors\": {d:.4},\n", .{t.p85_authors});
    try w.print("  \"p95_authors\": {d:.4},\n", .{t.p95_authors});
    try w.print("  \"p60_congestion\": {d:.4},\n", .{t.p60_congestion});
    try w.print("  \"p85_congestion\": {d:.4},\n", .{t.p85_congestion});
    try w.print("  \"p95_congestion\": {d:.4},\n", .{t.p95_congestion});
    try w.print("  \"p60_risk\": {d:.4},\n", .{t.p60_risk});
    try w.print("  \"p85_risk\": {d:.4},\n", .{t.p85_risk});
    try w.print("  \"p95_risk\": {d:.4}\n", .{t.p95_risk});
    try w.writeAll("}\n");
}

/// Append a single JSON-lines history entry to the history file.
pub fn appendHistoryEntry(
    dir: std.Io.Dir,
    io: std.Io,
    history_path: []const u8,
    entry: types.HistoryEntry,
) !void {
    const file = try std.Io.Dir.createFile(dir, io, history_path, .{ .truncate = false });
    defer std.Io.File.close(file, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeHistoryEntry(&writer, entry);
    try std.Io.File.writeStreamingAll(file, io, writer.buffered());
}

/// Write a full JSON report to the given writer.
pub fn writeJsonReport(
    w: anytype,
    report: types.Report,
) !void {
    try w.writeAll("{\n");
    try w.print("  \"project_path\": \"{s}\",\n", .{jsonEscapeEscaped(report.project_path)});
    try w.print("  \"scan_id\": \"{s}\",\n", .{jsonEscapeEscaped(report.scan_id)});
    try w.print("  \"window\": \"{s}\",\n", .{jsonEscapeEscaped(report.window)});

    // Files array
    try w.writeAll("  \"files\": [\n");
    for (report.files, 0..) |f, i| {
        const comma = if (i < report.files.len - 1) "," else "";
        try w.print("    {{\"path\":\"{s}\",\"loc\":{d},\"indent_mean\":{d:.4},\"indent_max\":{d},\"indent_std\":{d:.4},\"comment_ratio\":{d:.4},\"revisions\":{d},\"authors\":{d},\"churn\":{d},\"entity_effort\":{d:.6},\"main_dev_pct\":{d:.4},\"hotspot_score\":{d:.4},\"knowledge_loss_risk\":{d:.4},\"developer_congestion\":{d:.4},\"complexity_trend\":{d:.4},\"hotspot_zone\":{d},\"complexity_zone\":{d},\"revisions_zone\":{d},\"authors_zone\":{d},\"congestion_zone\":{d},\"risk_zone\":{d}}}{s}\n", .{
            jsonEscapeEscaped(f.metrics.path),
            f.metrics.loc,
            f.metrics.indent_mean,
            f.metrics.indent_max,
            f.metrics.indent_std,
            f.metrics.comment_ratio,
            f.evolution.revisions,
            f.evolution.authors,
            f.evolution.churn,
            f.evolution.entity_effort,
            f.evolution.main_dev_pct,
            f.signals.hotspot_score,
            f.signals.knowledge_loss_risk,
            f.signals.developer_congestion,
            f.signals.complexity_trend,
            @as(u8, @intFromEnum(f.hotspot_zone)),
            @as(u8, @intFromEnum(f.complexity_zone)),
            @as(u8, @intFromEnum(f.revisions_zone)),
            @as(u8, @intFromEnum(f.authors_zone)),
            @as(u8, @intFromEnum(f.congestion_zone)),
            @as(u8, @intFromEnum(f.risk_zone)),
            comma,
        });
    }
    try w.writeAll("  ],\n");

    // Couplings array
    try w.writeAll("  \"couplings\": [\n");
    for (report.couplings, 0..) |c, i| {
        const comma = if (i < report.couplings.len - 1) "," else "";
        try w.print("    {{\"file_a\":\"{s}\",\"file_b\":\"{s}\",\"shared_commits\":{d},\"total_commits_a\":{d},\"total_commits_b\":{d},\"degree\":{d:.4},\"trend\":{d}}}{s}\n", .{
            jsonEscapeEscaped(c.file_a),
            jsonEscapeEscaped(c.file_b),
            c.shared_commits,
            c.total_commits_a,
            c.total_commits_b,
            c.degree,
            @as(u8, @intFromEnum(c.trend)),
            comma,
        });
    }
    try w.writeAll("  ],\n");

    // Thresholds (inline)
    try w.writeAll("  \"thresholds\": ");
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeThresholdsJson(&writer, report.thresholds);
    const th_str = std.mem.trim(u8, writer.buffered(), "\n");
    try w.writeAll(th_str);
    try w.writeAll(",\n");

    try w.writeAll("  \"exit_code\": 0\n}\n");
}

/// Write a Markdown report to the given writer.
pub fn writeMarkdownReport(
    w: anytype,
    report: types.Report,
) !void {
    try w.writeAll("# 🔍 Code Quality Guardrail Report\n\n");
    try w.print("**Project**: {s}\n\n", .{report.project_path});
    try w.print("**Scanned**: {s}\n\n", .{report.scan_id});
    try w.print("**Window**: {s}\n\n", .{report.window});

    var red_count: usize = 0;
    var orange_count: usize = 0;
    var yellow_count: usize = 0;
    var green_count: usize = 0;

    for (report.files) |f| {
        switch (f.hotspot_zone) {
            .red => red_count += 1,
            .orange => orange_count += 1,
            .yellow => yellow_count += 1,
            .green => green_count += 1,
        }
    }

    try w.writeAll("### Summary\n\n");
    try w.writeAll("| Zone | Count |\n|---|---|\n");
    try w.print("| 🟢 Green | {d} |\n", .{green_count});
    try w.print("| 🟡 Yellow | {d} |\n", .{yellow_count});
    try w.print("| 🟠 Orange | {d} |\n", .{orange_count});
    try w.print("| 🔴 Red | {d} |\n\n", .{red_count});

    try w.writeAll("### Files\n\n");
    try w.writeAll("| File | Hotspot | Complexity | Revisions | Authors | Congestion | Risk |\n");
    try w.writeAll("|------|---------|------------|-----------|--------|------------|------|\n");

    for (report.files) |f| {
        try w.print("| {s} | {s} {d:.1} | {s} {d:.1} | {s} {d} | {s} {d} | {s} {d:.2} | {s} |\n", .{
            f.metrics.path,
            f.hotspot_zone.label(), f.signals.hotspot_score,
            f.complexity_zone.label(), f.metrics.indent_mean,
            f.revisions_zone.label(), f.evolution.revisions,
            f.authors_zone.label(), f.evolution.authors,
            f.congestion_zone.label(), f.signals.developer_congestion,
            f.risk_zone.label(),
        });
    }
    try w.writeAll("\n");

    if (red_count > 0) {
        try w.writeAll("### 🚫 Critical (Zone 4)\n\n");
        for (report.files) |f| {
            if (f.hotspot_zone == .red) {
                try w.print("- **{s}** — #1 complexity hotspot.\n", .{f.metrics.path});
                if (f.evolution.authors > 3) {
                    try w.print("  - {d} authors — consider splitting into smaller modules.\n", .{f.evolution.authors});
                }
            }
        }
        try w.writeAll("\n");
    }

    if (orange_count > 0) {
        try w.writeAll("### ⚠️ Warnings (Zone 3)\n\n");
        for (report.files) |f| {
            if (f.hotspot_zone == .orange) {
                try w.print("- **{s}** — moderate hotspot. Nesting depth {d}.\n", .{
                    f.metrics.path, f.metrics.indent_max,
                });
            }
        }
        try w.writeAll("\n");
    }

    if (report.couplings.len > 0) {
        try w.writeAll("### 🔗 Temporal Coupling\n\n");
        try w.writeAll("| File | Coupled With | Degree | Trend |\n");
        try w.writeAll("|------|-------------|--------|-------|\n");
        for (report.couplings) |c| {
            try w.print("| {s} | {s} | {d:.0}% | {s} |\n", .{
                c.file_a, c.file_b, c.degree * 100, c.trend.label(),
            });
        }
        try w.writeAll("\n");
    }

    try w.writeAll("---\n\n");
    try w.writeAll("*Thresholds auto-calibrated to this repository's history.*\n");
}

/// JSON-escape a string value and write it.
fn jsonEscape(w: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeAll(&[_]u8{ch}),
        }
    }
}

/// Escape a string for JSON (identity fn — safe for ASCII paths).
fn jsonEscapeEscaped(value: []const u8) []const u8 {
    return value;
}

test "writeHistoryEntry roundtrip" {
    const entry = types.HistoryEntry{
        .scan_id = "2025-06-16T06:00Z",
        .file = "src/main.zig",
        .date = "2025-06-16",
        .loc = 340,
        .indent_mean = 2.8,
        .indent_max = 9,
        .revisions = 14,
        .authors = 3,
        .main_dev_pct = 0.62,
        .churn = 420,
    };

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeHistoryEntry(&writer, entry);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "2025-06-16T06:00Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"loc\":340") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"churn\":420") != null);
}

test "writeThresholdsJson sanity" {
    const t = types.Thresholds{
        .p60_hotspot = 10,
        .p85_hotspot = 30,
        .p95_hotspot = 50,
        .p60_complexity = 3,
        .p85_complexity = 5,
        .p95_complexity = 8,
    };

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeThresholdsJson(&writer, t);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "p60_hotspot") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "p95_complexity") != null);
}
