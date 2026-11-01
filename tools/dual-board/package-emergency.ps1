param(
    [Parameter(Mandatory)][string]$MediaRun,
    [Parameter(Mandatory)][string]$RenderRun,
    [string]$Output='build/emergency-v1/release'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
try {
    $runs=@{media=(Resolve-Path -LiteralPath $MediaRun).Path;render=(Resolve-Path -LiteralPath $RenderRun).Path}
    if(Test-Path -LiteralPath $Output){throw 'Release destination already exists; use a fresh output directory.'}
    foreach($board in @('media','render')) {
        & "./$board/build/check-reports.ps1" -RunDir $runs[$board]
    }
    $regression=Get-Content -LiteralPath 'doc/dual-board/evidence/emergency-regression.json' -Raw | ConvertFrom-Json -AsHashtable
    if(-not $regression.full_regression){throw 'A full regression is required for release.'}
    foreach($board in @('media','render')) {
        $current=(& "./$board/build/input-fingerprint.ps1") | ConvertFrom-Json -AsHashtable
        if($current.Count -ne $regression.inputs[$board].Count){throw "Regression source set changed: $board"}
        foreach($name in $current.Keys){if($current[$name] -ne $regression.inputs[$board][$name]){throw "Regression input changed: $board/$name"}}
    }
    foreach($name in $regression.evidence.Keys){
        if((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $regression.evidence[$name]){throw "Regression evidence changed: $name"}
    }
    $out=[IO.Path]::GetFullPath((Join-Path $root $Output))
    New-Item -ItemType Directory -Path $out | Out-Null
    $manifest=[ordered]@{protocol='1.8';device='EG4S20BG256';hardware_acceptance='pending';boards=[ordered]@{};files=[ordered]@{}}
    foreach($board in @('media','render')) {
        $run=$runs[$board];$dest=Join-Path $out $board
        New-Item -ItemType Directory -Path $dest | Out-Null
        foreach($name in @("MultimediaSystem_$board.bit",'qualification.json','inputs.json','settings.cfg','final.qor',"MultimediaSystem_${board}_phy.area", "MultimediaSystem_${board}_phy.ts", "MultimediaSystem_${board}_pr.timing")) {
            Copy-Item -LiteralPath (Join-Path $run $name) -Destination $dest
        }
        $manifest.boards[$board]=Get-Content -LiteralPath (Join-Path $run 'qualification.json') -Raw | ConvertFrom-Json
        $src=Join-Path $out "source/$board"
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'build') | Out-Null
        foreach($folder in @('rtl','al_ip','constr','sim','doc')) {Copy-Item -LiteralPath "$board/$folder" -Destination $src -Recurse}
        foreach($file in (Get-ChildItem -LiteralPath "$board/build" -File)) {
            if($file.Extension -in @('.ps1','.tcl') -or $file.Name -in @('sources.txt','modules.json')) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $src 'build')
            }
        }
        Copy-Item -LiteralPath "$board/MultimediaSystem_$board.al" -Destination $src
        Copy-Item -LiteralPath "$board/README.md" -Destination $src
    }
    foreach($folder in @('tools/dual-board','examples/emergency')) {
        $parent=Join-Path $out ('source/'+(Split-Path -Parent $folder))
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Copy-Item -LiteralPath $folder -Destination $parent -Recurse
    }
    Copy-Item -LiteralPath 'tools/convert_fpga_wav.py' -Destination (Join-Path $out 'source/tools')
    New-Item -ItemType Directory -Force -Path (Join-Path $out 'source/doc') | Out-Null
    Copy-Item -LiteralPath 'doc/dual-board' -Destination (Join-Path $out 'source/doc') -Recurse
    Copy-Item -LiteralPath 'README.md' -Destination (Join-Path $out 'source')
    # The read-only audit also verifies the unchanged single-board baseline.
    $baseline=Get-Content -LiteralPath 'doc/dual-board/baseline.sha256.json' -Raw | ConvertFrom-Json -AsHashtable
    foreach($name in $baseline.Keys) {
        $target=Join-Path $out ('source/'+$name)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $name -Destination $target
    }
    Copy-Item -LiteralPath 'doc/dual-board/emergency-v1-2026-10-13.md' -Destination (Join-Path $out '操作与验收.md')
    New-Item -ItemType Directory -Force -Path (Join-Path $out 'verification') | Out-Null
    foreach($name in $regression.evidence.Keys) {
        $target=Join-Path $out ('verification/'+$name)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $name -Destination $target
    }
    Copy-Item -LiteralPath 'doc/dual-board/evidence/emergency-regression.json' -Destination (Join-Path $out 'verification')
    Copy-Item -LiteralPath 'build/emergency-v1/frames/emergency_arrow.png' -Destination $out
    foreach($file in (Get-ChildItem -LiteralPath $out -File -Recurse | Sort-Object FullName)) {
        $manifest.files[$file.FullName.Substring($out.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [IO.File]::WriteAllText((Join-Path $out 'manifest.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $sums=foreach($name in $manifest.files.Keys){$manifest.files[$name]+'  '+$name}
    $sums+=(Get-FileHash -LiteralPath (Join-Path $out 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()+'  manifest.json'
    [IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS.txt'),($sums -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    $zip=$out+'.zip';Compress-Archive -LiteralPath $out -DestinationPath $zip
    [IO.File]::WriteAllText(($zip+'.sha256'),(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($zip)+"`n",[Text.UTF8Encoding]::new($false))
    Write-Host "RELEASE: $out"
    Write-Host "ZIP SHA256: $((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant())"
} finally {Pop-Location}
