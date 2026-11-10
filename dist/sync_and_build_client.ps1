<#
.SYNOPSIS
    RustDesk 客户端版本同步与企业定制版 (上海逐城远程协助.exe) 一键构建脚本
.DESCRIPTION
    适用场景：
    当上游 RustDesk 发布新版本时，一键同步官方上游 Git 源码并下载对应版本的官方 EV 签名客户端二进制，
    同时在 dist/ 目录下生成两款默认启用 QuickSupport 自动 SYSTEM 提权的零配置交付包：
    1. 上海逐城远程协助-qs-host=...,key=...,.exe （100% 保留官方 PURSLANE EV 代码签名，零 SmartScreen 拦截）
    2. 上海逐城远程协助.exe （纯中文短文件名版，内置服务器地址、公钥与自动提权，防客户随意重命名破坏配置）
#>
param(
    [string]$Version = "1.5.3",
    [string]$ServerHost = "chosen.sh.cn",
    [string]$PublicKey = "kjr789wzgnShiHvE0TK3P9a1jSLe1t6nG80PjhzoEXY=",
    [string]$BrandName = "上海逐城远程协助",
    [string]$RepoRoot = "C:\repo\RustDesk",
    [switch]$SyncGitRepo
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$distDir = Join-Path $RepoRoot "dist"
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

# 1. 可选：从官方上游仓库 (rustdesk/rustdesk) 同步最新源码
if ($SyncGitRepo) {
    Write-Host "[INFO] 正在从官方上游 rustdesk/rustdesk 同步最新源码 ..."
    Push-Location $RepoRoot
    try {
        $remotes = git remote
        if ($remotes -notcontains "upstream") {
            git remote add upstream "https://github.com/rustdesk/rustdesk.git"
        }
        git fetch upstream --tags
        git rebase upstream/master
    } finally {
        Pop-Location
    }
}

# 2. 按版本号隔离缓存下载官方 EV 签名母包，杜绝升级时误用历史旧版本母包
$configSuffix = "qs-host=$ServerHost,key=$PublicKey,"
$versionedStockExe = Join-Path $distDir "rustdesk-$Version-x86_64-stock.exe"
$legacyEnglishExe  = Join-Path $distDir "rustdesk-host=$ServerHost,key=$PublicKey,.exe"
$signedChineseExe  = Join-Path $distDir "$BrandName-$configSuffix.exe"
$shortChineseExe   = Join-Path $distDir "$BrandName.exe"

if (-not (Test-Path $versionedStockExe)) {
    if ($Version -eq "1.4.6" -and (Test-Path $legacyEnglishExe)) {
        Copy-Item $legacyEnglishExe $versionedStockExe -Force
        Write-Host "[INFO] 已复用本地 v1.4.6 官方签名母包: $versionedStockExe"
    } else {
        $downloadUrl = "https://github.com/rustdesk/rustdesk/releases/download/$Version/rustdesk-$Version-x86_64.exe"
        Write-Host "[INFO] 正在下载官方签名版客户端 v$Version : $downloadUrl ..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $versionedStockExe -UseBasicParsing
    }
}

$stockSig = Get-AuthenticodeSignature $versionedStockExe
if ($stockSig.Status -ne "Valid") {
    throw "[ERROR] 母包数字签名校验未通过 ($($stockSig.Status)): $versionedStockExe"
}

# 3. 生成方案 A：100% 保留官方 EV 代码签名的中文前缀版
Copy-Item $versionedStockExe $signedChineseExe -Force
$sig = Get-AuthenticodeSignature $signedChineseExe
Write-Host "[OK] 已生成官方 EV 签名版: $signedChineseExe (签名状态: $($sig.Status))"

# 4. 生成方案 B：无损提取官方签名内核 (data.bin) 并编译纯中文短文件名版 上海逐城远程协助.exe
Write-Host "[INFO] 正在从官方二进制无损提取签名载荷并构建纯中文名: $shortChineseExe ..."
$portableDir = Join-Path $RepoRoot "libs\portable"

python -c @"
import re
exe_path = r'$versionedStockExe'
with open(exe_path, 'rb') as f:
    buf = f.read()
m = re.search(rb'timestamp = \d+\r?\n', buf)
ident = b'rustdesk'
pos = 0
while True:
    idx = buf.find(ident, pos)
    if idx == -1:
        raise RuntimeError('未找到嵌入式 data.bin 载荷')
    base = idx + 8
    ok = True
    count = 0
    while base + 8 <= len(buf):
        if buf[base:base+8] == ident:
            base += 8
            end_exe = buf[base:base+14]
            if end_exe in (b'./rustdesk.exe', b'.\\rustdesk.exe'):
                with open(r'$portableDir\data.bin', 'wb') as out:
                    out.write(buf[idx:base+14])
                with open(r'$portableDir\app_metadata.toml', 'wb') as out:
                    out.write(m.group(0) if m else b'timestamp = 1\n')
                break
            else:
                ok = False; break
        if base + 4 > len(buf): ok = False; break
        plen = int.from_bytes(buf[base:base+4], 'big')
        if plen <= 0 or plen > 260 or base + 4 + plen + 4 > len(buf): ok = False; break
        base += 4 + plen
        flen = int.from_bytes(buf[base:base+4], 'big')
        if flen < 0 or base + 4 + flen + 32 > len(buf): ok = False; break
        base += 4 + flen + 32
        count += 1
    if ok and count > 5:
        break
    pos = idx + 1
"@

$mainRsPath = Join-Path $portableDir "src\main.rs"
$cargoTomlPath = Join-Path $portableDir "Cargo.toml"
$cargoLockPath = Join-Path $portableDir "Cargo.lock"
$backupMain = Get-Content $mainRsPath -Raw -Encoding UTF8
$backupCargo = Get-Content $cargoTomlPath -Raw -Encoding UTF8
$backupLock = Get-Content $cargoLockPath -Raw -Encoding UTF8

$targetStr = '    cmd.env(APPNAME_RUNTIME_ENV_KEY, exe_name);'
$replacementStr = @"
    let appname_env = match exe_name.to_str() {
        Some(s) if s.to_lowercase().contains("host=") || s.contains("--") => exe_name.to_os_string(),
        _ => std::ffi::OsString::from("rustdesk-$configSuffix.exe"),
    };
    cmd.env(APPNAME_RUNTIME_ENV_KEY, appname_env);
"@
$targetQsStr = '    let quick_support = args.is_empty() && win::is_quick_support_exe(&arg_exe);'
$replacementQsStr = '    let quick_support = args.is_empty() && !click_setup;'

if (-not $backupMain.Contains($targetStr)) {
    throw "[ERROR] libs/portable/src/main.rs 未匹配到 APPNAME_RUNTIME_ENV_KEY 注入锚点，请检查上游代码变更。"
}
if (-not $backupMain.Contains($targetQsStr)) {
    throw "[ERROR] libs/portable/src/main.rs 未匹配到 quick_support 注入锚点，请检查上游代码变更。"
}

try {
    $patchedMain = $backupMain.Replace($targetStr, $replacementStr).Replace($targetQsStr, $replacementQsStr)
    [System.IO.File]::WriteAllText($mainRsPath, $patchedMain, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($cargoTomlPath, ($backupCargo + "`r`n[workspace]`r`n"), (New-Object System.Text.UTF8Encoding $false))
    cargo build --release --manifest-path $cargoTomlPath
    if ($LASTEXITCODE -ne 0) { throw "Cargo 编译失败" }
    Copy-Item (Join-Path $portableDir "target\release\rustdesk-portable-packer.exe") $shortChineseExe -Force
    Write-Host "[OK] 已生成纯中文短文件名版: $shortChineseExe"
} finally {
    [System.IO.File]::WriteAllText($mainRsPath, $backupMain, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($cargoTomlPath, $backupCargo, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($cargoLockPath, $backupLock, (New-Object System.Text.UTF8Encoding $false))
    Remove-Item (Join-Path $portableDir "data.bin"),(Join-Path $portableDir "app_metadata.toml") -Force -ErrorAction SilentlyContinue
}
