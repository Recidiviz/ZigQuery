//! HLL_COUNT.* — port of go-zetasqlite's HLL_COUNT_INIT / _MERGE /
//! _MERGE_PARTIAL / _EXTRACT (internal/function_aggregate.go +
//! function_bind.go) together with the two libraries they lean on:
//!
//!   * github.com/spaolacci/murmur3 Sum64 (= the x64/128 hash's first word)
//!     hashes each input value before it enters the sketch.
//!   * github.com/DataDog/go-hll v1.0.2 is the sketch itself; its wire format
//!     is the "hll storage spec" schema version 1:
//!
//!       byte 0: (version << 4) | type      type: 0=undefined 1=empty
//!                                                2=explicit 3=sparse 4=dense
//!       byte 1: ((regwidth - 1) << 5) | log2m
//!       byte 2: (sparseEnabled << 6) | explicit cutoff exponent
//!               (63 == "auto", 0 == explicit storage disabled)
//!       byte 3+: the storage payload
//!         explicit — the raw hashed values, 8 bytes big endian each,
//!                    sorted ascending as *signed* 64 bit integers.
//!         sparse   — (regnum << regwidth) | value packed into log2m+regwidth
//!                    bit big-endian-ish words (see writeBits), registers
//!                    ascending.
//!         dense    — every register in order, regwidth bits each, packed
//!                    MSB-first (go-hll keeps them in uint64 words and
//!                    serializes each word big endian).
//!
//! NOTE (bug-compatibility, load bearing for the corpus): go-zetasqlite's
//! HLL_COUNT_INIT calls hll.NewHll(hll.Settings{Log2m: precision}) with
//! Regwidth left at 0, which go-hll rejects (minimum 1). The error is
//! assigned to a named return that the function then overwrites with `return
//! nil`, so the zero Hll is stored and lazily picks up the package defaults
//! installed in that file's init(): log2m 15, regwidth 8, auto explicit
//! threshold, sparse enabled. The `precision` argument therefore has no
//! effect at all — corpus case "hll_count.init" passes 10 and still expects a
//! log2m-15 header byte (0xEF). We reproduce that exactly.
// ephor:ignore-file ZA301 ZA302 ZA303 ZA304

const std = @import("std");
const bind = @import("bind.zig");
const agg_opt = @import("aggregate_option.zig");

pub const Value = bind.Value;
pub const Error = bind.Error;
pub const AggregatorOption = agg_opt.AggregatorOption;

// ----------------------------------------------------------------------
// murmur3 (spaolacci/murmur3 Sum64 == Sum128WithSeed(data, 0) first word)
// ----------------------------------------------------------------------

pub fn murmur3Sum64(data: []const u8) u64 {
    const c1: u64 = 0x87c37b91114253d5;
    const c2: u64 = 0x4cf5ad432745937f;

    var h1: u64 = 0;
    var h2: u64 = 0;

    const nblocks = data.len / 16;
    var i: usize = 0;
    while (i < nblocks) : (i += 1) {
        // Go casts the block to *[2]uint64 through unsafe.Pointer, i.e. it
        // reads native (little) endian on every supported platform.
        var k1 = std.mem.readInt(u64, data[i * 16 ..][0..8], .little);
        var k2 = std.mem.readInt(u64, data[i * 16 + 8 ..][0..8], .little);

        k1 *%= c1;
        k1 = std.math.rotl(u64, k1, 31);
        k1 *%= c2;
        h1 ^= k1;

        h1 = std.math.rotl(u64, h1, 27);
        h1 +%= h2;
        h1 = h1 *% 5 +% 0x52dce729;

        k2 *%= c2;
        k2 = std.math.rotl(u64, k2, 33);
        k2 *%= c1;
        h2 ^= k2;

        h2 = std.math.rotl(u64, h2, 31);
        h2 +%= h1;
        h2 = h2 *% 5 +% 0x38495ab5;
    }

    const tail = data[nblocks * 16 ..];
    var k1: u64 = 0;
    var k2: u64 = 0;

    // Go's switch on len(tail)&15 falls through from the k2 bytes (9..15)
    // into the k1 bytes (1..8).
    if (tail.len > 8) {
        var j: usize = 8;
        while (j < tail.len) : (j += 1) {
            k2 ^= @as(u64, tail[j]) << @intCast(8 * (j - 8));
        }
        k2 *%= c2;
        k2 = std.math.rotl(u64, k2, 33);
        k2 *%= c1;
        h2 ^= k2;
    }
    if (tail.len > 0) {
        const n = @min(tail.len, 8);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            k1 ^= @as(u64, tail[j]) << @intCast(8 * j);
        }
        k1 *%= c1;
        k1 = std.math.rotl(u64, k1, 31);
        k1 *%= c2;
        h1 ^= k1;
    }

    h1 ^= @as(u64, data.len);
    h2 ^= @as(u64, data.len);
    h1 +%= h2;
    h2 +%= h1;
    h1 = fmix64(h1);
    h2 = fmix64(h2);
    h1 +%= h2;
    return h1;
}

fn fmix64(k0: u64) u64 {
    var k = k0;
    k ^= k >> 33;
    k *%= 0xff51afd7ed558ccd;
    k ^= k >> 33;
    k *%= 0xc4ceb9fe1a85ec53;
    k ^= k >> 33;
    return k;
}

// ----------------------------------------------------------------------
// go-hll settings.go
// ----------------------------------------------------------------------

const minimum_log2m = 4;
const maximum_log2m = 31;
const minimum_regwidth = 1;
const maximum_regwidth = 8;
const minimum_expthresh = -1;
const maximum_expthresh = 18;
const maximum_explicit_threshold = 1 << (maximum_expthresh - 1);

/// go-hll AutoExplicitThreshold.
pub const auto_explicit_threshold: i64 = -1;

