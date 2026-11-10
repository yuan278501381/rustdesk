#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk 私有服务端 (hbbs + hbbr) Windows Server 一键部署、迁移与升级脚本
.DESCRIPTION
    适用场景：
    1. 未来更换新的 Windows Server 云服务器时，一键完成全套私有中继服务端部署与密钥迁移。
    2. 未来官方发布新版 rustdesk-server 时，一键平滑就地升级（防回退设计，自动保留原密钥与注册库）。
    包含：目录 ACL 安全加固、二进制拉取/校验、密钥与 DB_URL 归集备份、在线日志自动轮转 (20MBx3)、防火墙放行、SYSTEM 守护计划任务、主路由网卡 hosts 映射。
#>
param(
    [string]$ServerDomain = "chosen.sh.cn",
    [string]$InstallDir = "C:\RustDeskServer",
    [string]$BackupKeyDir = "D:\certs\rustdesk_server_keys",
    [string]$Version = "1.1.16",
    [string]$AlwaysUseRelay = "N",
    [long]$MaxLogBytes = 20971520,
    [int]$MaxLogBackups = 2,
    [int]$HbbsNatPort = 21115,
    [int]$HbbsPort = 21116,
    [int]$HbbrPort = 21117,
    [int]$HbbsWsPort = 21118,
    [int]$HbbrWsPort = 21119,
    [string]$ExistingPrivateKeyPath = "",
    [string]$ExistingPublicKeyPath = "",
    [string]$LocalZipPath = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Set-RestrictedDirectoryAcl([string]$TargetPath) {
    if (-not (Test-Path $TargetPath)) {
        New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    }
    & icacls $TargetPath /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)(F)" "BUILTIN\Administrators:(OI)(CI)(F)" | Out-Null
}

Write-Host "[INFO] 1/6 准备服务端目录并加固 NTFS ACL 权限: $InstallDir"
Set-RestrictedDirectoryAcl -TargetPath $InstallDir

if ($ExistingPrivateKeyPath -and (Test-Path $ExistingPrivateKeyPath)) {
    Copy-Item $ExistingPrivateKeyPath (Join-Path $InstallDir "id_ed25519") -Force
    Write-Host "[OK] 已导入历史私钥 id_ed25519"
}
if ($ExistingPublicKeyPath -and (Test-Path $ExistingPublicKeyPath)) {
    Copy-Item $ExistingPublicKeyPath (Join-Path $InstallDir "id_ed25519.pub") -Force
    Write-Host "[OK] 已导入历史公钥 id_ed25519.pub"
}

Write-Host "[INFO] 2/6 准备 rustdesk-server v$Version 二进制载荷 ..."
$tempZip = if ($LocalZipPath -and (Test-Path $LocalZipPath)) {
    $LocalZipPath
} else {
    $zipUrl = "https://github.com/rustdesk/rustdesk-server/releases/download/$Version/rustdesk-server-windows-x86_64-unsigned.zip"
    $dlPath = Join-Path $env:TEMP "rustdesk-server-$Version.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $dlPath -UseBasicParsing
    $dlPath
}

$tempExtract = Join-Path $env:TEMP "rustdesk-server-extract-$Version"
if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

$binFiles = Get-ChildItem -Path $tempExtract -Recurse -Include "hbbs.exe","hbbr.exe","rustdesk-utils.exe"
if ($binFiles.Count -lt 2) {
    throw "[ERROR] 压缩包内未找到完整的 hbbs.exe / hbbr.exe，终止升级以防破坏现有环境。"
}

Stop-ScheduledTask -TaskName "RustDesk-hbbs" -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName "RustDesk-hbbr" -ErrorAction SilentlyContinue
Stop-Process -Name "hbbs","hbbr" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

foreach ($file in $binFiles) {
    Copy-Item $file.FullName (Join-Path $InstallDir $file.Name) -Force
}
if (-not $LocalZipPath) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "[OK] 二进制文件部署完成 (v$Version)"

Write-Host "[INFO] 3/6 写入配置、数据库路径归集与在线日志轮转器 (ALWAYS_USE_RELAY=$AlwaysUseRelay) ..."
$dbPath = Join-Path $InstallDir "db_v2.sqlite3"
$legacyDb = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\db_v2.sqlite3"
if ((-not (Test-Path $dbPath)) -and (Test-Path $legacyDb)) {
    Copy-Item $legacyDb $dbPath -Force
}

$envLines = @(
    "ALWAYS_USE_RELAY=$AlwaysUseRelay",
    "DB_URL=$dbPath"
)
Set-Content -Path (Join-Path $InstallDir ".env") -Value $envLines -Encoding ASCII

$rotatorScript = @'
param(
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][string]$LogPath,
    [string]$ArgLine = "",
    [long]$MaxBytes = 20971520,
    [int]$MaxBackups = 2
)
$ErrorActionPreference = "Continue"
Set-Location (Split-Path -Parent $ExePath)
$ExeArgs = if ($ArgLine.Trim()) { @($ArgLine.Trim() -split '\s+') } else { @() }

