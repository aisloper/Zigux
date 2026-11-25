// Тонкая обёртка над инструкциями x86_64.

pub const DescPtr = packed struct { limit: u16, base: u64 };

pub inline fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "{dx}" (port),
    );
}
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}
pub inline fn outw(port: u16, v: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (v),
          [p] "{dx}" (port),
    );
}
pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[p], %[r]"
        : [r] "={ax}" (-> u16),
        : [p] "{dx}" (port),
    );
}
pub inline fn outl(port: u16, v: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (v),
          [p] "{dx}" (port),
    );
}
pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}

pub inline fn rflags() u64 {
    return asm volatile ("pushfq\n\tpopq %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn cli() void {
    asm volatile ("cli");
}
pub inline fn sti() void {
    asm volatile ("sti");
}
pub inline fn hlt() void {
    asm volatile ("hlt");
}
pub inline fn pause() void {
    asm volatile ("pause");
}
pub fn halt() noreturn {
    cli();
    while (true) hlt();
}

pub inline fn readCr2() u64 {
    return asm volatile ("movq %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn readCr3() u64 {
    return asm volatile ("movq %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn readCr4() u64 {
    return asm volatile ("movq %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn writeCr3(v: usize) void {
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub inline fn wrmsr(msr: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
    );
}

pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

pub fn cpuid(leaf: u32, sub: u32) CpuidResult {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}
