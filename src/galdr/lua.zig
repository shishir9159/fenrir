//! Lua 5.4, declared by hand.
//!
//! The same bargain as `mimir/Db.zig` and `lyngvi/vk.zig`: the C library is
//! compiled from its pinned source by the build, and the *declarations* are
//! written here rather than translated from `lua.h`. That keeps the headers
//! out of the tree, keeps the surface to what Galdr calls, and puts the
//! calling convention of every entry point somewhere it can be read.
//!
//! Every signature below was copied from Lua 5.4.9's `lua.h`, `lauxlib.h` and
//! `lualib.h`, with the build's defaults: `lua_Integer` is `long long` and
//! `lua_Number` is `double`. A wrong signature here compiles, links, and
//! corrupts a stack at run time -- the tests at the bottom exercise every
//! type that crosses the boundary so that it corrupts one in a test instead.
//!
//! ## Errors, and the one rule that follows from them
//!
//! Lua reports an error by `longjmp`, straight past any frames between the
//! raise and the nearest `pcall`, Zig frames included. Zig has no destructors
//! to skip, but it has `defer`, and a `defer` in a frame that is jumped over
//! never runs. So a Zig function called *from* Lua must not hold anything
//! that a `defer` or `errdefer` would release across any call into Lua that
//! can raise -- which is nearly all of them, because even pushing a string
//! can fail for memory. Galdr's API functions check their arguments first and
//! touch the host after, and do not allocate across a Lua call.

const std = @import("std");
const build_options = @import("build_options");

/// Whether this build compiled Lua in.
pub const available = build_options.lua;

pub const State = opaque {};
pub const Debug = opaque {};

pub const Integer = i64;
pub const Number = f64;
pub const CFunction = *const fn (?*State) callconv(.c) c_int;
pub const Alloc = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
pub const Hook = *const fn (?*State, ?*Debug) callconv(.c) void;
pub const KFunction = *const fn (?*State, c_int, isize) callconv(.c) c_int;

pub const Reg = extern struct {
    name: ?[*:0]const u8,
    func: ?CFunction,
};

// -- constants ----------------------------------------------------------------

pub const ok: c_int = 0;
pub const yield: c_int = 1;
pub const err_run: c_int = 2;
pub const err_syntax: c_int = 3;
pub const err_mem: c_int = 4;
pub const err_err: c_int = 5;

pub const multret: c_int = -1;

/// `-LUAI_MAXSTACK - 1000`, with `LUAI_MAXSTACK` at its value for a 32-bit
/// `int`, which is every platform this builds for.
pub const registry_index: c_int = -1_000_000 - 1000;

pub fn upvalueIndex(i: c_int) c_int {
    return registry_index - i;
}

pub const Type = enum(c_int) {
    none = -1,
    nil = 0,
    boolean = 1,
    light_userdata = 2,
    number = 3,
    string = 4,
    table = 5,
    function = 6,
    userdata = 7,
    thread = 8,
    _,
};

pub const mask_count: c_int = 1 << 3;
pub const gc_count: c_int = 3;

/// `LUA_NOREF`: what `luaL_ref` returns for nil, and a safe "no function".
pub const no_ref: c_int = -2;

// -- lua.h --------------------------------------------------------------------

pub extern fn lua_newstate(f: Alloc, ud: ?*anyopaque) ?*State;
pub extern fn lua_close(L: ?*State) void;

pub extern fn lua_absindex(L: ?*State, idx: c_int) c_int;
pub extern fn lua_gettop(L: ?*State) c_int;
pub extern fn lua_settop(L: ?*State, idx: c_int) void;
pub extern fn lua_pushvalue(L: ?*State, idx: c_int) void;
pub extern fn lua_rotate(L: ?*State, idx: c_int, n: c_int) void;

pub extern fn lua_isinteger(L: ?*State, idx: c_int) c_int;
pub extern fn lua_type(L: ?*State, idx: c_int) c_int;
pub extern fn lua_typename(L: ?*State, tp: c_int) [*:0]const u8;

pub extern fn lua_tonumberx(L: ?*State, idx: c_int, isnum: ?*c_int) Number;
pub extern fn lua_tointegerx(L: ?*State, idx: c_int, isnum: ?*c_int) Integer;
pub extern fn lua_toboolean(L: ?*State, idx: c_int) c_int;
pub extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
pub extern fn lua_rawlen(L: ?*State, idx: c_int) u64;
pub extern fn lua_touserdata(L: ?*State, idx: c_int) ?*anyopaque;

