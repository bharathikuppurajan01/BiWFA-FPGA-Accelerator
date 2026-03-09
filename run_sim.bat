@echo off
set VIVADO_BIN=C:\Xilinx\Vivado\2024.2\bin

call %VIVADO_BIN%\xvlog.bat -m64 --incr --relax sim/biwfa_wrapper_tb.v src/biwfa_top_wrapper.v src/biwfa_master_ctrl.v src/biwfa_intersect.v src/biwfa_seg_stack.v src/biwfa_base_solver.v src/biwfa_cigar_coalescer.v src/wfa_master_ctrl.v src/wfa_layer1_streaming.v src/wfa_layer2_compute.v src/wfa_layer3_storage.v > xvlog.log 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] xvlog failed.
    type xvlog.log
    exit /b %errorlevel%
)

call %VIVADO_BIN%\xelab.bat -m64 --incr --debug typical --relax --mt 2 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip --snapshot biwfa_wrapper_tb_behav xil_defaultlib.biwfa_wrapper_tb xil_defaultlib.glbl -log xelab.log > xelab_out.log 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] xelab failed.
    type xelab.log
    exit /b %errorlevel%
)

call %VIVADO_BIN%\xsim.bat biwfa_wrapper_tb_behav -key {Behavioral:sim_1:Functional:biwfa_wrapper_tb} -tclbatch sim/simulate.tcl -log xsim.log > xsim_out.log 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] xsim failed.
    type xsim.log
    exit /b %errorlevel%
)

echo [SUCCESS] Simulation Finished.
type xsim.log
