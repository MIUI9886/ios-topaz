#!/bin/bash
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
#
# SWEET/marble console-revival + device-avoidance, v6:
#  - pre-apply ALL patches (0001-0091; 0012 excluded — it never applies and
#    dxb skips it silently anyway), so this script can edit the FULLY patched
#    tree (build.sh then skips every patch via git apply --check — harmless);
#  - keep the sweet_early framebuffer console alive past the bootstrap TTBR0
#    teardown and for the whole boot (marble has no serial/fbcon takeover);
#  - add console marks along the UFS root path;
#  - stub sweet_i2c1_init (topaz-only device; its MMIO access raises a
#    synchronous external abort on marble).
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "console-stage: pre-applying ALL patches (0012 excluded; pre-broken ones skipped, as dxb always did)"
for p in "$PATCH_DIR"/*.patch; do
    b=$(basename "$p")
    n=$((10#${b%%-*}))
    if [ "$n" -eq 12 ]; then
        echo "console-stage: SKIP  $b (never applies)"
    elif git apply "$p" 2>/dev/null; then
        echo "console-stage: applied $b"
    else
        echo "console-stage: SKIP  $b (pre-broken context, dxb skipped it too)"
    fi
done

python3 - <<'PY'
import os, re
from pathlib import Path

def load(p):
    return Path(p).read_text()

def save(p, t):
    Path(p).write_text(t)
    print(f'console-stage: patched {p}')

def replace_once(t, path, old, new, required=True):
    n = t.count(old)
    if n == 1:
        print(f'console-stage: ok  {path}: {old[:52]!r}')
        return t.replace(old, new, 1)
    if n == 0 and not required:
        print(f'console-stage: SKIP (absent) {path}: {old[:52]!r}')
        return t
    raise SystemExit(f'console-stage: {path}: expected 1 of {old[:60]!r}, found {n}')

# ---------------- osfmk/arm64/sweet_early.c ----------------
p = 'osfmk/arm64/sweet_early.c'
t = load(p)
t = replace_once(t, p,
    '#define EARLY_FB ((volatile uint32_t *)(uintptr_t)0xb8000000)',
    'static volatile uint32_t *early_fb = (volatile uint32_t *)(uintptr_t)0xb8000000;\n'
    '#define EARLY_FB early_fb\n'
    'unsigned long long sweet_fb_va;\t\t/* final-table FB alias; 0 = unmapped */')
t = replace_once(t, p,
    'if (early_disabled || stage > 8) {',
    'if (early_disabled || stage > 40) {')
# sweet_early_disable() becomes relocate-or-disable (called right after the
# final tables take over). No mark 8 here: the old VA=PA mapping is gone.
t = replace_once(t, p,
    '\tsweet_early_mark(8, "leaving bootstrap TTBR0");\n'
    '\tearly_disabled = 1;\n'
    '\t__asm__ volatile("dsb sy" ::: "memory");',
    '\tif (sweet_fb_va) {\n'
    '\t\tearly_fb = (volatile uint32_t *)(uintptr_t)sweet_fb_va;\n'
    '\t\t__asm__ volatile("dsb sy" ::: "memory");\n'
    '\t\tsweet_early_mark(9, "kernel framebuffer VA live");\n'
    '\t} else {\n'
    '\t\tearly_disabled = 1;\t/* no alias: fade out quietly */\n'
    '\t}')
save(p, t)

