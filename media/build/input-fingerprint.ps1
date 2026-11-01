param([string]$Output)
$ErrorActionPreference='Stop'
$dbRoot=Split-Path -Parent $PSScriptRoot
$dbFiles=@()
foreach($dbFolder in @('rtl','al_ip','constr')){
    $dbFiles+=Get-ChildItem -LiteralPath (Join-Path $dbRoot $dbFolder) -Recurse -File
}
$dbFiles+=Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {$_.Extension -in @('.tcl','.ps1') -or $_.Name -eq 'sources.txt'}
$dbInputs=[ordered]@{}
foreach($dbFile in ($dbFiles | Sort-Object FullName)){
    $dbRelative=$dbFile.FullName.Substring($dbRoot.Length+1).Replace('\','/')
    $dbInputs[$dbRelative]=(Get-FileHash -LiteralPath $dbFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$dbJson=$dbInputs | ConvertTo-Json -Depth 4
if($Output){[IO.File]::WriteAllText($Output,$dbJson,[Text.UTF8Encoding]::new($false))}
else{$dbJson}
