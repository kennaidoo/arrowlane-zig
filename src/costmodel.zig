//! Measured cost model for the lane selector.
//!
//! The coefficients are the shipped Python model. A JSON loader comes later;
//! the default model is embedded here so selection is deterministic offline.

const std = @import("std");

pub const SCHEMA_VERSION: u32 = 1;

pub const LaneCost = struct {
    fixed_ms: f64,
    enc_ms_per_mb: f64,
    dec_ms_per_mb: f64,
    ratio: f64,
};

pub const Model = struct {
    wire_same_host: f64 = 333.0,
    wire_same_network: f64 = 800.0,
    wire_wide_area: f64 = 25_000.0,
    ipc: LaneCost = .{
        .fixed_ms = 0.06,
        .enc_ms_per_mb = 0.301326,
        .dec_ms_per_mb = 0.002203,
        .ratio = 1.000034,
    },
    ipc_zstd: LaneCost = .{
        .fixed_ms = 8.094584,
        .enc_ms_per_mb = 2.249972,
        .dec_ms_per_mb = 1.280676,
        .ratio = 0.311601,
    },
    json: LaneCost = .{
        .fixed_ms = 0.002,
        .enc_ms_per_mb = 197.329541,
        .dec_ms_per_mb = 152.264359,
        .ratio = 2.615945,
    },
    shm: LaneCost = .{
        .fixed_ms = 0.05,
        .enc_ms_per_mb = 0.05,
        .dec_ms_per_mb = 0.05,
        .ratio = 0.0,
    },

    pub fn laneCost(self: *const Model, lane: []const u8) ?LaneCost {
        if (std.mem.eql(u8, lane, "ipc")) return self.ipc;
        if (std.mem.eql(u8, lane, "ipc-zstd")) return self.ipc_zstd;
        if (std.mem.eql(u8, lane, "json")) return self.json;
        if (std.mem.eql(u8, lane, "shm")) return self.shm;
        return null;
    }

    pub fn laneNames() []const []const u8 {
        return &lane_names;
    }

    pub fn wireCost(self: *const Model, topology: []const u8) ?f64 {
        if (std.mem.eql(u8, topology, "same_host")) return self.wire_same_host;
        if (std.mem.eql(u8, topology, "same_network")) return self.wire_same_network;
        if (std.mem.eql(u8, topology, "wide_area")) return self.wire_wide_area;
        return null;
    }

    pub fn predict(self: *const Model, lane: []const u8, mb: f64, topology: []const u8, policy: []const u8) ?f64 {
        const cost = self.laneCost(lane) orelse return null;
        var total = cost.fixed_ms + (cost.enc_ms_per_mb + cost.dec_ms_per_mb) * mb;
        if (!std.mem.eql(u8, policy, "cpu")) {
            const wire = self.wireCost(topology) orelse return null;
            total += (wire / 1000.0) * mb * cost.ratio;
        }
        return total;
    }

    pub fn bytesFor(self: *const Model, lane: []const u8, arrow_bytes: u64) ?u64 {
        const cost = self.laneCost(lane) orelse return null;
        const value = @as(f64, @floatFromInt(arrow_bytes)) * cost.ratio;
        return @intFromFloat(value);
    }
};

pub const lane_names = [_][]const u8{ "ipc", "ipc-zstd", "json", "shm" };

pub const default_model = Model{};

test "default model predicts" {
    const model = default_model;
    const ipc = model.predict("ipc", 1.0, "same_host", "latency").?;
    const json = model.predict("json", 1.0, "same_host", "latency").?;
    try std.testing.expect(ipc > 0);
    try std.testing.expect(json > ipc);
}

test "cpu drops the wire term" {
    const model = default_model;
    const latency = model.predict("ipc", 5.0, "wide_area", "latency").?;
    const cpu = model.predict("ipc", 5.0, "wide_area", "cpu").?;
    try std.testing.expect(cpu < latency);
}
