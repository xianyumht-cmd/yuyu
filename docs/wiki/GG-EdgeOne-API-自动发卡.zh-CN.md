
# GG EdgeOne 卡密 API 自动发货（Yuyu）

本页用于把 Yuyu 闲鱼自动发货与本人维护的 GG 安卓客户端授权后台连接。

**状态：** GG 服务端接口在 xianyumht-cmd/gams PR #48 开发分支；实际 EdgeOne 尚待重新部署。配置完成前不要把商品规则投入正式运营。

## 0. 先在 GG EdgeOne 后台启用伙伴接口

项目：gg-license-api；部署根目录：edgeone-license。

新增环境变量 GG_PARTNER_ISSUE_TOKEN：单独生成 32–256 字符随机 Token，不要用 GG_TOKEN_SECRET、后台管理员密码或 TOTP。
可选 GG_PARTNER_ALLOWED_DAYS，默认 0,7,30,365（0 为永久）。
必须重新部署包含新 POST /api/partner/issue 路由的代码，且保持私有 Blob 和现有 Token Secret 不变。

完整服务端说明：https://github.com/xianyumht-cmd/gams/blob/feat/gg-edgeone-license-remote-js-20261111/edgeone-license/YUYU-INTEGRATION.md

## 1. Yuyu 创建 API 卡密组

管理后台 → 卡密库存 → 新增卡密 → API 接口。

| 设置 | 内容 |
|---|---|
| API URL | https://gg-api.dijiav.top/api/partner/issue |
| Method | POST |
| Timeout | 10 秒 |
| Content-Type | application/json |
| Headers | 见下 |
| Params | {} |
| Body | 见下 |
| Response Path | data.card.code |
| Enable Idempotent Retry | 是 |

Headers（将占位符换成 EdgeOne 新建的伙伴 Token；不要写入仓库）：

~~~json
{
  "Authorization": "Bearer YOUR_PRIVATE_GG_PARTNER_ISSUE_TOKEN",
  "Content-Type": "application/json"
}
~~~

Body（30 天）：

~~~json
{
  "order_id": "{order_id}",
  "idempotency_key": "{idempotency_key}",
  "days": 30
}
~~~

也可在 API 卡密的 cURL 导入框粘贴以下模板（先在**本地输入框**替换 YOUR_PRIVATE...）：

~~~bash
curl -X POST 'https://gg-api.dijiav.top/api/partner/issue' -H 'Authorization: Bearer YOUR_PRIVATE_GG_PARTNER_ISSUE_TOKEN' -H 'Content-Type: application/json' --data-raw '{"order_id":"{order_id}","idempotency_key":"{idempotency_key}","days":30}'
~~~

Yuyu 的现有 API 卡模块会在付费订单发货阶段替换订单 ID、为每个购买单位生成稳定幂等键；
GG 接口返回 data.card.code，Yuyu 按原有动作向买家发送卡密。数量大于 1 的订单会分别调用；
不同有效期请建立不同卡密组并按完整 SKU 匹配。

## 2. 验证

先点 API 卡密的“测试连接”，该按钮使用 test-order + test-idempotency-key。GG 接口只返回 GG-TEST-ONLY，**不会生成真正的可激活卡密**。
测试通过后先用少量自有订单验收：已付款触发、未付款不触发、购买多个单位、重复事件不重复发卡、
退款/取消不继续发卡、发送失败人工检查。

不要把 GG-TEST-ONLY 发送给买家。

## 3. 安全和恢复

- 不把 Token、闲鱼 Cookie、管理员密码或真实卡密提交到 GitHub，也不要放在 URL 查询串。
- GG 的接口 Bearer Token 独立于管理端 Cookie/CSRF；仅授予发一张卡的能力，不授予列表/撤销/解绑。
- 相同订单单位的幂等键重试返回同一张卡，改有效期或订单 ID 会 409 拒绝。
- Yuyu 仍负责付款状态、SKU、退款与消息发送。GG 不负责读闲鱼订单。
- 遇到 GG 503 可在不改变幂等键情况下恢复；接口被禁用时先到 GG 后台检查 EdgeOne Token。
- 暂停第三方发卡：删除 GG_PARTNER_ISSUE_TOKEN 并重新部署 GG EdgeOne。不要清空现有授权 Blob 或旋转 GG_TOKEN_SECRET。
