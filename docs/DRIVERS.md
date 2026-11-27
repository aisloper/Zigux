# Драйверы: граница между ziglinux и zigos

Драйвера **не переписываются**. Они остаются в исходном виде в
`../extracted/zigos/src/`. На arch-этапе подключён serial:
`src/arch/drivers/serial.zig` скопирован без изменений и работает через
`TtyOps.write`/UART-опрос. Дополнительно в ziglinux написаны свои драйверы
`src/arch/drivers/pci.zig`, `virtio_blk.zig`, `virtio_scsi.zig`, `nvme.zig`,
`ahci.zig`, `disk.zig`, `console.zig`, `keyboard.zig`, `xhci.zig`, `src/gpt.zig`,
`src/device.zig`, `src/input.zig`, `src/hid.zig`, `src/stdio.zig`,
`src/vt.zig`, `src/ext4.zig`, `src/skb.zig`, `src/inet6.zig`, `src/net.zig`,
`src/tcp.zig`, `src/tcp_ca.zig`, `src/tcp_options.zig`, `src/netdev.zig`, `src/route.zig`, `src/ethernet.zig`,
`src/arp.zig`, `src/ipv4.zig`, `src/icmp.zig`, `src/icmp6.zig`, `src/qdisc.zig`, `src/napi.zig`, `src/fq_codel.zig`, `src/htb.zig`, `src/tcp_timers.zig`, `src/mld.zig`, `src/tcp_v6.zig`, `src/rx_mode.zig`,
    `src/usb_hotplug.zig`, `src/ncq.zig`, `src/drm.zig`,
    `src/igmp.zig`, `src/ip_defrag.zig`, `src/unix_sock.zig`,
    `src/ipv6_frag.zig`, `src/netlink.zig`, `src/cgroup.zig`,
    `src/cubic.zig`, `src/e1000.zig`,
`src/arch/drivers/virtio_net.zig` и `src/arch/drivers/font.zig` (legacy PCI,
read/write virtio-blk/virtio-scsi/NVMe/AHCI, boot-time GPT/MBR
scan и ext4 mount, PS/2-ввод, GOP-консоль, полный xHCI boot-keyboard,
декодирование HID, активный VT с Alt+Fn, TTY-backed stdio, overwrite и рост
файла ext4 через выделение блоков и разреженной записи, persistent creat/unlink,
mkdir/rmdir, JBD2-журнал с revoke/CRC32C/64-bit тегами, split extent-дерева
в корневом каталоге, net_device/ARP/IPv4 FIB и virtio-net NIC через
`DirOps`, файлы внутри подкаталогов, модель device/driver, `sk_buff`, socket
layer `AF_INET/SOCK_DGRAM`, `AF_INET/SOCK_STREAM` с TCP, `AF_INET6/SOCK_DGRAM`
с IPv6-checksum и ICMP echo через реальный NIC); файлы `zigos`
не изменялись.
В остальном переписано только ядро: TTY line
discipline, процессы/сигналы, планировщик, MM, VFS, syscall-слой и
arch-инфраструктура (UEFI/GDT/IDT/APIC/PIT/timer).

## Контракт

`src/tty.zig` определяет `TtyOps`:

```zig
pub const TtyOps = struct {
    ctx: ?*anyopaque = null,
    write: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
    signalPgrp: ?*const fn (ctx: ?*anyopaque, pgrp: u32, sig: u8) void = null,
};
```

- `write()` — вывод уже обработанных байтов (OPOST/ONLCR применены ядром).
  Драйвер просто отдаёт их в `console.write()` / `serial.write()`.
- `signalPgrp()` — job control: ^C/^\/^Z от драйвера клавиатуры. В `ziglinux`
  эта функция уже реализована в `src/init/main.zig` и зовёт
  `TaskManager.signalPgrp()`; `ctx` — указатель на `TaskManager`.

Ядро владеет: termios, входным кольцом 4096 байт, канонической строкой,
echo, `read_head`/`commit_head`/`canon_head`, session/pgrp и pending-сигналами.
Драйвер владеет: железом, сканкодами, framebuffer-ом, UART.

## Граница с файлами zigos

Как есть скопированы только `src/arch/drivers/serial.zig` (с заменой import
arch-слоя) и `src/arch/drivers/font.zig` как data-файл шрифта. Остальные
драйверы `zigos` остаются в исходном виде и используются как спецификация.

| Файл `zigos` (справочник) | Роль | Аналог в ziglinux |
|---|---|---|
| `src/serial.zig` | COM1 115200 8N1 | `src/arch/drivers/serial.zig`, скопирован без изменений логики |
| `src/keyboard.zig` | PS/2 + USB + UART ввод | `src/input.zig` + `src/arch/drivers/keyboard.zig` (PS/2, без UART-дублирования) |
| `src/console.zig` | GOP framebuffer, 8×16, VT100 | `src/arch/drivers/console.zig` (CR/LF/BS/scroll + diff, `swapState` для VT) |
| `src/font.zig` | 8×16 glyph bitmap | `src/arch/drivers/font.zig`, скопирован как есть |
| `src/hid.zig`, `src/xhci.zig` | HID boot keyboard и xHCI | `src/hid.zig` + `src/arch/drivers/xhci.zig` (полный boot-protocol transfer path) |
| `src/tty.zig` | VT switching, active_vt, Alt+Fn | `src/vt.zig` (Switcher/SwitchHook, маршрутизация в активный Tty) |
| `src/boot.zig`, `src/heap.zig`, `src/arch.zig` | загрузка, куча, port I/O | собственные `src/arch/boot.zig`, `src/arch/heap.zig`, `src/arch/x86_64.zig` |

