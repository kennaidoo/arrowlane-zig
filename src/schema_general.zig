//! General Arrow schema reader and writer for the common fixture types.
//!
//! This owns the Arrow Schema flatbuffer and the encapsulated message. It is a
//! schema codec only; the record-batch codec remains fixture-scoped.

const std = @import("std");

pub const Error = error{
    BadSchema,
    UnsupportedType,
    OutOfMemory,
};

pub const FloatPrecision = enum { half, single, double };
pub const DateUnit = enum { day, millisecond };
pub const TimeUnit = enum { second, millisecond, microsecond, nanosecond };

pub const DataType = union(enum) {
    int: struct { bit_width: u8, is_signed: bool },
    floating: FloatPrecision,
    binary,
    utf8,
    boolean,
    decimal: struct { precision: i32, scale: i32, bit_width: i32 },
    date: DateUnit,
    timestamp: struct { unit: TimeUnit, timezone: ?[]const u8 },
};

pub const Field = struct {
    name: []const u8,
    nullable: bool,
    data_type: DataType,
};

pub const Schema = struct {
    fields: []const Field,
};

pub const fixture_fields = [_]Field{
    .{ .name = "id", .nullable = true, .data_type = .{ .int = .{ .bit_width = 64, .is_signed = true } } },
    .{ .name = "name", .nullable = true, .data_type = .utf8 },
    .{ .name = "score", .nullable = true, .data_type = .{ .floating = .double } },
    .{ .name = "ok", .nullable = true, .data_type = .boolean },
    .{ .name = "day", .nullable = true, .data_type = .{ .date = .day } },
    .{ .name = "amount", .nullable = true, .data_type = .{ .decimal = .{ .precision = 9, .scale = 2, .bit_width = 128 } } },
    .{ .name = "ts", .nullable = true, .data_type = .{ .timestamp = .{ .unit = .microsecond, .timezone = "UTC" } } },
    .{ .name = "blob", .nullable = true, .data_type = .binary },
};

pub const fixture_schema = Schema{ .fields = &fixture_fields };

const type_int: u8 = 2;
const type_floating: u8 = 3;
const type_binary: u8 = 4;
const type_utf8: u8 = 5;
const type_bool: u8 = 6;
const type_decimal: u8 = 7;
const type_date: u8 = 8;
const type_timestamp: u8 = 10;

const FieldSpec = struct {
    alignment: u8,
    size: u8,
};

