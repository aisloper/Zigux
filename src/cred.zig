//! Порт include/linux/cred.h, kernel/cred.c, kernel/capability.c (Linux 7.3).
//! Упрощения: credentials хранятся по значению в task_struct (в ядре —
//! refcounted struct cred с copy-on-write), группы фиксированы, нет LSM,
//! user namespaces и file capabilities из xattr.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");

pub const Cap = struct {
    pub const CHOWN: u6 = 0;
    pub const DAC_OVERRIDE: u6 = 1;
    pub const DAC_READ_SEARCH: u6 = 2;
    pub const FOWNER: u6 = 3;
    pub const FSETID: u6 = 4;
    pub const KILL: u6 = 5;
    pub const SETGID: u6 = 6;
    pub const SETUID: u6 = 7;
    pub const SETPCAP: u6 = 8;
    pub const LINUX_IMMUTABLE: u6 = 9;
    pub const NET_BIND_SERVICE: u6 = 10;
    pub const NET_BROADCAST: u6 = 11;
    pub const NET_ADMIN: u6 = 12;
    pub const NET_RAW: u6 = 13;
    pub const IPC_LOCK: u6 = 14;
    pub const IPC_OWNER: u6 = 15;
    pub const SYS_MODULE: u6 = 16;
    pub const SYS_RAWIO: u6 = 17;
    pub const SYS_CHROOT: u6 = 18;
    pub const SYS_PTRACE: u6 = 19;
    pub const SYS_PACCT: u6 = 20;
    pub const SYS_ADMIN: u6 = 21;
    pub const SYS_BOOT: u6 = 22;
    pub const SYS_NICE: u6 = 23;
    pub const SYS_RESOURCE: u6 = 24;
    pub const SYS_TIME: u6 = 25;
    pub const SYS_TTY_CONFIG: u6 = 26;
    pub const MKNOD: u6 = 27;
    pub const LEASE: u6 = 28;
    pub const AUDIT_WRITE: u6 = 29;
    pub const AUDIT_CONTROL: u6 = 30;
    pub const SETFCAP: u6 = 31;
    pub const MAC_OVERRIDE: u6 = 32;
    pub const MAC_ADMIN: u6 = 33;
    pub const SYSLOG: u6 = 34;
    pub const WAKE_ALARM: u6 = 35;
    pub const BLOCK_SUSPEND: u6 = 36;
    pub const AUDIT_READ: u6 = 37;
    pub const PERFMON: u6 = 38;
    pub const BPF: u6 = 39;
    pub const CHECKPOINT_RESTORE: u6 = 40;
};

pub const CAP_LAST_CAP: u6 = Cap.CHECKPOINT_RESTORE;
pub const CAP_FULL: u64 = (@as(u64, 1) << (CAP_LAST_CAP + 1)) - 1;

pub const CapSet = struct {
    bits: u64 = 0,

    pub fn has(self: CapSet, cap: u6) bool {
        return self.bits & (@as(u64, 1) << cap) != 0;
    }

    pub fn add(self: *CapSet, cap: u6) void {
        self.bits |= @as(u64, 1) << cap;
    }

    pub fn del(self: *CapSet, cap: u6) void {
        self.bits &= ~(@as(u64, 1) << cap);
    }
};

/// include/linux/securebits.h.
pub const SecureBits = struct {
    pub const NOROOT: u32 = 1 << 0;
    pub const NOROOT_LOCKED: u32 = 1 << 1;
    pub const NO_SETUID_FIXUP: u32 = 1 << 2;
    pub const NO_SETUID_FIXUP_LOCKED: u32 = 1 << 3;
    pub const KEEP_CAPS: u32 = 1 << 4;
    pub const KEEP_CAPS_LOCKED: u32 = 1 << 5;
};