## Потоки

**Ввод:** i8042 (port 0x60/0x64) → `input.Keyboard.feed()`, xHCI event ring →
HID report → `src/hid.zig` → `input.Keyboard` USB API; оба пути через
`keyboard.drain()` → `vt.Switcher.feedKey()` → `tty.receive()` активной
консоли → line discipline → `tty.read()`. `Alt+F1..F4` меняет активный VT и
вызывает `SwitchHook` → `console.swapState()` + `console.redraw()`. UART
читается отдельно через `arch_tty.poll()`, чтобы не терять байты. `user.pumpTty()`
вызывает все три источника и из idle loop, и из `file_operations.read()`.

**Вывод:** процесс → fd 1/2 → `stdio.Ops.write` → `tty.write()` активного VT
(OPOST/ONLCR) → `TtyOps.write` → `console.write()` (diff по ячейкам 8×16 в GOP
framebuffer) и `serial.puts()`. `printk` по-прежнему пишет только в UART.

**Сигналы:** `tty.receive()` видит VINTR/VQUIT/VSUSP → `TtyOps.signalPgrp`
→ `TaskManager.signalPgrp()` → `SigSet.pending` → `deliverSignals()`.

## Что сделано на arch-этапе

1. UEFI-вход `src/uefi.zig:EfiMain` → `src/arch/kmain.zig:kmain()` (GOP, RSDP,
   memory map, `ExitBootServices`, собственный стек).
2. `ctx_switch`, IDT/GDT/PIC/APIC/PIT привязаны к `task.TaskStruct` и
   `sched.CfsRq`; таймер 250 Гц кормит timer wheel и EEVDF.
3. `std.heap.DebugAllocator` заменён на `src/arch/heap.zig` — физические
   страницы из PMM; `start_kernel()` работает в UEFI без libc.
4. Serial подключён: `printk`/panic → COM1; UART → `Tty.receive()`.
5. Блочный срез (0.22.0): `pci.scan()` через `0xCF8`/`0xCFC` находит
   virtio-blk `1af4:1001`; `virtio_blk.initFromPci()` поднимает split
   virtqueue и отдаёт `block.Device`; `disk.scanAndMount()` разбирает MBR,
   читает раздел целиком и монтирует ext4 в `/mnt` namespace init-задачи.
   QEMU подключает `tests/data/boot-disk.img` как
   `virtio-blk-pci,disable-modern=true` и печатает `MBR partition 1 ext4
   mounted at /mnt`, `/mnt/hello.txt ino 13`.
6. Блочный срез 0.23.0: `src/gpt.zig` проверяет CRC и отдаёт разделы через
   `block.sliceDevice()`; `nvme.zig` поднимает admin/IO очереди и читает через
   PRP; `ahci.zig` исполняет IDENTIFY и READ DMA EXT через PRDT. Все три
   драйвера отдают `block.Device`, `disk.scanAndMount()` пробует GPT перед MBR.
   QEMU проверяет `-Ddisk-backend=virtio|nvme|ahci` с `-Dboot-disk=...` для
   MBR и GPT образов (шесть комбинаций, без паник).
7. Блочный срез 0.24.0: `virtio_scsi.zig` поднимает legacy virtio-scsi
   (`1af4:1004`), очереди 0/1/2, 51-байтовый request с CDB@19 и 108-байтовый
   response со sense; INQUIRY, READ CAPACITY(10) с повтором на unit attention,
   READ(10) и `block.Device`. `disk.scanAndMount()` различает SCSI по
   `1af4:1004`, QEMU проверяет `-Ddisk-backend=scsi` с MBR и GPT (восемь
   комбинаций backend × таблица разделов, без паник).
8. Срез 0.25.0: `src/device.zig` реализует минимальный драйверный core
   (`match` → `probe`, повторный `rescan`, `remove`), `src/input.zig` декодирует
   scancodes set-1, `src/arch/drivers/keyboard.zig` поднимает i8042 и кормит
   `tty.receive()`, `src/arch/drivers/console.zig` рисует в GOP и пишет в UART,
   `src/arch/drivers/xhci.zig` обнаруживает xHCI через PCI. `kmain()` связывает
   `vt-console`, `atkbd`, `xhci-pci` через device core; QEMU с `-Dusb-kbd=true`
   печатает `device core: console=bound atkbd=bound xhci=bound`,
   `atkbd i8042 present=yes ack=yes` и `tty1 ready` без паник.
9. Срез 0.26.0: `xhci.zig` поднимает event ring и interrupt-IN transfer для
   boot-клавиатуры, `hid.zig` декодирует HID report-ы с модификаторами и
   автоповтором, `stdio.zig` подключает fd 0/1/2 к `Tty.read`/`Tty.write`.
   `user.pumpTty()` объединяет PS/2, UART и xHCI; ring3 `write(1, ...)` снова
   проходит через TTY и остаётся видимым как `USER!`. QEMU с `-Dusb-kbd=true`
   печатает `[usb]   boot keyboard ready`, `xhci ... kbd=yes` и
   `stdio: fd 0/1/2 -> active tty pgrp 1` (235/235 host-тестов).
