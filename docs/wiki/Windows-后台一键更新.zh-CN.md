# Yuyu Windows 后台一键更新

本仓库的 Windows Fork 候选版由 GitHub Actions 构建：`.github/workflows/fork-windows-candidate.yml`。每次向
`feat/gg-edgeone-api-delivery-20261115` 推送代码后，会重新构建前端、Go 服务、托盘、Playwright 驱动和 Chromium，
在 Windows Runner 实际安装并检查 `YdisksXianyuHelper` 服务与 `/health`，全部通过才生成 GitHub 预发布。

## 管理后台使用

1. **首次升级一次**：旧版本 `884a1b78a199` 尚未附带更新脚本，需要使用现有 `Deploy-Yuyu.ps1` 安装一个带更新器的新 Release。
2. 后续使用本机 `http://127.0.0.1:59188` 管理员登录，打开 **系统设置 → 软件更新**。
3. 点击 **检查更新**，对比当前安装提交与 Fork 已发布的完整提交。
4. 有新版本时点击 **立即更新**，确认短时间暂停闲鱼自动发货。更新任务在独立 PowerShell 进程中运行，服务重启后后台页面可继续查看状态。

**当前版本只有更新器源码与脚本，必须等待 Windows 构建及验收通过后才能用于本地安装。**

## GitHub 更新工作流

维护者修改源代码 → 推送 Fork 的功能分支 → PR 质量门禁通过 → Windows Installer 构建及 Windows 服务真实健康检查通过
→ GitHub Release `yuyu-win-<完整提交前12位>`（包含 `Ydisks-Xianyu-Helper-Setup.exe` 与 `SHA256SUMS`）
→ 本机后台点击更新 → 自动下载、校验、停止服务、备份、静默安装、健康检查。

**仅 push GitHub 不能自动改变本机程序。** 本机始终运行上一次安装成功的版本，直到主动点击更新；更新器不会下载任意第三方仓库的代码。

## 安全、备份与异常

- 只有管理员登录且从 Windows 本机同源页面发起的 POST 才能执行安装；服务使用固定的 Fork URL、分支与 SHA 校验，不能由前端任意指定 URL、脚本或文件路径。
- 更新器只接受已公开发布、目标 SHA 匹配最新分支 HEAD、带有 installer 和 SHA256SUMS 的 Release；下载后验证安装包 SHA256。
- 发布包目前未做 Windows Authenticode 签名。**SHA256 确认文件完整性，不等于独立软件供应链签名**；应保护 GitHub 仓库和 Actions 发布权限。
- 下载成功后才停止 Windows 服务，数据目录 `C:\ProgramData\YdisksXianyuHelper` 在服务停止后冷备份到 `C:\ProgramData\YuyuDeploy\Backup\<时间戳>`，保留账号数据库和加密密钥。
- 更新状态文件：`C:\ProgramData\YuyuDeploy\Updater\status.json`；安装日志：`C:\ProgramData\YuyuDeploy\Logs\update-*.log`。
- 若安装器或健康检查失败，状态显示「更新失败」，**不会擅自清空或回滚数据库**。根据备份、安装日志及服务状态进行人工恢复；数据库 schema 可能已经迁移，不能不经核对直接覆盖。
- 下载、备份和安装需要系统盘充足空间；更新期间自动发货暂停，因此应避开订单密集时段。
