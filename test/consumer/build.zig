const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const dep = b.dependency("venom_term", .{ .target = target, .headless = true });
    if (dep.builder.modules.contains("venom-term")) @panic("headless consumer loaded renderer module");
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{ .root_source_file = b.path("../vt_only.zig"), .target = target }) });
    exe.root_module.addImport("vt", dep.module("vt"));
    const step = b.step("test", "Run headless external consumers");
    step.dependOn(&b.addRunArtifact(exe).step);
    const chrome = b.addExecutable(.{ .name = "chrome-consumer", .root_module = b.createModule(.{ .root_source_file = b.path("../chrome_only.zig"), .target = target }) });
    chrome.root_module.addImport("chrome", dep.module("chrome"));
    step.dependOn(&b.addRunArtifact(chrome).step);
    const streams = b.addExecutable(.{ .name = "pane-stream-consumer", .root_module = b.createModule(.{ .root_source_file = b.path("../pane_stream_only.zig"), .target = target }) });
    streams.root_module.addImport("pane_stream", dep.module("pane_stream"));
    step.dependOn(&b.addRunArtifact(streams).step);
}