10. Срез 0.27.0: `src/vt.zig` реализует `active_vt` и `Alt+F1..F4`; PS/2 и HID
    идут в `Tty` активной консоли, `SwitchHook` меняет экраны через
    `console.swapState()`, `stdio.Ops` и ring3 `write(1, ...)` следуют за
    активным VT. QEMU печатает `tty1..tty4 ready` и
    `vt: 4 VTs, active=tty1, switches=4` (235/235 host-тестов).
11. Срез 0.28.0: `src/ext4.zig` добавляет `file_operations.write` для уже
    отображённых extent-ов, отслеживает грязные блоки и сбрасывает их в
    `super_operations.sync_fs`; `src/arch/drivers/virtio_blk.zig` исполняет
    `VIRTIO_BLK_T_OUT`, а `block.clonePartition()` удерживает `PartitionCtx`
    после mount. `disk.probeExt4Write()` с `-Dfs-write-probe=true` меняет
    `/mnt/hello.txt` на scratch-образе и печатает
    `ext4 write: ok readback=ok bytes=11 dirty=0 synced=8`.
12. Срез 0.29.0: `src/ext4.zig` добавляет first-fit аллокатор block bitmap,
    обновляет superblock/group descriptor/inode и вставляет лист в depth-0
    extent tree, предпроверяя ENOSPC до записи. `disk.probeExt4Grow()` с
    `-Dfs-grow-probe=true` дописывает 1100 байт к `/mnt/hello.txt` на
    scratch-образе и печатает
    `ext4 grow: ok readback=ok bytes=1100 size=1116 free=2732 dirty=0 synced=18`;
    `e2fsck -fn` на разделе проходит без ошибок (235/235 host-тестов).
13. Срез 0.30.0: `nvme.zig`, `ahci.zig` и `virtio_scsi.zig` получили
    `block.Device.write`: NVMe opcode `0x01` с read-modify-write внутри LBA,
    ATA WRITE DMA EXT (LBA48) с битом W в command header и SCSI WRITE(10) с
    device-readable data-out перед device-writable response. Host-тесты
    симулированных BAR проверяют write→read. QEMU с
    `-Ddisk-backend=nvme|ahci|scsi` и `-Dfs-write-probe=true` /
    `-Dfs-grow-probe=true` печатает `ext4 write: ok ...` и `ext4 grow: ok ...`,
    а `e2fsck -fn` scratch-раздела проходит чисто (235/235 host-тестов).
14. Срез 0.31.0: `vfs.zig` добавил `DirOps` и `Namespace.createAt()`/
    `unlinkAt()`; `ext4.zig` реализует first-fit inode bitmap, пересчёт
    `s_free_inodes_count`/`bg_free_inodes_count`, split `dir_entry_2` корневого
    каталога и освобождение extent-ов при unlink. `syscall.zig` направляет
    `creat`/`unlink` через `DirOps` смонтированного ext4, а `open()` получает
    `struct file` через `instantiate()`. `disk.probeExt4Namei()` с
    `-Dfs-namei-probe=true` печатает
    `ext4 namei: creat=ok unlink=ok readback=ok dirty=0 synced=18 errno=0`,
    а `e2fsck -fn` scratch-раздела проходит чисто (235/235 host-тестов).
15. Срез 0.32.0: `vfs.zig` добавил `DirOps.mkdir` и `Namespace.mkdirAt()`;
    `ext4.zig` выделяет inode и блок под новый каталог, пишет `.`/`..` и
    свободный хвост `dir_entry_2`, увеличивает `i_links_count` родителя и
    `bg_used_dirs_count`, а `vfs.zig` обновляет переиспользованный inode в
    `iget()`. `syscall.zig` направляет `mkdir` через `DirOps` смонтированного
    ext4. `disk.probeExt4Mkdir()` с `-Dfs-mkdir-probe=true`
    печатает `ext4 mkdir: mkdir=ok create=ok readback=ok unlink=ok dirty=0
    synced=18 errno=0`, а `e2fsck -fn` scratch-раздела проходит чисто
    (235/235 host-тестов).
16. Срез 0.33.0: `vfs.zig` добавил `DirOps.rmdir` и `Namespace.rmdirAt()`;
    `ext4.zig` проверяет пустоту каталога на носителе (только `.`/`..` и
    свободный хвост блока), удаляет имя из родителя, уменьшает
    `i_links_count` и `bg_used_dirs_count` и освобождает inode вместе с его
    extent-ами. `unlinkNode()` игнорирует снятые с хеша dentry при проверке
    потомков, `syscall.zig` направляет `rmdir` через `DirOps`. Проба
    `disk.probeExt4Rmdir()` с `-Dfs-rmdir-probe=true` печатает
    `ext4 rmdir: mkdir=ok nested=ok rmdir=ok dirty=0 synced=22 errno=0`,
    `e2fsck -fn` scratch-раздела проходит чисто (235/235 host-тестов).
17. Срез 0.34.0: `ext4.zig` нашёл внутренний journal inode по `s_journal_inum`,
    читает journal superblock и коммитит грязные блоки как JBD2-транзакцию:
    descriptor с 32-битными тегами и UUID, data blocks, commit block и
    `journal_superblock_t` с `s_start`. `INCOMPAT_RECOVER` выставляется до
    сброса целевых блоков и снимается только после чистки журнала; при
    монтировании с `INCOMPAT_RECOVER` транзакция воспроизводится. Проба
    `disk.probeExt4Journal()` с `-Dfs-journal-probe=true` печатает
    `ext4 journal: active=ok readback=ok commits=1 replays=0 start=0 dirty=0
    synced=8 errno=0`, `e2fsck -fn` scratch-раздела проходит чисто
    (235/235 host-тестов).
