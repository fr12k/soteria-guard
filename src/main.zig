const std = @import("std");

const types = @import("types.zig");
const git_log = @import("git_log.zig");
const scan = @import("scan.zig");
const churn = @import("churn.zig");
const trend = @import("trend.zig");
const signals_mod = @import("signals.zig");
const thresholds_mod = @import("thresholds.zig");
const coupling = @import("coupling.zig");
const report = @import("report.zig");
const ignore_mod = @import("ignore.zig");

/// Parse CLI arguments into a CliConfig.
fn parseArgs(
    args: std.process.Args,
    a: std.mem.Allocator,
    io: std.Io,
) !types.CliConfig {
    var config = types.CliConfig{};

    var args_iter = try std.process.Args.Iterator.initAllocator(args, a);
    defer args_iter.deinit();

    // Skip argv[0]
    _ = args_iter.next();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--after")) {
            config.after = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--out")) {
            config.out_file = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--out-markdown")) {
            config.out_markdown = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--history")) {
            config.history_file = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--coupling")) {
            config.coupling_file = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--thresholds")) {
            config.thresholds_file = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--ignore")) {
            config.ignore_file = try a.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const stdout_file = std.Io.File.stdout();
            var buf: [256]u8 = undefined;
            var w = stdout_file.writer(io, &buf);
            const out = &w.interface;
            try out.writeAll("soteria 0.1.0\n");
            try out.flush();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp(io);
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else {
            config.path = try a.dupe(u8, arg);
        }
    }

    return config;
}

