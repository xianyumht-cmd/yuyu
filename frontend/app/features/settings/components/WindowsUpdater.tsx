import React from 'react';
import { Download, RefreshCw } from 'lucide-react';
import { get, post } from '../../../../shared/http/client';

/** WindowsReleaseInfo 是后台固定 Fork 更新接口返回的可展示摘要。 */
interface WindowsReleaseInfo {
  /** supported 表示当前服务是否运行在 Windows 上。 */
  supported: boolean;
  /** current 是正在运行的构建 SHA。 */
  current: string;
  /** latest 是通过 GitHub Release 校验的最新构建 SHA。 */
  latest?: string;
  /** available 表示有不同于当前版本的已发布安装包。 */
  available: boolean;
  /** task 保存更新进程的跨服务重启状态。 */
  task?: {
    /** stage 表示更新任务当前执行阶段。 */
    stage: string;
    /** message 是后台更新器写入的简短状态说明。 */
    message: string;
    /** release 是任务对应的可信 GitHub Release 标签。 */
    release: string;
    /** updated_at 为任务状态上次修改时间。 */
    updated_at: string;
  };
}

/** WindowsUpdateStartResponse 是启动更新任务时返回的非敏感提示。 */
interface WindowsUpdateStartResponse {
  /** message 是已提交更新请求的回执信息。 */
  message: string;
}

/** WindowsUpdater 在系统设置中提供管理员主动确认的一键更新入口。 */
const WindowsUpdater: React.FC = () => {
  // release 保存当前版本、最新发布和安装进度。
  const [release, setRelease] = React.useState<WindowsReleaseInfo | null>(null);
  // busy 防止重复点击更新按钮。
  const [busy, setBusy] = React.useState(false);
  // error 保存本次检查或安装操作的可见错误。
  const [error, setError] = React.useState('');
  // started 保存更新开始后允许服务暂时离线的提示状态。
  const [started, setStarted] = React.useState(false);

  // refresh 从本地受管理员保护的接口读取状态。
  const refresh = React.useCallback(/* callback 是读取后台更新状态的稳定异步函数。 */ async () => {
    try {
      // next 是只读更新摘要，不包含授权令牌或自定义外部 URL。
      const next = await get<WindowsReleaseInfo>('/api/v1/settings/update', undefined, { timeoutMs: 20000 });
      setRelease(next);
      setError('');
      if (next.task?.stage === 'success' || next.task?.stage === 'failed') setStarted(false);
    } catch (/* err 是检查更新发生的网络或鉴权错误。 */ err) {
      if (!started) setError(err instanceof Error ? err.message : '检查更新失败');
    }
  }, [started]);

  // 每次进入设置页都检查一次；正在安装时允许服务暂时离线并继续轮询。
  React.useEffect(/* 进入设置页时检查更新并在卸载时清理轮询。 */ () => {
    void refresh();
    // interval 是只在本组件存活期间执行的状态轮询。
    const interval = window.setInterval(/* callback 定期读取后台版本和安装状态。 */ () => { void refresh(); }, started ? 5000 : 30000);
    return /* 清理页面轮询计时器。 */ () => window.clearInterval(interval);
  }, [refresh, started]);

  // performUpdate 只要求管理员确认；实际版本选择及完整性验证全部由服务端完成。
  const performUpdate = async () => {
    if (!release?.available || busy || !window.confirm('更新将暂停闲鱼自动发货，待服务重启后恢复。确认现在安装已验证的 GitHub 新版本？')) return;
    setBusy(true);
    setError('');
    try {
      await post<WindowsUpdateStartResponse>('/api/v1/settings/update', {});
      setStarted(true);
      await refresh();
    } catch (/* err 是启动安装任务产生的校验或授权错误。 */ err) {
      setError(err instanceof Error ? err.message : '启动更新失败');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="space-y-4">
      <h3 className="text-lg font-extrabold text-gray-800 flex items-center gap-2">
        <Download className="h-5 w-5 text-sky-600" />
        软件更新
      </h3>
      <div className="ios-card rounded-xl bg-white p-6 space-y-4">
        <div className="text-sm text-gray-600">
          <p>当前版本：<code className="font-mono">{release?.current?.slice(0, 12) || '读取中'}</code></p>
          {release?.latest && <p className="mt-1">最新版本：<code className="font-mono">{release.latest.slice(0, 12)}</code></p>}
        </div>
        {release?.supported === false && <p className="text-sm text-gray-500">当前系统不支持 Windows 自动安装。</p>}
        {release?.supported && release.available && !started && <p className="text-sm text-sky-700">发现新版本，可以直接下载安装。</p>}
        {release?.supported && !release.available && !started && <p className="text-sm text-green-700">已是最新发布版本。</p>}
        {started && <p className="text-sm text-amber-700">更新已开始。后台短暂断开属于正常现象，恢复后将自动显示结果。</p>}
        {release?.task?.stage && (
          <p role="status" className={`text-sm ${release.task.stage === 'failed' ? 'text-red-700' : 'text-gray-600'}`}>
            {release.task.message}
          </p>
        )}
        {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
        <div className="flex flex-wrap gap-3">
          <button type="button" onClick={/* 当前回调触发一次手动更新检查。 */ () => void refresh()} className="rounded-xl bg-gray-100 px-4 py-2 font-bold text-gray-700 hover:bg-gray-200">
            <RefreshCw className="mr-2 inline h-4 w-4" />检查更新
          </button>
          <button type="button" disabled={!release?.available || !release.supported || busy || started} onClick={/* 当前回调请求管理员确认并启动更新。 */ () => void performUpdate()} className="rounded-xl bg-sky-600 px-4 py-2 font-bold text-white hover:bg-sky-700 disabled:opacity-40">
            <Download className="mr-2 inline h-4 w-4" />{busy ? '正在启动更新' : '立即更新'}
          </button>
        </div>
        <p className="text-xs text-gray-500">仅使用 xianyumht-cmd/yuyu 的已验收 Windows Release；下载时校验 SHA-256，停止服务后备份数据库和加密密钥，再安装升级。</p>
      </div>
    </section>
  );
};

export default WindowsUpdater;