pub const Settings = struct {
    log2m: u8,
    regwidth: u8,
    explicit_auto: bool,
    sparse_enabled: bool,
    explicit_threshold: usize,
    sparse_threshold: usize,
    pw_max_mask: u64,
    m_bits_mask: u64,
    alpha_m_squared: f64,
    small_estimator_cutoff: f64,
    large_estimator_cutoff: f64,
    two_to_l: f64,

    /// go-hll Settings.toInternal (validation + derived constants).
    pub fn init(
        log2m: i64,
        regwidth: i64,
        explicit_threshold: i64,
        sparse_enabled: bool,
    ) Error!Settings {
        if (log2m < minimum_log2m) {
            return bind.fail(
                "Log2m is too small.  Requires at least {d} but got {d}",
                .{ minimum_log2m, log2m },
                error.CorruptData,
            );
        }
        if (log2m > maximum_log2m) {
            return bind.fail(
                "Log2m is too large.  Allows at most {d} but got {d}",
                .{ maximum_log2m, log2m },
                error.CorruptData,
            );
        }
        if (regwidth < minimum_regwidth) {
            return bind.fail(
                "Regwidth is too small.  Requires at least {d} but got {d}",
                .{ minimum_regwidth, regwidth },
                error.CorruptData,
            );
        }
        if (regwidth > maximum_regwidth) {
            return bind.fail(
                "Regwidth is too large.  Allows at most {d} but got {d}",
                .{ maximum_regwidth, regwidth },
                error.CorruptData,
            );
        }
        if (explicit_threshold < minimum_expthresh) {
            return bind.fail(
                "ExplicitThreshold is too small.  Requires at least {d} but got {d}",
                .{ minimum_expthresh, explicit_threshold },
                error.CorruptData,
            );
        }
        if (explicit_threshold > maximum_explicit_threshold) {
            return bind.fail(
                "ExplicitThreshold is too large.  Allows at most {d} but got {d}",
                .{ maximum_expthresh, explicit_threshold },
                error.CorruptData,
            );
        }

        const l2m: u8 = @intCast(log2m);
        const rw: u8 = @intCast(regwidth);
        const explicit_auto = explicit_threshold == auto_explicit_threshold;

        const two_to_l_val = twoToL(l2m, rw);
        return .{
            .log2m = l2m,
            .regwidth = rw,
            .explicit_auto = explicit_auto,
            .sparse_enabled = sparse_enabled,
            .explicit_threshold = if (explicit_auto)
                calculateExplicitThreshold(l2m, rw)
            else
                @intCast(explicit_threshold),
            .sparse_threshold = if (sparse_enabled) calculateSparseThreshold(l2m, rw) else 0,
            .pw_max_mask = pwMaxMask(rw),
            .m_bits_mask = (@as(u64, 1) << @intCast(l2m)) - 1,
            .alpha_m_squared = alphaMSquared(l2m),
            .small_estimator_cutoff = smallEstimatorCutoff(@as(u64, 1) << @intCast(l2m)),
            .large_estimator_cutoff = two_to_l_val / 30.0,
            .two_to_l = two_to_l_val,
        };
    }

    /// Number of registers (m).
    fn m(s: *const Settings) usize {
        return @as(usize, 1) << @intCast(s.log2m);
    }
};

/// The settings go-zetasqlite installs via hll.Defaults in its package init:
/// log2m 15, regwidth 8, auto explicit threshold, sparse enabled.
pub const default_settings: Settings =
    Settings.init(15, 8, auto_explicit_threshold, true) catch |err|
        @compileError("invalid default HLL settings: " ++ @errorName(err));

fn divideBy8RoundUp(i: usize) usize {
    var result = i >> 3;
    if (i & 0x7 > 0) result += 1;
    return result;
}

fn calculateExplicitThreshold(log2m: u8, regwidth: u8) usize {
    const m = @as(usize, 1) << @intCast(log2m);
    const full_representation_size = divideBy8RoundUp(@as(usize, regwidth) * m);
    const num_longs = full_representation_size / 8;
    if (num_longs > maximum_explicit_threshold) return maximum_explicit_threshold;
    return num_longs;
}

fn calculateSparseThreshold(log2m: u8, regwidth: u8) usize {
    const m = @as(usize, 1) << @intCast(log2m);
    const short_word_length: usize = @as(usize, log2m) + @as(usize, regwidth);
    const largest_pow2_less_than_cutoff = std.math.log2(
        @as(f64, @floatFromInt(m * regwidth)) / @as(f64, @floatFromInt(short_word_length)),
    );
    // Go: 1 << uint(largestPow2LessThanCutoff) — float truncated to an int.
    return @as(usize, 1) << @intFromFloat(@trunc(largest_pow2_less_than_cutoff));
}

/// go-hll pwMaxMask. NOTE the shift count is (2^regwidth - 2), which is >= 64
/// for regwidth >= 7; Go defines an over-wide shift of a uint64 as 0, so the
/// mask degenerates to ^(0-1) == 0 there (the default regwidth 8 included).
fn pwMaxMask(regwidth: u8) u64 {
    const max_register_value: u64 = (@as(u64, 1) << @intCast(regwidth)) - 1;
    const shift = max_register_value - 1;
    const shifted: u64 = if (shift >= 64) 0 else @as(u64, 1) << @intCast(shift);
    return ~(shifted -% 1);
}

fn alphaMSquared(log2m: u8) f64 {
    const m: f64 = @floatFromInt(@as(u64, 1) << @intCast(log2m));
    return switch (log2m) {
        4 => 0.673 * m * m,
        5 => 0.697 * m * m,
        6 => 0.709 * m * m,
        else => (0.7213 / (1.0 + 1.079 / m)) * m * m,
    };
}

fn smallEstimatorCutoff(m: u64) f64 {
    return (@as(f64, @floatFromInt(m)) * 5) / 2;
}

fn twoToL(log2m: u8, regwidth: u8) f64 {
    const max_register_value = (@as(u64, 1) << @intCast(regwidth)) - 1;
    const pw_bits = max_register_value - 1;
    const total_bits = pw_bits + log2m;
    return std.math.pow(f64, 2, @floatFromInt(total_bits));
}

// ----------------------------------------------------------------------
// go-hll util.go bit packing
// ----------------------------------------------------------------------

/// go-hll readBits: reads nBits starting at the given *bit* address, MSB
/// first, and returns them in the low bits of the result.
fn readBits(bytes: []const u8, addr: usize, n_bits: usize) u64 {
    var idx = addr >> 3;
    var pos = addr & 0x7;
    var value: u64 = 0;
    var bits_required = n_bits;

    while (bits_required > 0) {
        var bits_available = 8 - pos;
        if (bits_available > bits_required) bits_available = bits_required;

        value = value << @intCast(bits_available);

        const mask: u8 = @intCast((@as(u16, 1) << @intCast(bits_available)) - 1);
        var chunk = bytes[idx] & (mask << @intCast(8 - pos - bits_available));
        if (pos + bits_available != 8) {
            chunk = chunk >> @intCast(8 - (pos + bits_available));
        }
        value |= chunk;

        pos += bits_available;
        if (pos == 8) {
            idx += 1;
            pos = 0;
        }
        bits_required -= bits_available;
    }
    return value;
}

