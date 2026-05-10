const std = @import("std");
const types = @import("types.zig");

/// Compute derived signals from static and evolutionary metrics.
///
/// Signals computed:
/// - hotspot_score: revisions × mean_indentation_complexity
/// - knowledge_loss_risk: mean_indent_complexity × (1 - main_dev_pct)
/// - developer_congestion: author_count / revision_count
/// - complexity_trend: passed through from trend analysis
pub fn computeSignals(
    metrics: types.FileMetrics,
    evolution: types.EvolutionMetrics,
    complexity_trend: f64,
) types.Signals {
    const hotspot_score = @as(f64, @floatFromInt(evolution.revisions)) * metrics.indent_mean;

    const knowledge_loss_risk = metrics.indent_mean * (1.0 - evolution.main_dev_pct);

    const developer_congestion: f64 = if (evolution.revisions > 0)
        @as(f64, @floatFromInt(evolution.authors)) / @as(f64, @floatFromInt(evolution.revisions))
    else
        0.0;

    return .{
        .hotspot_score = hotspot_score,
        .knowledge_loss_risk = knowledge_loss_risk,
        .developer_congestion = developer_congestion,
        .complexity_trend = complexity_trend,
    };
}

test "computeSignals basic" {
    const metrics = types.FileMetrics{
        .path = "src/main.zig",
        .loc = 200,
        .indent_mean = 3.0,
        .indent_max = 8,
        .indent_std = 1.5,
        .comment_ratio = 0.1,
    };
    const evolution = types.EvolutionMetrics{
        .revisions = 10,
        .authors = 3,
        .churn = 500,
        .entity_effort = 0.05,
        .main_dev_pct = 0.6,
    };

    const signals = computeSignals(metrics, evolution, 0.5);

    // hotspot = 10 * 3.0 = 30
    try std.testing.expectEqual(@as(f64, 30.0), signals.hotspot_score);

    // risk = 3.0 * (1 - 0.6) = 1.2
    try std.testing.expectEqual(@as(f64, 1.2), signals.knowledge_loss_risk);

    // congestion = 3 / 10 = 0.3
    try std.testing.expectEqual(@as(f64, 0.3), signals.developer_congestion);

    // trend = 0.5 (passed through)
    try std.testing.expectEqual(@as(f64, 0.5), signals.complexity_trend);
}

test "computeSignals zero revisions" {
    const metrics = types.FileMetrics{
        .path = "src/new.zig",
        .loc = 50,
        .indent_mean = 2.0,
        .indent_max = 4,
        .indent_std = 1.0,
        .comment_ratio = 0.05,
    };
    const evolution = types.EvolutionMetrics{
        .revisions = 0,
        .authors = 0,
        .churn = 0,
        .entity_effort = 0,
        .main_dev_pct = 0,
    };

    const signals = computeSignals(metrics, evolution, 0.0);

    try std.testing.expectEqual(@as(f64, 0.0), signals.hotspot_score);
    try std.testing.expectEqual(@as(f64, 0.0), signals.developer_congestion);
}