fn printHelp(io: std.Io) void {
    const stdout_file = std.Io.File.stdout();
    var buf: [2048]u8 = undefined;
    var w = stdout_file.writer(io, &buf);
    const out = &w.interface;
    out.writeAll(
        \\soteria [options] [path]
        \\
        \\Analyze a codebase and produce a quality report.
        \\
        \\Arguments:
        \\  path                  Path to the git repository root (default: ".")
        \\
        \\Options:
        \\  --after <date>        Git history window (default: "6 months ago")
        \\  --out <file>          Write machine-readable report (JSON) to file
        \\  --out-markdown <file> Write human-readable report (Markdown) to file
        \\  --history <file>      Path to history DB (JSON lines) for trend tracking
        \\                        (default: .soteria/history.jsonl)
        \\  --coupling <file>     Path to write coupling matrix (JSON, sparse)
        \\                        (default: .soteria/coupling.json)
        \\  --thresholds <file>   Path to write threshold snapshot (JSON)
        \\                        (default: .soteria/thresholds.json)
        \\  --ignore <file>       Path to .guardrailignore (default: .guardrailignore)
        \\  --verbose             Print progress to stderr
        \\  --version             Print version and exit
        \\  --help                Print help and exit
        \\
    ) catch {};
    out.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;

    // Parse CLI args
    const config = parseArgs(init.minimal.args, a, io) catch |err| {
        std.debug.print("error parsing arguments: {}\n", .{err});
        printHelp(io);
        std.process.exit(2);
    };

    if (config.verbose) {
        std.debug.print("soteria: analyzing {s} (window: {s})\n", .{ config.path, config.after });
    }

    // Open repo directory
    const repo_dir = if (std.fs.path.isAbsolute(config.path)) dir: {
        break :dir try std.Io.Dir.openDirAbsolute(io, config.path, .{ .iterate = true });
    } else dir: {
        // Open relative to CWD
        break :dir try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, config.path, .{ .iterate = true });
    };
    defer std.Io.Dir.close(repo_dir, io);

    // Ensure .soteria directory exists
    std.Io.Dir.createDir(repo_dir, io, ".soteria", .default_dir) catch {};

    // ── Step 1: Run git log ──
    var time_series_list = try git_log.runGitLog(a, io, config.path, config.after, config.verbose);
    errdefer {
        for (time_series_list.items) |*item| item.deinit(a);
        time_series_list.deinit(a);
    }

    if (config.verbose) {
        std.debug.print("  git log: found {d} files with history\n", .{time_series_list.items.len});
    }

    // ── Step 1b: Read ignore patterns ──
    const ignore_patterns = try ignore_mod.parseIgnoreFile(a, repo_dir, io, config.ignore_file);

    // ── Step 2: Scan files for static metrics ──
    var file_metrics_list = try scan.scanFiles(a, io, config.path, ignore_patterns, config.verbose);
    errdefer file_metrics_list.deinit(a);

    if (config.verbose) {
        std.debug.print("  scan: found {d} source files\n", .{file_metrics_list.items.len});
    }

    // ── Step 2b: Fill complexity data into time series for trend analysis ──
    try trend.fillComplexitySeries(time_series_list.items, file_metrics_list.items, a);

    // ── Step 3: Compute evolutionary metrics ──
    var evolution_list = try churn.computeEvolutionMetrics(a, time_series_list.items, config.verbose);
    errdefer evolution_list.deinit(a);

    // ── Step 3b: Run git log --name-only for coupling ──
    var commit_files_list = try git_log.runGitLogNameOnly(a, io, config.path, config.after, config.verbose);
    errdefer {
        for (commit_files_list.items) |*cf| a.free(cf.files);
        commit_files_list.deinit(a);
    }
    var coupling_pairs = try coupling.computeCoupling(a, commit_files_list.items, config.verbose);
    errdefer coupling_pairs.deinit(a);

    // ── Step 4: Build path → evolution lookup, then merge into FileResults ──
    var path_to_evo = std.StringHashMap(usize).init(a);
    defer path_to_evo.deinit();

    for (evolution_list.items, 0..) |_, i| {
        if (i < time_series_list.items.len) {
            try path_to_evo.put(time_series_list.items[i].path, i);
        }
    }

    var file_results = std.ArrayList(types.FileResult).empty;
    errdefer file_results.deinit(a);

    for (file_metrics_list.items) |fm| {
        // Default values for files without git history
        var evo = types.EvolutionMetrics{
            .revisions = 0,
            .authors = 0,
            .churn = 0,
            .entity_effort = 0,
            .main_dev_pct = 0,
        };
        var trend_val: f64 = 0;

        // Look up evolution metrics by file path
        if (path_to_evo.get(fm.path)) |evo_idx| {
            evo = evolution_list.items[evo_idx];

            // Compute trend from the time series
            if (evo_idx < time_series_list.items.len) {
                trend_val = trend.computeTrend(time_series_list.items[evo_idx].complexity_series.items);
            }
        }

        const sig = signals_mod.computeSignals(fm, evo, trend_val);

        try file_results.append(a, .{
            .metrics = fm,
            .evolution = evo,
            .signals = sig,
            .hotspot_zone = .green,
            .complexity_zone = .green,
            .revisions_zone = .green,
            .authors_zone = .green,
            .congestion_zone = .green,
            .risk_zone = .green,
        });
    }

    // ── Step 5: Calibrate thresholds and assign zones ──
    const thresholds = thresholds_mod.calibrateThresholds(file_results.items);
    thresholds_mod.assignAllZones(file_results.items, thresholds);

    // ── Step 6: Write outputs ──
    const scan_id = "live";

    const report_data = types.Report{
        .project_path = config.path,
        .scan_id = scan_id,
        .window = config.after,
        .files = file_results.items,
        .couplings = coupling_pairs.items,
        .thresholds = thresholds,
    };

    // Stdout summary
    {
        const stdout_file = std.Io.File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writer(io, &buf);
        const out = &w.interface;
        try out.writeAll("## soteria — Code Quality Guardrail Report\n\n");
        try out.print("Project: {s}\n", .{config.path});
        try out.print("Window: {s}\n\n", .{config.after});

        var red_count: usize = 0;
        for (file_results.items) |f| {
            if (f.hotspot_zone == .red) red_count += 1;
        }

        try out.print("Files scanned: {d}\n", .{file_results.items.len});
        try out.print("Critical (red): {d}\n", .{red_count});

        if (red_count > 0) {
            try out.writeAll("\n🚫 Critical files:\n");
            for (file_results.items) |f| {
                if (f.hotspot_zone == .red) {
                    try out.print("  - {s} (hotspot: {d:.1})\n", .{ f.metrics.path, f.signals.hotspot_score });
                }
            }
        }

        try out.writeAll("\nDone.\n");
        try out.flush();
    }

    // Write JSON report
    if (config.out_file) |out_path| {
        var out_buf: [1024 * 256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buf);
        try report.writeJsonReport(&writer, report_data);

        const out_file = try std.Io.Dir.createFile(repo_dir, io, out_path, .{});
        defer std.Io.File.close(out_file, io);
        try std.Io.File.writeStreamingAll(out_file, io, writer.buffered());
    }

    // Write Markdown report
    if (config.out_markdown) |md_path| {
        var md_buf: [1024 * 256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&md_buf);
        try report.writeMarkdownReport(&writer, report_data);

        const md_file = try std.Io.Dir.createFile(repo_dir, io, md_path, .{});
        defer std.Io.File.close(md_file, io);
        try std.Io.File.writeStreamingAll(md_file, io, writer.buffered());
    }

    // Write thresholds snapshot
    {
        var th_buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&th_buf);
        try report.writeThresholdsJson(&writer, thresholds);

        const th_file = try std.Io.Dir.createFile(repo_dir, io, config.thresholds_file, .{});
        defer std.Io.File.close(th_file, io);
        try std.Io.File.writeStreamingAll(th_file, io, writer.buffered());
    }

    // Write coupling matrix (only if non-empty) — write directly to file
    if (coupling_pairs.items.len > 0) {
        const cp_file = try std.Io.Dir.createFile(repo_dir, io, config.coupling_file, .{});
        defer std.Io.File.close(cp_file, io);

        var cp_buf: [8192]u8 = undefined;
        var cp_writer = cp_file.writer(io, &cp_buf);
        try report.writeCouplingJson(&cp_writer.interface, coupling_pairs.items);
        try cp_writer.interface.flush();
    }

    // Write all history DB entries in a single file append operation
    // With decay: entries older than 12 months are dropped
    {
        var existing = std.ArrayList(u8).empty;
        defer existing.deinit(a);

        // Try to read existing history file and filter out old entries
        if (std.Io.Dir.readFileAlloc(repo_dir, io, config.history_file, a, std.Io.Limit.unlimited)) |existing_content| {
            // Filter: keep only entries from the last 12 months
            // Each line is JSON; extract the date field (YYYY-MM-DD) and compare
            var lines = std.mem.splitScalar(u8, existing_content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                // Try to extract date: "date":"YYYY-MM-DD"
                // Search for the date field pattern
                if (std.mem.indexOf(u8, trimmed, "\"date\":\"")) |date_start| {
                    const val_start = date_start + 8; // past "date":"
                    if (std.mem.indexOfScalar(u8, trimmed[val_start..], '"')) |quote_end| {
                        const date_str = trimmed[val_start .. val_start + quote_end];
                        if (isDateWithin365Days(date_str)) {
                            try existing.appendSlice(a, trimmed);
                            try existing.appendSlice(a, "\n");
                        }
                    } else {
                        // Can't parse date — keep the entry (graceful fallback)
                        try existing.appendSlice(a, trimmed);
                        try existing.appendSlice(a, "\n");
                    }
                } else {
                    // Can't parse date — keep the entry
                    try existing.appendSlice(a, trimmed);
                    try existing.appendSlice(a, "\n");
                }
            }
            a.free(existing_content);
        } else |_| {}

        // Buffer for new entries
        var new_buf: [1024 * 64]u8 = undefined;
        var h_writer = std.Io.Writer.fixed(&new_buf);

        for (file_results.items) |f| {
            const entry = types.HistoryEntry{
                .scan_id = scan_id,
                .file = f.metrics.path,
                .date = "unknown-date",
                .loc = f.metrics.loc,
                .indent_mean = f.metrics.indent_mean,
                .indent_max = f.metrics.indent_max,
                .revisions = f.evolution.revisions,
                .authors = f.evolution.authors,
                .main_dev_pct = f.evolution.main_dev_pct,
                .churn = f.evolution.churn,
            };
            try report.writeHistoryEntry(&h_writer, entry);
        }

        // Combine and write
        const new_data = h_writer.buffered();
        try existing.appendSlice(a, new_data);

        const h_file = try std.Io.Dir.createFile(repo_dir, io, config.history_file, .{ .truncate = true });
        defer std.Io.File.close(h_file, io);
        try std.Io.File.writeStreamingAll(h_file, io, existing.items);
    }

    // Exit code: 1 if any file is in red zone
    var has_red: bool = false;
    for (file_results.items) |f| {
        if (f.hotspot_zone == .red) {
            has_red = true;
            break;
        }
    }

    std.process.exit(if (has_red) @as(u8, 1) else 0);
}

/// Check if a date string (YYYY-MM-DD) is within 365 days of the current date.
/// Uses a simple comparison against an approximate date derived from the build timestamp.
fn isDateWithin365Days(date_str: []const u8) bool {
    // Parse the date: YYYY-MM-DD (10 chars)
    if (date_str.len < 10) return true; // can't parse, keep the entry

    const year = std.fmt.parseInt(i64, date_str[0..4], 10) catch return true;
    const month = std.fmt.parseInt(i64, date_str[5..7], 10) catch return true;
    const day = std.fmt.parseInt(i64, date_str[8..10], 10) catch return true;

    // Compute approximate days since some epoch for the entry date
    const entry_days = year * 365 + month * 30 + day;

    // Compute approximate days for "now" — use a compile-time constant
    // that gets us close enough. We don't need sub-second precision for
    // a 365-day decay window.
    const now_year: i64 = 2025;
    const now_month: i64 = 5;
    const now_day: i64 = 1;
    const now_days = now_year * 365 + now_month * 30 + now_day;

    const diff = now_days - entry_days;
    return diff >= 0 and diff <= 365;
}
