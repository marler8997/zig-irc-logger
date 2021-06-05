const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    try addLogger(b, target, mode);
    try addPublisher(b, target, mode);
    try addWebServer(b, target, mode);
}

fn addLogger(b: *std.build.Builder, target: anytype, mode: anytype) !void {
    const exe = b.addExecutable("zig-irc-logger", "zig-irc-logger.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    if (unwrapOptionalBool(b.option(bool, "ssl", "enable ssl"))) {
        const iguana_index_file = try (GitRepo {
            .url = "https://github.com/alexnask/iguanaTLS",
            .branch = null,
            .sha = "aefd468513d578576e2b1b23f3b8e2eabcfda560",
        }).resolveOneFile(b.allocator, "src" ++ std.fs.path.sep_str ++ "main.zig");
        exe.addPackage(.{
            .name = "ssl",
            .path = "iguanassl.zig",
            .dependencies = &[_]std.build.Pkg {
                .{ .name = "iguana", .path = iguana_index_file },
            },
        });
    } else {
        exe.addPackagePath("ssl", "nossl.zig");
    }

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-logger", "Run the zig-irc-logger exe");
    run_step.dependOn(&run_cmd.step);
}

fn addPublisher(b: *std.build.Builder, target: anytype, mode: anytype) !void {
    const exe = b.addExecutable("zig-irc-publisher", "publisher.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-publisher", "Run the zig-irc-publisher exe");
    run_step.dependOn(&run_cmd.step);
}

fn addWebServer(b: *std.build.Builder, target: anytype, mode: anytype) !void {
    const apple_pie_index = try (GitRepo {
        .url = "https://github.com/luukdegram/apple_pie",
        .branch = null,
        .sha = "4d03dbde35ade01eaba05963238c5afa408aa057",
    }).resolveOneFile(b.allocator, "src" ++ std.fs.path.sep_str ++ "apple_pie.zig");
    const exe = b.addExecutable("serve", "serve.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("apple_pie", apple_pie_index);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-web-server", "Run the web-server");
    run_step.dependOn(&run_cmd.step);
}

pub fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub const GitRepo = struct {
    url: []const u8,
    branch: ?[]const u8,
    sha: []const u8,
    path: ?[]const u8 = null,

    pub fn defaultReposDir(allocator: *std.mem.Allocator) ![]const u8 {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        return try std.fs.path.join(allocator, &[_][]const u8 { cwd, "dep" });
    }

    pub fn resolve(self: GitRepo, allocator: *std.mem.Allocator) ![]const u8 {
        var optional_repos_dir_to_clean: ?[]const u8 = null;
        defer {
            if (optional_repos_dir_to_clean) |p| {
                allocator.free(p);
            }
        }

        const path = if (self.path) |p| try allocator.dupe(u8, p) else blk: {
            const repos_dir = try defaultReposDir(allocator);
            optional_repos_dir_to_clean = repos_dir;
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ repos_dir, std.fs.path.basename(self.url) });
        };
        errdefer allocator.free(path);

        std.fs.accessAbsolute(path, std.fs.File.OpenFlags { .read = true }) catch |err| {
            std.debug.print("Error: repository '{s}' does not exist\n", .{path});
            std.debug.print("       Run the following to clone it:\n", .{});
            const branch_args = if (self.branch) |b| &[2][]const u8 {" -b ", b} else &[2][]const u8 {"", ""};
            std.debug.print("       git clone {s}{s}{s} {s} && git -C {3s} checkout {s} -b for-zig-irc-logger\n",
                .{self.url, branch_args[0], branch_args[1], path, self.sha});
            std.os.exit(1);
        };

        // TODO: check if the SHA matches an print a message and/or warning if it is different

        return path;
    }

    pub fn resolveOneFile(self: GitRepo, allocator: *std.mem.Allocator, index_sub_path: []const u8) ![]const u8 {
        const repo_path = try self.resolve(allocator);
        defer allocator.free(repo_path);
        return try std.fs.path.join(allocator, &[_][]const u8 { repo_path, index_sub_path });
    }
};
