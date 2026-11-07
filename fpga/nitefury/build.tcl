# build.tcl - a NiteFury II running SH-5 code.
#
#   vivado -mode batch -source fpga/nitefury/build.tcl
#   vivado -mode batch -source fpga/nitefury/build.tcl -tclargs -synth_only
#
# Options, via -tclargs:
#   -part <p>       FPGA part               (default xc7a200tfbg484-2)
#   -outdir <d>     where results go        (default out)
#   -core_div <n>   1000 MHz VCO / n        (default 40 -> 25 MHz)
#   -tck <ps>       DDR3 clock period       (default 3000, 666 MT/s: the
#                   speed that does not lose writes on this board,
#                   fpgaslop docs/ddr3-write-loss.md)
#   -slop <d>       the fpgaslop checkout   (default: the submodule)
#   -build_id <hex> BUILD_ID when there is no .git to ask
#   -effort high    slower, better place and route
#   -synth_only     stop after synth_design: utilisation and a first
#                   timing estimate
#
# Modelled on smol68k/fpga/nitefury/build.tcl, which has produced
# bitstreams that run on the card; the IP configuration is theirs, with
# the module names changed and SUBSYSTEM_ID 0x5a05. Builds in about 35
# minutes on Vivado 2026.1 (docs/soc.md, "Implementation"). The file list
# below is what boards/nitefury/lint-top.sh elaborates.

set part      xc7a200tfbg484-2
set outdir    ""
set coredat   40
set tck       3000
set effort    0
set synthonly 0

set here    [file normalize [file dirname [info script]]]
set sh5dir  [file normalize $here/../..]
set root    [file normalize $sh5dir/fpgaslop]

for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -part       { incr i; set part      [lindex $argv $i] }
        -outdir     { incr i; set outdir    [lindex $argv $i] }
        -core_div   { incr i; set coredat   [lindex $argv $i] }
        -tck        { incr i; set tck       [lindex $argv $i] }
        -slop       { incr i; set root      [lindex $argv $i] }
        -effort     { incr i; if {[lindex $argv $i] eq "high"} { set effort 1 } }
        -build_id   { incr i; set build_id_arg [lindex $argv $i] }
        -synth_only { set synthonly 1 }
        default     { puts "build.tcl: unknown option [lindex $argv $i]"; exit 2 }
    }
}

if {$outdir eq ""} { set outdir $sh5dir/out }

if {![file exists $root/rtl/slop_id.sv]} {
    error "build.tcl: the fpgaslop submodule is not checked out.\
           Run: git submodule update --init   (or pass -slop <path>)."
}

file mkdir $outdir
set ipdir $outdir/ip
# Wiped first: create_ip cannot reuse an output directory and silently
# builds name_1 (fpgaslop docs/notes-for-another-cpu-core.md section 5).
file delete -force $ipdir
file mkdir $ipdir

puts "build.tcl: part $part, core_div $coredat, tck $tck, fpgaslop from $root"

create_project -in_memory -part $part
set_msg_config -id {Synth 8-4442} -limit 100000
puts "build.tcl: Vivado [version -short]"

# ---------------------------------------------------------------------
# IP: identical to ddrslop's and smol68k's, module names changed
# ---------------------------------------------------------------------
create_ip -name axi_pcie -vendor xilinx.com -library ip \
    -module_name sh5_pcie_ep -dir $ipdir
set_property -dict [list \
    CONFIG.PCIE_BLK_LOCN            {X0Y0} \
    CONFIG.NO_OF_LANES              {X1} \
    CONFIG.MAX_LINK_SPEED           {2.5_GT/s} \
    CONFIG.REF_CLK_FREQ             {100_MHz} \
    CONFIG.INCLUDE_RC               {PCI_Express_Endpoint_device} \
    CONFIG.VENDOR_ID                {0x10EE} \
    CONFIG.DEVICE_ID                {0x7024} \
    CONFIG.CLASS_CODE               {0x058000} \
    CONFIG.BAR0_ENABLED             {true} \
    CONFIG.BAR0_TYPE                {Memory} \
    CONFIG.BAR0_SCALE               {Megabytes} \
    CONFIG.BAR0_SIZE                {512} \
    CONFIG.BAR_64BIT                {false} \
    CONFIG.PCIEBAR2AXIBAR_0         {0x00000000} \
    CONFIG.MSI_DECODE_ENABLED       {false} \
    CONFIG.INCLUDE_BAROFFSET_REG    {false} \
    CONFIG.axi_aclk_loopback        {false} \
] [get_ips sh5_pcie_ep]

