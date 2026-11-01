$ErrorActionPreference='Stop'
$dbBoard=Split-Path -Parent $PSScriptRoot
$dbMs=if($env:MODELSIM_BIN){$env:MODELSIM_BIN}else{'D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'}
$dbWork=Join-Path $env:TEMP ('prbs_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dbWork | Out-Null
Push-Location $dbWork
try{
 & (Join-Path $dbMs 'vlib.exe') work | Out-Null
 & (Join-Path $dbMs 'vlog.exe') (Join-Path $PSScriptRoot 'db_prbs_mac.v') (Join-Path $PSScriptRoot 'tb_prbs.v') *> compile.txt
 if($LASTEXITCODE -ne 0){Get-Content compile.txt;throw 'PRBS compile failed'}
 & (Join-Path $dbMs 'vsim.exe') -c -do 'run -all; quit -f' tb_prbs *> result.txt
 $dbText=Get-Content result.txt -Raw
 if($dbText -notmatch '\*\*\* PASS \*\*\*'){Write-Host $dbText;throw 'PRBS simulation failed'}
 New-Item -ItemType Directory -Force (Join-Path $dbBoard 'doc/evidence') | Out-Null
 [IO.File]::WriteAllText((Join-Path $dbBoard 'doc/evidence/prbs.txt'),$dbText)
 Write-Host ($dbText | Select-String -Pattern '.*\*\*\* PASS.*' | ForEach-Object {$_.Matches.Value})
}finally{Pop-Location}