/// go-hll writeBits: ORs the nBits low bits of value into the buffer at the
/// given bit address (the destination must start zeroed).
fn writeBits(bytes: []u8, addr: usize, value: u64, n_bits_in: usize) void {
    var idx = addr >> 3;
    var pos = addr & 0x7;
    var n_bits = n_bits_in;

    while (n_bits > 0) {
        var bits_to_write = 8 - pos;
        if (bits_to_write > n_bits) bits_to_write = n_bits;

        const mask: u8 = @intCast((@as(u16, 1) << @intCast(bits_to_write)) - 1);
        var part: u8 = mask & @as(u8, @truncate(value >> @intCast(n_bits - bits_to_write)));
        if (pos + bits_to_write != 8) {
            part = part << @intCast(8 - (pos + bits_to_write));
        }
        bytes[idx] |= part;

        pos += bits_to_write;
        if (pos == 8) {
            idx += 1;
            pos = 0;
        }
        n_bits -= bits_to_write;
    }
}

// ----------------------------------------------------------------------
// Storage (go-hll explicit.go / sparse.go / dense.go)
// ----------------------------------------------------------------------

const ExplicitSet = std.AutoHashMapUnmanaged(u64, void);
const SparseMap = std.AutoHashMapUnmanaged(i32, u8);

const StorageType = enum(u4) {
    undefined_ = 0,
    empty = 1,
    explicit = 2,
    sparse = 3,
    dense = 4,
};

const Storage = union(enum) {
    /// go-hll models "no storage yet" as a nil interface value.
    empty,
    explicit: ExplicitSet,
    sparse: SparseMap,
    /// Register words; go-hll keeps dense storage as []uint64 too.
    dense: []u64,
};

fn newDenseStorage(alloc: std.mem.Allocator, s: *const Settings) Error![]u64 {
    const bytes = divideBy8RoundUp(s.m() * s.regwidth);
    const words = try alloc.alloc(u64, divideBy8RoundUp(bytes));
    @memset(words, 0);
    return words;
}

fn denseCalcPosition(regnum: usize, regwidth: u8) struct { usize, usize } {
    const addr = regnum * regwidth;
    return .{ addr >> 6, addr & 0x3f };
}

/// go-hll denseStorage.get.
fn denseGet(words: []const u64, regnum: usize, regwidth: u8) u8 {
    const idx, const pos = denseCalcPosition(regnum, regwidth);
    if (pos + regwidth <= 64) {
        var shift_left: u6 = 0;
        if (pos + regwidth < 64) shift_left = @intCast(64 - (pos + regwidth));
        const mask = ((@as(u64, 1) << @intCast(regwidth)) - 1) << shift_left;
        return @truncate((mask & words[idx]) >> shift_left);
    }
    const n_bits_upper: u6 = @intCast(64 - pos);
    const n_bits_lower: u6 = @intCast(regwidth - (64 - pos));
    const mask_upper = (@as(u64, 1) << n_bits_upper) - 1;
    const upper = (words[idx] & mask_upper) << n_bits_lower;
    const lower = words[idx + 1] >> @intCast(64 - @as(u32, n_bits_lower));
    return @truncate(upper | lower);
}

/// go-hll denseStorage.setIfGreater.
fn denseSetIfGreater(words: []u64, s: *const Settings, regnum: usize, value: u8) void {
    const idx, const pos = denseCalcPosition(regnum, s.regwidth);
    const n_bits: usize = s.regwidth;

    if (pos + n_bits <= 64) {
        var mask = (@as(u64, 1) << @intCast(s.regwidth)) - 1;
        var part_to_write = @as(u64, value) & mask;
        var shift_left: u6 = 0;
        if (pos + n_bits < 64) {
            shift_left = @intCast(64 - (pos + n_bits));
            part_to_write = part_to_write << shift_left;
            mask = mask << shift_left;
        }
        const curr_val: u8 = @truncate((mask & words[idx]) >> shift_left);
        if (value > curr_val) words[idx] = (~mask & words[idx]) | part_to_write;
        return;
    }

    const n_bits_upper: u6 = @intCast(64 - pos);
    const n_bits_lower: u6 = @intCast(n_bits - (64 - pos));
    const mask_upper = (@as(u64, 1) << n_bits_upper) - 1;
    const mask_lower = (@as(u64, 1) << n_bits_lower) - 1;
    const upper = (words[idx] & mask_upper) << n_bits_lower;
    const lower = words[idx + 1] >> @intCast(64 - @as(u32, n_bits_lower));
    const curr_val = upper | lower;

    if (value >= @as(u8, @truncate(curr_val))) {
        const part_upper = (@as(u64, value) >> n_bits_lower) & mask_upper;
        const part_lower = (@as(u64, value) & mask_lower) << @intCast(64 - @as(u32, n_bits_lower));
        const mask_lower_shifted = mask_lower << @intCast(64 - @as(u32, n_bits_lower));
        words[idx] = (~mask_upper & words[idx]) | part_upper;
        words[idx + 1] = (~mask_lower_shifted & words[idx + 1]) | part_lower;
    }
}

/// The "indicator function" (Z in the HLL paper) plus the number of zero
/// valued registers (V).
const Indicator = struct { sum: f64, zeros: usize };

/// go-hll denseStorage.indicator, transcribed including its use of
/// mBitsMask (rather than a regwidth mask) to seed the register mask.
fn denseIndicator(words: []const u64, s: *const Settings) Indicator {
    const num_reg = s.m();
    const regwidth: usize = s.regwidth;

    var idx: usize = 0;
    var pos: usize = 0;
    var curr = words[0];
    var mask: u64 = s.m_bits_mask << @intCast(64 - regwidth);

    var sum: f64 = 0;
    var number_of_zeros: usize = 0;

    var i: usize = 0;
    while (i < num_reg) : (i += 1) {
        var value: u64 = undefined;
        const bits_available = 64 - pos;

        if (bits_available >= regwidth) {
            value = (curr & mask) >> @intCast(64 - pos - regwidth);
            pos += regwidth;
            mask = mask >> @intCast(regwidth);
        } else {
            const n_lower_bits: usize = regwidth - bits_available;

            var upper_bits: u64 = 0;
            if (bits_available > 0) upper_bits = (curr & mask) << @intCast(n_lower_bits);

            idx += 1;
            curr = words[idx];

            const lower_mask = ((@as(u64, 1) << @intCast(n_lower_bits)) - 1) <<
                @intCast(64 - n_lower_bits);
            const lower_bits = (curr & lower_mask) >> @intCast(64 - n_lower_bits);

            value = upper_bits | lower_bits;

            pos = n_lower_bits;
            mask = (s.m_bits_mask << @intCast(64 - regwidth)) >> @intCast(pos);
        }

        sum += 1.0 / @as(f64, @floatFromInt(shiftOne(value)));
        if (value == 0) number_of_zeros += 1;
    }

    return .{ .sum = sum, .zeros = number_of_zeros };
}

