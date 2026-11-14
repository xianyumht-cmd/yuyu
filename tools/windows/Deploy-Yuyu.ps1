[CmdletBinding()]
param(
    [switch]$ProbeOnly,
    [ValidateSet('Auto','Fork','Upstream')][string]$Source = 'Auto',
    [string]$InstallerPath = '',
    [string]$ExpectedSha256 = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$fork = 'xianyumht-cmd/yuyu'
$upstream = 'Christ9038/Ydisks-Xianyu-Helper'
$assetName = 'Ydisks-Xianyu-Helper-Setup.exe'
$serviceName = 'YdisksXianyuHelper'
$adminPage = 'http://127.0.0.1:59188'

# 探针只读取系统及服务状态，不上传账号、Cookie、Token、卡密或硬件序列号。
function Invoke-Probe {
    $os = Get-CimInstance Win32_OperatingSystem
    $memory = Get-CimInstance Win32_ComputerSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $portOpen = $false
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $connect = $tcp.BeginConnect('127.0.0.1',59188,$null,$null)
            if ($connect.AsyncWaitHandle.WaitOne(450)) {
                try { $tcp.EndConnect($connect); $portOpen = $true } catch { }
            }
            $connect.AsyncWaitHandle.Close()
        } finally { $tcp.Dispose() }
    } catch { }
    $network = 'unverified'
    try {
        [void](Invoke-WebRequest 'https://api.github.com/repos/xianyumht-cmd/yuyu' -TimeoutSec 12 -UseBasicParsing)
        $network = 'ok'
    } catch { $network = 'unavailable' }
    return [ordered]@{
        generated_at = (Get-Date).ToString('s')
        os_caption = $os.Caption
        os_version = $os.Version
        architecture = $env:PROCESSOR_ARCHITECTURE
        is_64bit = [Environment]::Is64BitOperatingSystem
        memory_gb = [Math]::Round($memory.TotalPhysicalMemory / 1GB, 1)
        system_disk_free_gb = [Math]::Round($disk.FreeSpace / 1GB, 1)
        github_api = $network
        service_status = if ($service) { [string]$service.Status } else { 'NotInstalled' }
        port_59188_open = $portOpen
    }
}

# 下载只接受固定 GitHub Releases URL；所有网络安装包必须用 Release 的 SHA256SUMS 进行完整性校验。
function Get-LatestRelease([string]$Repository) {
    try {
        return Invoke-RestMethod -Uri ("https://api.github.com/repos/" + $Repository + "/releases/latest") -Headers @{'User-Agent'='Yuyu-Windows-OneClick/1.0'} -TimeoutSec 25
    } catch { return $null }
}
function Download-Checked([string]$Url,[string]$Path) {
    $partial = $Path + '.partial'
    if (Test-Path $partial) { Remove-Item $partial -Force }
    $curlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curlPath) {
        & $curlPath --fail --location --retry 4 --retry-delay 3 --connect-timeout 30 --max-time 3600 --output $partial $Url
        if ($LASTEXITCODE -ne 0) { throw 'GitHub 下载失败，请检查网络，或使用本地安装包参数。' }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 3600
    }
    if (-not (Test-Path $partial) -or (Get-Item $partial).Length -eq 0) { throw '下载得到空文件。' }
    Move-Item $partial $Path -Force
}
function Ask-Yes([string]$Message) {
    return ((Read-Host ($Message + ' 输入 Y 继续')).Trim().ToUpperInvariant() -eq 'Y')
}

