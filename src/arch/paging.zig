// Собственные таблицы страниц: identity-map всей памяти из карты UEFI (2 МиБ-страницы),
// MMIO — uncached, framebuffer — write-combining (через PAT), mapMmio() для драйверов.
const arch = @import("x86_64.zig");
const boot = @import("boot.zig");
const pmm = @import("pmm.zig");

const P: u64 = 1 << 0;
const RW: u64 = 1 << 1;
const U: u64 = 1 << 2; // user-accessible ( ring 3 )
const PWT: u64 = 1 << 3;
const PCD: u64 = 1 << 4;
const PS: u64 = 1 << 7;
/// COW — software PTE bit (доступен в отсутствие shadow stack / protection keys).
const COW: u64 = 1 << 9;
const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const HUGE: usize = 2 * 1024 * 1024;

pub const Cache = enum { wb, wc, uc };

var pml4: [*]u64 = undefined;
/// Чистый снимок ядерных отображений до появления user-страниц. Каждая задача
/// клонирует его, поэтому aliases пользователя разных процессов не конфликтуют
/// в общем PML4 ядра (аналог отдельного mm_struct->pgd в Linux).
var kernel_template: u64 = 0;

fn newTable() [*]u64 {
    const a = pmm.allocFrame() orelse arch.halt();
    const t: [*]u64 = @ptrFromInt(a);
    @memset(t[0..512], 0);
    return t;
}

fn next(t: [*]u64, i: usize) [*]u64 {
    if ((t[i] & P) == 0) {
        const n = newTable();
        t[i] = @as(u64, @intFromPtr(n)) | P | RW;
        return n;
    }
    return @ptrFromInt(t[i] & ADDR_MASK);
}

/// Как next(), но все уровни таблицы доступны из ring 3 (U/S бит).
/// 2 МиБ-страницы ядерного identity-map нельзя использовать как таблицу —
/// иначе mapping пользователя испортит физическую память.
fn nextUser(t: [*]u64, i: usize) error{HugePageConflict}![*]u64 {
    if ((t[i] & P) == 0) {
        const n = newTable();
        t[i] = @as(u64, @intFromPtr(n)) | P | RW | U;
        return n;
    }
    if ((t[i] & PS) != 0) return error.HugePageConflict;
    return @ptrFromInt(t[i] & ADDR_MASK);
}

fn map2m(addr: usize, c: Cache) void {
    const l4: usize = (addr >> 39) & 511;
    const l3: usize = (addr >> 30) & 511;
    const l2: usize = (addr >> 21) & 511;
    const pd = next(next(pml4, l4), l3);
    const flags: u64 = switch (c) {
        .wb => 0,
        .wc => PWT, // PAT-индекс 1, перепрограммирован в WC
        .uc => PWT | PCD, // PAT-индекс 3 = UC
    };
    pd[l2] = @as(u64, addr) | P | RW | PS | flags;
}

fn mapRange(start: usize, len: usize, c: Cache) void {
    var a = start & ~(HUGE - 1);
    const end = (start + len + HUGE - 1) & ~(HUGE - 1);
    while (a < end) : (a += HUGE) map2m(a, c);
}

/// Физический адрес ядерного PML4 (для переключения CR3).
pub fn kernelCr3() u64 {
    return @intFromPtr(pml4);
}

/// Linux copy_pgdir(): отдельный PML4 процесса. Верхние уровни, описывающие
/// identity-map ядра, разделяются с ядерными (U/S бит не выставлен), поэтому
/// пользователь не может обратиться к памяти ядра, но прерывания видят стек
/// ядра ещё до переключения CR3 в common-handler.
fn cloneTemplate() u64 {
    const src: [*]const u64 = @ptrFromInt(if (kernel_template != 0) kernel_template else @intFromPtr(pml4));
    const fresh = newTable();
    @memcpy(fresh[0..512], src[0..512]);
    return @intFromPtr(fresh);
}

pub fn cloneKernelPml4() u64 {
    return cloneTemplate();
}

/// Отдельный PML4 для копирования пользовательских буферов ядром: те же
/// ядерные отображения, но свои 4 КиБ-таблицы для user-адресов.
pub fn newKernelAlias() u64 {
    return cloneTemplate();
}

