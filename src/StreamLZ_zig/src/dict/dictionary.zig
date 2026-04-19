//! Dictionary support for StreamLZ.
//!
//! Built-in dictionaries are compiled into the binary via @embedFile.
//! Each has a well-known dictionary_id stored in the SLZ1 frame header.
//! The decoder looks up the dictionary by ID; the encoder selects one
//! by file extension (auto) or explicit -D flag.
//!
//! Custom dictionaries use IDs >= 0x1000_0000. The caller must provide
//! the dictionary bytes to both encoder and decoder.

const std = @import("std");

pub const DictInfo = struct {
    id: u32,
    name: []const u8,
    data: []const u8,
    extensions: []const []const u8,
};

// Well-known built-in dictionary IDs.
pub const id_json: u32 = 1;
pub const id_html: u32 = 2;
pub const id_text: u32 = 3;
pub const id_xml: u32 = 4;
pub const id_css: u32 = 5;
pub const id_js: u32 = 6;
pub const id_general: u32 = 7;

pub const builtin_dicts: []const DictInfo = &.{
    .{
        .id = id_json,
        .name = "json",
        .data = @embedFile("builtin/json.dict"),
        .extensions = &.{ ".json", ".geojson", ".jsonl", ".ndjson" },
    },
    .{
        .id = id_html,
        .name = "html",
        .data = @embedFile("builtin/html.dict"),
        .extensions = &.{ ".html", ".htm", ".xhtml", ".svg" },
    },
    .{
        .id = id_text,
        .name = "text",
        .data = @embedFile("builtin/text.dict"),
        .extensions = &.{ ".txt", ".md", ".rst", ".log" },
    },
    .{
        .id = id_xml,
        .name = "xml",
        .data = @embedFile("builtin/xml.dict"),
        .extensions = &.{ ".xml", ".rss", ".atom", ".opml", ".pom", ".xsl" },
    },
    .{
        .id = id_css,
        .name = "css",
        .data = @embedFile("builtin/css.dict"),
        .extensions = &.{".css"},
    },
    .{
        .id = id_js,
        .name = "js",
        .data = @embedFile("builtin/js.dict"),
        .extensions = &.{ ".js", ".mjs", ".cjs", ".ts" },
    },
    .{
        .id = id_general,
        .name = "general",
        .data = @embedFile("builtin/general.dict"),
        .extensions = &.{},
    },
};

pub fn findByName(name: []const u8) ?*const DictInfo {
    for (builtin_dicts) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

pub fn findById(id: u32) ?*const DictInfo {
    for (builtin_dicts) |*d| {
        if (d.id == id) return d;
    }
    return null;
}

pub fn findByExtension(path: []const u8) ?*const DictInfo {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return findByName("general");
    var lower_buf: [16]u8 = undefined;
    const ext_lower = toLower(ext, &lower_buf) orelse return findByName("general");
    for (builtin_dicts) |*d| {
        for (d.extensions) |e| {
            if (std.mem.eql(u8, ext_lower, e)) return d;
        }
    }
    return findByName("general");
}

fn toLower(s: []const u8, buf: *[16]u8) ?[]const u8 {
    if (s.len > 16) return null;
    for (s, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..s.len];
}
