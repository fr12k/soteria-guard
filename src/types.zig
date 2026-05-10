const std = @import("std");

// ── File-level metrics (static snapshot) ──

pub const FileMetrics = struct {
    /// Absolute or relative path from repo root, normalized to forward slashes.
    path: []const u8,
    /// Lines of code (excluding blanks and pure-comment lines).
    loc: u32,
    /// Mean indentation depth across all non-blank lines.
    indent_mean: f64,
    /// Maximum indentation depth encountered.
    indent_max: u32,
    /// Standard deviation of indentation depths.
    indent_std: f64,
    /// Ratio of comment lines to total lines.
    comment_ratio: f64,
};

// ── Evolutionary metrics (git history) ──

pub const EvolutionMetrics = struct {
    /// Number of commits that touched this file.
    revisions: u32,
    /// Number of distinct authors who touched this file.
    authors: u32,
    /// Total lines added + deleted.
    churn: u32,
    /// Fraction of total project churn attributable to this file.
    entity_effort: f64,
    /// Share of commits by the single most active author (0.0 – 1.0).
    main_dev_pct: f64,
};

// ── Derived signals ──

pub const Signals = struct {
    /// revisions × mean_indent_complexity
    hotspot_score: f64,
    /// mean_indent_complexity × (1 - main_dev_pct)
    knowledge_loss_risk: f64,
    /// author_count / revision_count
    developer_congestion: f64,
    /// Slope of mean indentation over time (positive = deteriorating).
    complexity_trend: f64,
};

// ── Zone (1–4) for color coding ──

pub const Zone = enum(u3) {
    green = 1,
    yellow = 2,
    orange = 3,
    red = 4,

    pub fn label(self: Zone) []const u8 {
        return switch (self) {
            .green => "🟢",
            .yellow => "🟡",
            .orange => "🟠",
            .red => "🔴",
        };
    }

    pub fn name(self: Zone) []const u8 {
        return switch (self) {
            .green => "Green",
            .yellow => "Yellow",
            .orange => "Orange",
            .red => "Red",
        };
    }
};

// ── Per-file result combining all metrics ──

pub const FileResult = struct {
    metrics: FileMetrics,
    evolution: EvolutionMetrics,
    signals: Signals,
    hotspot_zone: Zone,
    complexity_zone: Zone,
    revisions_zone: Zone,
    authors_zone: Zone,
    congestion_zone: Zone,
    risk_zone: Zone,
};

// ── Change coupling entry ──

pub const CouplingPair = struct {
    file_a: []const u8,
    file_b: []const u8,
    shared_commits: u32,
    total_commits_a: u32,
    total_commits_b: u32,
    degree: f64,
    trend: TrendDirection,
};

pub const TrendDirection = enum(u2) {
    falling = 0,
    stable = 1,
    rising = 2,

    pub fn label(self: TrendDirection) []const u8 {
        return switch (self) {
            .falling => "🔽",
            .stable => "➡️",
            .rising => "🔺",
        };
    }
};

// ── Threshold snapshot ──

pub const Thresholds = struct {
    p60_hotspot: f64 = 0,
    p85_hotspot: f64 = 0,
    p95_hotspot: f64 = 0,
    p60_complexity: f64 = 0,
    p85_complexity: f64 = 0,
    p95_complexity: f64 = 0,
    p60_revisions: f64 = 0,
    p85_revisions: f64 = 0,
    p95_revisions: f64 = 0,
    p60_authors: f64 = 0,
    p85_authors: f64 = 0,
    p95_authors: f64 = 0,
    p60_congestion: f64 = 0,
    p85_congestion: f64 = 0,
    p95_congestion: f64 = 0,
    p60_risk: f64 = 0,
    p85_risk: f64 = 0,
    p95_risk: f64 = 0,
};

// ── History DB entry (JSON-lines record) ──

pub const HistoryEntry = struct {
    scan_id: []const u8,
    file: []const u8,
    date: []const u8,
    loc: u32,
    indent_mean: f64,
    indent_max: u32,
    revisions: u32,
    authors: u32,
    main_dev_pct: f64,
    churn: u32,
};

// ── CLI configuration ──

pub const CliConfig = struct {
    path: []const u8 = ".",
    after: []const u8 = "6 months ago",
    out_file: ?[]const u8 = null,
    out_markdown: ?[]const u8 = null,
    history_file: []const u8 = ".soteria/history.jsonl",
    coupling_file: []const u8 = ".soteria/coupling.json",
    thresholds_file: []const u8 = ".soteria/thresholds.json",
    ignore_file: []const u8 = ".guardrailignore",
    verbose: bool = false,
};

// ── Full scan report ──

pub const Report = struct {
    project_path: []const u8,
    scan_id: []const u8,
    window: []const u8,
    files: []FileResult,
    couplings: []CouplingPair,
    thresholds: Thresholds,
};

// ── Source extension whitelist ──

pub const source_extensions = [_][]const u8{
    ".zig", ".rs", ".go", ".java", ".js", ".ts",
    ".c", ".h", ".cpp", ".hpp", ".py", ".rb",
};

/// Returns `true` if `path` has a recognized source extension.
pub fn hasSourceExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (source_extensions) |valid| {
        if (std.mem.eql(u8, ext, valid)) return true;
    }
    return false;
}
