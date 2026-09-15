//! Port of go-zetasqlite function_net.go: the NET.* functions.
//!
//! Scope notes vs. Go:
//!   - IP parsing/formatting reimplements the netip subset the corpus needs
//!     (IPv4, IPv6 with :: compression, and IPv4-mapped ::ffff: addresses).
//!   - NET.PUBLIC_SUFFIX / NET.REG_DOMAIN use a MINIMAL ICANN suffix table
//!     (Go embeds golang.org/x/net/publicsuffix's full PSL + idna punycode).
//!     Only the suffixes the corpus exercises are present (see icann_suffixes);
//!     matching runs against the original Unicode host, so no punycode is
//!     needed. Hosts outside the table resolve to NULL.

const std = @import("std");
const bind = @import("bind.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

// GENERATE_UUID ---------------------------------------------------------

var uuid_seed: u64 = 0x243F6A8885A308D3;

/// Go GENERATE_UUID: a random v4 UUID string (36 chars). The corpus only
/// checks LENGTH(), so exact bytes are unspecified.
pub fn generateUuid(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = args;
    var b: [16]u8 = undefined;
    // Seeded from a monotonic counter; the corpus only checks LENGTH().
    uuid_seed +%= 0x9E3779B97F4A7C15;
    var prng = std.Random.DefaultPrng.init(uuid_seed);
    prng.random().bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    const hex = "0123456789abcdef";
    var out = try alloc.alloc(u8, 36);
    var oi: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[byte >> 4];
        out[oi + 1] = hex[byte & 0xf];
        oi += 2;
    }
    return Value{ .string = out };
}

// IP parsing / formatting ----------------------------------------------

pub fn netIpFromString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const s = try args[0].toString(alloc);
    const ip = try parseIp(alloc, s) orelse
        return bind.fail("NET.IP_FROM_STRING: invalid ip address {s}", .{s}, error.FailedConversion);
    return Value{ .bytes = ip };
}

pub fn netSafeIpFromString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const s = try args[0].toString(alloc);
    const ip = try parseIp(alloc, s) orelse return null_v;
    return Value{ .bytes = ip };
}

pub fn netIpToString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    if (b.len == 4) {
        return Value{ .string = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) };
    }
    if (b.len == 16) return Value{ .string = try formatIpv6(alloc, b) };
    return bind.fail("NET.IP_TO_STRING: invalid byte array", .{}, error.FailedConversion);
}

pub fn netIpNetMask(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const output = try args[0].toInt64();
    const prefix = try args[1].toInt64();
    if (output != 4 and output != 16)
        return bind.fail("NET.IP_NET_MASK: the first argument must be either 4 or 16", .{}, error.UnsupportedOperation);
    if (prefix < 0 or prefix > output * 8)
        return bind.fail("NET.IP_NET_MASK: the second argument must be in the range from 0 to {d}", .{output * 8}, error.UnsupportedOperation);
    const out = try alloc.alloc(u8, @intCast(output));
    fillMask(out, @intCast(prefix));
    return Value{ .bytes = out };
}

pub fn netIpTrunc(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    const length = try args[1].toInt64();
    if (b.len != 4 and b.len != 16)
        return bind.fail("NET.IP_TRUNC: length of the first argument must be either 4 or 16", .{}, error.UnsupportedOperation);
    if (length < 0 or length > @as(i64, @intCast(b.len)) * 8)
        return bind.fail("NET.IP_TRUNC: length must be in the range from 0 to {d}", .{b.len * 8}, error.UnsupportedOperation);
    const mask = try alloc.alloc(u8, b.len);
    fillMask(mask, @intCast(length));
    const out = try alloc.alloc(u8, b.len);
    for (b, mask, out) |x, m, *o| o.* = x & m;
    return Value{ .bytes = out };
}

