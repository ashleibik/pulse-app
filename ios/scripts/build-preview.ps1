# Rebuild the web preview of Pulse (docs/preview/pulse-preview.html) with fresh demo data:
#
#   .\ios\scripts\build-preview.ps1
#
# 1. runs PulseDemoExport (real PulseCore engine on a simulated month) -> docs/preview/demo.json
# 2. inlines that JSON into docs/preview/template.html -> docs/preview/pulse-preview.html

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here "..\..")
. (Join-Path $here "swift-env.ps1") | Out-Null

$json = Join-Path $repo "docs\preview\demo.json"
Push-Location (Join-Path $repo "ios\PulseCore")
try {
    cmd /c "swift run -c release PulseDemoExport > `"$json`""
    if ($LASTEXITCODE -ne 0) { throw "PulseDemoExport failed" }
} finally { Pop-Location }

$template = Get-Content (Join-Path $repo "docs\preview\template.html") -Raw -Encoding UTF8
$data = (Get-Content $json -Raw -Encoding UTF8).Trim()
# "</" inside inline JSON could end the <script> tag early; escape it.
$data = $data.Replace("</", "<\/")
$html = $template.Replace("/*__DATA__*/", $data)
$out = Join-Path $repo "docs\preview\pulse-preview.html"
[IO.File]::WriteAllText($out, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $out"
