# Exercise the real bitgen qualification procedure with report fixtures.
# Vendor bitgen is stubbed: this test never generates a bitstream.
set workspace [file normalize [file join [file dirname [info script]] ../..]]
set f [open [file join $workspace media build MyFlow.tcl] r]
set source [read $f]
close $f
set start [string first {proc bitgen_fun } $source]
if {$start<0} {error "Missing bitgen_fun"}
set body ""
foreach line [split [string range $source $start end] "\n"] {
  append body $line "\n"
  if {[info complete $body]} {break}
}
eval $body
proc bitgen {args} {set ::gate_test_bitgen_called 1}
proc setup_debugger {args} {}
proc export_bitgen_param {args} {}
set testdir [file join $workspace media Runs flow_gate_test_[pid]_[clock seconds]]
file mkdir $testdir
cd $testdir
proc write_fixture {path data} {
  set f [open $path w]
  puts $f $data
  close $f
}
proc run_gate_case {name ram9 fifo9 ram32 total setup stns hold htns expected} {
  set prj_name probe
  set singleRun 1
  set ::gate_test_bitgen_called 0
  write_fixture probe_phy.ts "SWNS: ${setup}ns\nSTNS: ${stns}ns\nHWNS: ${hold}ns\nHTNS: ${htns}ns"
  write_fixture final.qor "| slices percentage | 95.70% |\n| #RAMs | $total |"
  write_fixture probe_phy.area " #bram9k $ram9\n #fifo9k $fifo9\n #bram32k $ram32"
  set failed [catch {bitgen_fun} result]
  if {$expected} {
    if {$failed || !$::gate_test_bitgen_called} {error "FAIL $name: $result"}
  } elseif {!$failed || $::gate_test_bitgen_called} {
    error "FAIL $name: unqualified build reached bitgen"
  }
  puts "PASS $name"
}
run_gate_case current_design 58 0 1 59 0.218 0 0.059 0 1
run_gate_case exact_device_capacity 64 0 16 80 0.100 0 0 0 1
run_gate_case fifo_shared_pool 63 1 16 80 0.200 0 0.059 0 1
run_gate_case ram9_overflow 65 0 0 65 0.200 0 0.059 0 0
run_gate_case fifo_pool_overflow 63 2 0 65 0.200 0 0.059 0 0
run_gate_case ram32_overflow 0 0 17 17 0.200 0 0.059 0 0
run_gate_case count_mismatch 58 0 1 58 0.200 0 0.059 0 0
run_gate_case setup_margin 58 0 1 59 0.099 0 0.059 0 0
run_gate_case setup_violation 58 0 1 59 -0.001 -0.001 0.059 0 0
run_gate_case hold_violation 58 0 1 59 0.200 0 -0.001 -0.001 0
run_gate_case nonzero_tns 58 0 1 59 0.200 -0.001 0.059 0 0
write_fixture probe_phy.area "#bram9k 58\n#fifo9k 0"
set prj_name probe
set singleRun 1
set gate_test_bitgen_called 0
if {![catch {bitgen_fun}] || $gate_test_bitgen_called} {error "FAIL missing RAM counter"}
puts "PASS missing_ram_counter"
puts "*** PASS *** media bitgen RAM capacity/accounting and timing gates (12 cases)"
puts "Evidence: $testdir"
