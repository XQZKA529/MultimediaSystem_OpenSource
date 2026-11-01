param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RenderRunTag,
    [switch]$AllowRenderTimingViolation
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$baseline=Join-Path $root 'build/emergency-v1/trial-request3/emergency-trial-request3'
$mediaRun=Join-Path $root 'build/emergency-v1/candidates/request_mux/media/Runs/phy_emergency_request3'
$renderRun=Join-Path $root ('render/Runs/phy_'+$RenderRunTag)
$regression=Get-Content -LiteralPath (Join-Path $root 'doc/dual-board/evidence/emergency-regression.json') -Raw | ConvertFrom-Json -AsHashtable
if(-not $regression.full_regression -or $regression.test_count -lt 52){throw 'Current full 52-test regression is required'}
$out=Join-Path $root ('build/emergency-gpio/release_'+$RenderRunTag)
if(Test-Path -LiteralPath $out){throw 'Release directory already exists'}
$boardInputs=@{}
foreach($board in @('media','render')){
    $run=if($board -eq 'media'){$mediaRun}else{$renderRun}
    $expected=Get-Content -LiteralPath (Join-Path $run 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
    $current=(& (Join-Path $root "$board/build/input-fingerprint.ps1")) | ConvertFrom-Json -AsHashtable
    if($current.Count -ne $expected.Count -or $current.Count -ne $regression.inputs[$board].Count){throw "Source set changed: $board"}
    foreach($name in $expected.Keys){
        if($current[$name] -ne $expected[$name] -or $current[$name] -ne $regression.inputs[$board][$name]){throw "Input mismatch: $board/$name"}
    }
    $boardInputs[$board]=$current
}
foreach($name in $regression.evidence.Keys){
    if((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $regression.evidence[$name]){throw "Evidence changed: $name"}
}
$mediaBit=Join-Path $baseline 'media_TRIAL.bit'
if((Get-FileHash -LiteralPath $mediaBit -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'ad0490e957e343f9eed3ec34169d67eb104ed869bb557465045a7caf501e0d47'){throw 'Original hardware-tested media bit changed'}
$renderBit=Join-Path $renderRun 'MultimediaSystem_render.bit'
if(-not (Test-Path -LiteralPath $renderBit)){throw 'Missing render bit'}
$qualified=$false
if(Test-Path -LiteralPath (Join-Path $renderRun 'qualification.json')){
    & (Join-Path $root 'render/build/check-reports.ps1') -RunDir $renderRun
    $qualified=$true
}elseif(-not $AllowRenderTimingViolation){throw 'Render is unqualified; experimental packaging requires -AllowRenderTimingViolation'}
$timings=[ordered]@{}
foreach($board in @('media','render')){
    $run=if($board -eq 'media'){$mediaRun}else{$renderRun}
    $text=Get-Content -LiteralPath (Join-Path $run "MultimediaSystem_${board}_phy.ts") -Raw
    $timings[$board]=[ordered]@{}
    foreach($metric in @('SWNS','STNS','HWNS','HTNS')){
        $match=[regex]::Match($text,$metric+':\s*([-0-9.]+)ns')
        if(-not $match.Success){throw "Missing timing: $board/$metric"}
        $timings[$board][$metric]=[double]::Parse($match.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
    }
}
New-Item -ItemType Directory -Path $out | Out-Null
Copy-Item -LiteralPath $mediaBit -Destination (Join-Path $out 'media_TESTED.bit')
Copy-Item -LiteralPath $renderBit -Destination (Join-Path $out 'render_GPIO.bit')
foreach($board in @('media','render')){
    $run=if($board -eq 'media'){$mediaRun}else{$renderRun}
    $reports=Join-Path $out "reports/$board"
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    foreach($name in @('inputs.json','settings.cfg','final.qor',"MultimediaSystem_${board}_phy.ts", "MultimediaSystem_${board}_phy.area", "MultimediaSystem_${board}_pr.timing")){
        Copy-Item -LiteralPath (Join-Path $run $name) -Destination $reports
    }
    if($board -eq 'render' -and $qualified){Copy-Item -LiteralPath (Join-Path $run 'qualification.json') -Destination $reports}
    foreach($name in $boardInputs[$board].Keys){
        $target=Join-Path $out "source/$board/$name"
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root "$board/$name") -Destination $target
    }
    foreach($name in @('sim','doc')){Copy-Item -LiteralPath (Join-Path $root "$board/$name") -Destination (Join-Path $out "source/$board") -Recurse}
    Copy-Item -LiteralPath (Join-Path $root "$board/README.md"),(Join-Path $root "$board/MultimediaSystem_$board.al") -Destination (Join-Path $out "source/$board")
    Copy-Item -LiteralPath (Join-Path $root "$board/build/modules.json") -Destination (Join-Path $out "source/$board/build")
}
foreach($name in $regression.evidence.Keys){
    $target=Join-Path $out ('evidence/'+$name)
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $target
}
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/evidence/emergency-regression.json') -Destination (Join-Path $out 'evidence/regression.json')
Copy-Item -LiteralPath (Join-Path $root 'build/emergency-gpio/frames') -Destination $out -Recurse
Copy-Item -LiteralPath (Join-Path $root 'tools') -Destination (Join-Path $out 'source') -Recurse
New-Item -ItemType Directory -Path (Join-Path $out 'source/doc/dual-board'),(Join-Path $out 'source/doc/reference/board-support'),(Join-Path $out 'source/build') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/protocol-v1.md'),(Join-Path $root 'doc/dual-board/emergency-gpio-2026-10-14.md') -Destination (Join-Path $out 'source/doc/dual-board')
Copy-Item -LiteralPath (Join-Path $root 'doc/reference/board-support/gpio_header_dump.txt') -Destination (Join-Path $out 'source/doc/reference/board-support')
# Preserve the 88 original single-board inputs for the standard baseline audit.
$legacy=Get-Content -LiteralPath (Join-Path $root 'doc/dual-board/baseline.sha256.json') -Raw | ConvertFrom-Json -AsHashtable
foreach($name in $legacy.Keys){
    $target=Join-Path $out ('source/'+$name)
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $target
}
Copy-Item -LiteralPath (Join-Path $root 'doc/dual-board/baseline.sha256.json') -Destination (Join-Path $out 'source/doc/dual-board')
Copy-Item -LiteralPath (Join-Path $root 'examples') -Destination (Join-Path $out 'source') -Recurse
Copy-Item -LiteralPath (Join-Path $root 'README.md'),(Join-Path $root 'README-dual-board.md') -Destination (Join-Path $out 'source')
Copy-Item -LiteralPath (Join-Path $root 'examples/emergency/EMERG.WAV') -Destination $out
$manifest=[ordered]@{
    artifact_type='paired_gpio_emergency_hardware_trial';protocol='1.8';created_utc=[DateTime]::UtcNow.ToString('o')
    media_bit_reused=$true;prior_media_hardware_functional_test='passed_by_user';new_gpio_hardware_acceptance='pending'
    media_timing_qualified=$false;render_timing_qualified=$qualified;render_run=$RenderRunTag
    post_hold_timing_ns=$timings;test_count=$regression.test_count
    media_bit_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'media_TESTED.bit') -Algorithm SHA256).Hash.ToLowerInvariant()
    render_bit_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'render_GPIO.bit') -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $out 'manifest.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$readme=@"
# GPIO/C 应急试板包

media 板使用 media_TESTED.bit，render 板使用 render_GPIO.bit；两板协议仍为 1.8。
GPIOB0：render 板 J2 第 1 脚/P4，左方向；GPIOB1：J2 第 2 脚/N4，右方向。
输入为 0/3.3 V、共地、默认下拉；不得直接接 5 V。约 1 ms 稳定确认，高电平激活，低电平解除。
C 切换三角感叹号警报；B 本版无动作。多来源组合，上三角下箭头，小字显示有效来源触发顺序。
最后来源解除后恢复原图、原曲位置及暂停状态。SD 根目录放 EMERG.WAV，48 kHz/PCM16/单或双声道；附带文件是测试音。

media 保留用户实测正常的原 bit，Setup -2.154 ns，Hold +0.024 ns（保持修复后），时序仍未签核。
render 签核状态：$qualified；最终时序见 manifest.json/reports/render。本包作为两板实板试验产物交付。
通过 $($regression.test_count) 项回归，七张完整 720p 图案及 25 种顺序布局检查；新 GPIO 功能尚需实板验证。
建议覆盖全部组合、部分解除、重触发、20 次进入/恢复及 10 分钟应急循环。

完整说明：source/doc/dual-board/emergency-gpio-2026-10-14.md。
frames/emergency-combinations.png 为仿真画面预览；SHA256SUMS.txt 校验所有文件。
"@
[IO.File]::WriteAllText((Join-Path $out 'README.md'),$readme,[Text.UTF8Encoding]::new($false))
$checks=Get-ChildItem -LiteralPath $out -Recurse -File | Sort-Object FullName | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetRelativePath($out,$_.FullName).Replace('\','/')
}
[IO.File]::WriteAllLines((Join-Path $out 'SHA256SUMS.txt'),$checks,[Text.UTF8Encoding]::new($false))
$zip=$out+'.zip'
Compress-Archive -LiteralPath $out -DestinationPath $zip -CompressionLevel Optimal
$sha=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($zip+'.sha256'),$sha+'  '+[IO.Path]::GetFileName($zip)+"`n",[Text.UTF8Encoding]::new($false))
$manifest | ConvertTo-Json -Depth 8
Write-Host "PACKAGED $zip SHA256=$sha"
