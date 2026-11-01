param([string]$TdRoot='D:/AnLu_FPGA_environment',[ValidateSet('project','syn')][string]$Stage='syn',
    [ValidateSet('media','render')][string[]]$Boards=@('media','render'))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$target=Join-Path $env:TEMP ('dual board portability '+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $target | Out-Null
foreach($board in $Boards){
    # Deliberately change the directory name, and exclude generated products.
    $source=Join-Path $root $board
    $dest=Join-Path $target ($board+'_isolated')
    New-Item -ItemType Directory -Path $dest | Out-Null
    foreach($folder in @('rtl','al_ip','constr','build','sim','doc','diag')){
        Copy-Item -LiteralPath (Join-Path $source $folder) -Destination $dest -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $source ('MultimediaSystem_'+$board+'.al')) -Destination $dest
    & (Join-Path $dest 'build/run.ps1') -Stage project -TdRoot $TdRoot
    $log=Get-Content -LiteralPath (Join-Path $dest 'Runs/project.txt') -Raw
    if($log -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b'){throw "Portable project analysis failed: $dest"}
    if($Stage -eq 'syn'){& (Join-Path $dest 'build/run.ps1') -Stage syn -RunTag portable -TdRoot $TdRoot}
    & (Join-Path $dest 'sim/run.ps1') -Test tb_link
    Write-Host "PASS portable native analysis and link simulation: $dest"
}
Write-Host "PORTABLE_EVIDENCE=$target"