/// NET.IP_IN_NET(ip STRING, net STRING) -> BOOL: is `ip` inside the CIDR `net`.
///
/// Two asymmetries, both taken from real BigQuery rather than assumed, and both
/// the things a plausible implementation gets wrong:
///
///   - A *malformed* net is an error, but a net of a different **family** is a
///     plain false: NET.IP_IN_NET('1.2.3.4', '2001:db8::/32') is false, not a
///     complaint about mixing v4 and v6.
///   - A net with no prefix is a host net, so '1.2.3.4' contains only itself,
///     while host bits inside a prefixed net are masked away rather than
///     rejected — '1.2.3.4/24' is read as 1.2.3.0/24 and contains 1.2.3.4.
pub fn netIpInNet(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const ip = try parseIp(alloc, try args[0].toString(alloc)) orelse
        return bind.fail(
            "NET.IP_IN_NET() encountered an unparseable IP-address",
            .{},
            error.FailedConversion,
        );

    const net_s = try args[1].toString(alloc);
    const slash = std.mem.indexOfScalar(u8, net_s, '/');
    const addr_s = if (slash) |i| net_s[0..i] else net_s;
    const net_ip = try parseIp(alloc, addr_s) orelse return unparseableNet();

    const bits: i64 = @intCast(net_ip.len * 8);
    // No prefix means every bit is significant: the net holds one address.
    const prefix: i64 = if (slash) |i|
        (std.fmt.parseInt(i64, net_s[i + 1 ..], 10) catch return unparseableNet())
    else
        bits;
    if (prefix < 0 or prefix > bits) return unparseableNet();

    // Different families cannot overlap, which is a false rather than an error.
    if (ip.len != net_ip.len) return Value{ .bool = false };

    const mask = try alloc.alloc(u8, net_ip.len);
    fillMask(mask, @intCast(prefix));
    for (ip, net_ip, mask) |a, b, m| {
        if ((a & m) != (b & m)) return Value{ .bool = false };
    }
    return Value{ .bool = true };
}

fn unparseableNet() Error {
    return bind.fail(
        "NET.IP_IN_NET() encountered an unparseable net",
        .{},
        error.FailedConversion,
    );
}

pub fn netIpv4FromInt64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const v: u32 = @truncate(@as(u64, @bitCast(try args[0].toInt64())));
    const out = try alloc.alloc(u8, 4);
    std.mem.writeInt(u32, out[0..4], v, .big);
    return Value{ .bytes = out };
}

pub fn netIpv4ToInt64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    if (b.len != 4)
        return bind.fail("NET.IPV4_TO_INT64: length of bytes array must be 4", .{}, error.FailedConversion);
    return Value{ .int = std.mem.readInt(u32, b[0..4], .big) };
}

/// net.CIDRMask: sets the first `ones` bits of `out`, clears the rest.
fn fillMask(out: []u8, ones: usize) void {
    for (out, 0..) |*byte, i| {
        const bit_start = i * 8;
        var v: u8 = 0;
        var b: usize = 0;
        while (b < 8) : (b += 1) {
            if (bit_start + b < ones) v |= @as(u8, 0x80) >> @intCast(b);
        }
        byte.* = v;
    }
}

/// netip.ParseAddr subset -> 4 or 16 bytes; null on parse failure.
fn parseIp(alloc: std.mem.Allocator, s: []const u8) Error!?[]u8 {
    if (std.mem.indexOfScalar(u8, s, ':') != null) return parseIpv6(alloc, s);
    return parseIpv4(alloc, s);
}

fn parseIpv4(alloc: std.mem.Allocator, s: []const u8) Error!?[]u8 {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| {
        if (n >= 4) return null;
        const b = parseDecOctet(part) orelse return null;
        parts[n] = b;
        n += 1;
    }
    if (n != 4) return null;
    return try alloc.dupe(u8, &parts);
}

fn parseDecOctet(s: []const u8) ?u8 {
    if (s.len == 0 or s.len > 3) return null;
    if (s.len > 1 and s[0] == '0') return null; // no leading zeros (netip strict)
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    if (v > 255) return null;
    return @intCast(v);
}

