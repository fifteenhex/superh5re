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

## From larsbrinkhoff/awesome-cpus

`awesome-cpus/` holds the SH-5 documents from
<https://github.com/larsbrinkhoff/awesome-cpus/tree/master/SuperH> that are not
in the set above, under their names there. Their text streams use custom font
encodings, so `tools/pdfstrings.py` cannot read them; the dates are the PDF
CreationDate fields.

| File | PDF Title field | Created | SHA-256 |
|---|---|---|---|
| `sh5_abi.pdf` | Language Independent Application Binary Interface (SH-5 ABI) | 2002-02-28 | `f30e502d3001579d9c83e6668f5cf179317f98847b9607174bac61683dd6fafb` |
| `sysv1.pdf` | (Preface) -- SH-5 System Architecture, volume 1 by name and date | 2002-03-18 | `0755866440a207c1ceeaa01e67025b47765b186bba9578578d6d819bdc6e5b6c` |
| `sysv2.pdf` | (Preface) -- SH-5 System Architecture, volume 2 by name and date | 2002-03-18 | `54b991f688eaff52eb7c66cc93808a5e9004e654b1d6211d7f84c7c029e92357` |
| `sysv3.pdf` | (Preface) -- SH-5 System Architecture, volume 3; another copy of the debug manual by date | 2002-03-19 | `84c25a9cf0aae4b2a03fb3580e307410ef8e4c628ee258df7f36c88092c36a04` |

The same directory also has `cpush5v1..4.pdf` (the four CPU Core volumes) and
`sh5_asm.pdf` (05-ASM-10001, another copy of the file above, SHA-256
`5ef282768f198fdc029b00ae648682a98bf918ffeb7c29ce898951518b579ccc`), plus
SH-1/SH-4 manuals.
