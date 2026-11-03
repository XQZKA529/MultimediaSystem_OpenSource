$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$license = python -c "import importlib.metadata as m; d=m.distribution('miniaudio'); print(d.locate_file(next(f for f in d.files if str(f).endswith('licenses/LICENSE'))))"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $license -PathType Leaf)) { throw '未找到 miniaudio 许可证，请安装 host_app/requirements.txt 中的依赖。' }
python -m PyInstaller --noconfirm --clean --onefile --windowed --name FPGA-Media-Manager-Standalone --paths tools --specpath host_app --distpath host_app/dist --workpath host_app/build --icon "$(Join-Path $PSScriptRoot 'app.ico')" --add-data "$(Join-Path $PSScriptRoot 'app.ico');." --exclude-module numpy --hidden-import _cffi_backend --add-data "$license;audio-license" --add-data "$(Join-Path $PSScriptRoot 'test_data/smoke.mp3');test_data" host_app/app.py --log-level WARN
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller 打包失败' }
Write-Host 'Standalone EXE: host_app/dist/FPGA-Media-Manager-Standalone.exe'