18. Срез 0.35.0: `ext4.zig` при переполнении корневого extent-листа выделяет
    metadata-блок, переносит туда старые extent-ы и превращает корень в индекс
    depth 1 (`ei_block`, `ei_leaf_lo`, `ei_leaf_hi`); исправлено чтение индексных
    указателей в `mapBlock()`. Новые блоки после split пишутся в тот же leaf,
    `i_blocks` учитывает metadata-блок, а грязный leaf уходит в той же JBD2-
    транзакции. Проба `disk.probeExt4Split()` с `-Dfs-split-probe=true`
    печатает `ext4 split: depth=1 readback=ok bytes=5120 size=5136 free=2727
    dirty=0 synced=28 errno=0`, `e2fsck -fn` scratch-раздела проходит чисто
    (235/235 host-тестов).
19. Срез 0.36.0: `ext4.zig` разрешает запись за EOF: extent вставляется по
    ключу `ee_block` (`insertExtentEntry`, `validateInsertion`), поэтому
    пропущенные логические блоки остаются дырами и читаются нулями без
    выделения физических блоков. Поддерживается и запись в уже существующую
    дыру внутри файла; split полного корня тоже вставляет extent по ключу.
    Проба `disk.probeExt4Sparse()` с `-Dfs-sparse-probe=true` печатает
    `ext4 sparse: hole=ok readback=ok bytes=512 size=8704 entries=2 depth=0
    free=2732 dirty=0 synced=16 errno=0`; `debugfs` показывает `(0):1362,
    (8):1363`, `e2fsck -fn` scratch-раздела проходит чисто (235/235 host-тестов).
    Матрица 0.36.0: загрузка 9/9 и пробы 64/64 на scratch-копиях MBR/GPT через
    virtio-blk, virtio-scsi, NVMe и AHCI, `e2fsck -fn` = 0 для каждой копии.
20. Срез 0.37.0: `ext4.zig` поддерживает split extent-дерева depth 1 -> 2:
    `findLeafPath()` находит leaf для логического блока, вставка идёт по
    `ee_block`, полный leaf делится пополам (`splitLeafAndInsert`), полный корень
    depth 1 превращается в depth 2 с двумя новыми индексными блоками
    (`splitRootIndex`), а полный внутренний узел depth 1 делится через
    `splitIndexNode`. Preflight проверяет целевую вставку и резервирует данные
    вместе с metadata; старый leaf и внутренний узел добавляются в грязные
    блоки. Проба `disk.probeExt4Depth2()` с `-Dfs-depth2-probe=true` на
    synthetic full-depth1 разделе печатает
    `ext4 depth2: depth=2 entries=2 hole=ok readback=ok bytes=1024 size=345088
    free=3742 dirty=0 synced=9 errno=0`; `debugfs` показывает `(ETB0)`, `(ETB1)`
    и 339 extent-ов на leaf, `e2fsck -fn` проходит чисто (235/235 host-тестов).
    Матрица 0.37.0: загрузка 9/9 и пробы 72/72 на scratch-копиях MBR/GPT через
    virtio-blk, virtio-scsi, NVMe и AHCI, `e2fsck -fn` = 0 для каждой копии.
21. Срез 0.38.0: `src/skb.zig` и `src/net.zig` добавляют первый сетевой
    вертикальный срез. `sk_buff` держит head/data/tail/end в линейном буфере
    с датарефом: `skb_put`, `skb_push`, `skb_pull`, `skb_trim`, `skb_clone`,
    `skb_copy`, `unshare`, `kfree_skb` и RFC 1071 checksum. Socket layer
    портирует `proto_ops` и `socket_state`: `AF_INET`/`SOCK_DGRAM`/`IPPROTO_UDP`,
    bind с `AddrInUse`, ephemeral-порты, loopback через `sk_buff` с UDP-checksum
    и псевдозаголовком IPv4. Boot-проба с `-Dnet-probe=true` печатает
    `net: ok skb=ok clone=ok csum=ok bind=ok loopback=ok recv=ok inuse=ok
    refused=ok bytes=10 queue=0 packets=1 drops=1 errno=0`. Итоговая матрица
    0.63.0: загрузка 9/9 и пробы 280/280 (тридцать пять probe × четыре блочных
    backend × MBR/GPT), `e2fsck -fn` = 0 для каждой scratch-копии.
22. Срез 0.39.0: `src/tcp.zig` добавляет `AF_INET/SOCK_STREAM` поверх `sk_buff`
    и socket layer. Портированы состояния `include/net/tcp_states.h`,
    `struct tcphdr`, контрольная сумма с IPv4-псевдозаголовком (`tcp_v4_check`),
    ISS/IRS, трёхстороннее установление соединения через `listen`/`accept`,
    передача потока по MSS с ACK и retransmit queue, FIN-закрытие и истечение
    `TIME_WAIT`. `src/net.zig` добавляет `IPPROTO_TCP`, отдельные TCP
    `proto_ops`, `listen`/`accept` и `Net.tick()`. Boot-проба с
    `-Dtcp-probe=true` печатает `tcp: ok checksum=ok handshake=ok stream=ok
    retransmit=ok close=ok bytes=10 segments=11 acks=4 state=CLOSE errno=0`.
    Матрица 0.63.0: загрузка 9/9 и пробы 280/280; `e2fsck -fn` = 0 для каждой
    scratch-копии (235/235 host-тестов).
