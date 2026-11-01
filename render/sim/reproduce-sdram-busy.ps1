# Run the production 720p test against a temporary copy of the old busy gate.
# Production RTL is never changed; the expected underflow proves test coverage.
$ErrorActionPreference='Stop'
$board=Split-Path -Parent $PSScriptRoot
$ms=if($env:MODELSIM_BIN){$env:MODELSIM_BIN}else{'D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'}
$td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
$work=Join-Path $env:TEMP ('sdram_busy_repro_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$rtl=Get-Content -LiteralPath "$board/rtl/framebuffer/frame_fifo_read_dual.v" -Raw
$needle='App_rd_en=(state==S_BURST) && issued<target;'
if(-not $rtl.Contains($needle)){throw 'Production reader changed; review the reproduction patch.'}
$rtl=$rtl.Replace($needle,'App_rd_en=(state==S_BURST) && issued<target && !Sdr_busy;')
[IO.File]::WriteAllText((Join-Path $work 'old_reader.v'),$rtl,[Text.UTF8Encoding]::new($false))
$files=@('framebuffer/afifo_32_16_256.v','framebuffer/rgb888_word_reader.v','video/pixel_mixer.v',
    'video/video_stream_reg.v','framebuffer/sdram_app_arb.v','sdram/sdram.v','sdram/sdr_as_ram.enc.v',
    'sdram/sdr_init_ref.enc.v','sdram/sdr_wrrd.enc.v') | ForEach-Object {"$board/rtl/$_"}
$files=@("$work/old_reader.v","$td/sim_release/eg4/eg_phy_sdram_2m_32.v")+$files+@("$board/sim/tb_frame_read_dual.v")
Push-Location $work
try{
    & "$ms/vlib.exe" work | Out-Null
    & "$ms/vlog.exe" "+incdir+$board/rtl" "+incdir+$board/rtl/sdram" @files *> compile.txt
    if($LASTEXITCODE -ne 0){Get-Content compile.txt;throw 'Reproduction compile failed'}
    & "$ms/vsim.exe" -c -do 'run -all; quit -f' tb_frame_read_dual *> simulation.txt
    $log=Get-Content simulation.txt -Raw
    $path=Join-Path $board 'build/evidence/sdram-busy-old-underflow.txt'
    [IO.File]::WriteAllText($path,$log,[Text.UTF8Encoding]::new($false))
    if($log -notmatch '(old|new) pixel \d+ valid=0'){Write-Host $log;throw 'Expected underflow was not reproduced'}
    Write-Host ($log | Select-String -Pattern '.*Fatal:.*' | ForEach-Object {$_.Matches.Value})
    Write-Host 'PASS reproduction: old busy gate causes 720p underflow with actual vendor controller timing'
}finally{Pop-Location}
