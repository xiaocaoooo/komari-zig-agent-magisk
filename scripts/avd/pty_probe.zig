// PTY 可达性探针（AVD Shell Root 验证用，不进仓库）
// 目的：验证 musl 静态链接的 aarch64 二进制在 Android 上能真实分配 pty、
// 通过 master fd 写入命令、读回真实输出。这正是 Web SSH / Terminal 功能的前置条件。
const std = @import("std");

extern fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const anyopaque) c_int;
extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn usleep(usec: c_uint) c_int;

pub fn main() !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(std.Options.debug_io, &stdout_buf);
    const out = &stdout.interface;

    var master_fd: c_int = -1;
    const pid = forkpty(&master_fd, null, null, null);
    if (pid < 0) {
        try out.print("FORKPTY_FAILED errno={d}\n", .{std.c._errno().*});
        try out.flush();
        return;
    }
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/system/bin/sh", "-c", "echo PTY_ROUNDTRIP_OK; id -u; tty", null };
        _ = execvp("/system/bin/sh", &argv);
        std.c._exit(127);
    }

    try out.print("forkpty pid={d} master_fd={d}\n", .{ pid, master_fd });
    // 给子进程一点时间产出输出
    _ = usleep(300_000);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        const n = read(master_fd, &buf, buf.len);
        if (n <= 0) break;
        total += @intCast(n);
        try out.print("READ[{d}] {s}", .{ n, buf[0..@intCast(n)] });
    }
    try out.print("\ntotal_bytes={d}\n", .{total});

    // 测试向 pty 写入：发送一个命令并读回结果
    const cmd = "echo WRITE_PATH_OK\n";
    _ = write(master_fd, cmd.ptr, cmd.len);
    _ = usleep(300_000);
    const n2 = read(master_fd, &buf, buf.len);
    if (n2 > 0) {
        try out.print("WRITE_ECHO[{d}] {s}\n", .{ n2, buf[0..@intCast(n2)] });
    } else {
        try out.print("WRITE_ECHO n={d}\n", .{n2});
    }
    try out.flush();

    _ = std.c.kill(pid, std.posix.SIG.KILL);
    _ = std.c.waitpid(pid, null, 0);
}
