const std = @import("std");
const arrowlane = @import("arrowlane");

const MANIFEST =
    \\{"kind":"arrowlane","name":"arrowlane-zig","version":"0.1.0","frame":{"magic":"ALN1","version":1,"prefix_bytes":38,"max_header_bytes":65535,"max_payload_bytes":536870912,"max_uncompressed_bytes":1073741824},"streaming":{"default_chunk_rows":50000,"max_chunks":1000000},"lanes":["json","ipc","ipc-zstd","shm"],"capabilities":{"frame":true,"select":true,"schema":"general","json":"fixture","ipc":"fixture","ipc_zstd":"fixture","shm":false,"chunks":"fixture","c_abi":true}}
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
        \\  pack-int64 --values 1,2,null  write a one-column JSON frame
        \\  unpack-int64 --in frame.aln    read a one-column JSON frame
        \\  ipc-int64 --values 1,2,3       write a one-field int64 IPC stream
        \\  ipc-int64 --in stream.arrow    read a one-field int64 IPC stream
        \\  pack-ipc-int64 --values 1,2,3  write a one-field int64 IPC frame
        \\  unpack-ipc-int64 --in frame.aln read a one-field int64 IPC frame
        \\  pack --lane json [--rows N] [--out FILE]  write the fixture JSON frame
        \\  unpack FILE [--json]          validate a fixture JSON frame
        \\  pack-chunks --rows N --chunk-rows M --out FILE  write JSON chunks
        \\         [--lane json|ipc|ipc-zstd]
        \\  unpack-chunks --in FILE [--json]                validate chunks
        \\  schema-int64 [--nullable]  write the int64 schema spike to stdout
        \\  schema-general-fixture     write the general eight-field schema to stdout
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

