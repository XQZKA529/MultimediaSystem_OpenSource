param([string]$Output)
$ErrorActionPreference='Stop'
$dbRoot=Split-Path -Parent $PSScriptRoot
$dbQueue=[Collections.Generic.Queue[string]]::new()
$dbSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($dbLine in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sources.txt'))){
 if($dbLine.Trim()){$dbQueue.Enqueue((Join-Path $dbRoot $dbLine.Trim()))}
}
foreach($dbScript in (Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {$_.Extension -in @('.tcl','.ps1','.v','.adc','.sdc') -or $_.Name -eq 'sources.txt'})){
 $dbQueue.Enqueue($dbScript.FullName)
}
while($dbQueue.Count){
 $dbPath=[IO.Path]::GetFullPath($dbQueue.Dequeue())
 if(-not $dbPath.StartsWith($dbRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Diagnostic dependency escapes board: $dbPath"}
 if(-not (Test-Path -LiteralPath $dbPath -PathType Leaf)){throw "Missing diagnostic dependency: $dbPath"}
 if(-not $dbSeen.Add($dbPath)){continue}
 $dbDir=Split-Path -Parent $dbPath
 if([IO.Path]::GetExtension($dbPath) -in @('.v','.vh')){
  foreach($dbInclude in [regex]::Matches((Get-Content -LiteralPath $dbPath -Raw),'`include\s+"([^"]+)"')){
   $dbQueue.Enqueue((Join-Path $dbDir $dbInclude.Groups[1].Value))
  }
 }elseif([IO.Path]::GetExtension($dbPath) -eq '.ipc'){
  [xml]$dbIpc=Get-Content -LiteralPath $dbPath -Raw
  foreach($dbGenerated in $dbIpc.SelectNodes('//GeneratedFiles/*')){
   if($dbGenerated.GetAttribute('Enable') -eq 'true'){$dbQueue.Enqueue((Join-Path $dbDir $dbGenerated.InnerText))}
  }
 }
}
$dbInputs=[ordered]@{}
foreach($dbPath in ($dbSeen | Sort-Object)){
 $dbRelative=$dbPath.Substring($dbRoot.Length+1).Replace('\','/')
 $dbInputs[$dbRelative]=(Get-FileHash -LiteralPath $dbPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
$dbJson=$dbInputs | ConvertTo-Json -Depth 4
if($Output){[IO.File]::WriteAllText($Output,$dbJson,[Text.UTF8Encoding]::new($false))}else{$dbJson}
