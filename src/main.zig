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

    // ── Step 3b: Compute coupling (stub for v1) ──
    var coupling_pairs = try coupling.computeCoupling(a, time_series_list.items, config.verbose);
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

    // Write history DB entries
    {
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
            report.appendHistoryEntry(repo_dir, io, config.history_file, entry) catch {};
        }
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