# ---------------- osfmk/arm64/arm_vm_init.c ----------------
p = 'osfmk/arm64/arm_vm_init.c'
t = load(p)
map_fn = '''/*
 * SWEET/marble: map the splash framebuffer into the FINAL kernel tables at a
 * VA that actually has a free L2 slot. The stock 0012 candidate
 * (VM_MIN_KERNEL_ADDRESS + ARM_TT_L2_SIZE) hard-asserts on marble's memory
 * layout; try it first, then fall back below the physmap. Soft checks: on
 * failure the console just dies at TTBR0 teardown instead of panicking.
 */
static void
sweet_early_map_final(void)
{
\textern unsigned long long sweet_fb_va;
\tvm_map_address_t va = VM_MIN_KERNEL_ADDRESS + ARM_TT_L2_SIZE;
\tif (va + ARM_TT_L2_SIZE > gVirtBase)
\t\tva = gVirtBase - ARM_TT_L2_SIZE;
\ttt_entry_t l1 = cpu_tte[(va & ARM_TT_L1_INDEX_MASK) >> ARM_TT_L1_SHIFT];
\tif ((l1 & (ARM_TTE_VALID | ARM_TTE_TYPE_MASK)) != (ARM_TTE_VALID | ARM_TTE_TYPE_TABLE))
\t\treturn;
\ttt_entry_t *l2 = (tt_entry_t *)phystokv(l1 & ARM_TTE_TABLE_MASK);
\ttt_entry_t *slot = &l2[(va & ARM_TT_L2_INDEX_MASK) >> ARM_TT_L2_SHIFT];
\tif (*slot != ARM_TTE_EMPTY)
\t\treturn;
\t*slot = 0xb8000000ULL | ARM_TTE_VALID | ARM_TTE_TYPE_BLOCK |
\t    ARM_TTE_BLOCK_SH(SH_OUTER_MEMORY) |
\t    ARM_TTE_BLOCK_ATTRINDX(CACHE_ATTRINDX_WRITECOMB) |
\t    ARM_TTE_BLOCK_AF | ARM_TTE_BLOCK_PNX | ARM_TTE_BLOCK_NX;
\tsweet_fb_va = (unsigned long long)va;
\t__asm__ volatile("dsb ishst" ::: "memory");
}

'''
t = replace_once(t, p,
    'void\narm_vm_init(uint64_t memory_size, boot_args * args)',
    map_fn + 'void\narm_vm_init(uint64_t memory_size, boot_args * args)')
# 0010's call site becomes map_final ...
t = replace_once(t, p,
    '\tsweet_early_disable();',
    '\tsweet_early_map_final();')
# ... and the relocate must actually RUN after the final tables take over.
t = replace_once(t, p,
    '\tset_mmu_ttb(invalid_ttep & TTBR_BADDR_MASK);',
    '\tset_mmu_ttb(invalid_ttep & TTBR_BADDR_MASK);\n'
    '\tsweet_early_disable();\t/* now: relocate the console to the final tables */')
save(p, t)

# ---------------- iokit/bsddev/IOKitBSDInit.cpp ----------------
p = 'iokit/bsddev/IOKitBSDInit.cpp'
t = load(p)
t = ('extern "C" void sweet_early_mark(unsigned, const char *);\n' + t)
t = replace_once(t, p,
    '\tif (strcmp(rdBootVar, "ufsroot0") == 0) {',
    '\tsweet_early_mark(21, "IOFindBSDRoot ufsroot0");\n'
    '\tif (strcmp(rdBootVar, "ufsroot0") == 0) {')
t = replace_once(t, p,
    '\t\tint ufs_error = sweet_ufs_rootdev(root);',
    '\t\tsweet_early_mark(22, "calling sweet_ufs_rootdev");\n'
    '\t\tint ufs_error = sweet_ufs_rootdev(root);')
t = replace_once(t, p,
    '\t\tstrlcpy(rootName, rdBootVar, rootNameSize);',
    '\t\tstrlcpy(rootName, rdBootVar, rootNameSize);\n'
    '\t\tsweet_early_mark(28, "BSD root dev ready");')
save(p, t)

# ---------------- bsd/kern/bsd_init.c ----------------
p = 'bsd/kern/bsd_init.c'
t = load(p)
if 'vfs_mountroot' in t and 'sweet_early_mark(29' not in t:
    lines = t.split('\n')
    for i, l in enumerate(lines):
        if 'vfs_mountroot()' in l:
            lines.insert(i, '\textern void sweet_early_mark(unsigned, const char *);')
            lines.insert(i + 1, '\tsweet_early_mark(29, "vfs_mountroot");')
            print('console-stage: vfs_mountroot mark inserted')
            break
    t = '\n'.join(lines)
    save(p, t)
else:
    print('console-stage: bsd_init.c skipped')

# ---------------- bsd/dev/sweet_ufs.c: USB probe stays GATED on marble ----------------
# The probe (0072) reads topaz's GCC (0x00100000) first; on marble ml_io_map of
# that low address returns garbage and the read raises a synchronous external
# abort (captured live: pc=sweet_usb_probe+0x94, far phys 0xc49c6f04). Keep the
# probe gated behind sweethw=1 for now.

