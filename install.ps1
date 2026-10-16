# AI Stack installer for Windows (run in PowerShell):
#   irm https://raw.githubusercontent.com/gaspardol/ai-stack/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo = 'gaspardol/ai-stack'
Write-Host 'AI Stack - writing assistant + meeting notes for Chrome, powered by your own Claude plan' -ForegroundColor Cyan
Write-Host 'Downloading the latest release...'
$tmp = Join-Path $env:TEMP ('aistack-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$zip = Join-Path $tmp 'AI-Stack-Windows.zip'
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/releases/latest/download/AI-Stack-Windows.zip" -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $tmp -Force
Get-ChildItem -Path $tmp -Recurse -File | Unblock-File

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
& (Join-Path $tmp "AI Stack for Windows\helper-$arch\AIStackHelper.exe") --install