/// uint64(1) << v with Go's over-wide-shift-is-zero semantics.
fn shiftOne(v: u64) u64 {
    if (v >= 64) return 0;
    return @as(u64, 1) << @intCast(v);
}

/// uint64(math.Ceil(x)). Go's float->uint64 conversion is undefined for
/// out-of-range inputs (which the estimators cannot produce for a
/// well-formed sketch); clamp instead of tripping a safety check.
fn ceilToU64(x: f64) u64 {
    const c = @ceil(x);
    if (std.math.isNan(c) or c <= 0) return 0;
    if (c >= 18446744073709551616.0) return std.math.maxInt(u64);
    return @intFromFloat(c);
}

// ----------------------------------------------------------------------
// Hll (go-hll hll.go)
// ----------------------------------------------------------------------

pub const Hll = struct {
    settings: Settings,
    storage: Storage = .empty,

    pub fn init(settings: Settings) Hll {
        return .{ .settings = settings, .storage = .empty };
    }

    /// go-hll FromBytes.
    pub fn fromBytes(alloc: std.mem.Allocator, bytes: []const u8) Error!Hll {
        if (bytes.len < 3) {
            return bind.fail("insufficient bytes to deserialize Hll", .{}, error.CorruptData);
        }

        const version = bytes[0] >> 4;
        const raw_type = bytes[0] & 0xf;
        if (version != 1) {
            return bind.fail("unsupported Hll version: {d}", .{version}, error.CorruptData);
        }
        if (raw_type < @backingInt(StorageType.empty) or
            raw_type > @backingInt(StorageType.dense))
        {
            return bind.fail("invalid Hll type: {d}", .{raw_type}, error.CorruptData);
        }
        const storage_type: StorageType = @fromBackingInt(@intCast(raw_type));

        const regwidth = (bytes[1] >> 5) + 1;
        const log2m = bytes[1] & 0x1f;
        const sparse_enabled, const explicit_threshold = unpackCutoffByte(bytes[2]);

        const settings = try Settings.init(log2m, regwidth, explicit_threshold, sparse_enabled);

        var h = Hll{ .settings = settings, .storage = .empty };
        const payload = bytes[3..];

        switch (storage_type) {
            .undefined_, .empty => {},
            .explicit => {
                if (payload.len % 8 != 0) {
                    return bind.fail("insufficient bytes to deserialize Hll", .{}, error.CorruptData);
                }
                var set: ExplicitSet = .empty;
                var i: usize = 0;
                while (i < payload.len) : (i += 8) {
                    const v = std.mem.readInt(u64, payload[i..][0..8], .big);
                    try set.put(alloc, v, {});
                }
                h.storage = .{ .explicit = set };
            },
            .sparse => {
                const bits_per_register: usize = @as(usize, settings.regwidth) + settings.log2m;
                const reg_mask: u8 = @intCast((@as(u16, 1) << @intCast(settings.regwidth)) - 1);
                const num_registers = (8 * payload.len) / bits_per_register;
                var map: SparseMap = .empty;
                var i: usize = 0;
                while (i < num_registers) : (i += 1) {
                    const reg_and_val = readBits(payload, i * bits_per_register, bits_per_register);
                    const regnum: i32 = @bitCast(@as(
                        u32,
                        @truncate(reg_and_val >> @intCast(settings.regwidth)),
                    ));
                    try map.put(alloc, regnum, @as(u8, @truncate(reg_and_val)) & reg_mask);
                }
                h.storage = .{ .sparse = map };
            },
            .dense => {
                const expected = divideBy8RoundUp(settings.m() * settings.regwidth);
                if (payload.len != expected) {
                    return bind.fail("insufficient bytes to deserialize Hll", .{}, error.CorruptData);
                }
                const words = try newDenseStorage(alloc, &settings);
                const n_words = payload.len / 8;
                var i: usize = 0;
                while (i < n_words) : (i += 1) {
                    words[i] = std.mem.readInt(u64, payload[i * 8 ..][0..8], .big);
                }
                const remainder = payload.len % 8;
                if (remainder > 0) {
                    var last: u64 = 0;
                    var j: usize = 0;
                    while (j < remainder) : (j += 1) {
                        const shift: u6 = @intCast(64 - (8 * (j + 1)));
                        last |= @as(u64, payload[payload.len - (remainder - j)]) << shift;
                    }
                    words[words.len - 1] = last;
                }
                h.storage = .{ .dense = words };
            },
        }

        return h;
    }

    /// go-hll Hll.AddRaw.
    pub fn addRaw(h: *Hll, alloc: std.mem.Allocator, value: u64) Error!void {
        // by contract...ignore zero.
        if (value == 0) return;

        const s = &h.settings;

        if (h.storage == .empty) {
            if (s.explicit_threshold > 0) {
                h.storage = .{ .explicit = .empty };
            } else if (s.sparse_enabled) {
                h.storage = .{ .sparse = .empty };
            } else {
                h.storage = .{ .dense = try newDenseStorage(alloc, s) };
            }
        }

        switch (h.storage) {
            .explicit => |*set| try set.put(alloc, value, {}),
            .sparse, .dense => {
                const substream_value = value >> @intCast(s.log2m);
                // The paper does not cover p(0x0); go-hll returns early here,
                // skipping the over-capacity check below as well.
                if (substream_value == 0) return;

                const pw: u8 = @intCast(1 + @ctz(substream_value | s.pw_max_mask));
                const i: usize = @intCast(value & s.m_bits_mask);
                try h.setIfGreater(alloc, i, pw);
            },
            .empty => unreachable,
        }

        if (h.overCapacity()) try h.upgrade(alloc);
    }

    fn setIfGreater(h: *Hll, alloc: std.mem.Allocator, regnum: usize, value: u8) Error!void {
        switch (h.storage) {
            .sparse => |*map| {
                const key: i32 = @intCast(regnum);
                const existing = map.get(key) orelse 0;
                if (value > existing) try map.put(alloc, key, value);
            },
            .dense => |words| denseSetIfGreater(words, &h.settings, regnum, value),
            else => unreachable,
        }
    }

    fn overCapacity(h: *const Hll) bool {
        return switch (h.storage) {
            .empty => false,
            .explicit => |set| set.count() > h.settings.explicit_threshold,
            .sparse => |map| map.count() > h.settings.sparse_threshold,
            .dense => false,
        };
    }

    /// go-hll Hll.upgrade.
    fn upgrade(h: *Hll, alloc: std.mem.Allocator) Error!void {
        switch (h.storage) {
            .explicit => |set| {
                if (h.settings.sparse_enabled) {
                    h.storage = .{ .sparse = .empty };
                } else {
                    h.storage = .{ .dense = try newDenseStorage(alloc, &h.settings) };
                }
                var it = set.keyIterator();
                while (it.next()) |value| try h.addRaw(alloc, value.*);
            },
            .sparse => |map| {
                const words = try newDenseStorage(alloc, &h.settings);
                h.storage = .{ .dense = words };
                var it = map.iterator();
                while (it.next()) |e| {
                    denseSetIfGreater(words, &h.settings, @intCast(e.key_ptr.*), e.value_ptr.*);
                }
            },
            else => {},
        }
    }

    /// go-hll Hll.Cardinality.
    pub fn cardinality(h: *const Hll) u64 {
        const s = &h.settings;
        const ind: Indicator = switch (h.storage) {
            .empty => return 0,
            .explicit => |set| return set.count(),
            .sparse => |map| blk: {
                // go-hll sparseStorage.indicator.
                var acc: f64 = 0;
                var it = map.valueIterator();
                while (it.next()) |v| acc += 1.0 / @as(f64, @floatFromInt(shiftOne(v.*)));
                const zeros = s.m() - map.count();
                acc += @floatFromInt(zeros);
                break :blk .{ .sum = acc, .zeros = zeros };
            },
            .dense => |words| denseIndicator(words, s),
        };

        const estimator = s.alpha_m_squared / ind.sum;

        if (ind.zeros != 0 and estimator < s.small_estimator_cutoff) {
            // "small range correction"
            const m: f64 = @floatFromInt(s.m());
            const small_estimator = m * @log(m / @as(f64, @floatFromInt(ind.zeros)));
            return ceilToU64(small_estimator);
        }

        if (estimator <= s.large_estimator_cutoff) return ceilToU64(estimator);

        // "large range correction", adapted for 64 bit hashes.
        const large_estimator = -1 * s.two_to_l * @log(1.0 - (estimator / s.two_to_l));
        return ceilToU64(large_estimator);
    }

    /// go-hll Hll.Union (the non-strict form: settings may differ).
    pub fn unionWith(h: *Hll, alloc: std.mem.Allocator, other: Hll) Error!void {
        // other is empty...there's nothing to do.
        if (other.storage == .empty) return;

        // if this one is empty, deep copy the other's storage.
        if (h.storage == .empty) {
            if (other.storage == .sparse and !h.settings.sparse_enabled) {
                // edge case: the other is sparse but sparse is disabled here.
                h.storage = .{
                    .dense = try sparseToDense(alloc, &h.settings, other.storage.sparse),
                };
            } else {
                h.storage = try copyStorage(alloc, other.storage);
            }
            return;
        }

        switch (other.storage) {
            .empty => unreachable,
            .explicit => |set| try h.addFromExplicit(alloc, set),
            .sparse => |other_map| switch (h.storage) {
                .explicit => |this_set| {
                    if (h.settings.sparse_enabled) {
                        h.storage = try copyStorage(alloc, other.storage);
                    } else {
                        h.storage = .{ .dense = try sparseToDense(alloc, &h.settings, other_map) };
                    }
                    try h.addFromExplicit(alloc, this_set);
                },
                .sparse, .dense => {
                    var it = other_map.iterator();
                    while (it.next()) |e| {
                        // go-hll masks with byte(mBitsMask) here.
                        const v = e.value_ptr.* & @as(u8, @truncate(h.settings.m_bits_mask));
                        try h.setIfGreater(alloc, @intCast(e.key_ptr.*), v);
                    }
                },
                .empty => unreachable,
            },
            .dense => |other_words| switch (h.storage) {
                .explicit => |this_set| {
                    h.storage = try copyStorage(alloc, other.storage);
                    try h.addFromExplicit(alloc, this_set);
                },
                .sparse => {
                    try h.upgrade(alloc);
                    denseUnion(h.storage.dense, other_words, &h.settings, &other.settings);
                },
                .dense => |this_words| denseUnion(
                    this_words,
                    other_words,
                    &h.settings,
                    &other.settings,
                ),
                .empty => unreachable,
            },
        }

        if (h.overCapacity()) try h.upgrade(alloc);
    }

    fn addFromExplicit(h: *Hll, alloc: std.mem.Allocator, set: ExplicitSet) Error!void {
        var it = set.keyIterator();
        while (it.next()) |k| try h.addRaw(alloc, k.*);
    }

    /// go-hll Hll.ToBytes.
    pub fn toBytes(h: *const Hll, alloc: std.mem.Allocator) Error![]u8 {
        const s = &h.settings;
        const storage_type: StorageType = switch (h.storage) {
            .empty => .empty,
            .explicit => .explicit,
            .sparse => .sparse,
            .dense => .dense,
        };

        const bytes_needed: usize = switch (h.storage) {
            .empty => 0,
            .explicit => |set| 8 * set.count(),
            .sparse => |map| divideBy8RoundUp((@as(usize, s.log2m) + s.regwidth) * map.count()),
            .dense => divideBy8RoundUp(s.m() * s.regwidth),
        };

        const bytes = try alloc.alloc(u8, 3 + bytes_needed);
        errdefer alloc.free(bytes);
        @memset(bytes, 0);

        bytes[0] = (1 << 4) | @as(u8, @backingInt(storage_type));
        bytes[1] = @intCast(((@as(u16, s.regwidth) - 1) << 5) | s.log2m);
        bytes[2] = packCutoffByte(s);

        const out = bytes[3..];
        switch (h.storage) {
            .empty => {},
            .explicit => |set| {
                // Per the storage spec the values are sorted as *signed* 64
                // bit integers, ascending.
                const sorted = try alloc.alloc(i64, set.count());
                defer alloc.free(sorted);
                var it = set.keyIterator();
                var n: usize = 0;
                while (it.next()) |k| : (n += 1) sorted[n] = @bitCast(k.*);
                std.mem.sort(i64, sorted, {}, std.sort.asc(i64));
                for (sorted, 0..) |v, i| {
                    std.mem.writeInt(u64, out[i * 8 ..][0..8], @bitCast(v), .big);
                }
            },
            .sparse => |map| {
                const sorted = try alloc.alloc(i32, map.count());
                defer alloc.free(sorted);
                var it = map.keyIterator();
                var n: usize = 0;
                while (it.next()) |k| : (n += 1) sorted[n] = k.*;
                std.mem.sort(i32, sorted, {}, std.sort.asc(i32));

                const bits_per_register: usize = @as(usize, s.log2m) + s.regwidth;
                var addr: usize = 0;
                for (sorted) |reg| {
                    const reg_bits = @as(u64, @as(u32, @bitCast(reg)));
                    const packed_value = (reg_bits << @intCast(s.regwidth)) |
                        @as(u64, map.get(reg).?);
                    writeBits(out, addr, packed_value, bits_per_register);
                    addr += bits_per_register;
                }
            },
            .dense => |words| {
                const n_words = out.len / 8;
                var i: usize = 0;
                while (i < n_words) : (i += 1) {
                    std.mem.writeInt(u64, out[i * 8 ..][0..8], words[i], .big);
                }
                const remainder = out.len % 8;
                if (remainder > 0) {
                    const last_word = words[n_words];
                    var j: usize = 0;
                    while (j < remainder) : (j += 1) {
                        out[n_words * 8 + j] = @truncate(last_word >> @intCast(64 - (8 * (j + 1))));
                    }
                }
            },
        }

        return bytes;
    }
};