# ---------------- bsd/dev/sweet_usb.c: skip GCC, read DWC3 directly ----------------
# marble's ml_io_map works for high addresses (UFS 0x1d84000 maps fine) but not
# low ones (GCC 0x100000 -> garbage). The DWC3 controller at 0xa600000 is a high
# address and ABL left it powered/clocked (it drove fastboot). Rewrite the probe
# to skip the GCC power/clock checks and read the DWC3 + QUSB2 registers
# directly, so we get the real controller state without touching GCC.
p = 'bsd/dev/sweet_usb.c'
t = load(p)
# 1) neutralize the GCC block: map DWC3 first instead of GCC. We replace the
#    GCC-specific body by jumping straight to the DWC3 read.
t = replace_once(t, p,
    '\tvm_offset_t gcc = ml_io_map(GCC_PA, GCC_SIZE);\n'
    '\tif (gcc == 0) {\n'
    '\t\tprintf("SWEET USB: GCC map failed\\n");\n'
    '\t\treturn;\n'
    '\t}\n'
    '\tgdscr = usb_rd(gcc, GCC_USB30_PRIM_GDSCR);\n'
    '\tprintf("SWEET USB: GDSC usb30_prim 0x%08x (%s)\\n", gdscr, (gdscr & (1u << 31)) ? "on" : "off");\n'
    '\tfor (unsigned i = 0; i < sizeof(usb_cbcr) / sizeof(usb_cbcr[0]); i++) {\n'
    '\t\tcbcr[i] = usb_rd(gcc, usb_cbcr[i].off);\n'
    '\t\tprintf("SWEET USB: clk %-12s CBCR 0x%08x (%s)\\n", usb_cbcr[i].name, cbcr[i],\n'
    '\t\t    (cbcr[i] & CBCR_CLK_OFF) ? "off" : "on");\n'
    '\t}\n'
    '\t/* DWC3 registers need the GDSC, the master clock and the config-NoC path. */\n'
    '\tclocks_on = (gdscr & (1u << 31)) && !(cbcr[0] & CBCR_CLK_OFF) && !(cbcr[3] & CBCR_CLK_OFF);\n'
    '\tif (!clocks_on) {\n'
    '\t\tprintf("SWEET USB: controller unpowered or unclocked; DWC3 not read\\n");\n'
    '\t\treturn;\n'
    '\t}\n'
    '\tvm_offset_t dwc = ml_io_map(DWC3_PA, DWC3_SIZE);',
    '\tprintf("SWEET USB: skipping GCC (marble: ml_io_map of 0x100000 faults)\\n");\n'
    '\tvm_offset_t dwc = ml_io_map(DWC3_PA, DWC3_SIZE);')
save(p, t)

# 2) the QUSB2 read is gated on cbcr[5] (ahb2phy) which is now uninitialized;
#    replace that gate with an unconditional read (DWC3/PHY are high-addressed
#    and ABL-powered, so direct reads are safe).
t = load(p)
t = replace_once(t, p,
    '\tif (cbcr[5] & CBCR_CLK_OFF) {\n'
    '\t\tprintf("SWEET USB: ahb2phy clock off; QUSB2 PHY not read\\n");\n'
    '\t\treturn;\n'
    '\t}\n'
    '\tvm_offset_t phy = ml_io_map(QUSB2_PA, QUSB2_SIZE);',
    '\tvm_offset_t phy = ml_io_map(QUSB2_PA, QUSB2_SIZE);', required=False)
save(p, t)

# ---------------- bsd/dev/sweet_ufs.c: hoist the (now-safe) probe ----------------
p = 'bsd/dev/sweet_ufs.c'
t = load(p)
old_guard = (
    '\tif (hw == 1) {\n'
    '\t\tsweet_usb_probe();\n'
    '\t} else {\n'
    '\t\tprintf("SWEET UFS: USB skipped (topaz, sweethw=0)\\n");\n'
    '\t}')
new_guard = '\tsweet_usb_probe();\t/* marble: GCC-skipping probe, safe */'
t = replace_once(t, p, old_guard, new_guard)
save(p, t)