/// include/linux/cred.h: struct cred (упрощённый).
pub const Cred = struct {
    uid: u32 = 0,
    gid: u32 = 0,
    suid: u32 = 0,
    sgid: u32 = 0,
    euid: u32 = 0,
    egid: u32 = 0,
    fsuid: u32 = 0,
    fsgid: u32 = 0,

    cap_permitted: CapSet = .{},
    cap_effective: CapSet = .{},
    cap_inheritable: CapSet = .{},
    securebits: u32 = 0,
    no_new_privs: bool = false,

    groups: [16]u32 = @splat(0),
    ngroups: u8 = 0,

    /// prepare_kernel_cred(NULL): root с полным набором capabilities.
    pub fn kernelRoot() Cred {
        var c = Cred{};
        c.cap_permitted.bits = CAP_FULL;
        c.cap_effective.bits = CAP_FULL;
        return c;
    }

    /// kernel/capability.c: capable() с учётом securebits NOROOT.
    pub fn capable(self: *const Cred, cap: u6) bool {
        if (self.cap_effective.has(cap)) return true;
        return self.euid == 0 and (self.securebits & SecureBits.NOROOT) == 0;
    }

    /// syscall setresuid(): unprivileged может только переставлять r/e/s.
    pub fn setresuid(self: *Cred, r: u32, e: u32, s: u32) !void {
        const priv = self.capable(Cap.SETUID);
        if (!priv) {
            if (r != self.uid and r != self.euid and r != self.suid) return error.EPERM;
            if (e != self.uid and e != self.euid and e != self.suid) return error.EPERM;
            if (s != self.uid and s != self.euid and s != self.suid) return error.EPERM;
        }
        self.uid = r;
        self.euid = e;
        self.suid = s;
        self.fsuid = e; // fsuid следует за euid (Linux setresuid).
        self.applyUidFixups();
    }

    pub fn setresgid(self: *Cred, r: u32, e: u32, s: u32) !void {
        const priv = self.capable(Cap.SETGID);
        if (!priv) {
            if (r != self.gid and r != self.egid and r != self.sgid) return error.EPERM;
            if (e != self.gid and e != self.egid and e != self.sgid) return error.EPERM;
            if (s != self.gid and s != self.egid and s != self.sgid) return error.EPERM;
        }
        self.gid = r;
        self.egid = e;
        self.sgid = s;
        self.fsgid = e;
    }

    /// setuid(): root меняет все три ID; остальные — только effective.
    pub fn setuid(self: *Cred, uid: u32) !void {
        if (self.capable(Cap.SETUID)) {
            try self.setresuid(uid, uid, uid);
            return;
        }
        if (uid != self.uid and uid != self.suid) return error.EPERM;
        self.euid = uid;
        self.fsuid = uid;
        self.applyUidFixups();
    }

    /// fs/exec.c: bprm_creds_for_exec() — set-user-ID/set-group-ID и cap reset.
    /// Возвращает новую cred-структуру; вызывающий заменяет euid/fsuid и caps.
    pub fn forExec(self: *const Cred, mode: u32, file_uid: u32, file_gid: u32) Cred {
        var c = self.*;
        c.no_new_privs = self.no_new_privs;
        if (self.no_new_privs) return c;

        if (mode & 0x800 != 0) { // S_ISUID
            c.euid = file_uid;
            c.suid = file_uid;
            c.fsuid = file_uid;
            c.cap_permitted.bits = CAP_FULL;
            c.cap_effective.bits = CAP_FULL;
        }
        if (mode & 0x400 != 0) { // S_ISGID
            c.egid = file_gid;
            c.sgid = file_gid;
            c.fsgid = file_gid;
        }
        c.applyUidFixups();
        return c;
    }

    fn applyUidFixups(self: *Cred) void {
        if (self.securebits & SecureBits.NO_SETUID_FIXUP != 0) return;
        if (self.euid == 0) {
            self.cap_effective.bits = self.cap_permitted.bits;
        } else {
            self.cap_effective.bits = 0;
        }
    }
};

test "credentials: root capabilities and setuid fixups" {
    var c = Cred.kernelRoot();
    try std.testing.expect(c.capable(Cap.SYS_ADMIN));
    try c.setuid(1000);
    try std.testing.expectEqual(@as(u32, 1000), c.euid);
    try std.testing.expect(!c.capable(Cap.SYS_ADMIN)); // euid != 0 → сброс effective
    try std.testing.expectError(error.EPERM, c.setuid(0)); // suid уже 1000
}

test "credentials: setresuid rules for unprivileged process" {
    // Привилегированный процесс задаёт saved set-user-ID, затем навсегда
    // отказывается от root — дальше допустимы только перестановки r/e/s.
    var c = Cred.kernelRoot();
    try c.setresuid(1000, 1000, 2000);
    try std.testing.expectError(error.EPERM, c.setresuid(0, 0, 0));
    try std.testing.expectError(error.EPERM, c.setresuid(1000, 3000, 2000));

    try c.setuid(2000); // euid ← saved set-user-ID
    try std.testing.expectEqual(@as(u32, 2000), c.euid);
    try std.testing.expectEqual(@as(u32, 2000), c.fsuid);
    try std.testing.expectError(error.EPERM, c.setuid(0));
}

test "credentials: exec setuid binary raises euid/caps, no_new_privs blocks it" {
    const c = Cred{ .uid = 1000, .euid = 1000, .suid = 1000, .fsuid = 1000 };
    const exec = c.forExec(0x800 | 0o755, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), exec.euid);
    try std.testing.expect(exec.capable(Cap.CHOWN));

    var restricted = c;
    restricted.no_new_privs = true;
    const exec2 = restricted.forExec(0x800 | 0o755, 0, 0);
    try std.testing.expectEqual(@as(u32, 1000), exec2.euid);
    try std.testing.expect(!exec2.capable(Cap.CHOWN));
}
