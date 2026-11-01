param([string]$RunDir)
$ErrorActionPreference='Stop'
$dbRoot=Split-Path -Parent $PSScriptRoot
if(-not $RunDir){$RunDir=Join-Path $dbRoot 'Runs/phy'}
$dbProject='MultimediaSystem_media'
$dbTiming=Get-Content -LiteralPath (Join-Path $RunDir ($dbProject+'_phy.ts')) -Raw
$dbQorPath=Join-Path $RunDir 'final.qor'
if(-not (Test-Path -LiteralPath $dbQorPath)){throw 'Missing final post-hold QoR report; rebuild with the current flow.'}
$dbQor=Get-Content -LiteralPath $dbQorPath -Raw
$dbSetupEndpoints=[regex]::Match($dbQor,'Num of violated S-EP\s*\|\s*(\d+)')
$dbHoldEndpoints=[regex]::Match($dbQor,'Num of violated H-EP\s*\|\s*(\d+)')
if(-not $dbSetupEndpoints.Success -or -not $dbHoldEndpoints.Success){throw 'Missing final violation endpoint counts'}
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
$dbArea=Get-Content -LiteralPath (Join-Path $RunDir ($dbProject+'_phy.area')) -Raw
$dbSlices=[regex]::Match($dbQor,'#slices\s*\|\s*(\d+)')
$dbLuts=[regex]::Match($dbArea,'(?m)^\s*#lut\s+(\d+)\s+out of\s+(\d+)')
$dbRegs=[regex]::Match($dbArea,'(?m)^\s*#reg\s+(\d+)\s+out of\s+(\d+)')
$dbDsps=[regex]::Match($dbArea,'(?m)^\s*#dsp\s+(\d+)\s+out of\s+(\d+)')
$dbRam9Count=[int]([regex]::Match($dbArea,'(?m)^\s*#bram9k\s+(\d+)').Groups[1].Value)
$dbRam32Count=[int]([regex]::Match($dbArea,'(?m)^\s*#bram32k\s+(\d+)').Groups[1].Value)
$dbFifo9Count=[int]([regex]::Match($dbArea,'(?m)^\s*#fifo9k\s+(\d+)').Groups[1].Value)
if($dbRamCount -ne $dbRam9Count+$dbRam32Count+$dbFifo9Count){throw 'RAM resource type accounting mismatch'}
$dbSliceCount=if($dbSlices.Success){[int]$dbSlices.Groups[1].Value}else{throw 'Missing slice count'}
$dbLutCount=if($dbLuts.Success){[int]$dbLuts.Groups[1].Value}else{throw 'Missing LUT count'}
$dbRegCount=if($dbRegs.Success){[int]$dbRegs.Groups[1].Value}else{throw 'Missing register count'}
$dbDspCount=if($dbDsps.Success){[int]$dbDsps.Groups[1].Value}else{throw 'Missing DSP count'}
$dbLutLimit=[int]$dbLuts.Groups[2].Value;$dbRegLimit=[int]$dbRegs.Groups[2].Value;$dbDspLimit=[int]$dbDsps.Groups[2].Value
$dbResult=[ordered]@{board='media';setup_wns_ns=$dbValues.SWNS;setup_tns_ns=$dbValues.STNS;
    hold_wns_ns=$dbValues.HWNS;hold_tns_ns=$dbValues.HTNS;slice_percent=$dbSlicePct;slice_advisory_exceeded=($dbSlicePct -gt 80);bram9k=$dbRam9Count;bram32k=$dbRam32Count;fifo9k=$dbFifo9Count;qor_ram_count=$dbRamCount}
Write-Host ($dbResult | ConvertTo-Json -Compress)
if($dbSlicePct -gt 80){Write-Warning "Slice utilization $dbSlicePct% exceeds the 80% advisory level; timing and input checks remain mandatory."}
if($dbValues.SWNS -lt 0 -or $dbValues.STNS -ne 0 -or $dbValues.HWNS -lt 0 -or $dbValues.HTNS -ne 0 -or
   [int]$dbSetupEndpoints.Groups[1].Value -ne 0 -or [int]$dbHoldEndpoints.Groups[1].Value -ne 0 -or
   $dbSliceCount -gt 9800 -or $dbLutCount -gt $dbLutLimit -or $dbRegCount -gt $dbRegLimit -or $dbDspCount -gt $dbDspLimit -or
   ($dbRam9Count+$dbFifo9Count) -gt 64 -or $dbRam32Count -gt 16){
    throw 'UNQUALIFIED: requires zero setup/hold violations, Slice <=9800, LUT/register/DSP within device capacity, BRAM9K+FIFO9K <=64 and BRAM32K <=16.'
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
