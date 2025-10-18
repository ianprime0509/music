const std = @import("std");
const directory: Directory = @import("directory.zon");

const Directory = struct {
    pmd: []const Song,

    const Song = struct {
        file: []const u8,
        source: []const u8,
        title: []const u8,
    };
};

pub fn build(b: *std.Build) void {
    buildSite(b);
    compileMusic(b);
}

fn buildSite(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .cpu_model = .baseline,
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            // See https://webassembly.org/features/ for support
            .atomics,
            .bulk_memory,
            .extended_const,
            .multivalue,
            .mutable_globals,
            .nontrapping_fptoint,
            .reference_types,
            .sign_ext,
            .tail_call,
        }),
        .os_tag = .wasi,
    });
    const optimize = b.standardOptimizeOption(.{});

    // https://github.com/orgs/community/discussions/22399
    const use_coi_service_worker = b.option(
        bool,
        "use-coi-service-worker",
        "Use cross-origin isolation service worker hack",
    ) orelse false;

    const fmplayer_dep = b.dependency("fmplayer", .{});

    const fmplayer_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fmplayer_mod.addIncludePath(fmplayer_dep.path("."));
    fmplayer_mod.addCMacro("_POSIX_C_SOURCE", "199309L");
    fmplayer_mod.addCMacro("LIBOPNA_ENABLE_LEVELDATA", "");
    fmplayer_mod.addCSourceFiles(.{
        .root = fmplayer_dep.path("."),
        .files = &.{
            "common/fmplayer_drumrom_static.c",
            "common/fmplayer_file.c",
            "common/fmplayer_file_js.c",
            "common/fmplayer_work_opna.c",
            "libopna/opnaadpcm.c",
            "libopna/opnadrum.c",
            "libopna/opnafm.c",
            "libopna/opnassg.c",
            "libopna/opnassg-sinc-c.c",
            "libopna/opnatimer.c",
            "libopna/opna.c",
            "fmdriver/fmdriver_fmp.c",
            "fmdriver/fmdriver_pmd.c",
            "fmdriver/fmdriver_common.c",
            "fmdriver/ppz8.c",
            "fft/fft.c",
            "fmdsp/fmdsp-pacc.c",
            "fmdsp/font_fmdsp_small.c",
            "fmdsp/font_rom.c",
            "fmdsp/fmdsp_platform_js.c",
            "pacc/pacc-js.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            "-std=c11",
            "-fno-sanitize=shift",
            "-Wno-unknown-attributes", // due to optimize attribute
        },
    });

    const fmplayer_lib = b.addLibrary(.{
        .name = "fmplayer",
        .root_module = fmplayer_mod,
    });
    fmplayer_lib.installHeadersDirectory(fmplayer_dep.path("."), "", .{
        .include_extensions = &.{ ".h", ".inc" },
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.export_symbol_names = &.{"__stack_pointer"};
    mod.linkLibrary(fmplayer_lib);
    mod.addCMacro("LIBOPNA_ENABLE_LEVELDATA", "");
    mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "main.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            "-std=c23",
            "-Wno-unknown-attributes", // due to optimize attribute
        },
    });

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = mod,
    });
    exe.entry = .disabled;
    exe.wasi_exec_model = .reactor;
    exe.import_memory = true;
    exe.initial_memory = 64 * 1024 * 1024;
    exe.max_memory = 64 * 1024 * 1024;
    exe.shared_memory = true;
    exe.stack_size = 8 * 1024 * 1024;

    const static_files: []const []const u8 = &.{
        "index.html",
        "index.js",
        "audio.js",
        "wasi.js",
    };
    for (static_files) |static_file| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("src/{s}", .{static_file})),
            .prefix,
            static_file,
        ).step);
    }
    const extern_static_files: []const []const u8 = &.{
        "common/fmplayer_file_js.js",
        "fmdsp/fmdsp_platform_js.js",
        "pacc/pacc-js.js",
    };
    for (extern_static_files) |path| {
        const name = std.fs.path.basenamePosix(path);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            fmplayer_dep.path(path),
            .prefix,
            name,
        ).step);
    }

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        exe.getEmittedBin(),
        .prefix,
        "main.wasm",
    ).step);

    if (use_coi_service_worker) coi: {
        const coi_dep = b.lazyDependency("coi_serviceworker", .{}) orelse break :coi;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            coi_dep.path("coi-serviceworker.min.js"),
            .prefix,
            "coi-serviceworker.min.js",
        ).step);
    }
}

fn compileMusic(b: *std.Build) void {
    const pmdc_dep = b.dependency("pmdc", .{
        .target = b.graph.host,
        .optimize = .Debug,
        .lang = "en",
    });
    const mc = pmdc_dep.artifact("mc");
    for (directory.pmd) |song| {
        const run_mc = b.addRunArtifact(mc);
        run_mc.cwd = b.path("pmd");
        run_mc.clearEnvironment();
        run_mc.addArg(song.source);
        run_mc.addFileInput(b.path(b.fmt("pmd/{s}", .{song.source})));
        run_mc.addCheck(.{ .expect_term = .{ .Exited = 0 } });
        run_mc.has_side_effects = true;

        const copy = b.addInstallFileWithDir(
            b.path(b.fmt("pmd/{s}", .{song.file})),
            .prefix,
            song.file,
        );
        copy.step.dependOn(&run_mc.step);
        b.getInstallStep().dependOn(&copy.step);
    }

    const write_files = b.addWriteFiles();
    const write_directory = write_files.add("directory.json", b.fmt("{f}", .{std.json.fmt(directory, .{})}));
    b.getInstallStep().dependOn(&b.addInstallFile(write_directory, "directory.json").step);
}