# The BAR is 512 MB: sh5_hostif decodes bit 28, DRAM below and the
# register window above.
foreach {prop val} {
    CONFIG.SUBSYSTEM_VENDOR_ID 0x10EE
    CONFIG.SUBSYSTEM_ID        0x5a05
} {
    if {[catch {set_property $prop $val [get_ips sh5_pcie_ep]} e]} {
        puts "build.tcl: WARNING could not set $prop: [string trim $e]"
    }
}

create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
    -module_name sh5_pcie_cdc -dir $ipdir
set_property -dict [list \
    CONFIG.PROTOCOL         {AXI4} \
    CONFIG.DATA_WIDTH       {64} \
    CONFIG.ADDR_WIDTH       {32} \
    CONFIG.ID_WIDTH         {0} \
    CONFIG.READ_WRITE_MODE  {READ_WRITE} \
] [get_ips sh5_pcie_cdc]

# MIG from the board's .prj, with the clock period edited into a copy.
set prjsrc  $root/boards/nitefury/ddr3-1gb-800.prj
set prjfile $outdir/sh5_ddr3.prj
set fh [open $prjsrc r];  set prjtxt [read $fh]; close $fh
set n [regsub -all {<TimePeriod>[0-9]+</TimePeriod>} $prjtxt \
                  "<TimePeriod>$tck</TimePeriod>" prjout]
if {$n == 0} {
    error "build.tcl: no <TimePeriod> in $prjsrc"
}
set fh [open $prjfile w]; puts -nonewline $fh $prjout; close $fh
puts "build.tcl: DDR3 TimePeriod -> $tck ps in $n place(s)"

create_ip -name mig_7series -vendor xilinx.com -library ip \
    -module_name sh5_ddr3 -dir $ipdir
set_property CONFIG.XML_INPUT_FILE $prjfile [get_ips sh5_ddr3]

