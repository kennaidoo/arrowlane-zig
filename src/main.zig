const std = @import("std");
const arrowlane = @import("arrowlane");

const MANIFEST =
    \\{"kind":"arrowlane","name":"arrowlane-zig","version":"0.1.0","frame":{"magic":"ALN1","version":1,"prefix_bytes":38,"max_header_bytes":65535,"max_payload_bytes":536870912,"max_uncompressed_bytes":1073741824},"streaming":{"default_chunk_rows":50000,"max_chunks":1000000},"lanes":["json","ipc","ipc-zstd","shm"],"capabilities":{"frame":true,"select":true,"schema":"int64-spike","json":false,"ipc":false,"ipc_zstd":false,"shm":false,"chunks":false,"c_abi":false}}
;

fn usage() void {
    std.debug.print(
        \\usage: arrowlane-zig <command>
        \\
        \\commands:
        \\  describe [--compact]       print the machine-readable manifest
        \\  select --rows N --bytes N  explain a lane choice
        \\         [--topology same_host|same_network|wide_area]
        \\         [--policy latency|throughput|cpu]
        \\         [--allow lane1,lane2] [--shm-ready] [--json]
        \\  schema-int64 [--nullable]  write the int64 schema spike to stdout
        \\  version                   print the version
        \\
    , .{});
}

fn parseTopology(text: []const u8) !arrowlane.select.Topology {
    if (std.mem.eql(u8, text, "same_host")) return .same_host;
    if (std.mem.eql(u8, text, "same_network")) return .same_network;
    if (std.mem.eql(u8, text, "wide_area")) return .wide_area;
    return error.UnknownTopology;
}

fn parsePolicy(text: []const u8) !arrowlane.select.Policy {
    if (std.mem.eql(u8, text, "latency")) return .latency;
    if (std.mem.eql(u8, text, "throughput")) return .throughput;
    if (std.mem.eql(u8, text, "cpu")) return .cpu;
    return error.UnknownPolicy;
}

fn printDecision(writer: *std.Io.Writer, decision: arrowlane.select.Decision, as_json: bool) !void {
    if (as_json) {
        try writer.print(
            "{{\"lane\":\"{s}\",\"reason\":\"{s}\",\"predicted_ms\":{d:.4},\"predicted_bytes\":{d},\"scores\":[",
            .{ decision.lane, decision.reason, decision.predicted_ms, decision.predicted_bytes },
        );
        for (decision.scores[0..decision.score_count], 0..) |score, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("[\"{s}\",{d:.4}]", .{ score.name, score.value });
        }
        try writer.writeAll("],\"rejected\":[");
        for (decision.rejected[0..decision.rejected_count], 0..) |rejected, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("[\"{s}\",\"{s}\"]", .{ rejected.name, rejected.reason });
        }
        try writer.writeAll("]}\n");
        return;
    }
    try writer.print(
        "lane={s} reason={s} predicted_ms={d:.3} predicted_bytes={d}\n",
        .{ decision.lane, decision.reason, decision.predicted_ms, decision.predicted_bytes },
    );
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        usage();
        std.process.exit(2);
    }
    const command = args[1];
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &file_writer.interface;

    if (std.mem.eql(u8, command, "describe")) {
        try writer.writeAll(MANIFEST);
        try writer.writeAll("\n");
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "version")) {
        try writer.print("{s} {s}\n", .{ arrowlane.NAME, arrowlane.VERSION });
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "schema-int64")) {
        const nullable = args.len > 2 and std.mem.eql(u8, args[2], "--nullable");
        const raw = try arrowlane.schema.encodeInt64(init.gpa, nullable);
        defer init.gpa.free(raw);
        try writer.writeAll(raw);
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "select")) {
        var rows: ?u64 = null;
        var arrow_bytes: ?u64 = null;
        var topology: arrowlane.select.Topology = .same_network;
        var policy: arrowlane.select.Policy = .latency;
        var shm_ready = false;
        var as_json = false;
        var allow_seen = false;
        var allowed_buffer: [4][]const u8 = undefined;
        var allowed_count: usize = 0;

        var index: usize = 2;
        while (index < args.len) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--json")) {
                as_json = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--shm-ready")) {
                shm_ready = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--rows") or std.mem.eql(u8, arg, "--bytes") or
                std.mem.eql(u8, arg, "--topology") or std.mem.eql(u8, arg, "--policy") or
                std.mem.eql(u8, arg, "--allow"))
            {
                if (index + 1 >= args.len) return error.MissingValue;
                const value = args[index + 1];
                if (std.mem.eql(u8, arg, "--rows")) {
                    rows = try std.fmt.parseInt(u64, value, 10);
                } else if (std.mem.eql(u8, arg, "--bytes")) {
                    arrow_bytes = try std.fmt.parseInt(u64, value, 10);
                } else if (std.mem.eql(u8, arg, "--topology")) {
                    topology = try parseTopology(value);
                } else if (std.mem.eql(u8, arg, "--policy")) {
                    policy = try parsePolicy(value);
                } else {
                    allow_seen = true;
                    var parts = std.mem.splitScalar(u8, value, ',');
                    while (parts.next()) |part| {
                        const trimmed = std.mem.trim(u8, part, " ");
                        if (trimmed.len == 0) continue;
                        if (allowed_count == allowed_buffer.len) return error.TooManyLanes;
                        allowed_buffer[allowed_count] = trimmed;
                        allowed_count += 1;
                    }
                }
                index += 2;
            } else {
                return error.UnknownOption;
            }
        }
        if (rows == null or arrow_bytes == null) return error.MissingValue;
        const allowed: ?[]const []const u8 = if (allow_seen) allowed_buffer[0..allowed_count] else null;
        const decision = arrowlane.select.select(
            &arrowlane.costmodel.default_model,
            .{ .rows = rows.?, .arrow_bytes = arrow_bytes.? },
            topology,
            policy,
            allowed,
            shm_ready,
            0.10,
        ) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        try printDecision(writer, decision, as_json);
        try writer.flush();
        return;
    }
    _ = &buffer;
    usage();
    std.process.exit(2);
}
