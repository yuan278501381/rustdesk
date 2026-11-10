<#
.SYNOPSIS
    RustDesk 私有服务端 (hbbs + hbbr) Windows Server 一键部署、迁移与升级脚本
.DESCRIPTION
    适用场景：
    1. 未来更换新的 Windows Server 云服务器时，一键完成全套私有中继服务端部署与密钥迁移。
    2. 未来官方发布新版 rustdesk-server 时，一键平滑就地升级（防回退设计，自动保留原密钥）。
    包含：二进制拉取/校验、密钥注入与备份、Windows 高级防火墙放行、SYSTEM 级开机自启守护计划任务、同机内网 hosts 回环修正。
#>
param(
    [string]$ServerDomain = "chosen.sh.cn",
    [string]$InstallDir = "C:\RustDeskServer",
    [string]$BackupKeyDir = "D:\certs\rustdesk_server_keys",
    [string]$Version = "1.1.16",
    [string]$AlwaysUseRelay = "Y",
    [int]$HbbsNatPort = 21115,
    [int]$HbbsPort = 21116,
    [int]$HbbrPort = 21117,
    [int]$HbbsWsPort = 21118,
    [int]$HbbrWsPort = 21119,
    [string]$ExistingPrivateKeyPath = "",
    [string]$ExistingPublicKeyPath = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "[INFO] 1/6 准备服务端目录: $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# 1. 如果传入了旧服务器的密钥备份路径，优先恢复密钥，确保所有存量客户端无需重新下发
if ($ExistingPrivateKeyPath -and (Test-Path $ExistingPrivateKeyPath)) {
    Copy-Item $ExistingPrivateKeyPath (Join-Path $InstallDir "id_ed25519") -Force
    Write-Host "[OK] 已导入历史私钥 id_ed25519"
}
if ($ExistingPublicKeyPath -and (Test-Path $ExistingPublicKeyPath)) {
    Copy-Item $ExistingPublicKeyPath (Join-Path $InstallDir "id_ed25519.pub") -Force
    Write-Host "[OK] 已导入历史公钥 id_ed25519.pub"
}

# 2. 下载并更新指定版本的 rustdesk-server 二进制包（防回退：下载到临时目录校验通过后再替换）
$zipUrl = "https://github.com/rustdesk/rustdesk-server/releases/download/$Version/rustdesk-server-windows-x86_64-unsigned.zip"
$tempZip = Join-Path $env:TEMP "rustdesk-server-$Version.zip"
$tempExtract = Join-Path $env:TEMP "rustdesk-server-extract-$Version"

Write-Host "[INFO] 2/6 正在拉取 rustdesk-server v$Version ..."
Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

$binFiles = Get-ChildItem -Path $tempExtract -Recurse -Include "hbbs.exe","hbbr.exe","rustdesk-utils.exe"
if ($binFiles.Count -lt 2) {
    throw "[ERROR] 压缩包内未找到完整的 hbbs.exe / hbbr.exe，终止升级以防破坏现有环境。"
}

Stop-Process -Name "hbbs","hbbr" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

foreach ($file in $binFiles) {
    Copy-Item $file.FullName (Join-Path $InstallDir $file.Name) -Force
}
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "[OK] 二进制文件部署完成 (v$Version)"

# 3. 生成启动包装脚本与 .env 配置
Write-Host "[INFO] 3/6 写入环境配置与启动脚本 (ALWAYS_USE_RELAY=$AlwaysUseRelay) ..."
Set-Content -Path (Join-Path $InstallDir ".env") -Value "ALWAYS_USE_RELAY=$AlwaysUseRelay" -Encoding ASCII

$cmdHbbs = @"
@echo off
cd /d $InstallDir
set ALWAYS_USE_RELAY=$AlwaysUseRelay
$InstallDir\hbbs.exe -r ${ServerDomain}:${HbbrPort} -k _ >> $InstallDir\hbbs.log 2>&1
"@
$cmdHbbr = @"
@echo off
cd /d $InstallDir
$InstallDir\hbbr.exe -k _ >> $InstallDir\hbbr.log 2>&1
"@
Set-Content -Path (Join-Path $InstallDir "run_hbbs.cmd") -Value $cmdHbbs -Encoding ASCII
Set-Content -Path (Join-Path $InstallDir "run_hbbr.cmd") -Value $cmdHbbr -Encoding ASCII

# 4. 配置 Windows 防火墙入站规则
Write-Host "[INFO] 4/6 配置 Windows 高级防火墙入站放行规则 ..."
Remove-NetFirewallRule -DisplayName "RustDesk-Server-TCP","RustDesk-Server-UDP" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "RustDesk-Server-TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort "$HbbsNatPort-$HbbrWsPort" | Out-Null
New-NetFirewallRule -DisplayName "RustDesk-Server-UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort "$HbbsPort" | Out-Null
Write-Host "[OK] 防火墙规则已生效 (TCP $HbbsNatPort-$HbbrWsPort, UDP $HbbsPort)"

# 5. 配置同机内网 hosts 解析（防止云服务器 Hairpin NAT 回环不通或 127.0.0.1 绑定异常）
Write-Host "[INFO] 5/6 配置本机真实内网 IP 域名映射 ..."
$localIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*"
} | Select-Object -First 1).IPAddress

if ($localIp -and $ServerDomain) {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsLines = Get-Content $hostsPath | Where-Object { $_ -notmatch "\b$([regex]::Escape($ServerDomain))\b" }
    $hostsLines += "$localIp $ServerDomain"
    Set-Content -Path $hostsPath -Value $hostsLines -Encoding ASCII
    ipconfig /flushdns | Out-Null
    Write-Host "[OK] 已将 $ServerDomain 映射至本机内网网卡 IP: $localIp"
}

# 6. 注册 SYSTEM 级开机自启与异常守护计划任务并启动服务
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
        New-Item -ItemType Directory -Path $BackupKeyDir -Force | Out-Null
        Copy-Item (Join-Path $InstallDir "id_ed25519*") $BackupKeyDir -Force
    }
    Write-Host "[OK] 服务端部署并启动成功！专属公钥 (Key): $pubKey"
    Write-Host "[WARN] 请确保云平台安全组已放行入站端口：TCP $HbbsNatPort-$HbbrWsPort 与 UDP $HbbsPort"
} else {
    Write-Host "[ERROR] 未检测到公钥生成，请检查 $InstallDir\hbbs.log"
}
