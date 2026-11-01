param([string]$RunDir)
$ErrorActionPreference='Stop'
$dbRoot=Split-Path -Parent $PSScriptRoot
if(-not $RunDir){$RunDir=Join-Path $dbRoot 'Runs/phy'}
$dbProject='MultimediaSystem_render_linktest'
$dbTiming=Get-Content -LiteralPath (Join-Path $RunDir ($dbProject+'_phy.ts')) -Raw
$dbQorPath=Join-Path $RunDir 'final.qor'
if(-not (Test-Path -LiteralPath $dbQorPath)){throw 'Missing final post-hold QoR report; rebuild with the current flow.'}
$dbQor=Get-Content -LiteralPath $dbQorPath -Raw
$dbValues=@{}
foreach($dbName in @('SWNS','STNS','HWNS','HTNS')){
    $dbMatch=[regex]::Match($dbTiming,$dbName+':\s*([-0-9.]+)ns')
    if(-not $dbMatch.Success){throw "Missing timing metric $dbName"}
    $dbValues[$dbName]=[double]::Parse($dbMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
}
$dbSlices=[regex]::Match($dbQor,'slices percentage\s*\|\s*([0-9.]+)%')
$dbRams=[regex]::Match($dbQor,'#RAMs\s*\|\s*(\d+)')
if(-not $dbSlices.Success -or -not $dbRams.Success){throw 'Missing physical resource metrics'}
$dbSlicePct=[double]::Parse($dbSlices.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
$dbRamCount=[int]$dbRams.Groups[1].Value
$dbResult=[ordered]@{board='render';setup_wns_ns=$dbValues.SWNS;setup_tns_ns=$dbValues.STNS;
    hold_wns_ns=$dbValues.HWNS;hold_tns_ns=$dbValues.HTNS;slice_percent=$dbSlicePct;bram9k=$dbRamCount}
Write-Host ($dbResult | ConvertTo-Json -Compress)
if($dbValues.SWNS -lt 0.100 -or $dbValues.STNS -ne 0 -or $dbValues.HWNS -lt 0 -or $dbValues.HTNS -ne 0 -or $dbSlicePct -gt 80 -or $dbRamCount -gt 56){
    throw 'UNQUALIFIED: requires setup WNS >=100ps, zero setup/hold violations, slices <=80%, BRAM9K <=56.'
}
$dbInputsPath=Join-Path $RunDir 'inputs.json'
if(-not (Test-Path -LiteralPath $dbInputsPath)){throw 'Missing build input fingerprint'}
$dbExpected=Get-Content -LiteralPath $dbInputsPath -Raw | ConvertFrom-Json -AsHashtable
$dbCurrent=(& (Join-Path $PSScriptRoot 'input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
if($dbExpected.Count -ne $dbCurrent.Count){throw 'Source set changed since build started'}
foreach($dbName in $dbExpected.Keys){if($dbExpected[$dbName] -ne $dbCurrent[$dbName]){throw "Build input changed: $dbName"}}
$dbResult.bit_sha256=(Get-FileHash -LiteralPath (Join-Path $RunDir ($dbProject+'.bit')) -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $RunDir 'qualification.json'),($dbResult | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Host 'QUALIFIED: tool resource/timing/input gates passed. Hardware acceptance remains separate.'