fn copyStorage(alloc: std.mem.Allocator, storage: Storage) Error!Storage {
    return switch (storage) {
        .empty => .empty,
        .explicit => |set| blk: {
            var out: ExplicitSet = .empty;
            var it = set.keyIterator();
            while (it.next()) |k| try out.put(alloc, k.*, {});
            break :blk .{ .explicit = out };
        },
        .sparse => |map| blk: {
            var out: SparseMap = .empty;
            var it = map.iterator();
            while (it.next()) |e| try out.put(alloc, e.key_ptr.*, e.value_ptr.*);
            break :blk .{ .sparse = out };
        },
        .dense => |words| .{ .dense = try alloc.dupe(u64, words) },
    };
}

fn sparseToDense(alloc: std.mem.Allocator, s: *const Settings, sparse: SparseMap) Error![]u64 {
    const words = try newDenseStorage(alloc, s);
    var it = sparse.iterator();
    while (it.next()) |e| denseSetIfGreater(words, s, @intCast(e.key_ptr.*), e.value_ptr.*);
    return words;
}

/// go-hll denseUnion. The matching-settings branch in Go is a fused
/// word-at-a-time pass; taking the per-register maximum is the same
/// computation (the mask it walks selects exactly one register at a time
/// whenever log2m >= regwidth, which holds for every sketch this engine
/// produces and for every sketch the storage spec sanctions).
fn denseUnion(
    this_words: []u64,
    other_words: []const u64,
    this_s: *const Settings,
    other_s: *const Settings,
) void {
    if (this_s.log2m == other_s.log2m and this_s.regwidth == other_s.regwidth) {
        const num_reg = this_s.m();
        var i: usize = 0;
        while (i < num_reg) : (i += 1) {
            denseSetIfGreater(this_words, this_s, i, denseGet(other_words, i, other_s.regwidth));
        }
        return;
    }
    const num_reg = this_s.m();
    var i: usize = 0;
    while (i < num_reg) : (i += 1) {
        const reg_val = denseGet(other_words, i, other_s.regwidth) &
            @as(u8, @truncate(this_s.m_bits_mask));
        denseSetIfGreater(this_words, this_s, i, reg_val);
    }
}

