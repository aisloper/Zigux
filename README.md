# ziglinux

Порт исторического ядра Linux 7.3 на Zig 0.17.1 (без libc). Команды ниже
выполняются из корня репозитория.

## Статус

Разработка ведётся последовательными вертикальными срезами. Каждый срез
переносит группу алгоритмов из исходников `linux-7.3`, подключает её
к `start_kernel()`, добавляет модульные тесты,
boot-пробу и проходит полную проверку: форматирование, тесты, сборку, UEFI,
загрузку в QEMU и матрицу сценариев. Текущий номер среза и количество тестов
всегда определяются исходниками (`src/kernel.zig`, `src/tests.zig`) — не
фиксируются в этом файле.

Полного порта всех подсистем Linux 7.3 пока нет: остаются дополнительные
сетевые контроллеры и дополнительные DRM GPU-драйверы. Подробный журнал
срезов — в [docs/PORTING.md](docs/PORTING.md), граница с драйверами `zigos`
и список реализованных драйверов — в [docs/DRIVERS.md](docs/DRIVERS.md).

Лицензия: GPL-2.0-only; реализации являются производной работой по алгоритмам
и интерфейсам ядра Linux. Текст — в [LICENSE](LICENSE).

## Быстрый старт

```sh
zig fmt --check build.zig src
zig test src/tests.zig
zig build
zig build test
zig build run          # host-симулятор start_kernel()
zig build efi          # zig-out/esp/EFI/BOOT/BOOTX64.efi
zig build qemu         # загрузка в QEMU с OVMF
```

Для проверки отдельного модуля используется, например,
`zig test src/net.zig`, `zig test src/ext4.zig` или `zig test src/drm.zig`.
Boot-пробы включаются build-флагами (`-D...-probe=true`) и печатают маркер
в серийный лог; полный набор флагов описан в `docs/PORTING.md`.

## Структура

- `src/kernel.zig` — реестр портированных подсистем и `port_version`.
- `src/arch/` — UEFI-загрузка, GDT/IDT/APIC/timer, serial/console, SMP.
- `src/arch/drivers/` — PCI, virtio-blk/virtio-scsi/virtio-net, NVMe, AHCI,
  xHCI, GPT/MBR и дисковый слой.
- `src/ext4.zig`, `src/vfs.zig`, `src/mm.zig` — файловая система, VFS и память.
- `src/net.zig`, `src/tcp.zig`, `src/inet6.zig`, `src/netdev.zig`, `src/route.zig`
  и соседние модули — сетевой стек.
- `src/tty.zig`, `src/process.zig`, `src/signal.zig`, `src/sched.zig`,
  `src/syscall.zig` — ядерные подсистемы.
- `src/tests.zig` — агрегатор всех модульных тестов.
- `build.zig` — host-симулятор, UEFI-образ, probe-флаги и QEMU-цели.

Драйверы из архива `zigos` остаются в исходном виде в
`../extracted/zigos/src/`; контракт взаимодействия описан
в `docs/DRIVERS.md`. Архив `../zigos.zip` используется только
как справочник и не изменяется.

## Проверка файловых систем

Пробы записи в ext4 работают только под build-флагами и только на scratch-копиях
образа. Нельзя передавать `-Dboot-disk` с checked-in фикстурами. После каждой
мутации раздел извлекается из копии и проверяется oracle-командой
`e2fsck -fn`; ожидается нулевой код возврата.

Матрица QEMU разделяет 9 boot-кейсов и probe-кейсы. В документации запись
`пробы N/N` исключает 9 boot-кейсов; полная матрица содержит `N + 9` сценариев.
Каждый сценарий проверяет отсутствие `: FAIL`, `fsck=0` и пустой список `bad`.

## Синхронизация

```sh
git status --porcelain
git log --oneline -1
git ls-remote origin refs/heads/main
```

Ветка `main` синхронизируется с настроенным удалённым репозиторием `origin`.
Коммиты создаются только на проверенных чекпоинтах; в удалённый репозиторий
попадают только проверенные коммиты.