pub extern fn lua_pushnil(L: ?*State) void;
pub extern fn lua_pushnumber(L: ?*State, n: Number) void;
pub extern fn lua_pushinteger(L: ?*State, n: Integer) void;
pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) ?[*]const u8;
pub extern fn lua_pushcclosure(L: ?*State, f: CFunction, n: c_int) void;
pub extern fn lua_pushboolean(L: ?*State, b: c_int) void;
pub extern fn lua_pushlightuserdata(L: ?*State, p: ?*anyopaque) void;

pub extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
pub extern fn lua_getfield(L: ?*State, idx: c_int, k: [*:0]const u8) c_int;
pub extern fn lua_rawgeti(L: ?*State, idx: c_int, n: Integer) c_int;
pub extern fn lua_rawget(L: ?*State, idx: c_int) c_int;
pub extern fn lua_rawset(L: ?*State, idx: c_int) void;
pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
pub extern fn lua_getmetatable(L: ?*State, objindex: c_int) c_int;

pub extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
pub extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_rawseti(L: ?*State, idx: c_int, n: Integer) void;
pub extern fn lua_setmetatable(L: ?*State, objindex: c_int) c_int;

pub extern fn lua_pcallk(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?KFunction) c_int;
pub extern fn lua_callk(L: ?*State, nargs: c_int, nresults: c_int, ctx: isize, k: ?KFunction) void;
pub extern fn lua_getallocf(L: ?*State, ud: ?*?*anyopaque) Alloc;
pub extern fn lua_setupvalue(L: ?*State, funcindex: c_int, n: c_int) ?[*:0]const u8;
pub extern fn lua_gc(L: ?*State, what: c_int, ...) c_int;
pub extern fn lua_error(L: ?*State) c_int;
pub extern fn lua_next(L: ?*State, idx: c_int) c_int;
pub extern fn lua_sethook(L: ?*State, func: ?Hook, mask: c_int, count: c_int) void;

// -- lauxlib.h ----------------------------------------------------------------

