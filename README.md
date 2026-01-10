# ao486 port for MiSTer by Sorgelig.

MiSTer port of the ao486 core originally written by Aleksander Osman, which has been greatly reworked with many new features and performance added.

Original Core [repository](https://github.com/alfikpl/ao486)

## Features:
* 486DX-class performance with integrated **x87 FPU (phases 0–5 implemented)**.
* 256MB RAM
* SVGA with up to 1280x1024@256, 1024x768@64K, 640x480@16M resolutions
* Sound Blaster 16 (DSP v4.05) and Sound Blaster Pro (DSP v3.02) with OPL3 and C/MS
* High speed UART (3Mbps) internet connection
* MIDI port (dumb and fake-smart modes)
* External MIDI device support (MT32-pi and generic MIDI)
* 4 HDDs with up to 137GB each
* 2 CD-ROMs
* Shared folder support

## x87 FPU Implementation Status

### Implemented (Phases 0–5)
**Phase 0–1 (Presence & Control)**
* FINIT, FWAIT
* FLDCW / FNSTCW
* FNSTSW (AX)
* Proper FPU presence detection (486DX-style)

**Phase 2 (Core Arithmetic & Stack)**
* FLD / FST / FSTP
* FADD / FSUB / FMUL / FDIV
* FCOM / FCOMP
* Stack push/pop, tag word maintenance
* Condition codes (C0/C2/C3) modeled

**Phase 2P (Precision & Exceptions – Pragmatic)**
* Inexact (PE) generation on rounding
* Invalid operation on NaN / divide-by-zero
* Simplified rounding (IEEE-reasonable, not micro-exact)

**Phase 3 (Integer Conversions)**
* FILD (16/32-bit)
* FIST / FISTP (16/32-bit)

**Phase 4 (Unary / Misc)**
* FSQRT
* FRNDINT

**Phase 5A (Scaling & Remainder)**
* FSCALE
* FPREM (single-pass, C2=0)
* FPREM1 (IEEE remainder variant)

### Known Limitations (Intentional)
* No iterative FPREM/FPREM1 (C2 loop not implemented)
* Rounding control modes approximated (RC honored where practical)
* No transcendental instructions yet (FSIN, FCOS, FPTAN)
* No BCD support yet (FBLD / FBSTP)
* Not cycle-accurate vs Intel x87 microcode

This implementation targets **high software compatibility** (DOS extenders, games, demos, math libraries) rather than microarchitectural exactness.

### Roadmap
* Phase 5B: FXTRACT, FABS, FCHS, FTST
* Phase 6: Transcendentals (FSIN/FCOS/FPTAN)
* Phase 7: BCD operations (FBLD/FBSTP)
* Phase 8: Area/timing optimization (DE10 vs DE25)

## x87 FPU Feature Matrix

| Instruction Group | Instruction | Status | Notes |
|------------------|-------------|--------|-------|
| Init / Control | FINIT / FNINIT | ✓ | Architectural reset values |
| Init / Control | FWAIT | ✓ | Busy/done model |
| Status / Control | FNSTSW AX | ✓ | AX writeback |
| Status / Control | FLDCW / FNSTCW | ✓ | Pragmatic RC handling |
| Stack Ops | FLD ST(i) | ✓ | |
| Stack Ops | FST / FSTP ST(i) | ✓ | |
| Stack Ops | FXCH ST(i) | ✓ | |
| Memory | FLD m32 / m64 | ✓ | |
| Memory | FSTP m32 / m64 | ✓ | |
| Arithmetic | FADD / FADDP | ✓ | |
| Arithmetic | FSUB / FSUBP / FSUBR / FSUBRP | ✓ | |
| Arithmetic | FMUL / FMULP | ✓ | |
| Arithmetic | FDIV / FDIVP / FDIVR / FDIVRP | ✓ | |
| Compare | FCOM / FCOMP | ✓ | Sets C0/C2/C3 |
| Integer Conv | FILD | ✓ | 16/32-bit |
| Integer Conv | FIST / FISTP | ✓ | 16/32-bit |
| Unary | FCHS | ✓ | |
| Unary | FABS | ✓ | |
| Unary | FTST | ✓ | Compare vs +0 |
| Unary | FRNDINT | ✓ | RC honored |
| Unary | FSQRT | ✓ | Pragmatic sqrt |
| Scaling | FSCALE | ✓ | Uses trunc(ST1) |
| Remainder | FPREM | ✓ | Single-pass, C2=0 |
| Remainder | FPREM1 | ✓ | Single-pass |
| Extract | FXTRACT | ✓ | Push exponent + significand |
| Trig | FSIN | ✗ | Phase 6 pending |
| Trig | FCOS | ✗ | Phase 6 pending |
| Trig | FPTAN | ✗ | Phase 6 pending |
| Log/Exp | F2XM1 | ✗ | Phase 6 pending |
| Log/Exp | FYL2X | ✗ | Phase 6 pending |
| Log/Exp | FYL2XP1 | ✗ | Phase 6 pending |
| BCD | FBLD / FBSTP | ✗ | Not implemented |

## Compatibility Notes
This x87 implementation has been validated conceptually against common real-world software expectations rather than strict microcode equivalence.

Expected to work correctly with:
* DOS extenders (DOS/4GW, CauseWay, PMODE/W)
* Watcom C/C++ math runtime
* DJGPP libc math functions
* Many DOS games and demos requiring a 486DX-class FPU
* Windows 3.x / Win9x era applications using standard x87 paths

Known behavioral differences vs real Intel x87:
* FPREM/FPREM1 complete in a single pass (C2 is always cleared)
* Rounding control modes are honored pragmatically, not micro-cycle exact
* Exception timing is simplified (architectural flags are correct)

These differences are not known to affect typical application correctness.

## FPGA Resource Notes (DE10 vs DE25)
The current implementation prioritizes **functional completeness** over minimal area.

* **DE10-Nano (Cyclone V)**:
  * May be tight or fail to fit with all Phase 0–5 features enabled
  * Resource pressure mainly from fp64 arithmetic blocks
  * Further optimization or feature trimming may be required

* **DE25-class FPGA**:
  * Recommended for full x87 feature set without compromises
  * Allows cleaner timing closure and future Phase 6–7 expansion

An optimization pass (resource sharing, deeper pipelining, or reduced precision options) can be performed if DE10-Nano support is required.