const TableRef = struct {
    pos: usize,
    vtable_pos: usize,
    offsets: [8]u16,
    count: usize,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Builder) void {
        self.bytes.deinit(self.allocator);
    }

    fn appendZeros(self: *Builder, count: usize) Error!void {
        for (0..count) |_| self.bytes.append(self.allocator, 0) catch return error.OutOfMemory;
    }

    fn alignTo(self: *Builder, alignment: usize) Error!void {
        while (self.bytes.items.len % alignment != 0) try self.appendZeros(1);
    }

    fn writeU8(self: *Builder, position: usize, value: u8) void {
        self.bytes.items[position] = value;
    }

    fn writeU16(self: *Builder, position: usize, value: u16) void {
        self.bytes.items[position] = @truncate(value);
        self.bytes.items[position + 1] = @truncate(value >> 8);
    }

    fn writeU32(self: *Builder, position: usize, value: u32) void {
        self.bytes.items[position] = @truncate(value);
        self.bytes.items[position + 1] = @truncate(value >> 8);
        self.bytes.items[position + 2] = @truncate(value >> 16);
        self.bytes.items[position + 3] = @truncate(value >> 24);
    }

    fn writeI32(self: *Builder, position: usize, value: i32) void {
        self.writeU32(position, @bitCast(value));
    }

    fn allocTable(self: *Builder, specs: []const FieldSpec) Error!TableRef {
        const vtable_len = 4 + specs.len * 2;
        try self.alignTo(2);
        const vtable_pos = self.bytes.items.len;
        try self.appendZeros(vtable_len);
        try self.alignTo(8);
        const table_pos = self.bytes.items.len;
        var cursor: usize = 4;
        var offsets: [8]u16 = undefined;
        for (&offsets) |*value| value.* = 0;
        for (specs, 0..) |spec, index| {
            const alignment: usize = spec.alignment;
            cursor = std.mem.alignForward(usize, cursor, alignment);
            offsets[index] = @intCast(cursor);
            cursor += spec.size;
        }
        const object_size = std.mem.alignForward(usize, cursor, 8);
        try self.appendZeros(object_size);
        self.writeU16(vtable_pos, @intCast(vtable_len));
        self.writeU16(vtable_pos + 2, @intCast(object_size));
        for (specs, 0..) |spec, index| {
            _ = spec;
            self.writeU16(vtable_pos + 4 + index * 2, offsets[index]);
        }
        self.writeU32(table_pos, @intCast(table_pos - vtable_pos));
        return .{ .pos = table_pos, .vtable_pos = vtable_pos, .offsets = offsets, .count = specs.len };
    }

    fn fieldPosition(self: *Builder, table: TableRef, index: usize) usize {
        _ = self;
        return table.pos + table.offsets[index];
    }

    fn setU8(self: *Builder, table: TableRef, index: usize, value: u8) void {
        self.writeU8(self.fieldPosition(table, index), value);
    }

    fn setU16(self: *Builder, table: TableRef, index: usize, value: u16) void {
        self.writeU16(self.fieldPosition(table, index), value);
    }

    fn setI32(self: *Builder, table: TableRef, index: usize, value: i32) void {
        self.writeI32(self.fieldPosition(table, index), value);
    }

    fn setAbsent(self: *Builder, table: TableRef, index: usize) void {
        self.writeU16(table.vtable_pos + 4 + index * 2, 0);
    }

    fn setOffset(self: *Builder, table: TableRef, index: usize, target: usize) void {
        const position = self.fieldPosition(table, index);
        std.debug.assert(target > position);
        self.writeU32(position, @intCast(target - position));
    }

    fn addString(self: *Builder, text: []const u8) Error!usize {
        try self.alignTo(4);
        const position = self.bytes.items.len;
        try self.appendZeros(4);
        self.writeU32(position, @intCast(text.len));
        self.bytes.appendSlice(self.allocator, text) catch return error.OutOfMemory;
        self.bytes.append(self.allocator, 0) catch return error.OutOfMemory;
        return position;
    }

    fn addVector(self: *Builder, count: usize) Error!usize {
        try self.alignTo(4);
        const position = self.bytes.items.len;
        try self.appendZeros(4 + count * 4);
        self.writeU32(position, @intCast(count));
        return position;
    }

    fn setVectorElement(self: *Builder, vector_pos: usize, index: usize, target: usize) void {
        const position = vector_pos + 4 + index * 4;
        std.debug.assert(target > position);
        self.writeU32(position, @intCast(target - position));
    }

    fn finish(self: *Builder) Error![]u8 {
        return self.bytes.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }
};

