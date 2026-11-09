# Builds PG Connect's tunnel service (tunnelsvc -> pgc-tunnel.exe) and adds the prebuilt WireGuard
# driver library (wireguard.dll from wireguard-nt) and its licence to the deploy folder.
# Called by build-arch.bat:  powershell -File productify-tunnel.ps1 -Arch x64 -DeployDir <dir> -CacheDir <dir>
param(
    [Parameter(Mandatory)] [string] $Arch,
    [Parameter(Mandatory)] [string] $DeployDir,
    [Parameter(Mandatory)] [string] $CacheDir
)
$ErrorActionPreference = "Stop"

# Pinned: wireguard-nt 1.1 from the official download server (checked 2026-11-09; wireguard.dll
# is Authenticode-signed by WireGuard LLC). Change both lines together when updating.
$WgNtUrl = "https://download.wireguard.com/wireguard-nt/wireguard-nt-1.1.zip"
$WgNtSha256 = "DCEB30A9BC4BE48CCE0F74160FC88A585A2C2627366E8F846FC6658F9038DACE"

$goArch = @{ "x64" = "amd64"; "arm64" = "arm64"; "x86" = "386" }[$Arch]
$dllArch = @{ "x64" = "amd64"; "arm64" = "arm64"; "x86" = "x86" }[$Arch]
if (-not $goArch) { throw "Unknown architecture: $Arch" }

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$zip = Join-Path $CacheDir "wireguard-nt-1.1.zip"
if (-not (Test-Path $zip)) {
    Invoke-WebRequest -UseBasicParsing -Uri $WgNtUrl -OutFile $zip
}
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
if ($hash -ne $WgNtSha256) {
    Remove-Item $zip
    throw "wireguard-nt-1.1.zip checksum mismatch ($hash)"
}
$extract = Join-Path $CacheDir "wireguard-nt-1.1"
if (-not (Test-Path $extract)) {
    Expand-Archive -Path $zip -DestinationPath $extract
}
$dll = Join-Path $extract "wireguard-nt\bin\$dllArch\wireguard.dll"
$sig = Get-AuthenticodeSignature $dll
if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notlike "CN=WireGuard LLC,*") {
    throw "wireguard.dll signature is not a valid WireGuard LLC signature"
}
Copy-Item $dll (Join-Path $DeployDir "wireguard.dll") -Force
# The wireguard-nt prebuilt licence must ship alongside wireguard.dll.
Copy-Item (Join-Path $extract "wireguard-nt\LICENSE.txt") (Join-Path $DeployDir "WIREGUARD-NT-LICENSE.txt") -Force

$src = Join-Path $PSScriptRoot "..\tunnelsvc"
$env:GOOS = "windows"; $env:GOARCH = $goArch; $env:CGO_ENABLED = "0"
Push-Location $src
try {
    go build -trimpath -ldflags "-s -w" -o (Join-Path $DeployDir "pgc-tunnel.exe") .
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }
}
finally { Pop-Location }
Write-Host "Tunnel service ready: pgc-tunnel.exe + wireguard.dll ($Arch)"