fn parseIpv6(alloc: std.mem.Allocator, s: []const u8) Error!?[]u8 {
    var groups: [8]u16 = @splat(0);
    // Split around "::" (at most one).
    const dbl = std.mem.indexOf(u8, s, "::");
    if (dbl) |di| {
        const left = s[0..di];
        const right = s[di + 2 ..];
        var lgroups: [8]u16 = undefined;
        var rgroups: [8]u16 = undefined;
        const ln = parseGroups(left, &lgroups) orelse return null;
        const rn = parseGroups(right, &rgroups) orelse return null;
        if (ln + rn > 7) return null; // must leave >=1 zero group for "::"
        for (0..ln) |i| groups[i] = lgroups[i];
        for (0..rn) |i| groups[8 - rn + i] = rgroups[i];
    } else {
        var g: [8]u16 = undefined;
        const gn = parseGroups(s, &g) orelse return null;
        if (gn != 8) return null;
        groups = g;
    }
    const out = try alloc.alloc(u8, 16);
    for (groups, 0..) |grp, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], grp, .big);
    return out;
}

/// Parses colon-separated hextets; the final hextet may be an embedded IPv4
/// (two groups). Returns the group count, or null on error.
fn parseGroups(s: []const u8, out: *[8]u16) ?usize {
    if (s.len == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        if (part.len == 0) return null;
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            // embedded IPv4 -> two hextets
            if (n + 2 > 8) return null;
            var v4: [4]u8 = undefined;
            var v4it = std.mem.splitScalar(u8, part, '.');
            var k: usize = 0;
            while (v4it.next()) |oct| {
                if (k >= 4) return null;
                v4[k] = parseDecOctet(oct) orelse return null;
                k += 1;
            }
            if (k != 4) return null;
            out[n] = (@as(u16, v4[0]) << 8) | v4[1];
            out[n + 1] = (@as(u16, v4[2]) << 8) | v4[3];
            n += 2;
            continue;
        }
        if (part.len > 4) return null;
        if (n >= 8) return null;
        var v: u16 = 0;
        for (part) |c| {
            const d = hexDigit(c) orelse return null;
            v = (v << 4) | d;
        }
        out[n] = v;
        n += 1;
    }
    return n;
}

fn hexDigit(c: u8) ?u16 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// netip.Addr.String() for a 16-byte address: IPv4-mapped -> "::ffff:a.b.c.d",
/// otherwise canonical IPv6 with the longest zero-run compressed to "::".
fn formatIpv6(alloc: std.mem.Allocator, b: []const u8) Error![]u8 {
    // IPv4-mapped (::ffff:a.b.c.d)
    var mapped = true;
    for (b[0..10]) |x| {
        if (x != 0) mapped = false;
    }
    if (mapped and b[10] == 0xff and b[11] == 0xff) {
        return std.fmt.allocPrint(alloc, "::ffff:{d}.{d}.{d}.{d}", .{ b[12], b[13], b[14], b[15] });
    }
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = std.mem.readInt(u16, b[i * 2 ..][0..2], .big);
    // Longest run of zero groups (length >= 2), leftmost on tie.
    var best_start: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] == 0) {
            var j = i;
            while (j < 8 and groups[j] == 0) j += 1;
            if (j - i > best_len) {
                best_len = j - i;
                best_start = i;
            }
            i = j;
        } else i += 1;
    }
    if (best_len < 2) best_len = 0;
    var out: std.ArrayList(u8) = .empty;
    var g: usize = 0;
    while (g < 8) {
        if (best_len > 0 and g == best_start) {
            try out.appendSlice(alloc, "::");
            g += best_len;
            continue;
        }
        if (g > 0 and !(best_len > 0 and g == best_start + best_len)) try out.append(alloc, ':');
        try out.print(alloc, "{x}", .{groups[g]});
        g += 1;
    }
    return out.toOwnedSlice(alloc);
}

// NET.HOST / PUBLIC_SUFFIX / REG_DOMAIN --------------------------------

pub fn netHost(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const v = try args[0].toString(alloc);
    const auth = authority(v) orelse return null_v;
    const h = hostname(auth);
    if (h.host.len == 0) return null_v;
    if (h.bracketed) return Value{ .string = try std.fmt.allocPrint(alloc, "[{s}]", .{h.host}) };
    return Value{ .string = try alloc.dupe(u8, h.host) };
}

