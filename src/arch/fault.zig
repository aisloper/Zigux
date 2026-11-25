//! Обработчик #PF из ring 3: порт handle_mm_fault()/do_anonymous_page() из
//! mm/memory.c. Права и тип отображения берутся из vm_area_struct процесса,
//! а не из отдельного списка: VMA — единственный источник правды о памяти.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const x86 = @import("x86_64.zig");
const idt = @import("idt.zig");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const printk = @import("printk.zig");
const arch_sched = @import("sched.zig");
const percpu = @import("percpu.zig");
const vma = @import("../mm/vma.zig");

const MAX_PAGES_PER_CALL: usize = 64;

fn currentVmas() ?*vma.VmAreaTree {
    const t = arch_sched.current() orelse return null;
    const mm = t.mm orelse return null;
    return &mm.vmas;
}

/// access_ok(): адрес пользователя должен лежать в VMA текущего mm.
pub fn accessOk(addr: usize, len: usize) bool {
    const vmas = currentVmas() orelse return false;
    const end = std.math.add(usize, addr, len) catch return false;
    const v = vmas.find(@intCast(addr)) orelse return false;
    if (len == 0) return true;
    return vmas.find(@intCast(end - 1)) != null and v.vm_start <= end - 1;
}

/// get_user_pages(): убедиться, что диапазон пользователя отображён, до
/// копирования буфера системным вызовом. Страницы anon-VMA создаются здесь же.
pub fn ensureRange(start: usize, end: usize) bool {
    const st = percpu.current();
    const kcr3 = st.kcr3;
    const ucr3 = st.ucr3;
    if (kcr3 == 0 or ucr3 == 0) return false;
    const vmas = currentVmas() orelse return false;
    x86.cli();
    var page = start & ~(pmm.PAGE - 1);
    var count: usize = 0;
    while (page < end and count < MAX_PAGES_PER_CALL) : ({
        page += pmm.PAGE;
        count += 1;
    }) {
        const v = vmas.find(@intCast(page)) orelse return false;
        if (!paging.isUserPageMapped(kcr3, page)) {
            const phys = pmm.allocFrame() orelse return false;
            const dst = @as([*]u8, @ptrFromInt(phys))[0..pmm.PAGE];
            @memset(dst, 0);
            const shared = v.vm_flags & vma.VM_SHARED != 0;
            if (v.vm_file) |f| {
                // mm/memory.c: do_file_page() — read() из struct file в новую страницу.
                const page_off: u64 = @as(u64, @intCast(page)) - v.vm_start;
                const off = std.math.add(u64, v.vm_pgoff * @as(u64, pmm.PAGE), page_off) catch return false;
                _ = f.readAt(dst, off); // короткое чтение оставляет хвост нулями
            }
            const writable = v.vm_flags & vma.VM_WRITE != 0 and (v.vm_file == null or shared);
            paging.mapUserPageProt(kcr3, page, phys, writable) catch return false;
            paging.mapUserPageProt(ucr3, page, phys, writable) catch return false;
            // MAP_PRIVATE file-backed: запись должна идти через COW, как в Linux.
            if (v.vm_file != null and !shared) _ = paging.markUserPageCow(ucr3, page);
        }
        // kernel PTE должен указывать на текущую (возможно COW) страницу процесса.
        if (!paging.syncUserPageToKernel(kcr3, ucr3, page)) return false;
    }
    x86.writeCr3(@intCast(kcr3)); // сброс TLB после новых PTE
    return true;
}

/// sys_munmap(): убрать PTE из kernel/user PML4. COW-страницы не освобождаются —
/// ими могут ещё пользоваться родитель/ребёнок после fork (anon_vma пока нет).
pub fn unmapRange(start: usize, end: usize) bool {
    const st = percpu.current();
    const kcr3 = st.kcr3;
    const ucr3 = st.ucr3;
    if (kcr3 == 0 or ucr3 == 0) return false;
    x86.cli();
    var page = start & ~(pmm.PAGE - 1);
    var count: usize = 0;
    while (page < end and count < MAX_PAGES_PER_CALL) : ({
        page += pmm.PAGE;
        count += 1;
    }) {
        const cow = paging.isUserPageCow(ucr3, page);
        const uphys = paging.clearUserPage(ucr3, page);
        _ = paging.clearUserPage(kcr3, page);
        if (!cow) {
            if (uphys) |phys| pmm.free(phys, 1);
        }
    }
    x86.writeCr3(@intCast(kcr3));
    paging.flushUserTlb(ucr3);
    return true;
}

/// handle_mm_fault(): true означает, что #PF устранён и можно вернуться в ring 3.
pub fn handlePageFault(f: *idt.Frame) bool {
    if (f.vector != 14) return false;
    const addr: usize = @intCast(x86.readCr2());
    const vmas = currentVmas() orelse return false;
    const v = vmas.find(@intCast(addr)) orelse return false;
    // handle_pte_fault(): P=1 и W=1 по COW-PTE → скопировать страницу.
    if ((f.error_code & 1) != 0) {
        if ((f.error_code & 2) == 0 or v.vm_flags & vma.VM_WRITE == 0) return false;
        const page = addr & ~(pmm.PAGE - 1);
        const st = percpu.current();
        const kcr3 = st.kcr3;
        const ucr3 = st.ucr3;
        if (ucr3 == 0 or !paging.isUserPageCow(ucr3, page)) return false;
        const old_phys = paging.userPagePhys(ucr3, page) orelse return false;
        const new_phys = pmm.allocFrame() orelse return false;
        @memcpy(@as([*]u8, @ptrFromInt(new_phys))[0..pmm.PAGE], @as([*]const u8, @ptrFromInt(old_phys))[0..pmm.PAGE]);
        if (!paging.resolveUserPageCow(ucr3, page, new_phys)) {
            pmm.free(new_phys, 1);
            return false;
        }
        _ = paging.syncUserPageToKernel(kcr3, ucr3, page);
        paging.flushUserTlb(ucr3);
        printk.print("ziglinux: cow page at {x:0>16}\n", .{page});
        return true;
    }
    const write = (f.error_code & 2) != 0;
    const exec = (f.error_code & 16) != 0;
    if (exec) {
        if (v.vm_flags & vma.VM_EXEC == 0) return false;
    } else if (write) {
        if (v.vm_flags & vma.VM_WRITE == 0) return false;
    } else if (v.vm_flags & vma.VM_READ == 0) {
        return false;
    }
    const page = addr & ~(pmm.PAGE - 1);
    const ok = ensureRange(page, page + pmm.PAGE);
    if (ok) {
        printk.print("ziglinux: {s} page at {x:0>16}\n", .{ if (v.vm_file != null) "file" else "demand", page });
    }
    return ok;
}
