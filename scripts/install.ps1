param(
    [ValidateSet("server", "agent", "node")]
    [string]$Component = $(if ($env:FRPW_COMPONENT) { $env:FRPW_COMPONENT } else { "server" }),
    [string]$Version = $(if ($env:FRPW_VERSION) { $env:FRPW_VERSION } else { "v1.0.0" }),
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    # Older hosts may not expose the TLS 1.2 enum; the default protocol remains available.
}

if (-not $Version.StartsWith("v")) {
    $Version = "v$Version"
}

$Repo = if ($env:FRPW_REPO) { $env:FRPW_REPO } else { "ccmaoxiong/frpw" }
$ApiBase = if ($env:FRPW_GITHUB_API_URL) { $env:FRPW_GITHUB_API_URL.TrimEnd("/") } else { "https://api.github.com" }
$GithubDownloadBase = if ($env:FRPW_GITHUB_DOWNLOAD_URL) { $env:FRPW_GITHUB_DOWNLOAD_URL.TrimEnd("/") } else { "https://github.com" }
$DownloadBase = if ($env:FRPW_DOWNLOAD_BASE_URL) { $env:FRPW_DOWNLOAD_BASE_URL.TrimEnd("/") } else { "" }
$Token = if ($env:FRPW_TOKEN) { $env:FRPW_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { "" }
$ServiceUser = if ($env:FRPW_SERVICE_USER) { $env:FRPW_SERVICE_USER } else { "frpw" }

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Stop-Install([string]$Message) {
    throw $Message
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Architecture {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        "X64" { return "amd64" }
        "Arm64" { return "arm64" }
        default { Stop-Install "unsupported architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
    }
}

function Get-Headers([string]$Accept) {
    $headers = @{
        Accept = $Accept
        "User-Agent" = "frpw-installer"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($Token) {
        $headers.Authorization = "Bearer $Token"
    }
    return $headers
}

function Invoke-WebDownload([string]$Uri, [string]$Destination, [hashtable]$Headers) {
    $parameters = @{
        Uri = $Uri
        Headers = $Headers
        OutFile = $Destination
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $parameters.UseBasicParsing = $true
    }
    Invoke-WebRequest @parameters
}

function Get-Release([string]$ReleaseVersion) {
    $uri = "$ApiBase/repos/$Repo/releases/tags/$ReleaseVersion"
    return Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-Headers "application/vnd.github+json")
}

function Get-Asset([string]$AssetName, [string]$Destination, $Release) {
    if ($DownloadBase) {
        Invoke-WebDownload "$DownloadBase/$AssetName" $Destination (Get-Headers "application/octet-stream")
        return
    }
    if ($Release) {
        $asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
        if ($asset) {
            try {
                Invoke-WebDownload $asset.url $Destination (Get-Headers "application/octet-stream")
                return
            }
            catch {
                Write-Warning "GitHub API download failed for $AssetName; trying public download URL"
            }
        }
    }
    Invoke-WebDownload "$GithubDownloadBase/$Repo/releases/download/$Version/$AssetName" $Destination (Get-Headers "application/octet-stream")
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-ExpectedChecksum([string]$AssetName, [string]$SumsPath) {
    foreach ($line in (Get-Content -LiteralPath $SumsPath)) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$') {
            continue
        }
        $fileName = $parts[1] -replace '^\*', ''
        if ($fileName.StartsWith('./')) {
            $fileName = $fileName.Substring(2)
        }
        if ($fileName -eq $AssetName) {
            return $parts[0].ToLowerInvariant()
        }
    }
    return $null
}

function Assert-Checksum([string]$AssetName, [string]$Path, [string]$SumsPath) {
    $expected = Get-ExpectedChecksum $AssetName $SumsPath
    if (-not $expected) {
        Stop-Install "SHA256SUMS has no valid entry for $AssetName"
    }
    $actual = Get-Sha256 $Path
    if ($actual -ne $expected) {
        Stop-Install "checksum verification failed for $AssetName"
    }
}

function Write-Utf8File([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-RandomHexSecret([int]$ByteCount = 32) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Install-ServiceTask([string]$Name, [string]$Binary, [string]$Arguments) {
    if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
        if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        }
        $action = New-ScheduledTaskAction -Execute $Binary -Argument $Arguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $Name
        return
    }
    $command = "`"$Binary`" $Arguments"
    & schtasks.exe /Create /TN $Name /TR $command /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
    & schtasks.exe /Run /TN $Name | Out-Null
}

function Add-FirewallRule([string]$Name, [string[]]$Ports) {
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        return
    }
    foreach ($protocol in @("TCP", "UDP")) {
        foreach ($port in $Ports) {
            $displayName = "$Name $protocol $port"
            if (-not (Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $displayName -Direction Inbound -Action Allow -Protocol $protocol -LocalPort $port | Out-Null
            }
        }
    }
}

function Install-Server($Release, [string]$TempDir) {
    $installDir = if ($env:FRPW_INSTALL_DIR) { $env:FRPW_INSTALL_DIR } else { Join-Path $env:ProgramFiles "FRPW" }
    $dataDir = if ($env:FRPW_DATA_DIR) { $env:FRPW_DATA_DIR } else { Join-Path $env:ProgramData "FRPW" }
    $configFile = Join-Path $dataDir "server.yaml"
    $apiPort = if ($env:FRPW_API_PORT) { [int]$env:FRPW_API_PORT } else { 9000 }
    $agentPort = if ($env:FRPW_AGENT_PORT) { [int]$env:FRPW_AGENT_PORT } else { 7000 }
    $publicHttpPort = if ($env:FRPW_PUBLIC_HTTP_PORT) { [int]$env:FRPW_PUBLIC_HTTP_PORT } else { 8080 }
    $baseDomain = if ($env:FRPW_BASE_DOMAIN) { $env:FRPW_BASE_DOMAIN } else { "localhost" }
    $agentPublicAddr = if ($env:FRPW_AGENT_PUBLIC_ADDR) { $env:FRPW_AGENT_PUBLIC_ADDR } else { "" }
    $adminPath = if ($env:FRPW_ADMIN_PATH) { $env:FRPW_ADMIN_PATH } else { "/admin-panel" }
    $allowRegistration = if ($env:FRPW_ALLOW_REGISTRATION) { $env:FRPW_ALLOW_REGISTRATION } else { "true" }

    New-Item -ItemType Directory -Force -Path $installDir, $dataDir | Out-Null
    $assetName = "frpw-server-$Version-windows-$(Get-Architecture).exe"
    $assetPath = Join-Path $TempDir $assetName
    Get-Asset $assetName $assetPath $Release
    Assert-Checksum $assetName $assetPath (Join-Path $TempDir "SHA256SUMS")
    Copy-Item -LiteralPath $assetPath -Destination (Join-Path $installDir "frpw-server.exe") -Force

    if (-not (Test-Path $configFile)) {
        $jwtSecret = if ($env:FRPW_JWT_SECRET) { $env:FRPW_JWT_SECRET } else { New-RandomHexSecret 32 }
        $config = @"
data_dir: "$($dataDir.Replace('\', '/'))"
api_addr: ":$apiPort"
agent_addr: ":$agentPort"
agent_public_addr: "$agentPublicAddr"
client_release_dir: "$(($dataDir.Replace('\', '/') + '/client-releases'))"
public_http_addr: ":$publicHttpPort"
public_http_port: $publicHttpPort
base_domain: "$baseDomain"
port_range_from: 20000
port_range_to: 20999
jwt_secret: "$jwtSecret"
session_ttl: 12h
meter_interval: 30s
platform_admins:
  - admin@example.com
admin_console_path: "$adminPath"
allow_registration: $allowRegistration
log_level: info
payment:
  allow_mock: false
"@
        Write-Utf8File $configFile $config
    } else {
        Write-Step "preserving existing configuration: $configFile"
    }

    $clientDir = Join-Path $dataDir "client-releases"
    New-Item -ItemType Directory -Force -Path $clientDir | Out-Null
    foreach ($clientAsset in @(
        "frpw-agent-$Version-windows-amd64.exe",
        "frpw-agent-$Version-linux-amd64",
        "frpw-agent-$Version-linux-arm64",
        "frpw-agent-$Version-darwin-amd64",
        "frpw-agent-$Version-darwin-arm64",
        "frpw-node-$Version-windows-amd64.exe",
        "frpw-node-$Version-linux-amd64",
        "frpw-node-$Version-linux-arm64"
    )) {
        $destination = Join-Path $TempDir $clientAsset
        Get-Asset $clientAsset $destination $Release
        Assert-Checksum $clientAsset $destination (Join-Path $TempDir "SHA256SUMS")
        Copy-Item -LiteralPath $destination -Destination (Join-Path $clientDir $clientAsset) -Force
    }
    Copy-Item -LiteralPath (Join-Path $TempDir "SHA256SUMS") -Destination (Join-Path $clientDir "SHA256SUMS") -Force

    Install-ServiceTask "FRPW Server" (Join-Path $installDir "frpw-server.exe") "-config `"$configFile`""
    Add-FirewallRule "FRPW Server" @("$apiPort", "$agentPort", "$publicHttpPort", "20000-20999")
    Write-Step "FRPW server $Version installed"
    Write-Step "user console: http://<server-ip>:$apiPort"
    Write-Step "admin console: http://<server-ip>:$apiPort$adminPath"
    Write-Step "default admin: admin@example.com / admin12345 (change immediately)"
    Write-Step "default user: user@example.com / user12345 (change immediately)"
}

function Install-Agent($Release, [string]$TempDir) {
    $installDir = if ($env:FRPW_AGENT_INSTALL_DIR) { $env:FRPW_AGENT_INSTALL_DIR } else { Join-Path $env:ProgramFiles "FRPW Agent" }
    $dataDir = if ($env:FRPW_AGENT_DATA_DIR) { $env:FRPW_AGENT_DATA_DIR } else { Join-Path $env:ProgramData "FRPW Agent" }
    $configFile = Join-Path $dataDir "agent.yaml"
    $server = $env:FRPW_SERVER
    $agentToken = $env:FRPW_AGENT_TOKEN
    $controlPlane = $env:FRPW_CONTROL_PLANE
    $agentId = if ($env:FRPW_AGENT_ID) { $env:FRPW_AGENT_ID } else { $env:COMPUTERNAME }
    $nodeId = if ($env:FRPW_NODE_ID) { $env:FRPW_NODE_ID } else { "node_local" }

    if (-not $server) { Stop-Install "FRPW_SERVER is required" }
    if (-not $agentToken) { Stop-Install "FRPW_AGENT_TOKEN is required" }
    if (-not $controlPlane) { Stop-Install "FRPW_CONTROL_PLANE is required" }

    New-Item -ItemType Directory -Force -Path $installDir, $dataDir | Out-Null
    $assetName = "frpw-agent-$Version-windows-amd64.exe"
    $assetPath = Join-Path $TempDir $assetName
    Get-Asset $assetName $assetPath $Release
    Assert-Checksum $assetName $assetPath (Join-Path $TempDir "SHA256SUMS")
    Copy-Item -LiteralPath $assetPath -Destination (Join-Path $installDir "frpw-agent.exe") -Force

    if (-not (Test-Path $configFile)) {
        $config = @"
server: "$server"
control_plane: "$controlPlane"
token: "$agentToken"
agent_id: "$agentId"
node_id: "$nodeId"
auto_sync_interval: 30s
dial_timeout: 10s
max_backoff: 30s
tunnels: []
"@
        Write-Utf8File $configFile $config
    } else {
        Write-Step "preserving existing configuration: $configFile"
    }

    Install-ServiceTask "FRPW Agent" (Join-Path $installDir "frpw-agent.exe") "-headless -config `"$configFile`""
    Write-Step "FRPW Agent $Version installed on node $nodeId"
}

function Install-Node($Release, [string]$TempDir) {
    $installDir = if ($env:FRPW_NODE_INSTALL_DIR) { $env:FRPW_NODE_INSTALL_DIR } else { Join-Path $env:ProgramFiles "FRPW Node" }
    $dataDir = if ($env:FRPW_NODE_DATA_DIR) { $env:FRPW_NODE_DATA_DIR } else { Join-Path $env:ProgramData "FRPW Node" }
    $configFile = Join-Path $dataDir "node.yaml"
    $controlPlane = $env:FRPW_CONTROL_PLANE
    $nodeToken = $env:FRPW_NODE_TOKEN
    $agentPort = if ($env:FRPW_NODE_AGENT_PORT) { [int]$env:FRPW_NODE_AGENT_PORT } else { 7000 }
    $httpPort = if ($env:FRPW_NODE_PUBLIC_HTTP_PORT) { [int]$env:FRPW_NODE_PUBLIC_HTTP_PORT } else { 8080 }
    $baseDomain = if ($env:FRPW_NODE_BASE_DOMAIN) { $env:FRPW_NODE_BASE_DOMAIN } else { "localhost" }

    if (-not $controlPlane) { Stop-Install "FRPW_CONTROL_PLANE is required" }
    if (-not $nodeToken) { Stop-Install "FRPW_NODE_TOKEN is required" }

    New-Item -ItemType Directory -Force -Path $installDir, $dataDir | Out-Null
    $assetName = "frpw-node-$Version-windows-amd64.exe"
    $assetPath = Join-Path $TempDir $assetName
    Get-Asset $assetName $assetPath $Release
    Assert-Checksum $assetName $assetPath (Join-Path $TempDir "SHA256SUMS")
    Copy-Item -LiteralPath $assetPath -Destination (Join-Path $installDir "frpw-node.exe") -Force

    if (-not (Test-Path $configFile)) {
        $config = @"
control_plane: "$controlPlane"
token: "$nodeToken"
version: "$Version"
agent_addr: ":$agentPort"
http_addr: ":$httpPort"
public_http_port: $httpPort
base_domain: "$baseDomain"
port_range_from: 20000
port_range_to: 20999
heartbeat_interval: 15s
tunnel_timeout: 30s
log_level: info
"@
        Write-Utf8File $configFile $config
    } else {
        Write-Step "preserving existing configuration: $configFile"
    }

    Install-ServiceTask "FRPW Node" (Join-Path $installDir "frpw-node.exe") "-config `"$configFile`""
    Add-FirewallRule "FRPW Node" @("$agentPort", "$httpPort", "20000-20999")
    Write-Step "FRPW remote node $Version installed"
}

if (-not (Test-Administrator)) {
    if ($Elevated) {
        Stop-Install "administrator rights were not granted"
    }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }
    if (-not $scriptPath) {
        Stop-Install "download install.ps1 to a file before running it"
    }
    try {
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$scriptPath`"",
            "-Component", $Component,
            "-Version", $Version,
            "-Elevated"
        )
        $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
    catch {
        Stop-Install "administrator permission was not granted: $($_.Exception.Message)"
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("frpw-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
try {
    $release = $null
    if (-not $DownloadBase) {
        try {
            $release = Get-Release $Version
        }
        catch {
            Write-Warning "GitHub release metadata unavailable; falling back to public download URLs"
        }
    }
    Get-Asset "SHA256SUMS" (Join-Path $tempDir "SHA256SUMS") $release
    switch ($Component) {
        "server" { Install-Server $release $tempDir }
        "agent" { Install-Agent $release $tempDir }
        "node" { Install-Node $release $tempDir }
    }
}
finally {
    if (Test-Path $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