/// user mapping: 4 КиБ-страница с битом U/S на всех уровнях. Вызывается и для
/// ядерного PML4 — syscall entry меняет CR3, но ядро должно видеть буферы
/// пользователя по тем же виртуальным адресам.
pub fn mapUserPage(pml4_phys: u64, virt: usize, phys: usize) error{HugePageConflict}!void {
    return mapUserPageProt(pml4_phys, virt, phys, true);
}

/// Как mapUserPage(), но с RW-битом по vm_flags (PROT_WRITE из VMA).
pub fn mapUserPageProt(pml4_phys: u64, virt: usize, phys: usize, writable: bool) error{HugePageConflict}!void {
    const root: [*]u64 = @ptrFromInt(pml4_phys);
    const l4: usize = (virt >> 39) & 511;
    const l3: usize = (virt >> 30) & 511;
    const l2: usize = (virt >> 21) & 511;
    const l1: usize = (virt >> 12) & 511;
    const pt = try nextUser(try nextUser(try nextUser(root, l4), l3), l2);
    if ((pt[l1] & P) != 0) return; // уже отображено
    var e: u64 = @as(u64, phys) | P | U;
    if (writable) e |= RW;
    pt[l1] = e;
}

/// protection_map[] для уже отображённой страницы: sys_mprotect() меняет
/// vm_flags в VMA, а этот вызов синхронизирует PTE в обоих PML4.
pub fn setUserPageWritable(pml4_phys: u64, virt: usize, writable: bool) bool {
    var table: [*]u64 = @ptrFromInt(pml4_phys);
    const levels = [4]usize{ (virt >> 39) & 511, (virt >> 30) & 511, (virt >> 21) & 511, (virt >> 12) & 511 };
    for (levels, 0..) |idx, depth| {
        const e = table[idx];
        if ((e & P) == 0) return false;
        if (depth == 3) {
            table[idx] = if (writable) e | RW else e & ~RW;
            return true;
        }
        if ((e & PS) != 0) return false;
        table = @ptrFromInt(e & ADDR_MASK);
    }
    return false;
}

/// copy_page_range()/copy_p4d_range(): отдельный PML4 для fork. Таблицы
/// пользователя копируются рекурсивно, supervisor identity-map остаётся общей.
/// Present+Writable PTE становятся read-only с COW-битом в обоих процессах.
fn cloneUserTable(old: [*]const u64, depth: usize) [*]u64 {
    const fresh = newTable();
    for (0..512) |i| {
        const e = old[i];
        if ((e & P) == 0 or (e & U) == 0) {
            fresh[i] = e;
            continue;
        }
        if (depth == 3) {
            if ((e & RW) == 0) {
                fresh[i] = e;
            } else {
                fresh[i] = (e & ~RW) | COW;
                @as([*]u64, @ptrFromInt(@intFromPtr(old)))[i] = (e & ~RW) | COW;
            }
        } else if ((e & PS) == 0) {
            const child = cloneUserTable(@ptrFromInt(e & ADDR_MASK), depth + 1);
            fresh[i] = @as(u64, @intFromPtr(child)) | (e & 0xFFF);
        } else {
            fresh[i] = e;
        }
    }
    return fresh;
}

/// fork() в ring3: свой PML4 с COW-отображениями общих 4 КиБ-страниц.
pub fn cloneUserPml4(parent_phys: u64) u64 {
    const parent: [*]const u64 = @ptrFromInt(parent_phys);
    const child = cloneUserTable(parent, 0);
    return @intFromPtr(child);
}

fn userPte(pml4_phys: u64, virt: usize) ?*u64 {
    var table: [*]u64 = @ptrFromInt(pml4_phys);
    const levels = [4]usize{ (virt >> 39) & 511, (virt >> 30) & 511, (virt >> 21) & 511, (virt >> 12) & 511 };
    for (levels, 0..) |idx, depth| {
        const e = table[idx];
        if ((e & P) == 0 or (e & U) == 0) return null;
        if (depth == 3) return &table[idx];
        if ((e & PS) != 0) return null;
        table = @ptrFromInt(e & ADDR_MASK);
    }
    return null;
}

pub fn isUserPageCow(pml4_phys: u64, virt: usize) bool {
    const pte = userPte(pml4_phys, virt) orelse return false;
    return (pte.* & COW) != 0;
}

pub fn userPagePhys(pml4_phys: u64, virt: usize) ?usize {
    const pte = userPte(pml4_phys, virt) orelse return null;
    return @intCast(pte.* & ADDR_MASK);
}

