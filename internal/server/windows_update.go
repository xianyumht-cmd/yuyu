package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"xianyu-go/internal/version"
)

// windowsUpdateRepo 固定为本项目自己构建且经过 Windows 健康验收的 Fork。
const windowsUpdateRepo = "https://api.github.com/repos/xianyumht-cmd/yuyu"
const windowsUpdateBranch = "feat/gg-edgeone-api-delivery-20261115"

// windowsUpdateRelease 是只信任固定仓库、分支和 SHA 的候选版本。
type windowsUpdateRelease struct {
	Commit string
	Tag    string
}

// windowsUpdateStatus 是管理后台展示的本地安装任务状态。
type windowsUpdateStatus struct {
	Stage     string `json:"stage"`
	Message   string `json:"message"`
	Release   string `json:"release"`
	UpdatedAt string `json:"updated_at"`
}

// windowsUpdateResponse 是不泄露下载密钥或本机数据目录的更新状态。
type windowsUpdateResponse struct {
	Supported bool                 `json:"supported"`
	Current   string               `json:"current"`
	Latest    string               `json:"latest,omitempty"`
	Available bool                 `json:"available"`
	Task      *windowsUpdateStatus `json:"task,omitempty"`
}

// getForkUpdateRelease 仅发现目标版本；下载及 SHA256 校验由独立安装进程再次执行。
func getForkUpdateRelease(ctx context.Context) (windowsUpdateRelease, error) {
	// client 给外部 GitHub API 调用设置硬超时。
	client := &http.Client{Timeout: 12 * time.Second}
	// branchURL 只由代码内固定的可信仓库和分支组成。
	branchURL := windowsUpdateRepo + "/branches/" + url.PathEscape(windowsUpdateBranch)
	// branch 是 GitHub 分支响应中唯一使用的字段。
	var branch struct {
		Commit struct {
			SHA string `json:"sha"`
		} `json:"commit"`
	}
	if err := getGitHubUpdateJSON(ctx, client, branchURL, &branch); err != nil {
		return windowsUpdateRelease{}, err
	}
	// sha 是服务端核对的完整 Git commit，不允许接受其他仓库的 Release。
	sha := strings.TrimSpace(branch.Commit.SHA)
	if len(sha) != 40 || strings.Trim(sha, "0123456789abcdef") != "" {
		return windowsUpdateRelease{}, errors.New("GitHub 分支版本号无效")
	}
	// tag 为固定前缀加提交的 12 位简写。
	tag := "yuyu-win-" + sha[:12]
	// release 仅校验同一 SHA、已发布、且包含预期安装包和校验文件。
	var release struct {
		Tag        string `json:"tag_name"`
		Target     string `json:"target_commitish"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name string `json:"name"`
		} `json:"assets"`
	}
	if err := getGitHubUpdateJSON(ctx, client, windowsUpdateRepo+"/releases/tags/"+tag, &release); err != nil {
		return windowsUpdateRelease{}, err
	}
	if release.Tag != tag || release.Target != sha || release.Draft || !release.Prerelease {
		return windowsUpdateRelease{}, errors.New("更新候选未通过仓库及提交匹配校验")
	}
	// hasInstaller、hasSum 必须同时为真才允许出现更新按钮。
	hasInstaller, hasSum := false, false
	for _, asset := range release.Assets {
		if asset.Name == "Ydisks-Xianyu-Helper-Setup.exe" {
			hasInstaller = true
		}
		if asset.Name == "SHA256SUMS" {
			hasSum = true
		}
	}
	if !hasInstaller || !hasSum {
		return windowsUpdateRelease{}, errors.New("更新包或 SHA256 校验文件未发布")
	}
	return windowsUpdateRelease{Commit: sha, Tag: tag}, nil
}

// getGitHubUpdateJSON 限制 JSON 响应体大小，禁止使用用户可配置的更新 URL。
func getGitHubUpdateJSON(ctx context.Context, client *http.Client, endpoint string, target any) error {
	// request 是使用当前浏览器请求生命周期限制的外部 GET 请求。
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "Yuyu-Fork-Updater/1")
	// response 是外部 GitHub 请求返回的状态及 JSON。
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New("GitHub 尚未发布对应提交的更新包")
	}
	// decoder 只会读取受限大小的 JSON，不接受任意二进制内容。
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	return decoder.Decode(target)
}

// windowsUpdaterPaths 固定在服务数据目录，下载和备份时不允许外部指定路径。
func windowsUpdaterPaths() (string, string) {
	// dir 是本机部署脚本存放更新运行状态的目录。
	dir := filepath.Join(os.Getenv("ProgramData"), "YuyuDeploy", "Updater")
	return filepath.Join(dir, "status.json"), filepath.Join(dir, "running.lock")
}

// readWindowsUpdateStatus 不把任意日志直接暴露给管理后台。
func readWindowsUpdateStatus() *windowsUpdateStatus {
	// statusPath 为 updater 运行日志的简要状态文件。
	statusPath, _ := windowsUpdaterPaths()
	// data 是最大 16KB 的状态文件内容。
	data, err := os.ReadFile(statusPath)
	if err != nil || len(data) > 16*1024 {
		return nil
	}
	// status 仅从有限字段恢复更新状态。
	var status windowsUpdateStatus
	if json.Unmarshal(data, &status) != nil {
		return nil
	}
	return &status
}

// isLocalWindowsUpdaterRequest 限制提权安装仅能从本机同源管理后台发起。
func isLocalWindowsUpdaterRequest(r *http.Request) bool {
	// host 是当前连接的远端 TCP 地址。
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return false
	}
	// origin 是浏览器发起有副作用的 POST 必须携带的同源标识。
	origin := r.Header.Get("Origin")
	if origin == "" || origin != "http://"+r.Host {
		return false
	}
	return r.Host == "127.0.0.1:59188" || r.Host == "localhost:59188"
}

// getWindowsUpdate 显示当前安装版本和经过固定仓库验证的最新发布版本。
func (s *Server) getWindowsUpdate(w http.ResponseWriter, r *http.Request) {
	setNoStore(w)
	// result 是管理员设置页需要的全部更新状态。
	result := windowsUpdateResponse{Supported: runtime.GOOS == "windows", Current: version.Commit, Task: readWindowsUpdateStatus()}
	if !result.Supported {
		writeJSON(w, http.StatusOK, result)
		return
	}
	// release 是只来自固定 Fork 的最新 Release。
	release, err := getForkUpdateRelease(r.Context())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "检查 GitHub 更新失败，请稍后重试"})
		return
	}
	result.Latest = release.Commit
	result.Available = result.Current != release.Commit
	writeJSON(w, http.StatusOK, result)
}

// startWindowsUpdate 请求独立 PowerShell 更新器，以便停止服务后仍可继续安装。
func (s *Server) startWindowsUpdate(w http.ResponseWriter, r *http.Request) {
	setNoStore(w)
	if runtime.GOOS != "windows" || !isLocalWindowsUpdaterRequest(r) {
		writeErr(w, http.StatusForbidden, "仅允许在本机 Windows 管理后台执行更新")
		return
	}
	// release 再次确认固定仓库的发布内容，客户端不能指定提交或下载路径。
	release, err := getForkUpdateRelease(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "GitHub 发布版本尚不可用")
		return
	}
	if release.Commit == version.Commit {
		writeErr(w, http.StatusConflict, "当前已经是最新版本")
		return
	}
	// executable 是当前 Windows 服务二进制，脚本必须安装在同一目录。
	executable, err := os.Executable()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "无法读取安装路径")
		return
	}
	// script 是随安装包发布的受信任本地更新脚本。
	script := filepath.Join(filepath.Dir(executable), "update-Yuyu.ps1")
	if _, err := os.Stat(script); err != nil {
		writeErr(w, http.StatusConflict, "当前版本尚未安装更新器，请先手动升级一次")
		return
	}
	// statusPath、lockPath 让并发按钮请求不会同时执行两次安装。
	statusPath, lockPath := windowsUpdaterPaths()
	if err := os.MkdirAll(filepath.Dir(statusPath), 0700); err != nil {
		writeErr(w, http.StatusInternalServerError, "无法建立更新目录")
		return
	}
	// lock 防止并行安装；超过两小时的历史锁才允许清理。
	if info, err := os.Stat(lockPath); err == nil && time.Since(info.ModTime()) > 2*time.Hour {
		_ = os.Remove(lockPath)
	}
	// lock 是仅允许一个进程创建的更新任务互斥文件。
	lock, err := os.OpenFile(lockPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		writeErr(w, http.StatusConflict, "已有更新任务正在运行")
		return
	}
	_ = lock.Close()
	// command 是无可配置脚本、无自由命令字符串的 Windows 更新子进程。
	command := exec.Command(filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-ExpectedCommit", release.Commit)
	command.Dir = filepath.Dir(executable)
	if err := command.Start(); err != nil {
		_ = os.Remove(lockPath)
		writeErr(w, http.StatusInternalServerError, "无法启动更新器")
		return
	}
	_ = command.Process.Release()
	writeJSON(w, http.StatusAccepted, map[string]string{"message": "更新任务已启动，安装期间后台会暂时断开", "release": release.Tag})
}
