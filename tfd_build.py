#!/usr/bin/env python3
"""tfd_build.py — clang 直接构建（不经 Theos），产物为 FAT(arm64+arm64e)"""
import os, subprocess, sys, shutil, struct

W = '/var/minis/workspace/zzd-original'
SDK = '/root/theos/sdks/iPhoneOS16.5.sdk'
SUBSTRATE_INC = '/root/theos/vendor/include'
NAME = 'TFDRecordIsland'
OUT = f'{W}/build'

SRCS = ['src/TFDPlayer.m', 'src/TFDConfig.m', 'src/TFDTweak.m']


def run(cmd):
    print('+', ' '.join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=W)
    if r.stdout.strip():
        print(r.stdout.strip()[:5000])
    if r.returncode != 0:
        print('--- STDERR ---')
        print(r.stderr.strip()[:6000])
        sys.exit(r.returncode)
    if r.stderr.strip():
        print('--- warn ---')
        print(r.stderr.strip()[:3000])
    return r


def build_slice(arch, out):
    cmd = ['clang', '-target', f'{arch}-apple-ios15.0',
           '-isysroot', SDK,
           '-I', SUBSTRATE_INC,
           '-I', f'{W}/src',
           '-fobjc-arc', '-O2',
           '-Wno-deprecated-declarations',
           '-Wno-unused-parameter',
           '-Wno-nullability-completeness',
           '-dynamiclib', '-fuse-ld=lld',
           '-install_name', f'@rpath/{NAME}.dylib',
           '-framework', 'Foundation', '-framework', 'UIKit',
           '-framework', 'QuartzCore', '-framework', 'ImageIO',
           '-framework', 'CoreGraphics',
           '-L', '/root/theos/vendor/lib',
           '-F', '/root/theos/vendor/lib',
           '-lsubstrate',
           '-o', out] + SRCS
    run(cmd)
    run(['ldid', '-S', out])


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT, exist_ok=True)
    a64 = f'{OUT}/{NAME}.arm64.dylib'
    a64e = f'{OUT}/{NAME}.arm64e.dylib'
    build_slice('arm64', a64)
    build_slice('arm64e', a64e)

    blobs = []
    for p in (a64, a64e):
        d = open(p, 'rb').read()
        cputype, cpusub = struct.unpack_from('<ii', d, 4)
        blobs.append((cputype, cpusub, d))

    hdr = 8 + 20 * len(blobs)
    align = 0x4000
    offsets, cur = [], hdr
    for _, _, d in blobs:
        cur = (cur + align - 1) // align * align
        offsets.append(cur)
        cur += len(d)

    fat = bytearray(cur)
    struct.pack_into('>II', fat, 0, 0xcafebabe, len(blobs))
    for i, (ct, cs, d) in enumerate(blobs):
        struct.pack_into('>iiIII', fat, 8 + i * 20, ct, cs, offsets[i], len(d), 14)
        fat[offsets[i]:offsets[i] + len(d)] = d

    fatp = f'{OUT}/{NAME}.dylib'
    open(fatp, 'wb').write(fat)
    run(['ldid', '-S', fatp])

    print('\n=== 产物 ===')
    print(fatp, os.path.getsize(fatp), 'bytes')
    r = subprocess.run(['python3', '/var/minis/skills/ios-tweak-porting/scripts/macho.py',
                        'info', fatp], capture_output=True, text=True)
    print(r.stdout)


if __name__ == '__main__':
    main()