/// go-hll packCutoffByte.
fn packCutoffByte(s: *const Settings) u8 {
    var threshold: u8 = 0;
    if (s.explicit_auto) {
        threshold = 63;
    } else if (s.explicit_threshold == 0) {
        threshold = 0;
    } else {
        // bits.Len32(x) - 1
        threshold = @intCast(31 - @clz(@as(u32, @intCast(s.explicit_threshold))));
    }
    var cutoff = threshold;
    if (s.sparse_enabled) cutoff |= 1 << 6;
    return cutoff;
}

/// go-hll unpackCutoffByte.
fn unpackCutoffByte(b: u8) struct { bool, i64 } {
    const sparse_enabled = (b >> 6) == 1;
    const exp_threshold = b & 0x3f;
    if (exp_threshold == 0) return .{ sparse_enabled, 0 };
    if (exp_threshold == 63) return .{ sparse_enabled, -1 };
    return .{ sparse_enabled, @as(i64, 1) << @intCast(exp_threshold - 1) };
}

// ----------------------------------------------------------------------
// go-zetasqlite bindings
// ----------------------------------------------------------------------

/// Go HLL_COUNT_INIT.Step's type switch: only INT64 / NUMERIC / STRING /
/// BYTES contribute; anything else leaves the hashed value at 0, which
/// AddRaw ignores by contract.
fn hashInput(alloc: std.mem.Allocator, v: Value) Error!u64 {
    return switch (v) {
        // Go hashes IntValue/NumericValue via their string form, and
        // String/BytesValue via their raw bytes — ToBytes for all four.
        .int, .numeric, .string, .bytes => murmur3Sum64(try v.toBytes(alloc)),
        else => 0,
    };
}

pub const HLL_COUNT_INIT = struct {
    /// Go keeps *hll.Hll, created on the first Step (sync.Once) and left nil
    /// for an empty group, where Done returns a NULL value.
    hll: ?Hll = null,

    pub fn step(
        f: *HLL_COUNT_INIT,
        alloc: std.mem.Allocator,
        values: []const Value,
        _: *const AggregatorOption,
    ) Error!void {
        if (values.len < 1) {
            return bind.fail(
                "HLL_COUNT_INIT: invalid argument num {d}",
                .{values.len},
                error.UnsupportedOperation,
            );
        }
        if (values.len == 2) {
            // Go bindHllCountInit skips the whole row when the precision
            // argument is NULL (and validates that it is an integer).
            if (values[1] == .null) return;
            _ = try values[1].toInt64();
        }
        if (f.hll == null) f.hll = Hll.init(default_settings);
        try f.hll.?.addRaw(alloc, try hashInput(alloc, values[0]));
    }

    pub fn done(f: *HLL_COUNT_INIT, alloc: std.mem.Allocator) Error!Value {
        if (f.hll == null) return .null;
        return .{ .bytes = try f.hll.?.toBytes(alloc) };
    }
};