fn typeTable(builder: *Builder, data_type: DataType) Error!struct { tag: u8, pos: usize } {
    switch (data_type) {
        .int => |value| {
            const table = try builder.allocTable(&.{ .{ .alignment = 4, .size = 4 }, .{ .alignment = 1, .size = 1 } });
            builder.setI32(table, 0, value.bit_width);
            builder.setU8(table, 1, @intFromBool(value.is_signed));
            return .{ .tag = type_int, .pos = table.pos };
        },
        .floating => |value| {
            const table = try builder.allocTable(&.{.{ .alignment = 2, .size = 2 }});
            const precision: u16 = switch (value) {
                .half => 0,
                .single => 1,
                .double => 2,
            };
            builder.setU16(table, 0, precision);
            return .{ .tag = type_floating, .pos = table.pos };
        },
        .binary => {
            const table = try builder.allocTable(&.{});
            return .{ .tag = type_binary, .pos = table.pos };
        },
        .utf8 => {
            const table = try builder.allocTable(&.{});
            return .{ .tag = type_utf8, .pos = table.pos };
        },
        .boolean => {
            const table = try builder.allocTable(&.{});
            return .{ .tag = type_bool, .pos = table.pos };
        },
        .decimal => |value| {
            const table = try builder.allocTable(&.{
                .{ .alignment = 4, .size = 4 },
                .{ .alignment = 4, .size = 4 },
                .{ .alignment = 4, .size = 4 },
            });
            builder.setI32(table, 0, value.precision);
            builder.setI32(table, 1, value.scale);
            builder.setI32(table, 2, value.bit_width);
            return .{ .tag = type_decimal, .pos = table.pos };
        },
        .date => |value| {
            const table = try builder.allocTable(&.{.{ .alignment = 2, .size = 2 }});
            builder.setU16(table, 0, if (value == .day) 0 else 1);
            return .{ .tag = type_date, .pos = table.pos };
        },
        .timestamp => |value| {
            const table = try builder.allocTable(&.{
                .{ .alignment = 2, .size = 2 },
                .{ .alignment = 4, .size = 4 },
            });
            const unit: u16 = switch (value.unit) {
                .second => 0,
                .millisecond => 1,
                .microsecond => 2,
                .nanosecond => 3,
            };
            builder.setU16(table, 0, unit);
            if (value.timezone) |timezone| {
                const position = try builder.addString(timezone);
                builder.setOffset(table, 1, position);
            } else {
                builder.setAbsent(table, 1);
            }
            return .{ .tag = type_timestamp, .pos = table.pos };
        },
    }
}

fn writeField(builder: *Builder, field: Field) Error!usize {
    const table = try builder.allocTable(&.{
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 1, .size = 1 },
        .{ .alignment = 1, .size = 1 },
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 4, .size = 4 },
    });
    const name = try builder.addString(field.name);
    builder.setOffset(table, 0, name);
    builder.setU8(table, 1, @intFromBool(field.nullable));
    const type_info = try typeTable(builder, field.data_type);
    builder.setU8(table, 2, type_info.tag);
    builder.setOffset(table, 3, type_info.pos);
    builder.setAbsent(table, 4);
    builder.setAbsent(table, 5);
    builder.setAbsent(table, 6);
    return table.pos;
}

fn writeSchema(builder: *Builder, schema: Schema) Error!usize {
    const table = try builder.allocTable(&.{
        .{ .alignment = 2, .size = 2 },
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 4, .size = 4 },
    });
    builder.setU16(table, 0, 0);
    const vector = try builder.addVector(schema.fields.len);
    builder.setOffset(table, 1, vector);
    builder.setAbsent(table, 2);
    builder.setAbsent(table, 3);
    for (schema.fields, 0..) |field, index| {
        const field_pos = try writeField(builder, field);
        builder.setVectorElement(vector, index, field_pos);
    }
    return table.pos;
}

pub fn encode(allocator: std.mem.Allocator, schema: Schema) Error![]u8 {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.appendZeros(4);
    const message = try builder.allocTable(&.{
        .{ .alignment = 2, .size = 2 },
        .{ .alignment = 1, .size = 1 },
        .{ .alignment = 4, .size = 4 },
        .{ .alignment = 8, .size = 8 },
        .{ .alignment = 4, .size = 4 },
    });
    builder.setU16(message, 0, 4);
    builder.setU8(message, 1, 1);
    const schema_table = try writeSchema(&builder, schema);
    builder.setOffset(message, 2, schema_table);
    builder.setAbsent(message, 4);
    builder.writeU32(0, @intCast(message.pos));
    const flat = try builder.finish();
    defer allocator.free(flat);
    const out = allocator.alloc(u8, 8 + flat.len) catch return error.OutOfMemory;
    out[0] = 0xff;
    out[1] = 0xff;
    out[2] = 0xff;
    out[3] = 0xff;
    const length: u32 = @intCast(flat.len);
    out[4] = @truncate(length);
    out[5] = @truncate(length >> 8);
    out[6] = @truncate(length >> 16);
    out[7] = @truncate(length >> 24);
    @memcpy(out[8..], flat);
    return out;
}