fn printValues(writer: *std.Io.Writer, values: []const ?i64) !void {
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(",");
        if (value) |number| {
            try writer.print("{d}", .{number});
        } else {
            try writer.writeAll("null");
        }
    }
    try writer.writeAll("\n");
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

    if (std.mem.eql(u8, command, "schema-general-int64")) {
        const one = arrowlane.schema_general.Schema{ .fields = &.{
            .{ .name = "a", .nullable = false, .data_type = .{ .int = .{ .bit_width = 64, .is_signed = true } } },
        } };
        const encoded = try arrowlane.schema_general.encode(init.arena.allocator(), one);
        try writer.writeAll(encoded);
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, command, "schema-general-fixture")) {
        const encoded = try arrowlane.schema_general.encode(init.arena.allocator(), arrowlane.schema_general.fixture_schema);
        try writer.writeAll(encoded);
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "pack-int64")) {
        if (args.len < 4 or !std.mem.eql(u8, args[2], "--values")) return error.MissingValue;
        var values: std.ArrayList(?i64) = .empty;
        defer values.deinit(init.gpa);
        var parts = std.mem.splitScalar(u8, args[3], ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "null")) {
                values.append(init.gpa, null) catch return error.OutOfMemory;
            } else {
                const number = try std.fmt.parseInt(i64, trimmed, 10);
                values.append(init.gpa, number) catch return error.OutOfMemory;
            }
        }
        const owned = values.toOwnedSlice(init.gpa) catch return error.OutOfMemory;
        defer init.gpa.free(owned);
        const wire = arrowlane.json_int64.encode(init.gpa, owned) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(wire);
        try writer.writeAll(wire);
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "unpack-int64")) {
        if (args.len < 4 or !std.mem.eql(u8, args[2], "--in")) return error.MissingValue;
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.gpa, .limited(64 * 1024 * 1024));
        defer init.gpa.free(data);
        const values = arrowlane.json_int64.decode(init.gpa, data) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(values);
        try printValues(writer, values);
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
    if (std.mem.eql(u8, command, "ipc-int64")) {
        if (args.len < 4) return error.MissingValue;
        if (std.mem.eql(u8, args[2], "--values")) {
            var values: std.ArrayList(i64) = .empty;
            defer values.deinit(init.gpa);
            var parts = std.mem.splitScalar(u8, args[3], ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                values.append(init.gpa, try std.fmt.parseInt(i64, trimmed, 10)) catch return error.OutOfMemory;
            }
            const owned = values.toOwnedSlice(init.gpa) catch return error.OutOfMemory;
            defer init.gpa.free(owned);
            const raw = arrowlane.ipc_int64.encode(init.gpa, owned) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            defer init.gpa.free(raw);
            try writer.writeAll(raw);
            try writer.flush();
            return;
        }
        if (std.mem.eql(u8, args[2], "--in")) {
            const data = std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.gpa, .limited(64 * 1024 * 1024)) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            defer init.gpa.free(data);
            const values = arrowlane.ipc_int64.decode(init.gpa, data) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            defer init.gpa.free(values);
            for (values, 0..) |value, index| {
                if (index > 0) try writer.writeAll(",");
                try writer.print("{d}", .{value});
            }
            try writer.writeAll("\n");
            try writer.flush();
            return;
        }
        return error.MissingValue;
    }
    if (std.mem.eql(u8, command, "pack-ipc-int64")) {
        if (args.len < 4 or !std.mem.eql(u8, args[2], "--values")) return error.MissingValue;
        var values: std.ArrayList(i64) = .empty;
        defer values.deinit(init.gpa);
        var parts = std.mem.splitScalar(u8, args[3], ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) continue;
            values.append(init.gpa, try std.fmt.parseInt(i64, trimmed, 10)) catch return error.OutOfMemory;
        }
        const owned = values.toOwnedSlice(init.gpa) catch return error.OutOfMemory;
        defer init.gpa.free(owned);
        const wire = arrowlane.ipc_int64.encodeFrame(init.gpa, owned) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(wire);
        try writer.writeAll(wire);
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "unpack-ipc-int64")) {
        if (args.len < 4 or !std.mem.eql(u8, args[2], "--in")) return error.MissingValue;
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(data);
        const values = arrowlane.ipc_int64.decodeFrame(init.gpa, data) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(values);
        for (values, 0..) |value, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("{d}", .{value});
        }
        try writer.writeAll("\n");
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "pack")) {
        var lane: []const u8 = "ipc";
        var rows: usize = 500;
        var out_path: ?[]const u8 = null;
        var index: usize = 2;
        while (index < args.len) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--lane") or std.mem.eql(u8, arg, "--rows") or std.mem.eql(u8, arg, "--out")) {
                if (index + 1 >= args.len) return error.MissingValue;
                const value = args[index + 1];
                if (std.mem.eql(u8, arg, "--lane")) {
                    lane = value;
                } else if (std.mem.eql(u8, arg, "--rows")) {
                    rows = try std.fmt.parseInt(usize, value, 10);
                } else {
                    out_path = value;
                }
                index += 2;
            } else {
                return error.UnknownOption;
            }
        }
        if (!std.mem.eql(u8, lane, "json") and !std.mem.eql(u8, lane, "ipc") and !std.mem.eql(u8, lane, "ipc-zstd")) {
            std.debug.print("error: lane {s} is not implemented\n", .{lane});
            std.process.exit(2);
        }
        const wire = if (std.mem.eql(u8, lane, "ipc-zstd"))
            arrowlane.ipc_zstd.encodeFrame(init.gpa, rows) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            }
        else if (std.mem.eql(u8, lane, "ipc"))
            arrowlane.ipc_fixture.encodeFrame(init.gpa, rows) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            }
        else
            arrowlane.fixture_json.encodeSample(init.gpa, rows) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
        defer init.gpa.free(wire);
        if (out_path) |path| {
            std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = wire }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
        } else {
            try writer.writeAll(wire);
            try writer.flush();
        }
        return;
    }
    if (std.mem.eql(u8, command, "unpack")) {
        if (args.len < 3 or std.mem.startsWith(u8, args[2], "-")) return error.MissingValue;
        const path = args[2];
        const as_json = args.len > 3 and std.mem.eql(u8, args[3], "--json");
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(data);
        const parsed = arrowlane.frame.decode(init.gpa, data, .{}) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        const Summary = struct { rows: u64, lane: []const u8 };
        const summary: Summary = switch (parsed.lane_id) {
            1 => blk: {
                const value = arrowlane.fixture_json.validate(init.gpa, data) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    std.process.exit(2);
                };
                break :blk .{ .rows = value.rows, .lane = value.lane };
            },
            2 => blk: {
                const value = arrowlane.ipc_fixture.decodeFrame(init.gpa, data) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    std.process.exit(2);
                };
                break :blk .{ .rows = value.rows, .lane = value.lane };
            },
            3 => blk: {
                const value = arrowlane.ipc_zstd.decodeFrame(init.gpa, data) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    std.process.exit(2);
                };
                break :blk .{ .rows = value.rows, .lane = value.lane };
            },
            else => {
                std.debug.print("error: lane is not a fixture lane\n", .{});
                std.process.exit(2);
            },
        };
        if (as_json) {
            try writer.print(
                "{{\"lane\":\"{s}\",\"rows\":{d},\"columns\":8,\"wire_bytes\":{d}}}\n",
                .{ summary.lane, summary.rows, data.len },
            );
        } else {
            try writer.print("lane={s} rows={d} columns=8 wire_bytes={d}\n", .{ summary.lane, summary.rows, data.len });
        }
        try writer.flush();
        return;
    }
    if (std.mem.eql(u8, command, "pack-chunks")) {
        var rows: ?usize = null;
        var chunk_rows: ?usize = null;
        var out_path: ?[]const u8 = null;
        var lane: []const u8 = "json";
        var index: usize = 2;
        while (index < args.len) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--rows") or std.mem.eql(u8, arg, "--chunk-rows") or std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--lane")) {
                if (index + 1 >= args.len) return error.MissingValue;
                const value = args[index + 1];
                if (std.mem.eql(u8, arg, "--rows")) {
                    rows = try std.fmt.parseInt(usize, value, 10);
                } else if (std.mem.eql(u8, arg, "--chunk-rows")) {
                    chunk_rows = try std.fmt.parseInt(usize, value, 10);
                } else if (std.mem.eql(u8, arg, "--lane")) {
                    lane = value;
                } else {
                    out_path = value;
                }
                index += 2;
            } else {
                return error.UnknownOption;
            }
        }
        if (rows == null or chunk_rows == null) return error.MissingValue;
        const wire = arrowlane.chunks.packLane(init.gpa, rows.?, chunk_rows.?, lane) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(wire);
        if (out_path) |path| {
            std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = wire }) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
        } else {
            try writer.writeAll(wire);
            try writer.flush();
        }
        return;
    }
    if (std.mem.eql(u8, command, "unpack-chunks")) {
        if (args.len < 4 or !std.mem.eql(u8, args[2], "--in")) return error.MissingValue;
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(data);
        const summary = arrowlane.chunks.validate(init.gpa, data) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        const as_json = args.len > 4 and std.mem.eql(u8, args[4], "--json");
        if (as_json) {
            try writer.print(
                "{{\"lane\":\"{s}\",\"rows\":{d},\"chunks\":{d},\"wire_bytes\":{d}}}\n",
                .{ summary.lane, summary.rows, summary.chunks, data.len },
            );
        } else {
            try writer.print("lane={s} rows={d} chunks={d} wire_bytes={d}\n", .{ summary.lane, summary.rows, summary.chunks, data.len });
        }
        try writer.flush();
        return;
    }
    _ = &buffer;
    usage();
    std.process.exit(2);
}