/// Shared Step of HLL_COUNT_MERGE / HLL_COUNT_MERGE_PARTIAL.
fn mergeStep(hll: *?Hll, alloc: std.mem.Allocator, values: []const Value) Error!void {
    if (values.len < 1) {
        return bind.fail(
            "HLL_COUNT_MERGE: invalid argument num {d}",
            .{values.len},
            error.UnsupportedOperation,
        );
    }
    if (values[0] == .null) return;
    const sketch = try values[0].toBytes(alloc);
    const other = try Hll.fromBytes(alloc, sketch);
    if (hll.* == null) {
        hll.* = other;
    } else {
        try hll.*.?.unionWith(alloc, other);
    }
}

pub const HLL_COUNT_MERGE = struct {
    hll: ?Hll = null,

    pub fn step(
        f: *HLL_COUNT_MERGE,
        alloc: std.mem.Allocator,
        values: []const Value,
        _: *const AggregatorOption,
    ) Error!void {
        try mergeStep(&f.hll, alloc, values);
    }

    pub fn done(f: *HLL_COUNT_MERGE, _: std.mem.Allocator) Error!Value {
        if (f.hll == null) return .{ .int = 0 };
        return .{ .int = @bitCast(f.hll.?.cardinality()) };
    }
};

pub const HLL_COUNT_MERGE_PARTIAL = struct {
    hll: ?Hll = null,

    pub fn step(
        f: *HLL_COUNT_MERGE_PARTIAL,
        alloc: std.mem.Allocator,
        values: []const Value,
        _: *const AggregatorOption,
    ) Error!void {
        try mergeStep(&f.hll, alloc, values);
    }

    pub fn done(f: *HLL_COUNT_MERGE_PARTIAL, alloc: std.mem.Allocator) Error!Value {
        if (f.hll == null) return .null;
        return .{ .bytes = try f.hll.?.toBytes(alloc) };
    }
};

/// Go bindHllCountExtract + HLL_COUNT_EXTRACT (a scalar function).
pub fn hllCountExtract(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return .null;
    const sketch = try args[0].toBytes(alloc);
    const h = try Hll.fromBytes(alloc, sketch);
    return .{ .int = @bitCast(h.cardinality()) };
}

// ----------------------------------------------------------------------
// Tests. Reference values come from running the Go libraries directly
// (github.com/DataDog/go-hll v1.0.2 + github.com/spaolacci/murmur3).
// ----------------------------------------------------------------------

const testing = std.testing;

test "murmur3 Sum64 matches spaolacci/murmur3" {
    try testing.expectEqual(@as(u64, 0x3a5f10e7efa35633), murmur3Sum64("customer_id_1"));
    try testing.expectEqual(@as(u64, 0x4e58838db9a15440), murmur3Sum64("customer_id_2"));
    try testing.expectEqual(@as(u64, 0x3fad55ad182406b9), murmur3Sum64("customer_id_3"));
    try testing.expectEqual(@as(u64, 0), murmur3Sum64(""));
    try testing.expectEqual(@as(u64, 0x85555565f6597889), murmur3Sum64("a"));
    try testing.expectEqual(@as(u64, 0xb4963f3f3fad7867), murmur3Sum64("abc"));
    // exactly one 16 byte block, and one block plus a one byte tail
    try testing.expectEqual(@as(u64, 0x4be06d94cf4ad1a7), murmur3Sum64("0123456789abcdef"));
    try testing.expectEqual(@as(u64, 0x8e32612daa45f9de), murmur3Sum64("0123456789abcdefg"));
    // two blocks + a 5 byte tail
    try testing.expectEqual(
        @as(u64, 0x8fbd124535429053),
        murmur3Sum64("hello world, this is a longer string!"),
    );
}

test "default settings match hll.Defaults(15, 8, auto, sparse)" {
    const s = default_settings;
    try testing.expectEqual(@as(u8, 15), s.log2m);
    try testing.expectEqual(@as(u8, 8), s.regwidth);
    try testing.expect(s.explicit_auto);
    try testing.expect(s.sparse_enabled);
    try testing.expectEqual(@as(usize, 4096), s.explicit_threshold);
    try testing.expectEqual(@as(usize, 8192), s.sparse_threshold);
    // regwidth 8 => the pW clamp mask degenerates to 0 (see pwMaxMask).
    try testing.expectEqual(@as(u64, 0), s.pw_max_mask);
    try testing.expectEqual(@as(u64, 0x7fff), s.m_bits_mask);
}

fn hash31(bytes: []const u8) u64 {
    var sum: u64 = 0;
    for (bytes) |b| sum = sum *% 31 +% b;
    return sum;
}

/// A sketch over "value-0" .. "value-{n-1}", the same corpus the Go
/// reference program used.
fn buildRange(alloc: std.mem.Allocator, settings: Settings, lo: usize, hi: usize) !Hll {
    var h = Hll.init(settings);
    var i = lo;
    var buf: [32]u8 = undefined;
    while (i < hi) : (i += 1) {
        const s = try std.fmt.bufPrint(&buf, "value-{d}", .{i});
        try h.addRaw(alloc, murmur3Sum64(s));
    }
    return h;
}

fn expectSketch(
    alloc: std.mem.Allocator,
    h: *const Hll,
    card: u64,
    len: usize,
    storage_type: u8,
    fingerprint: u64,
) !void {
    const b = try h.toBytes(alloc);
    try testing.expectEqual(len, b.len);
    try testing.expectEqual(storage_type, b[0] & 0xf);
    try testing.expectEqual(fingerprint, hash31(b));
    try testing.expectEqual(card, h.cardinality());
}

test "sketch serialization matches go-hll across representations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const s = default_settings;

    const Case = struct { n: usize, card: u64, len: usize, typ: u8, fp: u64 };
    const cases = [_]Case{
        .{ .n = 0, .card = 0, .len = 3, .typ = 1, .fp = 0x0000000000005d41 },
        .{ .n = 1, .card = 1, .len = 11, .typ = 2, .fp = 0x004b404ef6260420 },
        .{ .n = 3, .card = 3, .len = 27, .typ = 2, .fp = 0x6d16ff30afbc5e33 },
        // right at the explicit threshold, and one past it (-> sparse)
        .{ .n = 4096, .card = 4096, .len = 32771, .typ = 2, .fp = 0xa93aa0e26238225b },
        .{ .n = 4097, .card = 4097, .len = 11075, .typ = 3, .fp = 0x7aa6f0e6f5cfee7a },
        .{ .n = 5000, .card = 5015, .len = 13372, .typ = 3, .fp = 0xb80a84461a3c9be8 },
        .{ .n = 8192, .card = 8241, .len = 20951, .typ = 3, .fp = 0x1cc78420bc27672f },
        // past the sparse threshold (-> dense)
        .{ .n = 20000, .card = 20115, .len = 32771, .typ = 4, .fp = 0x366e3f4adccb233f },
        .{ .n = 100000, .card = 101439, .len = 32771, .typ = 4, .fp = 0x904accac3a31c7d6 },
    };

    for (cases) |c| {
        var h = try buildRange(alloc, s, 0, c.n);
        try expectSketch(alloc, &h, c.card, c.len, c.typ, c.fp);

        // round trip: deserializing and reserializing is a fixed point.
        const b = try h.toBytes(alloc);
        var back = try Hll.fromBytes(alloc, b);
        try expectSketch(alloc, &back, c.card, c.len, c.typ, c.fp);
    }
}