fn getU16(buffer: []const u8, position: usize) Error!u16 {
    if (position + 2 > buffer.len) return error.BadSchema;
    return @as(u16, buffer[position]) | (@as(u16, buffer[position + 1]) << 8);
}

fn getU32(buffer: []const u8, position: usize) Error!u32 {
    if (position + 4 > buffer.len) return error.BadSchema;
    return @as(u32, buffer[position]) |
        (@as(u32, buffer[position + 1]) << 8) |
        (@as(u32, buffer[position + 2]) << 16) |
        (@as(u32, buffer[position + 3]) << 24);
}

fn getI32(buffer: []const u8, position: usize) Error!i32 {
    return @bitCast(try getU32(buffer, position));
}

fn tableField(buffer: []const u8, table: usize, index: usize) Error!?usize {
    const raw_offset = try getU32(buffer, table);
    const signed_offset: i32 = @bitCast(raw_offset);
    const vtable_signed: i64 = @as(i64, @intCast(table)) - signed_offset;
    if (vtable_signed < 0 or vtable_signed + 4 > @as(i64, @intCast(buffer.len))) return error.BadSchema;
    const vtable: usize = @intCast(vtable_signed);
    const length = try getU16(buffer, vtable);
    if (length < 4 + index * 2 + 2) return null;
    const field = try getU16(buffer, vtable + 4 + index * 2);
    if (field == 0) return null;
    return table + field;
}

fn offsetTarget(buffer: []const u8, table: usize, index: usize) Error!?usize {
    const field = (try tableField(buffer, table, index)) orelse return null;
    const relative = try getU32(buffer, field);
    if (relative == 0) return null;
    return field + relative;
}

fn readString(buffer: []const u8, target: usize) Error![]const u8 {
    const length = try getU32(buffer, target);
    if (target + 4 + length > buffer.len) return error.BadSchema;
    return buffer[target + 4 .. target + 4 + length];
}

fn readType(buffer: []const u8, tag: u8, table: usize) Error!DataType {
    return switch (tag) {
        type_int => .{ .int = .{
            .bit_width = @intCast(try getI32(buffer, (try tableField(buffer, table, 0)) orelse return error.BadSchema)),
            .is_signed = (try getU8(buffer, (try tableField(buffer, table, 1)) orelse return error.BadSchema)) != 0,
        } },
        type_floating => .{ .floating = switch (try getU16(buffer, (try tableField(buffer, table, 0)) orelse return error.BadSchema)) {
            0 => .half,
            1 => .single,
            2 => .double,
            else => return error.UnsupportedType,
        } },
        type_binary => .binary,
        type_utf8 => .utf8,
        type_bool => .boolean,
        type_decimal => .{ .decimal = .{
            .precision = try getI32(buffer, (try tableField(buffer, table, 0)) orelse return error.BadSchema),
            .scale = try getI32(buffer, (try tableField(buffer, table, 1)) orelse return error.BadSchema),
            .bit_width = if (try tableField(buffer, table, 2)) |field| try getI32(buffer, field) else 128,
        } },
        type_date => .{ .date = switch (try getU16(buffer, (try tableField(buffer, table, 0)) orelse return error.BadSchema)) {
            0 => .day,
            1 => .millisecond,
            else => return error.UnsupportedType,
        } },
        type_timestamp => blk: {
            const unit: TimeUnit = switch (try getU16(buffer, (try tableField(buffer, table, 0)) orelse return error.BadSchema)) {
                0 => .second,
                1 => .millisecond,
                2 => .microsecond,
                3 => .nanosecond,
                else => return error.UnsupportedType,
            };
            const timezone = if (try offsetTarget(buffer, table, 1)) |target| try readString(buffer, target) else null;
            break :blk .{ .timestamp = .{ .unit = unit, .timezone = timezone } };
        },
        else => error.UnsupportedType,
    };
}