foreach ip {sh5_pcie_ep sh5_pcie_cdc sh5_ddr3} {
    generate_target {instantiation_template synthesis} [get_ips $ip]
    synth_ip [get_ips $ip]
    set veo [glob -nocomplain $ipdir/$ip/*.veo]
    if {[llength $veo]} {
        file copy -force [lindex $veo 0] $outdir/$ip.veo
        puts "build.tcl: wrote $outdir/$ip.veo -- the real port list"
    }
}

# ---------------------------------------------------------------------
# RTL: fpgaslop's blocks, the core, the system, the board top
# ---------------------------------------------------------------------
read_verilog -sv [list \
    $root/rtl/slop_card.sv \
    $root/rtl/slop_id.sv \
    $root/rtl/slop_reset.sv \
    $root/rtl/slop_mailbox.sv \
    $root/rtl/slop_flashreg.sv \
    $root/rtl/slop_spiflash.sv \
    $root/rtl/slop_dma.sv \
    $root/rtl/slop_dmadesc.sv \
    $root/rtl/slop_dmablk.sv \
    $root/rtl/axi4_to_req.sv \
    $root/rtl/req_to_axi4.sv \
    $root/rtl/mem_cdc.sv \
    $root/rtl/memarb.sv \
    $sh5dir/rtl/shwy_pkg.sv \
    $sh5dir/rtl/sh5_pkg.sv \
    $sh5dir/rtl/sh5_uop_pkg.sv \
    $sh5dir/rtl/sh5_decode.sv \
    $sh5dir/rtl/sh5_alu.sv \
    $sh5dir/rtl/sh5_cexpand.sv \
    $sh5dir/rtl/sh5_ctrl.sv \
    $sh5dir/rtl/sh5_tlb.sv \
    $sh5dir/rtl/sh5_ram_sdp.sv \
    $sh5dir/rtl/sh5_icache.sv \
    $sh5dir/rtl/sh5_dcache.sv \
    $sh5dir/rtl/sh5_biu.sv \
    $sh5dir/rtl/sh5_ifu.sv \
    $sh5dir/rtl/sh5_mm.sv \
    $sh5dir/rtl/sh5_fpu.sv \
    $sh5dir/rtl/sh5_core.sv \
    $sh5dir/rtl/soc/sh5_shwy_req.sv \
    $sh5dir/rtl/soc/sh5_periph.sv \
    $sh5dir/rtl/soc/sh5_hub.sv \
    $sh5dir/rtl/soc/sh5_hostif.sv \
    $sh5dir/rtl/soc/sh5_top.sv \
    $here/sh5_board_top.sv \
]

# MIG writes the DDR3 pin constraints itself. nitefury_core.xdc carries
# the clock, reset and LED pins and the configuration settings;
# nitefury_p2.xdc is for header pins this design does not use.
read_xdc $root/boards/nitefury/nitefury_core.xdc
read_xdc $root/boards/nitefury/nitefury_pcie.xdc

# BUILD_ID: upper 32 bits the commit, lower 32 a hash of the diff when
# the tree is dirty (fpgaslop docs/notes-for-another-cpu-core.md section 4).
set git_sha 0
set git_diff 0
if {[info exists build_id_arg]} {
    scan $build_id_arg %llx build_id_probe
    set git_sha  [expr {($build_id_probe >> 32) & 0xFFFFFFFF}]
    set git_diff [expr {$build_id_probe & 0xFFFFFFFF}]
} elseif {![catch {exec git -C $sh5dir rev-parse --short=8 HEAD} sha]} {
    scan [string trim $sha] %x git_sha
}
if {![info exists build_id_arg] && ![catch {exec git -C $sh5dir diff HEAD} d]} {
    set d [string trim $d]
    if {[string length $d] > 0} {
        set h 0
        foreach c [split $d ""] {
            set h [expr {(($h * 33) + [scan $c %c]) & 0xFFFFFFFF}]
        }
        set git_diff $h
        puts "build.tcl: WORKING TREE IS DIRTY -- BUILD_ID carries a diff hash"
    }
}
set build_id [expr {($git_sha << 32) | $git_diff}]
# BUILD_CFG: [15:8] core_div, [31:16] DDR3 tck in ps
set build_cfg [expr {($tck << 16) | ($coredat << 8)}]
set clk_hz [expr {int(1000000000.0 / $coredat)}]
puts [format "build.tcl: BUILD_ID %016llx BUILD_CFG %016llx core %d Hz" $build_id $build_cfg $clk_hz]

# ---- messages that have cost silicon are errors here ----
# Verilator accepts all three and the netlist is wrong (checklog.py has the
# history): an undeclared name becomes a one-bit wire (Synth 8-11241); a
# net without a driver in one of our modules (Synth 8-3848: the register
# file, bitstream 8a0aba28, every register read as zero). Promoted for our
# files and modules only; the IP cores produce both benignly.
set_msg_config -id {Synth 8-11241} -string [list "[file normalize $sh5dir]/rtl/"] -new_severity ERROR
set_msg_config -id {Synth 8-11241} -string [list "[file normalize $sh5dir]/fpga/"] -new_severity ERROR
set_msg_config -id {Synth 8-11241} -string [list "[file normalize $root]/rtl/"] -new_severity ERROR
foreach f [get_files -quiet *.sv] {
    set n [file normalize $f]
    if {[string first [file normalize $sh5dir] $n] == 0 || [string first [file normalize $root]/rtl $n] == 0} {
        set m [file rootname [file tail $f]]
        set_msg_config -id {Synth 8-3848} -string [list "module/entity $m "] -new_severity ERROR
    }
}

synth_design -top sh5_board_top -part $part \
    -generic [list BUILD_ID=64'd$build_id \
                   BUILD_CFG=64'd$build_cfg \
                   CLK_HZ=$clk_hz \
                   CORE_DIV=[expr {double($coredat)}]]

report_utilization -hierarchical -file $outdir/synth_util.rpt
report_timing_summary -file $outdir/synth_timing.rpt

if {$synthonly} {
    puts "build.tcl: -synth_only, stopping before place and route."
    exit 0
}

if {$effort} {
    opt_design -directive Explore
    place_design    -directive ExtraTimingOpt
    phys_opt_design -directive AggressiveExplore
    route_design    -directive Explore
    phys_opt_design -directive AggressiveExplore
} else {
    opt_design
    place_design
    phys_opt_design
    route_design
}

report_timing_summary -file $outdir/timing.rpt
report_utilization    -file $outdir/util.rpt
report_utilization -hierarchical -file $outdir/util_hier.rpt
report_timing -max_paths 20 -nworst 1 -unique_pins -delay_type max \
    -sort_by slack -input_pins -file $outdir/timing_paths.rpt
report_clock_networks -file $outdir/clocks.rpt
# the core clock on its own: the MIG's 200 MHz paths head the overall list
report_timing -max_paths 40 -nworst 1 -unique_pins -delay_type max -sort_by slack \
    -group clk_core -file $outdir/timing_core.rpt

# setup and hold separately (smol68k read a hold slack as a setup problem once)
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "build.tcl: setup WNS = $wns ns, hold WHS = $whs ns"
if {$wns < 0} { puts "build.tcl: SETUP NOT MET: lower the clock with -core_div or read $outdir/timing_paths.rpt" }
if {$whs < 0} { puts "build.tcl: HOLD NOT MET: a clock-skew or crossing problem, not a depth problem" }

set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
write_bitstream -force $outdir/sh5.bit
write_cfgmem -force -format bin -interface spix4 -size 16 \
    -loadbit "up 0x0 $outdir/sh5.bit" $outdir/sh5.bin

puts "build.tcl: $outdir/sh5.bit  (build id $build_id)"
