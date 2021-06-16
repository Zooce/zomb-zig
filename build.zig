const bld = @import("std").build;

pub fn build(b: *bld.Builder) void {
    const mode = b.standardReleaseOptions();

    // build the library
    const zomb_lib = b.addStaticLibrary("zomb", "src/zomb.zig");
    zomb_lib.setBuildMode(b.standardReleaseOptions());
    zomb_lib.install();

    // build the tests
    const test_step = b.step("test", "Run ZOMB-Zig library tests");
    var t = b.addTest("src/zomb.zig");
    t.setBuildMode(mode);
    test_step.dependOn(&t.step);

    // build the example executable
    const exe = b.addExecutable("zomb2json", "example/zomb2json.zig");
    exe.setBuildMode(mode);
    exe.addPackagePath("zomb", "src/zomb.zig");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Create a `run` step (so we can do `zig build run`)
    const run_step = b.step("example", "Run the example app");
    run_step.dependOn(&run_cmd.step);
}
