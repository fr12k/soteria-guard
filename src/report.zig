const std = @import("std");
const types = @import("types.zig");

// ── Static documentation strings (module-level to reduce function body noise) ──

const COUPLING_LEGEND =
    \\<details>
    \\<summary>📖 What is Temporal Coupling?</summary>
    \\
    \\**Temporal coupling** (also called *change coupling*) measures how often two files are modified together in the same commit. It detects logical dependencies without needing a language-specific parser.
    \\
    \\### How to Read the Degree
    \\
    \\The degree answers: *"If I change file A, what's the chance I also need to change file B?"*
    \\
    \\| Range | Meaning |
    \\|-------|---------|
    \\| 0–15% | Noise — filtered out |
    \\| 15–40% | Occasional co-change; may be legitimate API boundaries |
    \\| 40–70% | Suspicious — likely a missing abstraction or copy-paste |
    \\| 70%+ | Almost always co-changed — files are logically welded together |
    \\
    \\### The Trend Arrow
    \\
    \\- **🔺 Rising** — coupling is getting stronger. The architectural boundary is eroding.
    \\- **🔽 Falling** — coupling is weakening. Files are becoming more independent.
    \\- **➡️ Stable** — coupling is consistent over time.
    \\
    \\Rising trends are the most actionable signal. They indicate that refactoring should be scheduled before the entanglement gets worse.
    \\
    \\### Cross-Package Coupling
    \\
    \\The most interesting pairs are those in **different packages/directories**. These suggest:
    \\
    \\- A missing abstraction that should be extracted into a shared module
    \\- A copy-paste relationship between unrelated parts of the codebase
    \\- An architectural dependency that violates the intended layering
    \\
    \\</details>
    \\
;

const ZONE_LEGEND =
    \\<details>
    \\<summary>📖 Understanding the Report — Zones &amp; Signals</summary>
    \\
    \\Each file in the table below is scored on six signals. Every signal is classified into a **zone** (1–4) based on percentile thresholds. When the repository has enough revision history (default: >= 5 files with >= 5 revisions), thresholds are auto-calibrated from the project's own data. Otherwise, conservative hard-coded defaults are used.
    \\
    \\### Zone Colors
    \\
    \\| Zone | Color | Percentile | Meaning |
    \\|------|-------|------------|---------|
    \\| 🟢 **Green** | 1 | ≥ p95 | Low risk — within normal bounds |
    \\| 🟡 **Yellow** | 2 | p85 – p95 | Elevated — worth monitoring |
    \\| 🟠 **Orange** | 3 | p60 – p85 | Warning — above typical range |
    \\| 🔴 **Red** | 4 | < p60 | Critical — top tier of concern |
    \\
    \\Percentiles are computed from the current snapshot of all tracked files. A **red** file is in the worst ~40% of the codebase for that signal; a **green** file is in the best ~5%.
    \\
    \\### Signal Definitions
    \\
    \\| Signal | Formula | What It Detects |
    \\|--------|---------|------------------|
    \\| **Hotspot** | `revisions × indent_mean` | Files that change often and are deeply nested — painful to maintain |
    \\| **Complexity** | `indent_mean` | Average nesting depth; higher values indicate tangled control flow |
    \\| **Revisions** | `revision count` | How many commits touched this file — churn-prone code |
    \\| **Authors** | `distinct author count` | Many authors = diffusion of ownership |
    \\| **Congestion** | `authors / revisions` | High ratio means many people edit a file that changes infrequently — coordination bottleneck |
    \\| **Risk*** | `indent_mean × (1 - main_dev_pct)` | Complex code where no single author dominates — knowledge-loss danger |
    \\
    \\### How to Use This
    \\
    \\- **Red** files should be reviewed and refactored as soon as feasible.
    \\- **Orange** files are trending toward red — schedule a review in the next iteration.
    \\- **Yellow** files are above average but not urgent — keep an eye on them.
    \\- **Green** files are fine; no action needed.
    \\
    \\The **Risk** column combines complexity with knowledge-loss potential. A red risk zone means the file is complex *and* lacks a clear primary owner — if the main developer leaves, that knowledge is gone.
    \\
    \\</details>
    \\
;

// ── JSON helpers ──

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

/// Identity escape — used for ASCII paths that need no escaping.
fn jsonEscapeEscaped(value: []const u8) []const u8 {
    return value;
}