# ---------------- osfmk/arm64/sleh.c ----------------
# Qualcomm's hypervisor traps EL1 accesses to the physical timer registers
# (CNTP_*) and reflects them to the guest as undefined instructions. Emulate
# them in the undefined-instruction path: reads return 0 (timer disabled),
# writes are ignored, PC advances by 4. Genuine undefined instructions still
# panic as before.
p = 'osfmk/arm64/sleh.c'
t = load(p)
anchor = (
    '\tif (PSR64_IS_KERNEL(get_saved_state_cpsr(state))) {\n'
    '\t\tif (IS_ARM_GDB_TRAP(instr)) {')
emu = (
    '\tif (PSR64_IS_KERNEL(get_saved_state_cpsr(state))) {\n'
    "\t\t/* SWEET/marble: the Qualcomm hypervisor traps EL1 accesses to the\n"
    '\t\t * physical timer registers (CNTP_*) and reflects them to the guest\n'
    '\t\t * as undefined instructions. Emulate them: reads return 0 (timer\n'
    '\t\t * disabled), writes are ignored; PC advances by 4. */\n'
    '\t\tif ((instr >> 22) == 0x354) {\t/* MRS/MSR system register class */\n'
    '\t\t\tuint32_t s_op0 = (instr >> 19) & 1;\n'
    '\t\t\tuint32_t s_op1 = (instr >> 16) & 7;\n'
    '\t\t\tuint32_t s_crn = (instr >> 12) & 0xF;\n'
    '\t\t\tuint32_t s_crm = (instr >> 8) & 0xF;\n'
    '\t\t\tif (s_op0 == 1 && s_op1 == 3 && s_crn == 14 && s_crm == 2) {\n'
    '\t\t\t\t/* CNTP_TVAL/CTL/CVAL */\n'
    '\t\t\t\tif (((instr >> 21) & 1) && (instr & 0x1F) < 29) {\n'
    '\t\t\t\t\tsaved_state64(state)->x[instr & 0x1F] = 0;\n'
    '\t\t\t\t}\n'
    '\t\t\t\tsaved_state64(state)->pc = get_saved_state_pc(state) + 4;\n'
    '\t\t\t\treturn;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t\tif (IS_ARM_GDB_TRAP(instr)) {')
t = replace_once(t, p, anchor, emu)
save(p, t)

# ---------------- stub sweet_i2c1_init (topaz-only device) ----------------
# Its MMIO access raises a synchronous external abort on marble (device not
# clocked / not present). Find the definition anywhere in the tree and make
# it return immediately.
stubbed = False
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in ('.git', 'build', 'BUILD')]
    for f in sorted(files):
        if not f.endswith(('.c', '.cpp', '.h', '.hpp')):
            continue
        p = os.path.join(root, f)
        try:
            s = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
# ---------------- stub topaz-only device inits ----------------
# These drivers touch topaz-only peripherals whose MMIO raises synchronous
# external aborts on marble. Stub each definition (return immediately) so
# the boot proceeds without them. Extend the list as new ones surface.
STUB_NAMES = ['sweet_i2c1_init', 'sweet_keys_init', 'sweet_touch_init',
              'sweet_spmi_init']
stubbed = set()
for name in STUB_NAMES:
    for root, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in ('.git', 'build', 'BUILD')]
        found = False
        for f in sorted(files):
            if not f.endswith(('.c', '.cpp', '.h', '.hpp')):
                continue
            p = os.path.join(root, f)
            try:
                s = open(p, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            m = re.search(r'\b' + name + r'\s*\([^)]*\)\s*\{', s)
            if not m:
                continue		# no definition in this file (only call sites)
            b = s.find('{', m.start())
            # return type: text between the previous ';' or '}' and the name
            start = max(s.rfind(';', 0, m.start()), s.rfind('}', 0, m.start()),
                        s.rfind('{', 0, m.start()))
            sig = s[start + 1:m.start()]
            ret_void = ('void' in sig) and ('int' not in sig)
            ins = 'return;' if ret_void else 'return 0;'
            s = s[:b + 1] + '\n\t' + ins + '\t/* marble: topaz-only device, not brought up */' + s[b + 1:]
            save(p, s)
            print(f'console-stage: stubbed {name} in {p} ({ins})')
            stubbed.add(name)
            found = True
            break
        if found:
            break
missing = [n for n in STUB_NAMES if n not in stubbed]
if missing:
    print(f'console-stage: WARNING: no definition found for: {missing}')

print('console-stage: done')
PY
