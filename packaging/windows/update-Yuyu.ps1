#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedCommit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'xianyumht-cmd/yuyu'
$branch = 'feat/gg-edgeone-api-delivery-20261115'
$assetName = 'Ydisks-Xianyu-Helper-Setup.exe'
$serviceName = 'YdisksXianyuHelper'
$root = Join-Path $env:ProgramData 'YuyuDeploy'
$updaterDir = Join-Path $root 'Updater'
$downloads = Join-Path $root 'Downloads'
$logs = Join-Path $root 'Logs'
$backupRoot = Join-Path $root 'Backup'
$statusPath = Join-Path $updaterDir 'status.json'
$lockPath = Join-Path $updaterDir 'running.lock'
$releaseName = 'yuyu-win-' + $ExpectedCommit.Substring(0,12)

# 更新状态以无 BOM UTF-8 原子写入，服务重启后仍可在后台查询。
function Set-UpdateStatus([string]$Stage,[string]$Message) {
    $record = [ordered]@{
        stage = $Stage
        message = $Message
        release = $releaseName
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = ConvertTo-Json -InputObject $record -Compress
    $temp = $statusPath + '.pending'
    [IO.File]::WriteAllText($temp,$json,(New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $statusPath -Force
}

# 仅允许固定 Github Release 地址；严格检查下载退出码和空文件。
function Download-UpdateFile([string]$Uri,[string]$Destination) {
    $partial = $Destination + '.partial'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        & $curl --fail --location --retry 4 --retry-delay 3 --connect-timeout 30 --max-time 3600 --output $partial $Uri
        if ($LASTEXITCODE -ne 0) { throw '下载 GitHub 安装包失败' }
    } else {
        Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $partial -TimeoutSec 3600
    }
    if (-not (Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -le 0) {
        throw 'GitHub 下载结果为空'
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

# 等待实际后台服务和 SQLite 健康检查成功。
function Wait-Healthy {
    for ($i = 0; $i -lt 75; $i++) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            $health = Invoke-RestMethod -Uri 'http://127.0.0.1:59188/health' -TimeoutSec 2
            if ($service.Status -eq 'Running' -and $health.status -eq 'ok' -and $health.database -eq 'ok') { return $true }
        } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

New-Item -ItemType Directory -Force -Path $updaterDir,$downloads,$logs,$backupRoot | Out-Null
try {
    Set-UpdateStatus 'checking' '正在验证 GitHub 新版本'
    $api = 'https://api.github.com/repos/' + $repo
    $headers = @{'User-Agent'='Yuyu-Fork-Updater/1';'Accept'='application/vnd.github+json'}
    $branchInfo = Invoke-RestMethod -Uri ($api + '/branches/' + [Uri]::EscapeDataString($branch)) -Headers $headers -TimeoutSec 30
    if ([string]$branchInfo.commit.sha -cne $ExpectedCommit) { throw '版本已变化，请返回后台重新检查更新' }
    $release = Invoke-RestMethod -Uri ($api + '/releases/tags/' + $releaseName) -Headers $headers -TimeoutSec 30
    if ([string]$release.tag_name -cne $releaseName -or [string]$release.target_commitish -cne $ExpectedCommit -or $release.draft -or -not $release.prerelease) {
        throw 'Release 与目标提交不匹配，拒绝安装'
    }
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    $sumAsset = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if (-not $asset -or -not $sumAsset) { throw '安装包或 SHA256SUMS 缺失' }
    $prefix = 'https://github.com/' + $repo + '/releases/download/' + $releaseName + '/'
    if ($asset.browser_download_url -cne ($prefix + $assetName) -or $sumAsset.browser_download_url -cne ($prefix + 'SHA256SUMS')) {
        throw '下载链接未通过固定仓库校验'
    }

    Set-UpdateStatus 'downloading' '正在下载并校验新版 Windows 安装包'
    $sumPath = Join-Path $updaterDir ('SHA256SUMS-' + $releaseName)
    $installer = Join-Path $downloads ($releaseName + '-' + $assetName)
    Download-UpdateFile $sumAsset.browser_download_url $sumPath
    $sumLine = Get-Content -LiteralPath $sumPath | Where-Object { $_ -match 'Ydisks-Xianyu-Helper-Setup\.exe$' } | Select-Object -First 1
    if ($sumLine -notmatch '^([0-9a-fA-F]{64})\s+\*?Ydisks-Xianyu-Helper-Setup\.exe$') { throw '校验文件格式不正确' }
    $expectedHash = $Matches[1]
    if (-not (Test-Path -LiteralPath $installer)) { Download-UpdateFile $asset.browser_download_url $installer }
    $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) { throw '安装包 SHA256 校验失败，已拒绝安装' }

    Set-UpdateStatus 'backing_up' '正在停止服务并备份账号、卡密和本地数据库'
    $dataDir = Join-Path $env:ProgramData $serviceName
    $backup = Join-Path $backupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    # 备份同时包含数据库和加密主密钥，仅 SYSTEM 与管理员可以读取。
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $icacls $backup '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法将备份目录设置为仅管理员访问，已取消更新' }
    $old = Get-Service -Name $serviceName -ErrorAction Stop
    if ($old.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -ErrorAction Stop
        $old.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(60))
    }
    $old.Dispose()
    if (Test-Path -LiteralPath $dataDir) {
        Copy-Item -LiteralPath $dataDir -Destination (Join-Path $backup $serviceName) -Recurse -Force
    }
    Set-UpdateStatus 'installing' '已备份数据，正在安装并启动新版本'
    $installLog = Join-Path $logs ('update-' + $releaseName + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="' + $installLog + '"'))
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw ('Windows 安装器退出码：' + $process.ExitCode + '；检查更新日志') }
    Set-UpdateStatus 'verifying' '安装完成，正在确认 Windows 服务和数据库正常'
    if (-not (Wait-Healthy)) { throw '新版未通过服务健康检查；请使用备份和日志恢复' }
    Set-UpdateStatus 'success' '更新成功，重新打开或刷新后台即可'
} catch {
    $reason = $_.Exception.Message
    Set-UpdateStatus 'failed' ('更新失败：' + $reason + '；旧数据备份位于 ProgramData\YuyuDeploy\Backup')
    exit 1
} finally {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