/// Serialize a single FileResult as a compact JSON object (no outer wrapper).
pub fn writeFileResultJson(w: anytype, f: types.FileResult) !void {
    try w.writeAll("{\"path\":\"");
    try jsonEscape(w, f.metrics.path);
    try w.writeAll("\",\"loc\":");
    try w.print("{d},\"indent_mean\":{d:.4},\"indent_max\":{d},\"indent_std\":{d:.4},\"comment_ratio\":{d:.4}", .{
        f.metrics.loc,
        f.metrics.indent_mean,
        f.metrics.indent_max,
        f.metrics.indent_std,
        f.metrics.comment_ratio,
    });
    try w.print(",\"revisions\":{d},\"authors\":{d},\"churn\":{d},\"entity_effort\":{d:.6},\"main_dev_pct\":{d:.4}", .{
        f.evolution.revisions,
        f.evolution.authors,
        f.evolution.churn,
        f.evolution.entity_effort,
        f.evolution.main_dev_pct,
    });
    try w.print(",\"hotspot_score\":{d:.4},\"knowledge_loss_risk\":{d:.4},\"developer_congestion\":{d:.4},\"complexity_trend\":{d:.4}", .{
        f.signals.hotspot_score,
        f.signals.knowledge_loss_risk,
        f.signals.developer_congestion,
        f.signals.complexity_trend,
    });
    try w.print(",\"hotspot_zone\":{d},\"complexity_zone\":{d},\"revisions_zone\":{d},\"authors_zone\":{d},\"congestion_zone\":{d},\"risk_zone\":{d}}}", .{
        @as(u8, @intFromEnum(f.hotspot_zone)),
        @as(u8, @intFromEnum(f.complexity_zone)),
        @as(u8, @intFromEnum(f.revisions_zone)),
        @as(u8, @intFromEnum(f.authors_zone)),
        @as(u8, @intFromEnum(f.congestion_zone)),
        @as(u8, @intFromEnum(f.risk_zone)),
    });
}

/// Serialize a single CouplingPair as a compact JSON object.
pub fn writeCouplingPairJson(w: anytype, p: types.CouplingPair) !void {
    try w.writeAll("{\"file_a\":\"");
    try jsonEscape(w, p.file_a);
    try w.writeAll("\",\"file_b\":\"");
    try jsonEscape(w, p.file_b);
    try w.print("\",\"shared_commits\":{d},\"total_commits_a\":{d},\"total_commits_b\":{d},\"degree\":{d:.4},\"trend\":{d}}}", .{
        p.shared_commits,
        p.total_commits_a,
        p.total_commits_b,
        p.degree,
        @as(u8, @intFromEnum(p.trend)),
    });
}

/// Write a HistoryEntry as a JSON line to the given writer.
pub fn writeHistoryEntry(w: anytype, entry: types.HistoryEntry) !void {
    try w.writeAll("{\"scan_id\":\"");
    try jsonEscape(w, entry.scan_id);
    try w.writeAll("\",\"file\":\"");
    try jsonEscape(w, entry.file);
    try w.writeAll("\",\"date\":\"");
    try jsonEscape(w, entry.date);
    try w.print("\",\"loc\":{d},\"indent_mean\":{d:.6},\"indent_max\":{d}", .{
        entry.loc, entry.indent_mean, entry.indent_max,
    });
    try w.print(",\"revisions\":{d},\"authors\":{d},\"main_dev_pct\":{d:.4},\"churn\":{d},\"hotspot_score\":{d:.4},\"knowledge_loss_risk\":{d:.4},\"developer_congestion\":{d:.4}}}\n", .{
        entry.revisions,     entry.authors,             entry.main_dev_pct,         entry.churn,
        entry.hotspot_score, entry.knowledge_loss_risk, entry.developer_congestion,
    });
}

// ── Threshold helpers ──

