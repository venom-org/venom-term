const std = @import("std");
/// libghostty-vt release pinned in build.zig.zon, and the commit its tag
/// (`vt-<version>`) points at.
const ghostty_version = "1.0.0";
const ghostty_commit = "0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec";
comptime {
    if (ghostty_commit.len != 40) @compileError("ghostty_commit must be a full 40-hex commit");
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Ghostty's Debug build runs page integrity checks on every scroll,
    // which makes short-line output ~1000x slower (see
    // docs/debug-feed-throughput.md). Build it optimized by default even when
    // we are Debug; our own code keeps the requested mode.
    // `-Dghostty-optimize=debug` restores a Debug ghostty.
    const ghostty_optimize = b.option(std.builtin.Optimize, "ghostty-optimize", "Optimize mode for libghostty-vt (default: safe for debug builds, else the build's mode)") orelse
        if (optimize == .debug) .safe else optimize;
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = ghostty_optimize });
    const tc = b.addTranslateC(.{ .root_source_file = ghostty.path("include/ghostty/vt.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(ghostty.path("include"));
    tc.defineCMacro("GHOSTTY_STATIC", "");
    const types = b.addModule("types", .{ .root_source_file = b.path("src/types.zig"), .target = target, .optimize = optimize });
    const vt = b.addModule("vt", .{ .root_source_file = b.path("src/vt.zig"), .target = target, .optimize = optimize });
    vt.addImport("types", types);
    // Shared presentation-client logic (keys, tags, status layout): pure, so headless
    // dependents such as a daemon checking key config can import it.
    const chrome = b.addModule("chrome", .{ .root_source_file = b.path("src/chrome.zig"), .target = target, .optimize = optimize });
    chrome.addImport("types", types);
    // Pane-stream client state machine: on `vt` only, so it builds headless.
    const pane_stream = b.addModule("pane_stream", .{ .root_source_file = b.path("src/pane_stream.zig"), .target = target, .optimize = optimize });
    pane_stream.addImport("vt", vt);
    // The ghostty commit names the pane-stream snapshot format. The release
    // tarball URL carries only the version, so the commit of its tag lives
    // here; bumping the URL without both constants fails the build, and
    // vt.zig checks the header's GHOSTTY_VT_VERSION against the version.
    const ghostty_url: []const u8 = @import("build.zig.zon").dependencies.ghostty.url;
    if (!std.mem.endsWith(u8, ghostty_url, "/" ++ ghostty_version ++ "/libghostty-vt-" ++ ghostty_version ++ ".tar.gz"))
        @panic("ghostty dependency URL must be the libghostty-vt " ++ ghostty_version ++ " release tarball; update ghostty_version and ghostty_commit in build.zig");
    const options = b.addOptions();
    options.addOption([]const u8, "ghostty_version", ghostty_version);
    options.addOption([]const u8, "ghostty_commit", ghostty_commit);
    vt.addOptions("build_options", options);
    vt.addImport("ghostty_c", tc.createModule());
    vt.linkLibrary(ghostty.artifact("ghostty-vt-static"));
    // Headless dependents use this option: the build graph never loads vaxis.
    const headless = b.option(bool, "headless", "Build only the headless VT API") orelse false;
    const tests = b.step("test", "Run unit and independent consumer tests");
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vt })).step);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = chrome })).step);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pane_stream })).step);
    const consumer = b.addExecutable(.{ .name = "vt-only", .root_module = b.createModule(.{ .root_source_file = b.path("test/vt_only.zig"), .target = target, .optimize = optimize }) });
    consumer.root_module.addImport("vt", vt);
    b.installArtifact(consumer);
    tests.dependOn(&b.addRunArtifact(consumer).step);
    const feed_bench = b.addExecutable(.{ .name = "feed-bench", .root_module = b.createModule(.{ .root_source_file = b.path("test/feed_bench.zig"), .target = target, .optimize = optimize }) });
    feed_bench.root_module.addImport("vt", vt);
    b.installArtifact(feed_bench);
    // Not part of `zig build test`: it times 16 MiB exports.
    const plain_bench = b.addExecutable(.{ .name = "plain-bench", .root_module = b.createModule(.{ .root_source_file = b.path("test/plain_bench.zig"), .target = target, .optimize = optimize }) });
    plain_bench.root_module.addImport("vt", vt);
    b.installArtifact(plain_bench);
    if (!headless) {
        const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
        const term = b.addModule("venom-term", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
        term.addImport("types", types);
        term.addImport("vt", vt);
        term.addImport("chrome", chrome);
        term.addImport("pane_stream", pane_stream);
        term.addImport("vaxis", vaxis.module("vaxis"));
        tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = term })).step);
        const bench = b.addExecutable(.{ .name = "term-bench", .root_module = b.createModule(.{ .root_source_file = b.path("test/bench.zig"), .target = target, .optimize = optimize }) });
        bench.root_module.addImport("venom-term", term);
        const run = b.addRunArtifact(bench);
        run.addPassthruArgs();
        b.step("bench", "Render and idle resource probe").dependOn(&run.step);
        b.installArtifact(bench);
        // Not part of `zig build test`: it draws a 10k-block transcript.
        const scroll_bench = b.addExecutable(.{ .name = "scroll-bench", .root_module = b.createModule(.{ .root_source_file = b.path("test/scroll_bench.zig"), .target = target, .optimize = optimize }) });
        scroll_bench.root_module.addImport("venom-term", term);
        const run_scroll = b.addRunArtifact(scroll_bench);
        run_scroll.addPassthruArgs();
        b.step("bench-scroll", "ScrollView render cost for a 10k-block transcript").dependOn(&run_scroll.step);
        // Not part of `zig build test`: it times draws and needs a release build.
        const popup_bench = b.addExecutable(.{ .name = "popup-bench", .root_module = b.createModule(.{ .root_source_file = b.path("test/popup_bench.zig"), .target = target, .optimize = optimize }) });
        popup_bench.root_module.addImport("venom-term", term);
        const run_popup = b.addRunArtifact(popup_bench);
        run_popup.addPassthruArgs();
        b.step("bench-popup", "Leader popup draw cost and idle output").dependOn(&run_popup.step);
        const panes = b.addExecutable(.{ .name = "example-panes", .root_module = b.createModule(.{ .root_source_file = b.path("examples/panes.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
        panes.root_module.addImport("venom-term", term);
        b.installArtifact(panes);
        const run_panes = b.addRunArtifact(panes);
        run_panes.stdio = .inherit;
        run_panes.addPassthruArgs();
        b.step("example-panes", "Run two PTY panes side by side").dependOn(&run_panes.step);
        const widgets = b.addExecutable(.{ .name = "example-widgets", .root_module = b.createModule(.{ .root_source_file = b.path("examples/widgets.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
        widgets.root_module.addImport("venom-term", term);
        b.installArtifact(widgets);
        const run_widgets = b.addRunArtifact(widgets);
        run_widgets.stdio = .inherit;
        run_widgets.addPassthruArgs();
        b.step("example-widgets", "Run the widgets v0 demo: agent list, transcript, input").dependOn(&run_widgets.step);
        // The example's App runs headless in tests, driven by raw key bytes.
        tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = widgets.root_module })).step);
    }
    const external = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    external.setCwd(b.path("test/consumer"));
    external.expectExitCode(0);
    external.has_side_effects = true;
    tests.dependOn(&external.step);
}