try {
    Write-Host '== Yuyu Windows 环境探针 ==' -ForegroundColor Cyan
    $report = Invoke-Probe
    $reports = Join-Path $PSScriptRoot 'Reports'
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    $probeFile = Join-Path $reports ('probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $report | ConvertTo-Json -Depth 4 | Set-Content $probeFile -Encoding UTF8
    $report | Format-List | Out-Host
    Write-Host ('环境报告：' + $probeFile)
    if ($ProbeOnly) { exit 0 }

    if (-not $report.is_64bit -or $report.architecture -ne 'AMD64' -or
        ([version]$report.os_version).Major -lt 10) { throw '只支持 Windows 10/11 x64 AMD64。' }
    if ($report.system_disk_free_gb -lt 3) { throw '系统盘至少需要 3 GB 可用空间。' }
    if ($report.port_59188_open -and $report.service_status -eq 'NotInstalled') {
        throw '59188 端口已被其他程序占用，请先处理冲突。'
    }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Source ' + $Source
        if ($InstallerPath) { $arguments += ' -InstallerPath "' + $InstallerPath.Replace('"','') + '"' }
        if ($ExpectedSha256) { $arguments += ' -ExpectedSha256 ' + $ExpectedSha256 }
        Write-Host '安装 Windows 服务需要管理员权限，正在请求 UAC。' -ForegroundColor Yellow
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        exit $child.ExitCode
    }

    $workDir = Join-Path $env:ProgramData 'YuyuDeploy'
    $downloadDir = Join-Path $workDir 'Downloads'
    $logDir = Join-Path $workDir 'Logs'
    New-Item -ItemType Directory -Force -Path $downloadDir,$logDir | Out-Null
    $setup = $InstallerPath
    $expected = $ExpectedSha256
    $chosenRepo = 'local'
    if (-not $setup) {
        $release = $null
        if ($Source -ne 'Upstream') {
            $release = Get-LatestRelease $fork
            if ($release -and -not ($release.assets | Where-Object name -eq $assetName)) { $release = $null }
            if ($release) { $chosenRepo = $fork }
            elseif ($Source -eq 'Fork') { throw '你的 Fork 没有可用的 Windows Release，不能假装部署 Fork 版本。' }
            else {
                Write-Warning 'Fork 暂无 Windows Release；上游原版不包含你 Fork 中的修改。'
                if (-not (Ask-Yes '是否明确使用上游正式安装包？')) { throw '已取消上游回退。' }
            }
        }
        if (-not $release) { $chosenRepo = $upstream; $release = Get-LatestRelease $upstream }
        if (-not $release) { throw 'GitHub Release 无法访问，请用 -InstallerPath 提供本地安装包。' }
        $asset = $release.assets | Where-Object name -eq $assetName | Select-Object -First 1
        $sumAsset = $release.assets | Where-Object name -eq 'SHA256SUMS' | Select-Object -First 1
        if (-not $asset -or -not $sumAsset) { throw '安装包或校验和文件缺失，拒绝安装。' }
        $sumFile = Join-Path $downloadDir 'SHA256SUMS'
        Download-Checked $sumAsset.browser_download_url $sumFile
        $checksumLine = (Get-Content $sumFile) | Where-Object { $_ -match 'Ydisks-Xianyu-Helper-Setup\.exe$' } | Select-Object -First 1
        if ($checksumLine -notmatch '^([0-9a-fA-F]{64})\s+\*?Ydisks-Xianyu-Helper-Setup\.exe$') {
            throw 'SHA256SUMS 中找不到 Windows 安装包的合法校验记录。'
        }
        $expected = [regex]::Match($checksumLine, '^([0-9a-fA-F]{64})\s+\*?Ydisks-Xianyu-Helper-Setup\.exe
        $setup = Join-Path $downloadDir ($release.tag_name + '-' + $assetName)
        Download-Checked $asset.browser_download_url $setup
    } else {
        if (-not $expected -or $expected -notmatch '^[0-9a-fA-F]{64}$') {
            throw '本地安装包必须同时提供 -ExpectedSha256 的完整 64 位 SHA256。'
        }
        $setup = (Resolve-Path -LiteralPath $setup -ErrorAction Stop).Path
    }

    $actual = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
    if ($actual -ine $expected) { throw 'SHA256 校验失败，拒绝运行安装包。' }
    Write-Host ('已验证安装包 SHA256：' + $actual)
    Write-Host ('安装来源：' + $chosenRepo)

    $signature = Get-AuthenticodeSignature -FilePath $setup
    if ($signature.Status -ne 'Valid') {
        Write-Warning ('安装包的 Windows 签名验证状态：' + $signature.Status)
        if (-not (Ask-Yes '签名不受信任，是否仍要使用已通过 SHA256 校验的安装包？')) {
            throw '用户拒绝安装签名状态异常的安装包。'
        }
    }

    $dataRoot = Join-Path $env:ProgramData $serviceName
    if (Test-Path $dataRoot) {
        Write-Warning ('已发现既有数据目录：' + $dataRoot)
        if (-not (Ask-Yes '是否备份现有数据并继续升级？')) { throw '用户取消升级。' }
        $backupDir = Join-Path $workDir ('Backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $old = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($old -and $old.Status -ne 'Stopped') { Stop-Service -Name $serviceName -ErrorAction Stop }
        Copy-Item -Path $dataRoot -Destination (Join-Path $backupDir $serviceName) -Recurse -Force
        Write-Host ('完整数据备份（含加密密钥）：' + $backupDir)
    }

    $logFile = Join-Path $logDir ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + $logFile + '"'
    $installer = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru
    if ($installer.ExitCode -ne 0) { throw ('Windows 安装程序失败，错误码：' + $installer.ExitCode + '，日志：' + $logFile) }
    $healthy = $false
    for ($i = 0; $i -lt 45; $i++) {
        try {
            $health = Invoke-RestMethod -Uri ($adminPage + '/health') -TimeoutSec 3
            if ($health.status -eq 'ok' -and $health.database -eq 'ok') { $healthy = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw '安装程序已运行，但后台健康检查未通过。请检查服务和日志。' }
    Write-Host ('部署成功，管理页面：' + $adminPage) -ForegroundColor Green
    Start-Process $adminPage
} catch {
    Write-Error ('部署/探针失败：' + $_.Exception.Message)
    exit 1
}
).Groups[1].Value
        $setup = Join-Path $downloadDir ($release.tag_name + '-' + $assetName)
        Download-Checked $asset.browser_download_url $setup
    } else {
        if (-not $expected -or $expected -notmatch '^[0-9a-fA-F]{64}$') {
            throw '本地安装包必须同时提供 -ExpectedSha256 的完整 64 位 SHA256。'
        }
        $setup = (Resolve-Path -LiteralPath $setup -ErrorAction Stop).Path
    }

    $actual = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
    if ($actual -ine $expected) { throw 'SHA256 校验失败，拒绝运行安装包。' }
    Write-Host ('已验证安装包 SHA256：' + $actual)
    Write-Host ('安装来源：' + $chosenRepo)

    $signature = Get-AuthenticodeSignature -FilePath $setup
    if ($signature.Status -ne 'Valid') {
        Write-Warning ('安装包的 Windows 签名验证状态：' + $signature.Status)
        if (-not (Ask-Yes '签名不受信任，是否仍要使用已通过 SHA256 校验的安装包？')) {
            throw '用户拒绝安装签名状态异常的安装包。'
        }
    }

    $dataRoot = Join-Path $env:ProgramData $serviceName
    if (Test-Path $dataRoot) {
        Write-Warning ('已发现既有数据目录：' + $dataRoot)
        if (-not (Ask-Yes '是否备份现有数据并继续升级？')) { throw '用户取消升级。' }
        $backupDir = Join-Path $workDir ('Backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $old = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($old -and $old.Status -ne 'Stopped') { Stop-Service -Name $serviceName -ErrorAction Stop }
        Copy-Item -Path $dataRoot -Destination (Join-Path $backupDir $serviceName) -Recurse -Force
        Write-Host ('完整数据备份（含加密密钥）：' + $backupDir)
    }

    $logFile = Join-Path $logDir ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + $logFile + '"'
    $installer = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru
    if ($installer.ExitCode -ne 0) { throw ('Windows 安装程序失败，错误码：' + $installer.ExitCode + '，日志：' + $logFile) }
    $healthy = $false
    for ($i = 0; $i -lt 45; $i++) {
        try {
            $health = Invoke-RestMethod -Uri ($adminPage + '/health') -TimeoutSec 3
            if ($health.status -eq 'ok' -and $health.database -eq 'ok') { $healthy = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw '安装程序已运行，但后台健康检查未通过。请检查服务和日志。' }
    Write-Host ('部署成功，管理页面：' + $adminPage) -ForegroundColor Green
    Start-Process $adminPage
} catch {
    Write-Error ('部署/探针失败：' + $_.Exception.Message)
    exit 1
}