function Rotate-LogFile([string]$Path, [long]$Limit, [int]$Keep) {
    if (-not (Test-Path $Path)) { return }
    if ((Get-Item $Path).Length -lt $Limit) { return }
    for ($i = $Keep; $i -ge 1; $i--) {
        $src = if ($i -eq 1) { $Path } else { "$Path.$($i - 1)" }
        $dst = "$Path.$i"
        if (Test-Path $src) {
            Move-Item -Path $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
}

Rotate-LogFile -Path $LogPath -Limit $MaxBytes -Keep $MaxBackups
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stream = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
$writer.AutoFlush = $true
$lineCount = 0

try {
    & $ExePath @ExeArgs 2>&1 | ForEach-Object {
        $writer.WriteLine($_.ToString())
        $lineCount++
        if ($lineCount -ge 500) {
            $lineCount = 0
            if ($writer.BaseStream.Length -ge $MaxBytes) {
                $writer.Dispose()
                Rotate-LogFile -Path $LogPath -Limit $MaxBytes -Keep $MaxBackups
                $stream = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                $writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
                $writer.AutoFlush = $true
            }
        }
    }
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
}
exit $LASTEXITCODE
'@
Set-Content -Path (Join-Path $InstallDir "invoke_rotated.ps1") -Value $rotatorScript -Encoding UTF8

$cmdHbbs = @"
@echo off
cd /d $InstallDir
set ALWAYS_USE_RELAY=$AlwaysUseRelay
set DB_URL=$dbPath
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\invoke_rotated.ps1" -ExePath "$InstallDir\hbbs.exe" -LogPath "$InstallDir\hbbs.log" -MaxBytes $MaxLogBytes -MaxBackups $MaxLogBackups -ArgLine "-r ${ServerDomain}:${HbbrPort} -k _"
"@
$cmdHbbr = @"
@echo off
cd /d $InstallDir
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\invoke_rotated.ps1" -ExePath "$InstallDir\hbbr.exe" -LogPath "$InstallDir\hbbr.log" -MaxBytes $MaxLogBytes -MaxBackups $MaxLogBackups -ArgLine "-k _"
"@
Set-Content -Path (Join-Path $InstallDir "run_hbbs.cmd") -Value $cmdHbbs -Encoding ASCII
Set-Content -Path (Join-Path $InstallDir "run_hbbr.cmd") -Value $cmdHbbr -Encoding ASCII

Write-Host "[INFO] 4/6 配置 Windows 高级防火墙入站放行规则 ..."
Remove-NetFirewallRule -DisplayName "RustDesk-Server-TCP","RustDesk-Server-UDP" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "RustDesk-Server-TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort "$HbbsNatPort-$HbbrWsPort" | Out-Null
New-NetFirewallRule -DisplayName "RustDesk-Server-UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort "$HbbsPort" | Out-Null
Write-Host "[OK] 防火墙规则已生效 (TCP $HbbsNatPort-$HbbrWsPort, UDP $HbbsPort)"

Write-Host "[INFO] 5/6 按主出网默认路由探测本机真实物理网卡 IP ..."
$primaryIfIndex = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).InterfaceIndex
$localIp = if ($primaryIfIndex) {
    (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $primaryIfIndex -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*"
    } | Select-Object -First 1).IPAddress
} else {
    (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*"
    } | Select-Object -First 1).IPAddress
}

if ($localIp -and $ServerDomain) {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsLines = @(Get-Content $hostsPath | Where-Object { $_ -notmatch "\b$([regex]::Escape($ServerDomain))\b" })
    $hostsLines += "$localIp $ServerDomain"
    Set-Content -Path $hostsPath -Value $hostsLines -Encoding ASCII
    ipconfig /flushdns | Out-Null
    Write-Host "[OK] 已将 $ServerDomain 映射至主路由网卡 IP: $localIp"
}

Write-Host "[INFO] 6/6 注册 SYSTEM 级开机自启守护计划任务 ..."
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$actionHbbs = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$InstallDir\run_hbbs.cmd`"" -WorkingDirectory $InstallDir
$actionHbbr = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$InstallDir\run_hbbr.cmd`"" -WorkingDirectory $InstallDir

Register-ScheduledTask -TaskName "RustDesk-hbbs" -Action $actionHbbs -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Register-ScheduledTask -TaskName "RustDesk-hbbr" -Action $actionHbbr -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Start-ScheduledTask -TaskName "RustDesk-hbbr"
Start-ScheduledTask -TaskName "RustDesk-hbbs"
Start-Sleep -Seconds 3

$pubKeyPath = Join-Path $InstallDir "id_ed25519.pub"
if (Test-Path $pubKeyPath) {
    $pubKey = (Get-Content $pubKeyPath -Raw).Trim()
    if ($BackupKeyDir) {
        Set-RestrictedDirectoryAcl -TargetPath $BackupKeyDir
        Copy-Item (Join-Path $InstallDir "id_ed25519*") $BackupKeyDir -Force
    }
    Write-Host "[OK] 服务端部署并启动成功！专属公钥 (Key): $pubKey"
    Write-Host "[WARN] 请确保云平台安全组已放行入站端口：TCP $HbbsNatPort-$HbbrWsPort 与 UDP $HbbsPort"
} else {
    Write-Error "[ERROR] 未检测到公钥生成，请检查 $InstallDir\hbbs.log"
    exit 1
}
