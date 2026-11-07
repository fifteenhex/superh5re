# SH-5 manuals

SuperH, Inc. documentation from <https://docs.alexrp.com/sh/>, renamed to the
titles printed in the documents.

| File | Title | Document ID | Date | Source file | SHA-256 |
|---|---|---|---|---|---|
| `SH-5_CPU_Core_Vol1_Architecture_05-CC-10001_V1.0.pdf` | SH-5 CPU Core, Volume 1: Architecture | 05-CC-10001 V1.0 | 2001 | `sh5_arch.pdf` | `3b49502fb909312deab9a591d4028c518c12e046648fd5825439da9e27876bc9` |
| `SH-5_CPU_Core_Vol2_SHmedia_05-CC-10002_V1.0.pdf` | SH-5 CPU Core, Volume 2: SHmedia | 05-CC-10002 V1.0 | 2001 | `sh5_media.pdf` | `c07447014eae379c7cb19181ef2bcf0bc283dcb27bb26ba166f8084124e37459` |
| `SH-5_CPU_Core_Vol3_SHcompact_05-CC-10003_V1.0.pdf` | SH-5 CPU Core, Volume 3: SHcompact | 05-CC-10003 V1.0 | 2001 | `sh5_compact.pdf` | `ed6d293f46c831be8fc7d3417426b34d8ad99d1619841f90bfaa2cbc247115ee` |
| `SH-5_CPU_Core_Vol4_Implementation_05-CC-10004_V1.0.pdf` | SH-5 CPU Core, Volume 4: Implementation | 05-CC-10004 V1.0 | 2001 | `sh5_impl.pdf` | `0aa8b1fb3844c228e6bbfd25fcbf396238860db6481b3edccfc9714e8da9fd31` |
| `SH-5_Common_Assembly_Language_Syntax_05-ASM-10001_v1.0.pdf` | SH-5 Common Assembly Language Syntax (9 pages: the assembly subset all SH-5 toolchains accept) | 05-ASM-10001 v1.0 | 28 February 2002 | `sh5asmsyntax.pdf` (supplied by the user) | `060d797cfc7eef334dfebef40bf899027da3c3c7420552740010fde794f02307` |
| `SH-5_System_Architecture_Vol3_Debug_05-SA-10003_v1.0_DRAFT.pdf` | SH-5 System Architecture, Volume 3: Debug (draft, preliminary data) | 05-SA-10003 v1.0 | 19 March 2002 | `sh5_debug.pdf` | `c9f37d1f0029eb91503e5ed9e695e31e8394c5b3729f9482755dc624efef2639` |

The CPU Core prefaces list the "SH-5 CPU core documentation suite" as exactly
volumes 05-CC-10001 to 05-CC-10004, so that set is complete.

The debug manual is volume 3 of a separate "SH-5 System Architecture" suite
(05-SA-1000n). Volumes 1 and 2 of that suite are not held here.

`tools/pdfstrings.py` and `tools/pdfgrep.py` dump text operands from the PDF
content streams using only the Python standard library. They work on the four
CPU Core volumes (text comes out without spaces) but not on the debug manual,
which uses custom font encodings.