/// Write the full thresholds snapshot as compact inline JSON (no trailing newline).
pub fn writeThresholdsJson(w: anytype, t: types.Thresholds) !void {
    try w.writeAll("{\n");
    const info = @typeInfo(types.Thresholds);
    const fields = switch (info) {
        .@"struct" => |s| s.fields,
        else => @compileError("Thresholds must be a struct"),
    };
    inline for (fields, 0..) |f, i| {
        try w.print("  \"{s}\": {d:.4}", .{ f.name, @field(t, f.name) });
        if (i < fields.len - 1) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("}\n");
}

/// Append a single JSON-lines history entry to the history file.
pub fn appendHistoryEntry(dir: std.Io.Dir, io: std.Io, history_path: []const u8, entry: types.HistoryEntry) !void {
    const file = try std.Io.Dir.createFile(dir, io, history_path, .{ .truncate = false });
    defer std.Io.File.close(file, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeHistoryEntry(&writer, entry);
    try std.Io.File.writeStreamingAll(file, io, writer.buffered());
}

// ── Report writers ──

/// Write a full JSON report to the given writer.
pub fn writeJsonReport(w: anytype, report: types.Report) !void {
    try w.writeAll("{\n");
    try w.print("  \"project_path\": \"{s}\",\n", .{jsonEscapeEscaped(report.project_path)});
    try w.print("  \"scan_id\": \"{s}\",\n", .{jsonEscapeEscaped(report.scan_id)});
    try w.print("  \"window\": \"{s}\",\n", .{jsonEscapeEscaped(report.window)});

    // Files array
    try w.writeAll("  \"files\": [\n");
    for (report.files, 0..) |f, i| {
        const comma = if (i < report.files.len - 1) "," else "";
        try w.writeAll("    ");
        try writeFileResultJson(w, f);
        try w.print("{s}\n", .{comma});
    }
    try w.writeAll("  ],\n");

    // Couplings array
    try w.writeAll("  \"couplings\": [\n");
    for (report.couplings, 0..) |c, i| {
        const comma = if (i < report.couplings.len - 1) "," else "";
        try w.writeAll("    ");
        try writeCouplingPairJson(w, c);
        try w.print("{s}\n", .{comma});
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

    try w.print("  \"calibration\": \"{s}\",\n", .{jsonEscapeEscaped(report.calibration)});

    try w.writeAll("  \"exit_code\": 0\n}\n");
}

/// Write the coupling matrix as a standalone JSON file.
pub fn writeCouplingJson(w: anytype, pairs: []const types.CouplingPair) !void {
    try w.writeAll("[\n");
    for (pairs, 0..) |p, i| {
        const comma = if (i < pairs.len - 1) "," else "";
        try w.writeAll("  ");
        try writeCouplingPairJson(w, p);
        try w.print("{s}\n", .{comma});
    }
    try w.writeAll("]\n");
}

// ── Markdown section helpers ──

fn writeMarkdownSummary(w: anytype, report: types.Report) !void {
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
}

fn writeMarkdownFileTable(w: anytype, files: []const types.FileResult) !void {
    try w.writeAll("### Files\n\n");
    try w.writeAll("| File | Hotspot | Complexity | Revisions | Authors | Congestion | Risk |\n");
    try w.writeAll("|------|---------|------------|-----------|--------|------------|------|\n");

    for (files) |f| {
        try w.print("| {s} | {s} {d:.1} | {s} {d:.1} | {s} {d} | {s} {d} | {s} {d:.2} | {s} |\n", .{
            f.metrics.path,
            f.hotspot_zone.label(),
            f.signals.hotspot_score,
            f.complexity_zone.label(),
            f.metrics.indent_mean,
            f.revisions_zone.label(),
            f.evolution.revisions,
            f.authors_zone.label(),
            f.evolution.authors,
            f.congestion_zone.label(),
            f.signals.developer_congestion,
            f.risk_zone.label(),
        });
    }
    try w.writeAll("\n");
}

fn writeMarkdownCriticalSection(w: anytype, files: []const types.FileResult) !void {
    var red_count: usize = 0;
    for (files) |f| {
        if (f.hotspot_zone == .red) red_count += 1;
    }

    if (red_count > 0) {
        try w.writeAll("### 🚫 Critical (Zone 4)\n\n");
        for (files) |f| {
            if (f.hotspot_zone == .red) {
                try w.print("- **{s}** — #1 complexity hotspot.\n", .{f.metrics.path});
                if (f.evolution.authors > 3) {
                    try w.print("  - {d} authors — consider splitting into smaller modules.\n", .{f.evolution.authors});
                }
            }
        }
        try w.writeAll("\n");
    }

    var orange_count: usize = 0;
    for (files) |f| {
        if (f.hotspot_zone == .orange) orange_count += 1;
    }

    if (orange_count > 0) {
        try w.writeAll("### ⚠️ Warnings (Zone 3)\n\n");
        for (files) |f| {
            if (f.hotspot_zone == .orange) {
                try w.print("- **{s}** — moderate hotspot. Nesting depth {d}.\n", .{
                    f.metrics.path, f.metrics.indent_max,
                });
            }
        }
        try w.writeAll("\n");
    }
}

fn writeMarkdownCouplingSection(w: anytype, couplings: []const types.CouplingPair) !void {
    if (couplings.len == 0) return;

    try w.writeAll("### 🔗 Temporal Coupling\n\n");
    try w.writeAll("| File | Coupled With | Degree | Trend |\n");
    try w.writeAll("|------|-------------|--------|-------|\n");
    for (couplings) |c| {
        try w.print("| {s} | {s} | {d:.0}% | {s} |\n", .{
            c.file_a, c.file_b, c.degree * 100, c.trend.label(),
        });
    }
    try w.writeAll("\n");
    try w.writeAll(COUPLING_LEGEND);
}

fn writeMarkdownLegend(w: anytype) !void {
    try w.writeAll(ZONE_LEGEND);
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

    try writeMarkdownSummary(w, report);
    try writeMarkdownLegend(w);
    try writeMarkdownFileTable(w, report.files);
    try writeMarkdownCriticalSection(w, report.files);
    try writeMarkdownCouplingSection(w, report.couplings);

    try w.writeAll("---\n\n");
    if (std.mem.eql(u8, report.calibration, "percentile")) {
        try w.writeAll("*Thresholds auto-calibrated to this repository's history.*\n");
    } else {
        try w.writeAll("*Thresholds use conservative defaults (not enough revision history for auto-calibration).*\n");
    }
}

/// Write a hotspot.json snapshot (lightweight file-level score list).
pub fn writeHotspotJson(
    w: anytype,
    scan_id: []const u8,
    thresholds: types.Thresholds,
    calibration_method: []const u8,
    files: []const types.FileResult,
    a: std.mem.Allocator,
) !void {
    try w.print("{{\"scan_id\":\"{s}\",\"created_at\":\"{s}\"", .{
        scan_id, scan_id,
    });

    try w.print(",\"thresholds\":{{\"p60\":{d:.4},\"p85\":{d:.4},\"p95\":{d:.4}}}", .{
        thresholds.p60_hotspot,
        thresholds.p85_hotspot,
        thresholds.p95_hotspot,
    });

    try w.print(",\"calibration\":\"{s}\"", .{jsonEscapeEscaped(calibration_method)});

    // Files array — sort descending by hotspot_score
    var sorted_idxs = std.ArrayList(usize).empty;
    defer sorted_idxs.deinit(a);
    for (files, 0..) |_, i| {
        try sorted_idxs.append(a, i);
    }
    std.mem.sort(usize, sorted_idxs.items, files, struct {
        fn lessThan(ctx: []const types.FileResult, i: usize, j: usize) bool {
            return ctx[i].signals.hotspot_score > ctx[j].signals.hotspot_score;
        }
    }.lessThan);

    try w.writeAll(",\"files\":[");
    for (sorted_idxs.items, 0..) |idx, i| {
        const f = files[idx];
        const comma = if (i > 0) "," else "";
        try w.print("{s}{{\"path\":\"{s}\",\"hotspot_score\":{d:.4},\"zone\":\"{s}\",\"zone_level\":{d}}}", .{
            comma,
            jsonEscapeEscaped(f.metrics.path),
            f.signals.hotspot_score,
            f.hotspot_zone.name(),
            @as(u8, @intFromEnum(f.hotspot_zone)),
        });
    }
    try w.writeAll("]}");
}

// ── Tests ──

test "writeFileResultJson roundtrip" {
    var b: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);

    const entry = types.FileResult{
        .metrics = .{
            .path = "src/main.zig",
            .loc = 100,
            .indent_mean = 3.5,
            .indent_max = 10,
            .indent_std = 1.2,
            .comment_ratio = 0.15,
        },
        .evolution = .{ .revisions = 5, .authors = 2, .churn = 100, .entity_effort = 0.1, .main_dev_pct = 0.5 },
        .signals = .{ .hotspot_score = 17.5, .knowledge_loss_risk = 1.75, .developer_congestion = 0.4, .complexity_trend = 0.0 },
        .hotspot_zone = .red,
        .complexity_zone = .orange,
        .revisions_zone = .yellow,
        .authors_zone = .green,
        .congestion_zone = .green,
        .risk_zone = .orange,
    };

    try writeFileResultJson(&w, entry);
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"path\":\"src/main.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hotspot_score\":17.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hotspot_zone\":4") != null);
}

