//! Deterministic lane selection from the cost model.
//!
//! The rule order matches the Python package: non-tabular, empty, candidate
//! filtering, score, gain floor, then the tie break.

const std = @import("std");
const builtin = @import("builtin");
const costmodel = @import("costmodel.zig");

pub const Topology = enum {
    same_host,
    same_network,
    wide_area,

    pub fn asText(self: Topology) []const u8 {
        return switch (self) {
            .same_host => "same_host",
            .same_network => "same_network",
            .wide_area => "wide_area",
        };
    }
};

pub const Policy = enum {
    latency,
    throughput,
    cpu,

    pub fn asText(self: Policy) []const u8 {
        return switch (self) {
            .latency => "latency",
            .throughput => "throughput",
            .cpu => "cpu",
        };
    }
};

pub const Workload = struct {
    rows: u64,
    arrow_bytes: u64,
    tabular: bool = true,

    pub fn validate(self: Workload) Error!void {
        if (self.rows > 0 and self.arrow_bytes == 0) return error.InvalidWorkload;
    }
};

pub const Score = struct {
    name: []const u8,
    value: f64,
};

pub const Rejection = struct {
    name: []const u8,
    reason: []const u8,
};

pub const Decision = struct {
    lane: []const u8,
    reason: []const u8,
    predicted_ms: f64,
    predicted_bytes: u64,
    scores: [4]Score,
    score_count: usize,
    rejected: [4]Rejection,
    rejected_count: usize,
};

pub const Error = error{
    InvalidWorkload,
    InvalidGain,
    UnknownTopology,
    UnknownPolicy,
};

const windows_lanes = [_][]const u8{ "json", "ipc", "ipc-zstd" };
const posix_lanes = [_][]const u8{ "json", "ipc", "ipc-zstd", "shm" };

pub fn platformLanes() []const []const u8 {
    return if (builtin.os.tag == .windows) &windows_lanes else &posix_lanes;
}

fn contains(lanes: []const []const u8, name: []const u8) bool {
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane, name)) return true;
    }
    return false;
}

fn order(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "shm")) return 0;
    if (std.mem.eql(u8, name, "ipc-zstd")) return 1;
    if (std.mem.eql(u8, name, "ipc")) return 2;
    if (std.mem.eql(u8, name, "json")) return 3;
    return 99;
}

fn jsonInScores(scores: []const Score) bool {
    for (scores) |score| {
        if (std.mem.eql(u8, score.name, "json")) return true;
    }
    return false;
}

fn emptyDecision(baseline: f64, arrow_bytes: u64) Decision {
    return .{
        .lane = "json",
        .reason = "",
        .predicted_ms = baseline,
        .predicted_bytes = arrow_bytes,
        .scores = undefined,
        .score_count = 0,
        .rejected = undefined,
        .rejected_count = 0,
    };
}