test "union matches go-hll for every storage pairing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const s = default_settings;

    const Case = struct { a: [2]usize, b: [2]usize, card: u64, len: usize, typ: u8, fp: u64 };
    const cases = [_]Case{
        // explicit + explicit (overlapping)
        .{
            .a = .{ 0, 10 },
            .b = .{ 5, 20 },
            .card = 20,
            .len = 163,
            .typ = 2,
            .fp = 0xb666ce72fdbca781,
        },
        // explicit + explicit (disjoint)
        .{
            .a = .{ 0, 3 },
            .b = .{ 100000, 100003 },
            .card = 6,
            .len = 51,
            .typ = 2,
            .fp = 0x3b8625c2bfabf658,
        },
        // sparse + sparse
        .{
            .a = .{ 0, 5000 },
            .b = .{ 4000, 9000 },
            .card = 9053,
            .len = 22745,
            .typ = 3,
            .fp = 0x83eceae151bcbd09,
        },
        // sparse + explicit
        .{
            .a = .{ 0, 9000 },
            .b = .{ 0, 3 },
            .card = 9053,
            .len = 22745,
            .typ = 3,
            .fp = 0x83eceae151bcbd09,
        },
        // explicit + explicit crossing into sparse
        .{
            .a = .{ 0, 4097 },
            .b = .{ 0, 2 },
            .card = 4097,
            .len = 11075,
            .typ = 3,
            .fp = 0x7aa6f0e6f5cfee7a,
        },
        // dense + dense
        .{
            .a = .{ 0, 20000 },
            .b = .{ 15000, 30000 },
            .card = 30134,
            .len = 32771,
            .typ = 4,
            .fp = 0xfaf197a7c3edcfc9,
        },
        // dense + explicit
        .{
            .a = .{ 0, 20000 },
            .b = .{ 0, 5 },
            .card = 20115,
            .len = 32771,
            .typ = 4,
            .fp = 0x366e3f4adccb233f,
        },
        // dense + sparse
        .{
            .a = .{ 0, 20000 },
            .b = .{ 0, 5000 },
            .card = 20115,
            .len = 32771,
            .typ = 4,
            .fp = 0x366e3f4adccb233f,
        },
        // explicit + dense (the receiver adopts the dense storage)
        .{
            .a = .{ 0, 5 },
            .b = .{ 0, 20000 },
            .card = 20115,
            .len = 32771,
            .typ = 4,
            .fp = 0x366e3f4adccb233f,
        },
        // explicit + sparse (the receiver adopts the sparse storage)
        .{
            .a = .{ 0, 5 },
            .b = .{ 0, 5000 },
            .card = 5015,
            .len = 13372,
            .typ = 3,
            .fp = 0xb80a84461a3c9be8,
        },
    };

    for (cases) |c| {
        var a = try buildRange(alloc, s, c.a[0], c.a[1]);
        const b = try buildRange(alloc, s, c.b[0], c.b[1]);
        try a.unionWith(alloc, b);
        try expectSketch(alloc, &a, c.card, c.len, c.typ, c.fp);
    }
}

test "non-default settings: regwidth 5 spans register words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // explicit storage disabled -> straight to sparse; log2m 11 + regwidth 5
    // means dense registers straddle the 64 bit words.
    const sparse_settings = try Settings.init(11, 5, 0, true);
    var a = try buildRange(alloc, sparse_settings, 0, 300);
    try expectSketch(alloc, &a, 287, 537, 3, 0x1a2f341a8ccd56a8);

    const dense_settings = try Settings.init(11, 5, 0, false);
    var b = try buildRange(alloc, dense_settings, 200, 5000);
    try expectSketch(alloc, &b, 5126, 1283, 4, 0x07e1e4d6c8e1a6f4);

    // sparse union dense: upgrades the receiver, then a dense union.
    try a.unionWith(alloc, b);
    try expectSketch(alloc, &a, 5314, 1283, 4, 0xf48356bf8ec4af8f);

    // and the dense round trip through the wire format
    const bytes = try b.toBytes(alloc);
    var back = try Hll.fromBytes(alloc, bytes);
    try expectSketch(alloc, &back, 5126, 1283, 4, 0x07e1e4d6c8e1a6f4);
}

test "corpus sketches: HLL_COUNT.INIT over customer ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Case = struct { ids: []const []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .ids = &.{"customer_id_3"}, .want = "Eu9/P61VrRgkBrk=" },
        .{ .ids = &.{ "customer_id_2", "customer_id_2" }, .want = "Eu9/TliDjbmhVEA=" },
        .{ .ids = &.{ "customer_id_1", "customer_id_2" }, .want = "Eu9/Ol8Q5++jVjNOWIONuaFUQA==" },
    };

    for (cases) |c| {
        var h = Hll.init(default_settings);
        for (c.ids) |id| try h.addRaw(alloc, murmur3Sum64(id));
        const b = try h.toBytes(alloc);
        const enc = std.base64.standard.Encoder;
        const out = try alloc.alloc(u8, enc.calcSize(b.len));
        try testing.expectEqualStrings(c.want, enc.encode(out, b));
    }
}

test "fromBytes rejects malformed sketches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(error.CorruptData, Hll.fromBytes(alloc, "ab"));
    // version 2
    try testing.expectError(error.CorruptData, Hll.fromBytes(alloc, "\x22\xef\x7f"));
    // type 0 (undefined) is rejected by the range check in Go too
    try testing.expectError(error.CorruptData, Hll.fromBytes(alloc, "\x10\xef\x7f"));
    // type 5 does not exist
    try testing.expectError(error.CorruptData, Hll.fromBytes(alloc, "\x15\xef\x7f"));
    // explicit payload that is not a multiple of 8 bytes
    try testing.expectError(error.CorruptData, Hll.fromBytes(alloc, "\x12\xef\x7f\x01\x02"));
    // truncated dense payload
    try testing.expectError(error.CorruptData, Hll.fromBytes(alloc, "\x14\xef\x7f\x01\x02"));
}