test "writeCouplingPairJson roundtrip" {
    var b: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);

    const entry = types.CouplingPair{
        .file_a = "a.zig",
        .file_b = "b.zig",
        .shared_commits = 5,
        .total_commits_a = 10,
        .total_commits_b = 8,
        .degree = 0.5,
        .trend = .rising,
    };

    try writeCouplingPairJson(&w, entry);
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"file_a\":\"a.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"degree\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"trend\":2") != null);
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

test "writeMarkdownReport smoke" {
    var b: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);

    const f = types.FileResult{
        .metrics = .{
            .path = "src/main.zig",
            .loc = 100,
            .indent_mean = 3.5,
            .indent_max = 10,
            .indent_std = 1.2,
            .comment_ratio = 0.15,
        },
        .evolution = .{ .revisions = 5, .authors = 2, .churn = 100, .entity_effort = 0.1, .main_dev_pct = 0.5 },
        .signals = .{ .hotspot_score = 17.5, .knowledge_loss_risk = 1.75, .developer_congestion = 0.4, .complexity_trend = 0.0 },
        .hotspot_zone = .red,
        .complexity_zone = .orange,
        .revisions_zone = .yellow,
        .authors_zone = .green,
        .congestion_zone = .green,
        .risk_zone = .orange,
    };

    const report = types.Report{
        .project_path = ".",
        .scan_id = "live",
        .window = "6 months ago",
        .files = &.{f},
        .couplings = &.{},
        .thresholds = .{},
    };

    try writeMarkdownReport(&w, report);
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "# 🔍 Code Quality Guardrail Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Understanding the Report") != null);
}
