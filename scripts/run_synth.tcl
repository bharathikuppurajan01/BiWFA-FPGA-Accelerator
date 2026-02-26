# Vivado TCL script for WFA Synthesis and Resource / Timing extraction
# Designed for automated execution to support academic publication results.

# Set project parameters
set proj_name "wfa_algo_hw"
set target_part "xczu9eg-ffvb1156-2-e" 
# (Example: Zynq UltraScale+ commonly used in bioinformatics accelerators)

# Start clean
create_project $proj_name ./$proj_name -part $target_part -force

# Add Verilog tracking all files automatically generated
add_files ../src/wfa_layer1_streaming.v
add_files ../src/wfa_layer2_compute.v
add_files ../src/wfa_layer3_storage.v
add_files ../src/wfa_layer4_traceback.v
add_files ../src/wfa_layer5_reconstruct.v
add_files ../src/wfa_master_ctrl.v
add_files ../src/wfa_top_5layer_algo.v

# Set top module for algorithms
set_property top wfa_top_5layer_algo [current_fileset]

# Create a baseline clock constraint for 200MHz (5.0ns)
set synth_constraints_file "wfa_timing.xdc"
set fd [open $synth_constraints_file w]
puts $fd "create_clock -period 5.000 -name clk -waveform {0.000 2.500} \[get_ports clk\]"
close $fd
add_files -fileset constrs_1 $synth_constraints_file

# Synthesis
puts "Starting Hardware Synthesis..."
synth_design -top wfa_top_5layer_algo -part $target_part -mode out_of_context

# Report Academic Metrics
puts "Generating Utilization and Performance Reports..."
report_utilization -file wfa_utilization_report.txt
report_timing_summary -file wfa_timing_summary.txt
report_power -file wfa_power_report.txt

# Save the checkpoint
write_checkpoint -force wfa_post_synth.dcp
puts "Synthesis Complete. Data generated for paper integration."

close_project
