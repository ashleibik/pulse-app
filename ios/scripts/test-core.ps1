# Run PulseCore's tests on Windows with one command:
#
#   .\ios\scripts\test-core.ps1
#
# Loads the Swift/Visual Studio environment, runs `swift test`, and hides the harmless
# 'wchar_t' warnings that the Swift for Windows SDK itself prints.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "swift-env.ps1")
Push-Location (Join-Path $here "..\PulseCore")
try {
    cmd /c "swift test 2>&1" | Where-Object { $_ -notmatch "wchar_t|_Builtin_stddef|^\s*\|" }
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
