#!/usr/bin/env python3
"""Build a small GPT disk image containing the ext4 partition used by QEMU.

Protective MBR + primary/backup GPT headers with CRCs, one Linux filesystem
entry starting at LBA 2048. The partition payload is copied from boot-disk.img.
"""
import pathlib
import struct
import zlib

SECTOR = 512
TOTAL_SECTORS = 16384  # 8 MiB
PART_START = 2048
PART_SECTORS = 8192
LINUX_FS_GUID = bytes.fromhex("af3dc60f838472478e793d69d8477de4")
MAGIC = b"EFI PART"

here = pathlib.Path(__file__).resolve().parent
source = (here / "boot-disk.img").read_bytes()
image = bytearray(TOTAL_SECTORS * SECTOR)
image[510:512] = b"\x55\xaa"
image[446 + 4] = 0xEE
struct.pack_into("<I", image, 446 + 8, 1)
struct.pack_into("<I", image, 446 + 12, TOTAL_SECTORS - 1)

array = bytearray(128 * 128)
array[0:16] = LINUX_FS_GUID
array[16] = 0x11
struct.pack_into("<Q", array, 32, PART_START)
struct.pack_into("<Q", array, 40, PART_START + PART_SECTORS - 1)
name = "hello".encode("utf-16-le")
array[56 : 56 + len(name)] = name
entries_crc = zlib.crc32(array) & 0xFFFFFFFF


def header(my_lba, alternate_lba, entry_lba):
    h = bytearray(92)
    h[0:8] = MAGIC
    struct.pack_into("<I", h, 8, 0x00010000)
    struct.pack_into("<I", h, 12, 92)
    struct.pack_into("<Q", h, 24, my_lba)
    struct.pack_into("<Q", h, 32, alternate_lba)
    struct.pack_into("<Q", h, 40, 34)
    struct.pack_into("<Q", h, 48, TOTAL_SECTORS - 34)
    struct.pack_into("<Q", h, 72, entry_lba)
    struct.pack_into("<I", h, 80, 128)
    struct.pack_into("<I", h, 84, 128)
    struct.pack_into("<I", h, 88, entries_crc)
    struct.pack_into("<I", h, 16, zlib.crc32(h) & 0xFFFFFFFF)
    return h


primary = header(1, TOTAL_SECTORS - 1, 2)
backup = header(TOTAL_SECTORS - 1, 1, TOTAL_SECTORS - 33)
image[SECTOR : SECTOR + 92] = primary
image[2 * SECTOR : 2 * SECTOR + len(array)] = array
image[(TOTAL_SECTORS - 33) * SECTOR : (TOTAL_SECTORS - 33) * SECTOR + len(array)] = array
image[(TOTAL_SECTORS - 1) * SECTOR : (TOTAL_SECTORS - 1) * SECTOR + 92] = backup
image[PART_START * SECTOR : (PART_START + PART_SECTORS) * SECTOR] = source[
    PART_START * SECTOR : (PART_START + PART_SECTORS) * SECTOR
]

out = here / "boot-gpt.img"
out.write_bytes(image)
print(f"{out}: {len(image)} bytes, part at LBA {PART_START}, entries CRC {entries_crc:#x}")