23. Срез 0.63.0: `src/inet6.zig` добавляет `AF_INET6/SOCK_DGRAM` loopback.
    Портированы `struct in6_addr`/`struct sockaddr_in6`, `ipv6_addr_equal()`,
    `ipv6_addr_any()`, `ipv6_addr_loopback()`, `csum_ipv6_magic()` с 40-байтовым
    псевдозаголовком IPv6 и UDP-дейтаграммы поверх `sk_buff`. `src/net.zig`
    добавляет отдельный `proto_ops6`, `bind6`/`connect6`/`sendto6`/`recvfrom6`
    и IPv6-ephemeral-порты. Boot-проба с `-Dinet6-probe=true` печатает
    `inet6: ok addr=ok csum=ok bind=ok loopback=ok recv=ok inuse=ok refused=ok
    bytes=12 queue=0 packets=1 drops=1 errno=0`. Матрица 0.63.0: загрузка 9/9
    и пробы 280/280; `e2fsck -fn` = 0 для каждой scratch-копии
    (235/235 host-тестов).
24. Срез 0.63.0: `src/ext4.zig` расширяет JBD2 до revoke, checksum,
    64-битных тегов и wrap-around. Портированы CRC32C (`0x82f63b78`) с seed из
    UUID журнала, checksum `journal_superblock_t`, теги v2/v3 (12/14/16 байт)
    с checksum и старшими 32 битами номера блока, revoke-блоки с записями
    4/8 байт, порядок `JournalWriteBlock`/`revoke` (revoke после dirty
    побеждает, dirty после revoke отменяет revoke), кольцевой `wrap()` от
    `s_first` до `s_maxlen` и сравнение tid через `tid_geq()`. Recovery
    сканирует revoke до replay и проверяет checksum дескриптора, тегов,
    revoke и commit. Boot-проба `disk.probeExt4Jbd2()` с `-Djbd2-probe=true`
    включает `REVOKE|64BIT|CSUM_V3` на scratch-копии журнала, отзывает блок
    1363 и печатает
    `ziglinux: jbd2: active=ok features=ok csum=ok revoke=ok commit=ok
    readback=ok commits=1 replays=0 start=0 dirty=0 synced=9 errno=0`.
    Матрица 0.63.0: загрузка 9/9 и пробы 280/280 (тридцать пять probe × четыре
    блочных backend × MBR/GPT), `e2fsck -fn` = 0 для каждой scratch-копии
    (235/235 host-тестов).
25. Срез 0.63.0: netdev, IPv4 FIB и virtio-net NIC. `src/netdev.zig` портирует
    `net_device`/netdev_ops (`dev_queue_xmit`, `netif_rx`, `IFF_*`, ifindex,
    MTU, MAC, statistics, registry), `src/route.zig` — `flowi4`, `fib_result`,
    longest-prefix match с metric и iif. `src/ethernet.zig`, `src/arp.zig`,
    `src/ipv4.zig` и `src/icmp.zig` строят и проверяют ethhdr/arphdr/IPv4/ICMP
    echo. `src/arch/drivers/virtio_net.zig` поднимает legacy PCI NIC с
    `VIRTIO_NET_F_MAC`, 10-байтовым `virtio_net_hdr` и split RX/TX-очередями.
    Boot-проба `src/arch/drivers/net.zig` с `-Dnetdev-probe=true` регистрирует
    eth0, находит gateway через ARP и печатает
    `ziglinux: netdev: ok device=ok route=ok arp=ok icmp=ok
    mac=525400123456 ifindex=1 prefix=24 tx=2 rx=2 errno=0`. Матрица 0.63.0:
    загрузка 9/9 и пробы 280/280; `e2fsck -fn` = 0 для каждой scratch-копии
    (235/235 host-тестов).
26. Срез 0.63.0: TCP Reno congestion control. `src/tcp_ca.zig` переносит
    `tcp_slow_start()`, `tcp_cong_avoid_ai()`, `tcp_reno_ssthresh()`,
    `tcp_reno_undo_cwnd()`, состояния `TCP_CA_*` и fast retransmit после трёх
    dup ACK; по таймеру окно падает до одного сегмента. `src/tcp.zig` ведёт
    `packets_out`, ограничивает отправку через `snd_cwnd`, учитывает ACK и
    обрабатывает dup ACK как `tcp_fastretrans_alert()`. Boot-проба
    `-Dtcp-ca-probe=true` печатает
    `ziglinux: tcp-ca: ok reno=ok slow-start=ok avoidance=ok ssthresh=ok
    fast-retransmit=ok recovery=ok timeout=ok cwnd=1 threshold=8 dupacks=0
    state=Loss acks=10 errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280
    (235/235 host-тестов).
27. Срез 0.63.0: TCP window scale, SACK и RTO backoff. `src/tcp_options.zig`
    переносит `TCPOPT_WINDOW`, `TCPOPT_SACK_PERM`, `TCPOPT_SACK` и разбор
    `tcp_parse_options()`; `src/tcp.zig` согласует сдвиг окна в SYN/SYN-ACK,
    домасштабирует `snd_wnd`, кладёт внеочередные сегменты в очередь пропусков
    и посылает SACK, помечает SACK-ом подтверждённые сегменты и удваивает RTO
    на каждом новом таймауте. Boot-проба `-Dtcp-options-probe=true` печатает
    `ziglinux: tcp-opt: ok window-scale=ok sack=ok ofo=ok backoff=ok shift=7
    blocks=1 sacked=1 rto=200/400/800 errno=0`. Матрица 0.63.0: загрузка 9/9
    и пробы 280/280 (235/235 host-тестов).

28. Срез 0.63.0: ICMPv6 и NDP. `src/icmp6.zig` переносит echo
    request/reply, neighbor solicitation/advertisement, опции link-layer
    address, solicited-node multicast и небольшую таблицу соседей с переходами
    `Incomplete → Reachable → Stale`; checksum считается через
    `csum_ipv6_magic()` для IPPROTO_ICMPV6. Boot-проба `-Dicmp6-probe=true`
    печатает `ziglinux: icmp6: ok echo=ok checksum=ok ndp=ok multicast=ok
    state=Stale errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280
    (235/235 host-тестов).