/// handle_pte_fault() → COW-путь: новая физическая страница в PML4 текущего
/// процесса, родитель остаётся с COW-PTE и получит свой fault при записи.
pub fn resolveUserPageCow(pml4_phys: u64, virt: usize, phys: usize) bool {
    const pte = userPte(pml4_phys, virt) orelse return false;
    if ((pte.* & COW) == 0) return false;
    pte.* = (pte.* & ~(ADDR_MASK | COW)) | @as(u64, phys) | RW;
    return true;
}

/// file-backed MAP_PRIVATE: страница заполнена из файла, но первая запись
/// должна пройти через COW-путь handle_pte_fault().
pub fn markUserPageCow(pml4_phys: u64, virt: usize) bool {
    const pte = userPte(pml4_phys, virt) orelse return false;
    pte.* = (pte.* & ~RW) | COW;
    return true;
}

/// sys_munmap(): снять PTE в заданном PML4, вернув физический адрес страницы.
pub fn clearUserPage(pml4_phys: u64, virt: usize) ?usize {
    const pte = userPte(pml4_phys, virt) orelse return null;
    const phys: usize = @intCast(pte.* & ADDR_MASK);
    pte.* = 0;
    return phys;
}

/// syscall entry меняет CR3 на kernel PML4; ядро должно видеть ту же физическую
/// страницу, что и текущий процесс (особенно после COW — она уже другая).
pub fn syncUserPageToKernel(kernel_phys: u64, user_phys: u64, virt: usize) bool {
    const upte = userPte(user_phys, virt) orelse return false;
    const kpte = userPte(kernel_phys, virt) orelse return false;
    // Ядру нужна запись даже в COW-страницу пользователя.
    kpte.* = (kpte.* & ~(ADDR_MASK | COW)) | (upte.* & ADDR_MASK) | RW;
    return true;
}

/// ПТЕ меняются, пока CR3 = kernel: сбросить TLB обоих пользовательских PML4.
pub fn flushUserTlb(pml4_phys: u64) void {
    const saved = arch.readCr3();
    arch.writeCr3(@intCast(pml4_phys));
    arch.writeCr3(@intCast(saved));
}

/// pte_present() для 4 КиБ-страницы пользователя: проверяет все уровни.
/// Возвращает false, если страница ещё не выделена (demand paging) или если
/// на пути лежит 2 МиБ-страница ядра — такую запись нельзя перезаписать PTE.
pub fn isUserPageMapped(pml4_phys: u64, virt: usize) bool {
    var table: [*]u64 = @ptrFromInt(pml4_phys);
    const levels = [4]usize{ (virt >> 39) & 511, (virt >> 30) & 511, (virt >> 21) & 511, (virt >> 12) & 511 };
    for (levels, 0..) |idx, depth| {
        const e = table[idx];
        if ((e & P) == 0) return false;
        if (depth == 3) return true; // PTE пользователя присутствует
        if ((e & PS) != 0) return false; // huge page: 4 КиБ-страницы здесь нет
        table = @ptrFromInt(e & ADDR_MASK);
    }
    return false;
}

pub fn init() void {
    // PAT: запись 1 (PWT=1) -> Write-Combining (0x01); остальные — по умолчанию.
    var pat = arch.rdmsr(0x277);
    pat = (pat & ~(@as(u64, 0xFF) << 8)) | (@as(u64, 0x01) << 8);
    arch.wrmsr(0x277, pat);

    pml4 = newTable();
    for (boot.info.regions) |r| {
        if (r.kind != .mmio) mapRange(r.start, r.pages * pmm.PAGE, .wb);
    }
    for (boot.info.regions) |r| {
        if (r.kind == .mmio) mapRange(r.start, r.pages * pmm.PAGE, .uc);
    }
    const i = boot.info;
    mapRange(i.fb_base, @as(usize, i.fb_stride) * i.fb_height * 4, .wc);

    kernel_template = cloneTemplate();
    arch.writeCr3(@intFromPtr(pml4));
}

/// Отображает физический диапазон регистров устройства (uncached, identity).
/// Возвращает адрес, по которому можно обращаться (равен физическому).
pub fn mapMmio(phys: usize, len: usize) void {
    mapRange(phys, len, .uc);
    arch.writeCr3(@intFromPtr(pml4)); // сброс TLB
}