pub extern fn luaL_checklstring(L: ?*State, arg: c_int, len: ?*usize) [*]const u8;
pub extern fn luaL_optlstring(L: ?*State, arg: c_int, def: ?[*:0]const u8, len: ?*usize) ?[*]const u8;
pub extern fn luaL_checknumber(L: ?*State, arg: c_int) Number;
pub extern fn luaL_optnumber(L: ?*State, arg: c_int, def: Number) Number;
pub extern fn luaL_checkinteger(L: ?*State, arg: c_int) Integer;
pub extern fn luaL_optinteger(L: ?*State, arg: c_int, def: Integer) Integer;
pub extern fn luaL_checktype(L: ?*State, arg: c_int, t: c_int) void;
pub extern fn luaL_checkstack(L: ?*State, sz: c_int, msg: ?[*:0]const u8) void;
pub extern fn luaL_error(L: ?*State, fmt: [*:0]const u8, ...) c_int;
pub extern fn luaL_ref(L: ?*State, t: c_int) c_int;
pub extern fn luaL_unref(L: ?*State, t: c_int, ref: c_int) void;
pub extern fn luaL_loadbufferx(L: ?*State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern fn luaL_traceback(L: ?*State, L1: ?*State, msg: ?[*:0]const u8, level: c_int) void;
pub extern fn luaL_requiref(L: ?*State, modname: [*:0]const u8, openf: CFunction, glb: c_int) void;
pub extern fn luaL_setfuncs(L: ?*State, l: [*]const Reg, nup: c_int) void;
pub extern fn luaL_tolstring(L: ?*State, idx: c_int, len: ?*usize) [*]const u8;

// -- lualib.h -----------------------------------------------------------------

pub extern fn luaopen_base(L: ?*State) c_int;
pub extern fn luaopen_coroutine(L: ?*State) c_int;
pub extern fn luaopen_table(L: ?*State) c_int;
pub extern fn luaopen_string(L: ?*State) c_int;
pub extern fn luaopen_utf8(L: ?*State) c_int;
pub extern fn luaopen_math(L: ?*State) c_int;

// -- the macros, as functions -------------------------------------------------

pub fn pop(L: ?*State, n: c_int) void {
    lua_settop(L, -n - 1);
}

pub fn pcall(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}

pub fn newTable(L: ?*State) void {
    lua_createtable(L, 0, 0);
}

pub fn typeOf(L: ?*State, idx: c_int) Type {
    return @enumFromInt(lua_type(L, idx));
}

/// The string at `idx`, or null if it is not a string or a number. Borrowed
/// from Lua: valid while the value stays on the stack.
pub fn toString(L: ?*State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}

pub fn pushString(L: ?*State, s: []const u8) void {
    _ = lua_pushlstring(L, s.ptr, s.len);
}

pub fn checkString(L: ?*State, arg: c_int) []const u8 {
    var len: usize = 0;
    const p = luaL_checklstring(L, arg, &len);
    return p[0..len];
}

pub fn optString(L: ?*State, arg: c_int) ?[]const u8 {
    if (typeOf(L, arg) == .nil or typeOf(L, arg) == .none) return null;
    return checkString(L, arg);
}

/// Raises a Lua error with a message. Never returns to the caller -- see
/// the note on `longjmp` at the top of the file.
pub fn raise(L: ?*State, message: []const u8) noreturn {
    pushString(L, message);
    _ = lua_error(L);
    unreachable;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn testAlloc(_: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    // libc's, for the tests of the declarations alone; Galdr's own allocator
    // is tested with the runtime.
    _ = osize;
    if (nsize == 0) {
        std.c.free(ptr);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}

fn fresh() !*State {
    return lua_newstate(testAlloc, null) orelse error.NoState;
}

test "every type crosses the boundary intact" {
    if (!available) return error.SkipZigTest;
    const L = try fresh();
    defer lua_close(L);

    lua_pushinteger(L, -9_007_199_254_740_993); // not representable as a double
    lua_pushnumber(L, 0.1);
    lua_pushboolean(L, 1);
    pushString(L, "a\x00b"); // an embedded NUL, which a C string would cut

    try testing.expectEqual(@as(c_int, 4), lua_gettop(L));
    try testing.expect(lua_isinteger(L, 1) != 0);
    try testing.expectEqual(@as(Integer, -9_007_199_254_740_993), lua_tointegerx(L, 1, null));
    try testing.expectEqual(@as(Number, 0.1), lua_tonumberx(L, 2, null));
    try testing.expect(lua_toboolean(L, 3) != 0);
    try testing.expectEqualSlices(u8, "a\x00b", toString(L, 4).?);
    try testing.expectEqual(Type.string, typeOf(L, 4));
}

test "a chunk runs, and an error in it comes back as a status and a message" {
    if (!available) return error.SkipZigTest;
    const L = try fresh();
    defer lua_close(L);
    luaL_requiref(L, "_G", luaopen_base, 1);
    pop(L, 1);

    const good = "return 6 * 7";
    try testing.expectEqual(ok, luaL_loadbufferx(L, good, good.len, "=test", "t"));
    try testing.expectEqual(ok, pcall(L, 0, 1, 0));
    try testing.expectEqual(@as(Integer, 42), lua_tointegerx(L, -1, null));
    pop(L, 1);

    const bad = "error('no')";
    try testing.expectEqual(ok, luaL_loadbufferx(L, bad, bad.len, "=test", "t"));
    try testing.expectEqual(err_run, pcall(L, 0, 0, 0));
    try testing.expect(std.mem.indexOf(u8, toString(L, -1).?, "no") != null);
}

fn zigRaises(L: ?*State) callconv(.c) c_int {
    raise(L, "raised from zig");
}

test "an error raised from zig crosses zig's frame back to pcall" {
    // The `longjmp` question, answered on this platform: a Zig function
    // called from Lua raises, the jump goes through the Zig frame, and the
    // `pcall` that called it gets the message and the process carries on.
    if (!available) return error.SkipZigTest;
    const L = try fresh();
    defer lua_close(L);

    lua_pushcclosure(L, zigRaises, 0);
    try testing.expectEqual(err_run, pcall(L, 0, 0, 0));
    try testing.expectEqualStrings("raised from zig", toString(L, -1).?);
}

test "binary chunks are refused when only text is allowed" {
    // Lua bytecode is not verified; a crafted chunk can crash the VM. `t`
    // is how every load in Galdr refuses it.
    if (!available) return error.SkipZigTest;
    const L = try fresh();
    defer lua_close(L);

    const bytecode = "\x1bLua\x54\x00junk";
    try testing.expect(luaL_loadbufferx(L, bytecode, bytecode.len, "=evil", "t") != ok);
}