29. Срез 0.63.0: queueing discipline, NAPI и SMP tasklist lock.
    `src/qdisc.zig` переносит `sch_default_prio2band`, `pfifo_fast` с тремя
    FIFO-полосами, limit и статистику; `src/napi.zig` переносит `napi_struct`,
    weight 64, `schedulePrep`/`complete` и `net_rx_action` с бюджетом 300 и
    repoll; `src/task.zig` добавляет spinlock вокруг pidhash/next_pid/children
    (аналог `tasklist_lock`), убирающий гонку параллельного `fork()` на BSP и
    AP. Boot-проба `-Dqueue-probe=true` печатает `ziglinux: queue: ok qdisc=ok
    priority=ok order=ok limit=ok napi=ok weight=ok schedule=ok budget=ok
    repoll=ok processed=24 errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы
    280/280 (235/235 host-тестов).

30. Срез 0.63.0: fq_codel. `src/fq_codel.zig` переносит classification по
    hash skb->priority через `reciprocal_scale()`, new/old round-robin-списки,
    deficit, `fq_codel_drop()` и CoDel с target/interval, Newton-шагом и ECN.
    Boot-проба `-Dfq-codel-probe=true` печатает `ziglinux: fqcodel: ok hash=ok
    rr=ok deficit=ok codel=ok ecn=ok overlimit=ok drops=2 marks=1 errno=0`.
    Матрица 0.63.0: загрузка 9/9 и пробы 280/280 (235/235 host-тестов).

31. Срез 0.63.0: HTB. `src/htb.zig` переносит иерархический token bucket:
    `psched_l2t_ns()`, классы root/leaf с rate/ceil и buffer/cbuffer,
    гистерезис, `htb_class_mode()`, заимствование у родителя и deficit
    round-robin по приоритетам. Boot-проба `-Dhtb-probe=true` печатает
    `ziglinux: htb: ok rate=ok ceil=ok borrow=ok prio=ok deficit=ok limit=ok
    errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280 (235/235
    host-тестов).

32. Срез 0.63.0: `src/tcp_timers.zig` переносит `tcp_write_timer()`,
    `tcp_retransmit_timer()`, `tcp_probe_timer()`/`tcp_send_probe0()`,
    `tcp_delack_timer()` и `tcp_keepalive_timer()` с константами RTO_MIN/MAX,
    TCP_RETRIES2, DELACK_MIN/MAX и keepalive 2 часа / 9 проб / 75 с. Boot-проба
    `-Dtcp-timers-probe=true` печатает `ziglinux: tcptimers: ok retrans=ok
    backoff=ok probe0=ok delack=ok keepalive=ok user-timeout=ok errno=0`.
    Матрица 0.63.0: загрузка 9/9 и пробы 280/280 (235/235 host-тестов).

33. Срез 0.63.0: `src/mld.zig` переносит MLDv1 query/report/done, MLDv2
    report с grec, кодирование MRC/QQIC из `include/net/mld.h`, router
    solicitation/advertisement и разбор ND-опций. Boot-проба
    `-Dmld-probe=true` печатает `ziglinux: mld: ok mld1=ok mld2=ok grec=ok
    mrc=ok qqic=ok ra=ok options=ok rs=ok errno=0`. Матрица 0.63.0: загрузка
    9/9 и пробы 280/280 (235/235 host-тестов).