pub fn select(
    model: *const costmodel.Model,
    workload: Workload,
    topology: Topology,
    policy: Policy,
    allowed: ?[]const []const u8,
    shm_ready: bool,
    min_gain: f64,
) Error!Decision {
    try workload.validate();
    if (!(min_gain >= 0.0 and min_gain < 1.0)) return error.InvalidGain;

    const mb = @as(f64, @floatFromInt(@max(workload.arrow_bytes, 1))) / 1_000_000.0;
    const baseline = model.predict("json", mb, topology.asText(), policy.asText()) orelse return error.UnknownTopology;

    var decision = emptyDecision(baseline, workload.arrow_bytes);
    if (!workload.tabular) {
        decision.reason = "NON_TABULAR";
        return decision;
    }
    if (workload.rows == 0) {
        decision.reason = "EMPTY";
        return decision;
    }

    const platform = platformLanes();
    const names = allowed orelse costmodel.Model.laneNames();
    for (names) |name| {
        if (model.laneCost(name) == null) {
            decision.rejected[decision.rejected_count] = .{ .name = name, .reason = "UNKNOWN_LANE" };
            decision.rejected_count += 1;
            continue;
        }
        if (std.mem.eql(u8, name, "shm") and !shm_ready) {
            decision.rejected[decision.rejected_count] = .{ .name = name, .reason = "SHM_UNAVAILABLE" };
            decision.rejected_count += 1;
            continue;
        }
        if (!contains(platform, name)) {
            decision.rejected[decision.rejected_count] = .{ .name = name, .reason = "NOT_AVAILABLE_ON_PLATFORM" };
            decision.rejected_count += 1;
            continue;
        }
        const value = model.predict(name, mb, topology.asText(), policy.asText()) orelse continue;
        decision.scores[decision.score_count] = .{ .name = name, .value = value };
        decision.score_count += 1;
    }
    const scores = decision.scores[0..decision.score_count];
    if (scores.len == 0) {
        decision.lane = "json";
        decision.reason = "NO_CANDIDATE";
        return decision;
    }

    var best_name: []const u8 = scores[0].name;
    var best_value: f64 = scores[0].value;
    if (policy == .throughput) {
        var floor = scores[0].value;
        for (scores[1..]) |score| {
            floor = @min(floor, score.value);
        }
        floor *= 1.05;
        var found = false;
        for (scores) |score| {
            if (score.value > floor) continue;
            const bytes = model.bytesFor(score.name, workload.arrow_bytes) orelse continue;
            if (!found) {
                best_name = score.name;
                best_value = score.value;
                found = true;
            } else {
                const best_bytes = model.bytesFor(best_name, workload.arrow_bytes) orelse 0;
                if (bytes < best_bytes or (bytes == best_bytes and score.value < best_value)) {
                    best_name = score.name;
                    best_value = score.value;
                }
            }
        }
    } else {
        for (scores[1..]) |score| {
            if (score.value < best_value or (score.value == best_value and order(score.name) < order(best_name))) {
                best_name = score.name;
                best_value = score.value;
            }
        }
    }

    if (!std.mem.eql(u8, best_name, "json") and jsonInScores(scores)) {
        const too_small = if (policy == .throughput) blk: {
            const chosen_bytes = model.bytesFor(best_name, workload.arrow_bytes) orelse 0;
            const base_bytes = model.bytesFor("json", workload.arrow_bytes) orelse 0;
            break :blk @as(f64, @floatFromInt(chosen_bytes)) > @as(f64, @floatFromInt(base_bytes)) * (1.0 - min_gain);
        } else best_value > baseline * (1.0 - min_gain);
        if (too_small) {
            decision.lane = "json";
            decision.reason = "GAIN_TOO_SMALL";
            decision.predicted_ms = baseline;
            decision.predicted_bytes = workload.arrow_bytes;
            return decision;
        }
    }
    decision.lane = best_name;
    decision.reason = "BEST";
    decision.predicted_ms = best_value;
    decision.predicted_bytes = model.bytesFor(best_name, workload.arrow_bytes) orelse workload.arrow_bytes;
    return decision;
}

test "empty and non-tabular use json" {
    const model = costmodel.default_model;
    const empty = try select(&model, .{ .rows = 0, .arrow_bytes = 0 }, .same_network, .latency, null, false, 0.10);
    try std.testing.expectEqualStrings("json", empty.lane);
    try std.testing.expectEqualStrings("EMPTY", empty.reason);
    const text = try select(&model, .{ .rows = 1, .arrow_bytes = 100, .tabular = false }, .same_network, .latency, null, false, 0.10);
    try std.testing.expectEqualStrings("json", text.lane);
    try std.testing.expectEqualStrings("NON_TABULAR", text.reason);
}

test "shm needs a token" {
    const model = costmodel.default_model;
    const decision = try select(&model, .{ .rows = 1000, .arrow_bytes = 1_000_000 }, .same_host, .latency, &.{ "shm", "ipc" }, false, 0.10);
    try std.testing.expectEqualStrings("ipc", decision.lane);
    try std.testing.expectEqualStrings("shm", decision.rejected[0].name);
    try std.testing.expectEqualStrings("SHM_UNAVAILABLE", decision.rejected[0].reason);
}