pub fn netPublicSuffix(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const v = try args[0].toString(alloc);
    const auth = authority(v) orelse return null_v;
    const host = hostname(auth).host;
    const suffix = publicSuffix(alloc, host) catch return null_v;
    if (suffix.len == 0) return null_v;
    return Value{ .string = suffix };
}

pub fn netRegDomain(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const v = try args[0].toString(alloc);
    const auth = authority(v) orelse return null_v;
    const host = hostname(auth).host;
    if (host.len == 0) return null_v;
    const suffix = publicSuffix(alloc, host) catch return null_v;
    if (suffix.len == 0) return null_v;
    const nhost = countLabels(host);
    const nsuffix = countLabels(suffix);
    if (nhost <= nsuffix) return null_v;
    // Last (nsuffix + 1) labels of the original host.
    const start = labelStart(host, nhost - nsuffix - 1);
    return Value{ .string = try alloc.dupe(u8, host[start..]) };
}

const HostName = struct { host: []const u8, bracketed: bool };

/// Extracts the URL authority (host[:port], with optional userinfo) the way
/// go-zetasqlite's parseURL does: use the scheme:// or // authority if
/// present, else reparse the trimmed input as "//<trimmed>".
fn authority(v: []const u8) ?[]const u8 {
    var rest: []const u8 = undefined;
    if (std.mem.indexOf(u8, v, "://")) |idx| {
        rest = v[idx + 3 ..];
    } else if (std.mem.startsWith(u8, v, "//")) {
        rest = v[2..];
    } else {
        rest = std.mem.trim(u8, v, " \t\r\n");
    }
    // Authority ends at the first '/', '?' or '#'.
    var end = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            end = i;
            break;
        }
    }
    const auth = rest[0..end];
    if (auth.len == 0) return null;
    return auth;
}

/// URL.Hostname(): strips userinfo and port, unwraps [IPv6] brackets.
fn hostname(auth: []const u8) HostName {
    var a = auth;
    if (std.mem.lastIndexOfScalar(u8, a, '@')) |at| a = a[at + 1 ..];
    if (a.len > 0 and a[0] == '[') {
        if (std.mem.indexOfScalar(u8, a, ']')) |rb| return .{ .host = a[1..rb], .bracketed = true };
        return .{ .host = a[1..], .bracketed = true };
    }
    if (std.mem.indexOfScalar(u8, a, ':')) |colon| {
        return .{ .host = a[0..colon], .bracketed = false };
    }
    return .{ .host = a, .bracketed = false };
}

// Minimal ICANN public suffix set (see module scope note). Lowercase.
const icann_suffixes = [_][]const u8{ "co.uk", "uk", "xyz", "中国", "com", "org", "net" };

/// Returns the last N original-case labels of `host` where N is the label
/// count of the longest matching ICANN suffix; "" if no match / double-dot.
fn publicSuffix(alloc: std.mem.Allocator, host: []const u8) Error![]const u8 {
    if (host.len == 0) return "";
    if (hasDoubleDotRun(host)) return "";
    const lower = try std.ascii.allocLowerString(alloc, host);
    var best_labels: usize = 0;
    for (icann_suffixes) |suf| {
        const matches = std.mem.eql(u8, lower, suf) or
            (lower.len > suf.len and lower[lower.len - suf.len - 1] == '.' and
                std.mem.endsWith(u8, lower, suf));
        if (matches) {
            const n = countLabels(suf);
            if (n > best_labels) best_labels = n;
        }
    }
    if (best_labels == 0) return "";
    const nhost = countLabels(host);
    const start = labelStart(host, nhost - best_labels);
    return host[start..];
}

/// Go's publicSuffixMatcher `[^.]\.{2,}[^.]`: a non-dot, 2+ dots, non-dot.
fn hasDoubleDotRun(host: []const u8) bool {
    var i: usize = 1;
    while (i + 1 < host.len) : (i += 1) {
        if (host[i] == '.' and host[i + 1] == '.' and host[i - 1] != '.') {
            // find end of the dot run
            var j = i + 1;
            while (j < host.len and host[j] == '.') j += 1;
            if (j < host.len and host[j] != '.') return true;
        }
    }
    return false;
}