fn getU8(buffer: []const u8, position: usize) Error!u8 {
    if (position >= buffer.len) return error.BadSchema;
    return buffer[position];
}

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) Error!Schema {
    if (raw.len < 12) return error.BadSchema;
    if (raw[0] != 0xff or raw[1] != 0xff or raw[2] != 0xff or raw[3] != 0xff) return error.BadSchema;
    const length = try getU32(raw, 4);
    if (8 + length > raw.len) return error.BadSchema;
    const buffer = raw[8 .. 8 + length];
    const root = try getU32(buffer, 0);
    if (root >= buffer.len) return error.BadSchema;
    const header_type = try getU8(buffer, (try tableField(buffer, root, 1)) orelse return error.BadSchema);
    if (header_type != 1) return error.BadSchema;
    const schema_table = (try offsetTarget(buffer, root, 2)) orelse return error.BadSchema;
    const vector = (try offsetTarget(buffer, schema_table, 1)) orelse return error.BadSchema;
    const count = try getU32(buffer, vector);
    if (count > 1024) return error.BadSchema;
    const fields = allocator.alloc(Field, count) catch return error.OutOfMemory;
    errdefer allocator.free(fields);
    for (0..count) |index| {
        const element = vector + 4 + index * 4;
        const relative = try getU32(buffer, element);
        const field_table = element + relative;
        const name_target = (try offsetTarget(buffer, field_table, 0)) orelse return error.BadSchema;
        const name = try readString(buffer, name_target);
        const nullable = (try getU8(buffer, (try tableField(buffer, field_table, 1)) orelse return error.BadSchema)) != 0;
        const type_tag = try getU8(buffer, (try tableField(buffer, field_table, 2)) orelse return error.BadSchema);
        const type_target = (try offsetTarget(buffer, field_table, 3)) orelse return error.BadSchema;
        fields[index] = .{
            .name = name,
            .nullable = nullable,
            .data_type = try readType(buffer, type_tag, type_target),
        };
    }
    return .{ .fields = fields };
}

test "general schema reads the canonical fixture" {
    const base64 = @import("base64.zig");
    const fixture_schema_file = @import("fixture_schema.zig");
    const allocator = std.testing.allocator;
    const raw = try base64.decode(allocator, fixture_schema_file.schema_b64);
    defer allocator.free(raw);
    const schema = try parse(allocator, raw);
    defer allocator.free(schema.fields);
    try std.testing.expectEqual(@as(usize, 8), schema.fields.len);
    try std.testing.expectEqualStrings("amount", schema.fields[5].name);
    try std.testing.expectEqual(@as(i32, 9), schema.fields[5].data_type.decimal.precision);
    try std.testing.expectEqualStrings("UTC", schema.fields[6].data_type.timestamp.timezone.?);
}

test "general schema round trip" {
    const allocator = std.testing.allocator;
    const schema = Schema{ .fields = &.{
        .{ .name = "id", .nullable = true, .data_type = .{ .int = .{ .bit_width = 64, .is_signed = true } } },
        .{ .name = "name", .nullable = true, .data_type = .utf8 },
        .{ .name = "amount", .nullable = true, .data_type = .{ .decimal = .{ .precision = 9, .scale = 2, .bit_width = 128 } } },
        .{ .name = "ts", .nullable = true, .data_type = .{ .timestamp = .{ .unit = .microsecond, .timezone = "UTC" } } },
    } };
    const encoded = try encode(allocator, schema);
    defer allocator.free(encoded);
    const decoded = parse(allocator, encoded) catch |err| return err;
    defer allocator.free(decoded.fields);
    try std.testing.expectEqual(schema.fields.len, decoded.fields.len);
    try std.testing.expectEqualStrings("id", decoded.fields[0].name);
    try std.testing.expectEqualStrings("UTC", decoded.fields[3].data_type.timestamp.timezone.?);
}
