//! **Galdr** — plugins, in Lua.
//!
//! A galdr is a spell: runes written or words chanted to make the world act
//! differently than it would. That is what a plugin is to this reader -- a
//! few lines, written by whoever uses it, that change what a key does, add a
//! command, or react when a page turns.
//!
//! It is Neovim's model, deliberately, because that model is known to work
//! and known to the people most likely to want it:
//!
//!     <config>/init.lua              run first
//!     <config>/plugins/<name>.lua    then each plugin, in order of name
//!     <config>/plugins/<name>/init.lua
//!     <config>/lua/<module>.lua      what `require "module"` finds
//!
//! and a `fenrir` table in place of `vim`:
//!
//!     fenrir.keymap("n", "<C-d>", function() fenrir.exec("page +1") end)
//!     fenrir.command("Wc", function() fenrir.notify(#fenrir.highlights()) end)
//!     fenrir.on("page", function(p) fenrir.store.set("last", p) end)
//!
//! What it is not is Neovim's *trust*. A plugin here runs in a sandbox with
//! no files, no processes and no native code, and with a limit on how much
//! memory and time any one call can take. `Runtime.zig` says exactly what is
//! in the sandbox; `Host.zig` says exactly what a plugin can reach.
//!
//! The configuration directory is the platform's, beside Mímir's database:
//!
//!   Windows   %APPDATA%\fenrir
//!   macOS     ~/Library/Application Support/fenrir
//!   otherwise $XDG_CONFIG_HOME/fenrir, or ~/.config/fenrir
//!
//! and `FENRIR_CONFIG` overrides it. `-Dlua=false` builds a reader with no
//! Lua in it at all, which runs no scripts and says so.

const std = @import("std");
const Allocator = std.mem.Allocator;

const mimir = @import("mimir.zig");

pub const Host = @import("galdr/Host.zig");
pub const Runtime = @import("galdr/Runtime.zig");
pub const keyspec = @import("galdr/keyspec.zig");
pub const lua = @import("galdr/lua.zig");

/// True when this build can run Lua.
pub const available = lua.available;

pub const Error = error{NoHome} || Allocator.Error;

/// The directory plugins and `init.lua` are read from. Caller owns it.
pub fn configDir(gpa: Allocator, env: mimir.Environment) Error![]u8 {
    if (env.get("FENRIR_CONFIG")) |dir| {
        if (dir.len != 0) return gpa.dupe(u8, dir);
    }

    const builtin = @import("builtin");
    const join = std.fs.path.join;
    switch (builtin.os.tag) {
        .windows => {
            const base = nonEmpty(env.get("APPDATA")) orelse nonEmpty(env.get("LOCALAPPDATA")) orelse
                return error.NoHome;
            return join(gpa, &.{ base, "fenrir" });
        },
        .macos, .ios => {
            const home = nonEmpty(env.get("HOME")) orelse return error.NoHome;
            return join(gpa, &.{ home, "Library", "Application Support", "fenrir" });
        },
        else => {
            if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |x| return join(gpa, &.{ x, "fenrir" });
            const home = nonEmpty(env.get("HOME")) orelse return error.NoHome;
            return join(gpa, &.{ home, ".config", "fenrir" });
        },
    }
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

test {
    _ = Host;
    _ = Runtime;
    _ = keyspec;
    _ = lua;
}

test "the configuration directory follows the platform, and FENRIR_CONFIG overrides it" {
    const gpa = std.testing.allocator;
    const Fake = struct {
        pairs: []const [2][]const u8,
        fn get(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
            return null;
        }
    };

    const override: Fake = .{ .pairs = &.{.{ "FENRIR_CONFIG", "/tmp/cfg" }} };
    const a = try configDir(gpa, .{ .ptr = &override, .lookup = Fake.get });
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/tmp/cfg", a);

    const plain: Fake = .{ .pairs = &.{
        .{ "APPDATA", "C:/Users/x/AppData/Roaming" },
        .{ "HOME", "/home/x" },
    } };
    const b = try configDir(gpa, .{ .ptr = &plain, .lookup = Fake.get });
    defer gpa.free(b);
    try std.testing.expect(std.mem.endsWith(u8, b, "fenrir"));

    const nothing: Fake = .{ .pairs = &.{} };
    try std.testing.expectError(error.NoHome, configDir(gpa, .{ .ptr = &nothing, .lookup = Fake.get }));
}
