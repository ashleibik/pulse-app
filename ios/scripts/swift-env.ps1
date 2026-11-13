# Load everything Swift needs on Windows into the CURRENT PowerShell session.
#
#   . .\ios\scripts\swift-env.ps1        (note the leading dot + space: "dot-sourcing")
#
# Why: Swift on Windows compiles with Microsoft's C/C++ linker (link.exe) and the Windows SDK.
# Those only appear on PATH inside a "Visual Studio developer environment", so we load it via
# vcvars64.bat and copy its variables into this session. We also pick up SDKROOT/PATH that the
# Swift installer set, in case this terminal was opened before Swift was installed.
#
# Only needed on Windows. On a Mac, Xcode provides all of this.

$ErrorActionPreference = "Stop"

# 1) Machine + user PATH and SDKROOT from the registry (fresh values, not this session's stale copy).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
$sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if (-not $sdk) { $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'Machine') }
if (-not $sdk) { throw "SDKROOT not set. Is Swift installed?  winget install --id Swift.Toolchain -e" }
$env:SDKROOT = $sdk

# 2) Find a Visual Studio install that has the C++ tools, via Microsoft's vswhere.exe.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "Visual Studio (Build Tools) not found." }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "No Visual Studio install with C++ tools (VC.Tools.x86.x64) found." }
$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"

# 3) Run vcvars64.bat in cmd, print the resulting environment, and import it here.
#    (vswhere's folder is added to PATH first, because vcvars calls it.)
$env:Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;" + $env:Path
cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}

Write-Host "Swift environment ready: $(swift --version 2>&1 | Select-Object -First 1)"