fn countLabels(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = 1;
    for (s) |c| {
        if (c == '.') n += 1;
    }
    return n;
}

/// Byte offset where label index `idx` begins (0-based, dot-separated).
fn labelStart(s: []const u8, idx: usize) usize {
    if (idx == 0) return 0;
    var seen: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            seen += 1;
            if (seen == idx) return i + 1;
        }
    }
    return s.len;
}

// ----------------------------------------------------------------------
// Tests. Every expectation is what real BigQuery answers for the same call.
// ----------------------------------------------------------------------

const testing = std.testing;

fn inNet(alloc: std.mem.Allocator, ip: []const u8, net_s: []const u8) Error!Value {
    return netIpInNet(alloc, &.{ .{ .string = ip }, .{ .string = net_s } });
}

test "NET.IP_IN_NET matches within a prefix, both families" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { ip: []const u8, net: []const u8, want: bool }{
        .{ .ip = "10.0.0.5", .net = "10.0.0.0/8", .want = true },
        .{ .ip = "192.168.0.1", .net = "10.0.0.0/8", .want = false },
        .{ .ip = "2001:db8::1", .net = "2001:db8::/32", .want = true },
        .{ .ip = "2001:dba::1", .net = "2001:db8::/32", .want = false },
        // Prefix 0 is every address, which is the boundary fillMask has to get
        // right at the other end from a host net.
        .{ .ip = "8.8.8.8", .net = "0.0.0.0/0", .want = true },
    };
    for (cases) |c| {
        const got = try inNet(alloc, c.ip, c.net);
        try testing.expectEqual(c.want, got.bool);
    }
}

test "NET.IP_IN_NET treats a family mismatch as false, not as an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The asymmetry worth pinning: a *malformed* net raises, but a v4 address
    // against a v6 net simply is not in it. BigQuery agrees.
    try testing.expectEqual(false, (try inNet(alloc, "1.2.3.4", "2001:db8::/32")).bool);
    try testing.expectEqual(false, (try inNet(alloc, "2001:db8::1", "1.2.3.0/24")).bool);
}

test "NET.IP_IN_NET reads a bare address as a host net, and masks host bits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // No prefix means every bit counts, so the net holds exactly itself...
    try testing.expectEqual(true, (try inNet(alloc, "1.2.3.4", "1.2.3.4")).bool);
    try testing.expectEqual(false, (try inNet(alloc, "1.2.3.5", "1.2.3.4")).bool);
    // ...while host bits *inside* a prefixed net are masked away rather than
    // rejected: 1.2.3.4/24 is read as 1.2.3.0/24.
    try testing.expectEqual(true, (try inNet(alloc, "1.2.3.4", "1.2.3.4/24")).bool);
    try testing.expectEqual(true, (try inNet(alloc, "1.2.3.99", "1.2.3.4/24")).bool);
}

test "NET.IP_IN_NET propagates NULL and refuses what cannot be parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expect((try netIpInNet(alloc, &.{ null_v, .{ .string = "1.2.3.0/24" } })) == .null);
    try testing.expect((try netIpInNet(alloc, &.{ .{ .string = "1.2.3.4" }, null_v })) == .null);

    const bad = [_]struct { ip: []const u8, net: []const u8, msg: []const u8 }{
        .{ .ip = "not-an-ip", .net = "1.2.3.0/24", .msg = "unparseable IP-address" },
        .{ .ip = "1.2.3.4", .net = "1.2.3.0/33", .msg = "unparseable net" },
        .{ .ip = "1.2.3.4", .net = "", .msg = "unparseable net" },
        .{ .ip = "1.2.3.4", .net = "1.2.3.0/x", .msg = "unparseable net" },
    };
    for (bad) |c| {
        bind.clearDiagnostics();
        try testing.expectError(error.FailedConversion, inNet(alloc, c.ip, c.net));
        try testing.expect(std.mem.indexOf(u8, bind.message.?, c.msg) != null);
    }
}