34. Срез 0.63.0: `src/tcp_v6.zig` переносит `tcp_v6_check()`, разбор и сборку
    TCP-сегментов с IPv6-псевдозаголовком, таблицу сокетов по 4-кортежу,
    `tcp_v6_connect()`, `tcp_v6_send_synack()` и завершение handshake по ACK.
    Boot-проба `-Dtcpv6-probe=true` печатает `ziglinux: tcpv6: ok checksum=ok
    handshake=ok lookup=ok data=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и
    пробы 280/280 (235/235 host-тестов).

35. Срез 0.63.0: `src/rx_mode.zig` переносит счётчики promiscuity/allmulti,
    multicast-список с refcount, команды virtio-net control RX и фильтрацию
    кадра по MAC. Boot-проба `-Drx-mode-probe=true` печатает `ziglinux: rxmode:
    ok promisc=ok allmulti=ok mc=ok virtio=ok filter=ok errno=0`. Матрица
    0.63.0: загрузка 9/9 и пробы 280/280 (235/235 host-тестов).

36. Срез 0.63.0: `src/usb_hotplug.zig` переносит декодирование xHCI Port
    Status Change Event, состояние PORTSC, обработку изменения подключения,
    сброс порта и переиспользование слотов. Boot-проба
    `-Dusb-hotplug-probe=true` печатает `ziglinux: usbhotplug: ok decode=ok
    attach=ok detach=ok reset=ok reuse=ok errno=0`. Матрица 0.63.0: загрузка
    9/9 и пробы 280/280 (235/235 host-тестов).

37. Срез 0.63.0: `src/ncq.zig` переносит проверку CAP.NCQ и IDENTIFY word 76,
    глубину очереди из CAP.NCS, H2D FIS FPDMA READ/WRITE, регистры SActive/CI и
    завершение по тегу. Boot-проба `-Dncq-probe=true` печатает `ziglinux: ncq:
    ok cap=ok fis=ok queue=ok completion=ok errno=0`. Матрица 0.63.0: загрузка
    9/9 и пробы 280/280 (235/235 host-тестов).

38. Срез 0.63.0: `src/drm.zig` переносит базовую проверку режима и размеров,
    расчёт частоты обновления, геометрию framebuffer и page flip CRTC.
    Boot-проба `-Ddrm-probe=true` печатает `ziglinux: drm: ok basic=ok size=ok
    refresh=ok framebuffer=ok crtc=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и
    пробы 280/280 (235/235 host-тестов).

39. Срез 0.63.0: `src/igmp.zig` переносит IGMPv1/v2/v3: кодирование MRC/QQIC,
    разбор и сборку query/report/leave с контрольной суммой, состояние групп и
    ответ по таймеру. Boot-проба `-Digmp-probe=true` печатает `ziglinux: igmp:
    ok encoding=ok message=ok membership=ok query=ok leave=ok errno=0`. Матрица
    0.63.0: загрузка 9/9 и пробы 280/280 (235/235 host-тестов).

40. Срез 0.63.0: `src/ip_defrag.zig` переносит дефрагментацию IPv4: разбор
    IP_MF/IP_OFFSET, проверки границ и дубликатов из `ip_frag_queue()`, усечение
    MF до 8 байт, сборку `ip_frag_reasm()` и истечение очереди. Boot-проба
    `-Dip-defrag-probe=true` печатает `ziglinux: ipdefrag: ok offsets=ok
    reorder=ok limits=ok timeout=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и
    пробы 280/280 (235/235 host-тестов).

41. Срез 0.63.0: `src/unix_sock.zig` переносит базовое AF_UNIX-ядро:
    проверку `sockaddr_un`, BSD- и abstract-имена, bind/listen/connect/accept,
    socketpair, stream/dgram-очереди и освобождение сокета. Boot-проба
    `-Dunix-sock-probe=true` печатает `ziglinux: unixsock: ok names=ok pair=ok
    bind=ok datagram=ok close=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и
    пробы 280/280 (235/235 host-тестов).

42. Срез 0.63.0: `src/ipv6_frag.zig` переносит фрагментацию IPv6: заголовок
    frag_hdr, IP6_MF/IP6_OFFSET, выравнивание MF, лимит IPV6_MAXPLEN, сборку с
    восстановлением next-header и истечение очереди. Boot-проба
    `-Dipv6-frag-probe=true` печатает `ziglinux: ipv6frag: ok header=ok
    offsets=ok reorder=ok limits=ok timeout=ok errno=0`. Матрица 0.63.0:
    загрузка 9/9 и пробы 280/280 (235/235 host-тестов).

43. Срез 0.63.0: `src/netlink.zig` переносит базовое netlink-ядро: заголовки
    nlmsghdr/nlattr, проверки длин и выравнивание, маску типов атрибутов,
    multipart-поток, приём сообщений по правилам `netlink_rcv_skb()` и
    multicast-группы сокета. Boot-проба `-Dnetlink-probe=true` печатает
    `ziglinux: netlink: ok header=ok messages=ok attrs=ok dispatch=ok
    socket=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280
    (235/235 host-тестов).

44. Срез 0.63.0: `src/cgroup.zig` переносит базовое ядро cgroup v2: иерархию
    и проверки имён при `mkdir`, правила `subtree_control`, миграцию задач с
    проверкой `pids.max`, заряд `memory.max`, параметр `cpu.max`, события
    лимитов и `rmdir` только пустых листьев. Boot-проба `-Dcgroup-probe=true`
    печатает `ziglinux: cgroup: ok hierarchy=ok controllers=ok attach=ok
    limits=ok rmdir=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280
    (235/235 host-тестов).

