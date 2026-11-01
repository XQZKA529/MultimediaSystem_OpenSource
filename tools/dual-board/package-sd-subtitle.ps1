param(
    [Parameter(Mandatory=$true)][string]$MediaRun,
    [Parameter(Mandatory=$true)][string]$RenderRun,
    [string]$Output='build/sd-subtitle-release'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outPath=[IO.Path]::GetFullPath((Join-Path $root $Output))
if(Test-Path -LiteralPath $outPath){throw 'Output already exists; select a fresh -Output directory.'}
$workspacePrefix=$root.TrimEnd('\')+'\'
if(-not $outPath.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Package output must be inside the workspace.'}
$stagePath=$outPath+'_staging_'+[Guid]::NewGuid().ToString('N')
$runs=@{media=$MediaRun;render=$RenderRun}
# Check both boards before creating a package. The checker also compares the
# full RTL/IP/constraint/build fingerprint with the current workspace.
foreach($board in @('media','render')){
    $runPath=[IO.Path]::GetFullPath((Join-Path $root $runs[$board]))
    & (Join-Path $root "$board/build/check-reports.ps1") -RunDir $runPath
    # Confirm final STA used every original clock domain. A report with lost
    # generated-clock constraints must never qualify just because WNS is high.
    $timing=Get-Content -LiteralPath (Join-Path $runPath "MultimediaSystem_${board}_pr.timing") -Raw
    $clocks=@{sys_clk=50.000;bus_clk=100.000;mem_tx_clk=125.000;rgmii_rx_clk=125.000;tx_clk_90=125.000}
    if($board -eq 'render'){$clocks.video_clk=75.002;$clocks.hdmi_5x_clk=375.094;$clocks.mem_sft_clk=125.000}
    foreach($clock in $clocks.Keys){
        $pattern='(?m)^\s*clk\d+:\s+([0-9.]+)\s+\d+\s+'+[regex]::Escape($clock)+'\s*$'
        $match=[regex]::Match($timing,$pattern)
        if(-not $match.Success){throw "Missing final STA clock: $board/$clock"}
        $frequency=[double]::Parse($match.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
        if([Math]::Abs($frequency-$clocks[$clock]) -gt 0.001){throw "Unexpected final STA frequency: $board/$clock=$frequency MHz"}
    }
}
New-Item -ItemType Directory -Force $stagePath | Out-Null
foreach($board in @('media','render')){
    $runPath=[IO.Path]::GetFullPath((Join-Path $root $runs[$board]))
    $target=Join-Path $stagePath $board
    New-Item -ItemType Directory -Force $target | Out-Null
    foreach($name in @("MultimediaSystem_$board.bit",'qualification.json','inputs.json',
        'settings.cfg','entry.tcl','final.qor',"MultimediaSystem_${board}_phy.area", "MultimediaSystem_${board}_phy.ts")){
        Copy-Item -LiteralPath (Join-Path $runPath $name) -Destination $target
    }
    # TD's automatic final_timing.rpt can precede the second hold repair.
    # Package the explicit final report used by this flow instead.
    Copy-Item -LiteralPath (Join-Path $runPath "MultimediaSystem_${board}_pr.timing") -Destination (Join-Path $target 'final_timing.rpt')
    Copy-Item -LiteralPath (Join-Path $root "$board/build/evidence") -Destination (Join-Path $target 'simulation') -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $root 'examples/sd-subtitle') -Destination (Join-Path $stagePath 'examples') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/sd-subtitle-2026-10-11.md') -Destination $stagePath
$guidePath=Join-Path $stagePath 'sd-subtitle-2026-10-11.md'
$guide=(Get-Content -LiteralPath $guidePath -Raw).Replace('../../examples/sd-subtitle/','examples/')
[IO.File]::WriteAllText($guidePath,$guide,[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/protocol-v1.md') -Destination $stagePath
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/evidence/sd-subtitle-system.txt') -Destination $stagePath
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/evidence') -Destination (Join-Path $stagePath 'system-simulation') -Recurse -Force
$frames=Join-Path $root 'build/sd-subtitle-sim/frames'
if(Test-Path -LiteralPath $frames){Copy-Item -LiteralPath $frames -Destination (Join-Path $stagePath 'frames') -Recurse -Force}
$manifest=[ordered]@{protocol='1.7';hardware_acceptance='pending';media_run=$MediaRun;render_run=$RenderRun;sha256=[ordered]@{}}
$readme=@'
# SD TXT subtitle paired release — protocol 1.7

Program media/MultimediaSystem_media.bit and render/MultimediaSystem_render.bit
as a pair. Verify their hashes against manifest.json before programming.

Place ASCII/UTF-8 TXT files in the FAT32 root. A BMP and its automatic subtitle
must share the complete basename. Select a TXT in FILES for a manual subtitle;
use SETTINGS > SD SUBTITLE for DISPLAY, AUTO, and CLEAR MANUAL. Both modes are
off after a media system reset. Only the first line (up to 106 characters) is
displayed. See sd-subtitle-2026-10-11.md for usage and the hardware checklist.

Each board includes qualification.json, final timing/resource reports,
inputs.json, build settings, and simulation evidence. The input fingerprints
describe the source revision used for these bits. frames/ contains simulation
previews, and examples/ contains editable TXT samples.

Physical-board programming and the 30-minute endurance acceptance are pending;
the qualification reports certify the build and simulation checks only.
'@
[IO.File]::WriteAllText((Join-Path $stagePath 'README.md'),$readme,[Text.UTF8Encoding]::new($false))
foreach($file in (Get-ChildItem -LiteralPath $stagePath -Recurse -File | Where-Object {$_.Name -ne 'manifest.json'} | Sort-Object FullName)){
    $relative=$file.FullName.Substring($stagePath.Length+1).Replace('\','/')
    $manifest.sha256[$relative]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $stagePath 'manifest.json'),($manifest | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
# Both resolved targets are fresh directories beneath the verified workspace;
# publish the complete package only after its checksums have been written.
if(-not $stagePath.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid staging target'}
Move-Item -LiteralPath $stagePath -Destination $outPath
Write-Host "QUALIFIED paired SD subtitle package: $outPath"