45. Срез 0.63.0: `src/cubic.zig` переносит TCP CUBIC: кубический корень,
    пересчёт ssthresh с fast convergence, CUBIC-функцию, TCP-дружелюбие, slow
    start/AIMD и HyStart. Boot-проба `-Dcubic-probe=true` печатает
    `ziglinux: cubic: ok root=ok ssthresh=ok update=ok growth=ok hystart=ok
    errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280 (235/235
    host-тестов).

46. Срез 0.63.0: `src/e1000.zig` переносит драйвер Intel PRO/1000: кольца
    дескрипторов TX/RX, TSO и checksum-offload, разбиение пакета на куски по
    4096 байт, ожидание DD на EOP-дескрипторе, Wake queue, проверку ошибок
    кадра, NAPI-бюджет и повторный постинг RX-буферов. Boot-проба
    `-De1000-probe=true` печатает `ziglinux: e1000: ok ring=ok tx=ok rx=ok
    csum=ok napi=ok errno=0`. Матрица 0.63.0: загрузка 9/9 и пробы 280/280
    (235/235 host-тестов).

47. Срез 0.64.0: `src/xhci_hub_cascade.zig` переносит каскад внешних хабов
    xHCI: дескрипторы HS/SS, TT single/multi и think time, разряды
    `DEV_HUB`/`DEV_MTT`/`TT_THINK_TIME`, маршрутную строку, `HUB_SET_DEPTH`,
    выбор корневого порта, задержку каскада и проверку полосы. Boot-проба
    `-Dxhci-cascade-probe=true` печатает `ziglinux: xhci-cascade: ok
    descriptor=ok depth=ok tt=ok cascade=ok bandwidth=ok errno=0`. Матрица
    0.64.0: загрузка 9/9 и пробы 288/288 (244/244 host-тестов).

48. Срез 0.65.0: `src/pcnet32.zig` переносит AMD PCnet32: WIO/DWIO-доступ
    через RAP=88, chipcode из CSR88/CSR89, MAC и multicast, init block,
    ownership-биты колец, TXPOLL, разбор RX-статусов, NAPI-маски и
    reset/start/stop. Boot-проба `-Dpcnet32-probe=true` печатает
    `ziglinux: pcnet32: ok probe=ok ring=ok mac=ok tx=ok rx=ok irq=ok errno=0`.
    Матрица 0.65.0: загрузка 9/9 и пробы 296/296 (253/253 host-тестов).

49. Срез 0.66.0: `src/ne2k.zig` переносит NE2000/RTL8019 (8390): SAPROM
    dedupe/RTL8019 quirk, layout кольца TX/RX, двухслотовая передача, заголовок
    RX-кадра, валидация next-указателя, ENRSR_RXOK и ISR/overrun-recovery.
    Boot-проба `-Dne2k-probe=true` печатает `ziglinux: ne2k: ok probe=ok mac=ok
    init=ok tx=ok rx=ok irq=ok errno=0`. Матрица 0.66.0: загрузка 9/9 и пробы
    304/304 (261/261 host-тестов).

50. Срез 0.67.0: `src/rtl8139.zig` переносит RTL8139 (8139too): gating
    8139C+, ревизия чипа, TxConfig/RxConfig, TX/RX кольца, wraparound RX,
    ISR pending/ack и multicast hash filter. Boot-проба `-Drtl8139-probe=true`
    печатает `ziglinux: rtl8139: ok probe=ok mac=ok tx=ok rx=ok irq=ok mcast=ok
    errno=0`. Матрица 0.67.0: загрузка 9/9 и пробы 312/312 (269/269 host-тестов).

51. Срез 0.68.0: `src/e100.zig` переносит Intel PRO/100 (e100): CSR/SCB,
    CU/RU кольца, CB/RFD форматы, EEPROM checksum, IRQ ack/mask и configure
    defaults. Boot-проба `-De100-probe=true` печатает `ziglinux: e100: ok
    probe=ok mac=ok cu=ok ru=ok irq=ok eeprom=ok errno=0`. Матрица 0.68.0:
    загрузка 9/9 и пробы 320/320 (277/277 host-тестов).

52. Срез 0.69.0: `src/rtl8139cp.zig` переносит 8139C+ (8139cp): gating
    ревизии, дескрипторы TX/RX, кольца, ISR ack/NAPI rearm, multicast hash.
    Boot-проба `-Drtl8139cp-probe=true` печатает `ziglinux: 8139cp: ok
    probe=ok mac=ok tx=ok rx=ok irq=ok mcast=ok errno=0`. Матрица 0.69.0:
    загрузка 9/9 и пробы 328/328 (285/285 host-тестов).

## Что осталось подключить

1. DRM-драйверы GPU (базовое DRM-ядро уже реализовано); extent
   tree — без split выше depth 2
   (creat/unlink, mkdir/rmdir, JBD2 с revoke/checksum/64-bit/wrap, split depth
   0→1 и 1→2, разреженная запись и работа через все четыре блочных драйвера
   уже реализованы).
2. Сеть: `sk_buff`, `proto_ops`, `AF_INET/SOCK_DGRAM`, `AF_INET/SOCK_STREAM`
   с TCP, `AF_INET6/SOCK_DGRAM`, netdev/IPv4 FIB, ARP, virtio-net NIC, Reno,
   window scale, SACK, RTO backoff, ICMPv6 echo, базовый NDP, pfifo_fast, NAPI,
   fq_codel, HTB, полные TCP-таймеры, CUBIC, e1000, MLD, RA, IGMPv3, TCPv6,
   дефрагментация IPv4/IPv6, AF_UNIX, netlink, cgroup v2, promiscuous и
   multicast
   уже реализованы; остаются другие NIC и реальная сеть за пределами QEMU user
   net.
3. `user.zig` использовать как справочник по Linux ABI syscalls, handlers
   брать из `ziglinux/src/syscall.zig`; ring3 и syscall entry уже включены.

## Почему так

Порт TTY в C-коде Linux — это 8755 строк только ядра (`n_tty.c`, `tty_io.c`,
`tty_buffer.c`, `tty_ldisc.c`, `tty_jobctrl.c`, `tty.h`). Драйвера уже
реализованы и рабочие в `zigos`; трогать их без нужды — риск сломать загрузку.
Поэтому граница проходит по `TtyOps`, а всё, что относится к семантике Linux
(termios, line discipline, job control, сигналы), портировано в `ziglinux`.
