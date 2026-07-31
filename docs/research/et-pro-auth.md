# EasyTier Pro 账号认证与设备接入方案调查

调查日期：2026-07-28

调查对象：官方 EasyTier Pro 控制台 <https://console.easytier.net/index.html>、其生产接口，以及 EasyTier Pro 官方公开客户端仓库。

## 结论摘要

EasyTier Pro 的公开实现采用的是“双平面”架构：

```text
用户浏览器 / EasyTier Pro App
             |
             | OIDC 登录或 OAuth Device Authorization
             v
  EasyTier Pro 自有控制平面 API
             |
             | 设备接入密钥、设备归属、审批、期望网络配置
             v
     EasyTier Web Config Server
             |
             v
         EasyTier Core
```

核心判断如下：

1. **OIDC 不由 EasyTier Core 或 Config Server 客户端直接配置。** Web 控制台由 `api.console.easytier.net` 发起 OIDC Authorization Code + PKCE，身份提供方是部署在 `auth.console.easytier.net` 的 Casdoor；原生 App 则通过 EasyTier Pro API 使用 OAuth Device Authorization，App 不需要知道 issuer、client ID 或 claim。
2. **Google、GitHub 等上游登录应当配置在 Casdoor。** 当前公开证据可以确认 EasyTier Pro 使用 Casdoor 作为 OIDC Provider；生产环境究竟启用了哪些社交 Provider 无法在未登录状态下从公开接口可靠确认。
3. **设备连接 Config Server 时使用的是 `bootstrap_token`，不是用户的 OIDC access token。** App 从控制平面取得或创建 Device Enrollment Key，然后把 `bootstrap_token` 直接拼到 `tcp://et-web.console.easytier.net:22020/<token>`。
4. **EasyTier Pro 没有使用 Caddy/TCP gateway 改写 `user_token`。** Caddy 只出现在 HTTP 服务入口；公开客户端直接连接独立的 `et-web.console.easytier.net:22020` Config Server 地址。
5. **它确实依赖对 `easytier-web` 的功能扩展，但这些扩展已经提交并合并进 EasyTier 官方仓库。** 主要是 webhook token validation、节点生命周期回调、按 machine 管理以及 webhook 下发网络配置，不是 EasyTier Pro 私有 sidecar 对 Config Server 协议做代理。
6. **原版 `easytier-web` 仍然会把通过 webhook 验证的 token 用作本地用户名。** EasyTier Pro 通过“控制平面拥有真实账号与设备归属；EasyTier Web 本地 user 只是执行层内部记录”的方式绕开 stable principal 问题，而不是让 webhook 返回一个独立 principal。

## 1. Web 控制台如何登录

控制台前端的 API base URL 是 `https://api.console.easytier.net/api/v1`，登录按钮跳转到 `/auth/login`。实际访问：

```text
GET https://api.console.easytier.net/api/v1/auth/login
```

生产接口返回 `302`，重定向到：

```text
https://auth.console.easytier.net/login/oauth/authorize
```

请求包含：

```text
response_type=code
scope=openid profile email
code_challenge_method=S256
redirect_uri=https://api.console.easytier.net/api/v1/auth/callback
```

这说明浏览器面对的是 EasyTier Pro 自有 API，由 API 作为 OIDC Relying Party 和 Casdoor 通信，而不是让控制台或 EasyTier 客户端暴露 issuer/client ID 配置。

`https://auth.console.easytier.net/.well-known/openid-configuration` 的生产响应声明：

```json
{
  "issuer": "https://auth.console.easytier.net",
  "authorization_endpoint": "https://auth.console.easytier.net/login/oauth/authorize",
  "token_endpoint": "https://auth.console.easytier.net/api/login/oauth/access_token",
  "device_authorization_endpoint": "https://auth.console.easytier.net/api/device-auth"
}
```

该站点 HTML 的产品描述和 Cookie 名也明确表明它是 Casdoor。来源：[EasyTier Pro 生产 OIDC Discovery](https://auth.console.easytier.net/.well-known/openid-configuration)、[EasyTier Pro 生产登录入口](https://api.console.easytier.net/api/v1/auth/login?return_to=%2F)。

因此，若产品要支持 Google、GitHub 等第三方登录，与 EasyTier Pro 一致的做法是把它们作为 Casdoor 的上游 Provider；客户端只认识 EasyTier Server/控制平面，不认识每个社交登录提供方。

## 2. 原生 App 如何登录

EasyTier Pro 官方客户端没有内置 Casdoor issuer 或 OIDC client ID 表单，而是请求控制平面的设备授权接口：

```text
POST /api/v1/auth/device
POST /api/v1/auth/device/token
```

请求 scope 为 `openid profile email`，随后轮询标准 device-code grant：

```text
grant_type=urn:ietf:params:oauth:grant-type:device_code
```

授权完成后，App 得到 `access_token`、可选 `id_token` 和 `refresh_token`，并以 Bearer token 调用 `/api/v1/auth/me` 和租户 API。来源：[console_auth_http_service.dart](https://github.com/EasyTier-Pro/easytier-pro-app/blob/bea3572baf1bd1b32eb915b3081c578c144dc3b0/lib/src/auth/console_auth_http_service.dart#L30)、[console_auth_models.dart](https://github.com/EasyTier-Pro/easytier-pro-app/blob/bea3572baf1bd1b32eb915b3081c578c144dc3b0/lib/src/auth/console_auth_models.dart#L30)。

生产 `POST https://api.console.easytier.net/api/v1/auth/device` 会返回 `device_code`、`user_code` 和位于 `auth.console.easytier.net/login/oauth/device/...` 的验证 URL。这进一步证明 App 与 Casdoor 之间隔着 EasyTier Pro 控制平面，而不是 App 自行执行可配置的通用 OIDC discovery。

## 3. 账号 access token 与 Config Server token 是两套凭证

EasyTier Pro 明确区分：

- **控制台 access token**：登录后访问控制平面 REST API。
- **Device Enrollment Key / `bootstrap_token`**：设备连接 EasyTier Web Config Server。

登录成功后，官方客户端会：

1. 请求当前 workspace 的 `/device-enrollment-keys`。
2. 查找名为 `Desktop Auto Key` 或 `Android Auto Key` 的可复用 key。
3. 请求该 key 的 `/secret`，取得 `bootstrap_token`。
4. 若不存在，则创建 `reusable: true`、`pre_approved: true` 的 key。
5. 将该 `bootstrap_token` 和发布接口返回的 Config Server 地址交给本地 EasyTier runtime。

来源：[console_auth_http_service.dart 的 `prepareCoreBootstrap`](https://github.com/EasyTier-Pro/easytier-pro-app/blob/bea3572baf1bd1b32eb915b3081c578c144dc3b0/lib/src/auth/console_auth_http_service.dart#L837)、[平台自动 key 选择规则](https://github.com/EasyTier-Pro/easytier-pro-app/blob/bea3572baf1bd1b32eb915b3081c578c144dc3b0/lib/src/auth/console_auth_http_service.dart#L1140)。

生产 release API 当前返回：

```json
{
  "stable": { "version": "v2.6.4" },
  "web_config_server_url": "tcp://et-web.console.easytier.net:22020"
}
```

来源：[EasyTier Pro 生产 release API](https://api.console.easytier.net/api/v1/releases/latest)。

Android 客户端最终构造：

```dart
return '$trimmedBase/${Uri.encodeComponent(token)}';
```

也就是：

```text
tcp://et-web.console.easytier.net:22020/<bootstrap_token>
```

来源：[android_core_runtime.dart](https://github.com/EasyTier-Pro/easytier-pro-app/blob/bea3572baf1bd1b32eb915b3081c578c144dc3b0/lib/src/core/android_core_runtime.dart#L1908)。

所以 EasyTier Pro 没有把 OIDC access token 直接传给 EasyTier Web，也没有在 Caddy 中把它换成另一种身份；它先由业务控制平面签发独立的设备接入密钥。

## 4. Device Enrollment Key 如何表达用户归属

EasyTier Pro 控制台的已部署前端公开了这些 Device Enrollment Key 字段和操作：

- `owner_user_id`
- `reusable`
- `pre_approved`
- 查看 secret
- 调整 owner
- revoke key
- 对单台 device 执行 approve、reject、reauthorize、remove、restore、purge

控制台文案还明确说明：通过某个 key 接入的设备都会归到该 key 选中的成员名下；调整 key owner 后，该 key 下的设备也会随之转移。这说明真正的“用户/租户/设备归属”由 EasyTier Pro 控制平面维护，不由 EasyTier Web 的 `users.username` 作为业务真相来源。来源：[EasyTier Pro 已部署控制台 JS](https://console.easytier.net/assets/index-BCayweUi.js)。

官方 App 自动创建的是**每个 workspace、每个平台一个可复用 key**，而不是每台设备一个新的 credential：

```json
{
  "display_name": "Desktop Auto Key",
  "reusable": true,
  "pre_approved": true
}
```

因此，多台 Desktop 默认会共享同一个 enrollment token。控制平面再根据 webhook 中的 `machine_id` 建立独立设备记录、审批状态和网络配置。

## 5. EasyTier Web 在方案里的作用

EasyTier Pro 所需的 EasyTier Web 能力已经由 EasyTier 官方 PR #1989 引入：

- webhook 验证客户端提交的 token；
- webhook 返回要下发给该 machine 的 network config；
- 保存 binding version；
- node connected/disconnected 回调；
- 通过内部鉴权接口按 machine 管理 session 和 network instance。

PR 本身将目标描述为“generic webhook-driven management flow”，让外部 control plane 验证 token、注入网络配置并追踪节点生命周期。来源：[EasyTier PR #1989](https://github.com/EasyTier/EasyTier/pull/1989)。

后续官方 PR #2057 将 webhook 返回从单一 config 扩展为精确的 `managed_network_configs` 集合，并把网络配置唯一性按 device 隔离；PR #2383 又加入 revision/cache 优化。来源：[EasyTier PR #2057](https://github.com/EasyTier/EasyTier/pull/2057)、[EasyTier PR #2383](https://github.com/EasyTier/EasyTier/pull/2383)。

这意味着 EasyTier Pro 并非“完全不改 EasyTier Web”。更准确地说：

> EasyTier Pro 所需的 Web 改动已经被设计成通用能力并合并到 EasyTier 上游，所以生产可以基于带这些功能的官方 EasyTier Web，而不必长期维护一个私有协议 gateway。

## 6. Token 是否仍然被当作 EasyTier Web username

是的。在当前 EasyTier v2.6.4 的上游代码中，webhook 返回 `valid: true` 后，`easytier-web` 仍然执行：

```rust
match storage.db().get_user_id_by_token(req.user_token.clone()).await? {
    Some(id) => id,
    None => storage.auto_create_user(&req.user_token).await?,
}
```

来源：[EasyTier v2.6.4 `session.rs`](https://github.com/EasyTier/EasyTier/blob/8428a89d2dabc94c97d370ec607c6ca142473626/easytier-web/src/client_manager/session.rs#L331)。

所以在 EasyTier Web 的本地数据库层面：

```text
bootstrap_token -> users.username -> local user_id
```

EasyTier Pro 能接受这一点，是因为：

1. `bootstrap_token` 是高熵接入 secret，不是 OIDC token 或可读用户名；
2. 默认一个 workspace/platform 重用同一 key，多台同平台设备因此会落到相同 EasyTier Web local user；
3. 业务上的用户、workspace、key owner、device 和 network 权限全部由外部控制平面维护；
4. webhook 每次根据 token + `machine_id` 返回这台机器的期望网络配置，EasyTier Web local user 只是承载 runtime config 的内部实现细节。

它并没有解决“多个不同 enrollment key 必须映射为同一个 EasyTier Web user”这一通用问题。两个不同 key 即使 owner 相同，在原版 EasyTier Web 中仍会形成两个 local user。EasyTier Pro 的控制台不会把这个 local user 当作业务账号，因此不受影响。

## 7. 是否使用 sidecar 或 gateway

可以把 EasyTier Pro 自有 API/控制平面理解成 EasyTier Web 的 external manager 或 control-plane sidecar，但它不是透明协议 gateway：

```text
HTTPS 控制台/API -> 登录、租户、用户、key、device、network 数据
Webhook          -> token validation、machine 状态、期望配置
TCP ConfigServer -> 客户端直接连接 EasyTier Web
```

公开证据没有显示 Caddy 在 TCP 层解析或重写 EasyTier Config Server RPC。生产 HTTP 响应带有 `Via: 1.1 Caddy`，说明 Caddy 用于 HTTP 入口代理；而 App 从 release API 取得独立的 `tcp://et-web.console.easytier.net:22020` 并直接拼接 token。

因此，若“sidecar 配合 Caddy”是指：

- Caddy 路由控制平面 HTTP API；
- 独立 control plane 实现 webhook；
- EasyTier Web 保持 Config Server；

那么这与 EasyTier Pro 基本一致。

若是指 Caddy 或 sidecar 在 `22020` 上解析 EasyTier RPC、替换 `user_token`，则 EasyTier Pro 的公开方案不是这样做的。

## 8. 对当前 easytier-macos 方案的启示

当前项目新增 `principal.id -> EasyTier Web user_id` 补丁，是为了同时满足：

- 每台设备持有不同、可独立轮换和撤销的 credential；
- 同一个真实用户的所有设备仍落到同一个 EasyTier Web user；
- 继续把 EasyTier Web 本地用户作为权限和网络配置归属的一部分。

EasyTier Pro 选择了另一种边界：

- 外部控制平面拥有真实账号、设备归属和网络期望状态；
- enrollment key 可以复用并拥有 owner；
- EasyTier Web local user 不再承担稳定业务 principal 的职责；
- 每台机器的配置由 webhook 按 `machine_id` 下发。

因此，可以不维护当前 `principal` 补丁，但不能只删除补丁而保持其余假设不变。需要在以下两个方向中选择：

### 方向 A：复制 EasyTier Pro 边界

- Broker 升级为完整 control plane，拥有用户、设备、key、网络和权限数据；
- 使用上游 EasyTier Web webhook-managed config；
- 接受 token 继续成为 EasyTier Web local username；
- EasyTier Web 的 local user 不作为产品业务账号；
- 可以使用 owner-scoped reusable key，或允许每设备 key 产生不同 local user。

这样可以删除 `broker_principal_id` 和 principal mapping 补丁，使用上游 EasyTier Web。

### 方向 B：保持当前 stable-principal 模型

- 每设备 credential 独立；
- EasyTier Web user 仍是共享配置/权限的稳定归属；
- webhook 必须返回 stable principal；
- 保留当前很小的 EasyTier Web principal mapping 补丁，或推动它成为上游通用 external-principal 功能。

### 推荐判断

如果目标是**绝对不维护 EasyTier Web fork**，EasyTier Pro 的方案证明可行路线不是 TCP gateway，而是让外部控制平面成为业务事实来源，并把 EasyTier Web 降为 webhook 驱动的执行平面。

如果仍希望使用 EasyTier Web 自带用户、前端和用户级网络归属，同时要求每设备 credential 独立，那么 EasyTier Pro 的做法不能直接解决 stable principal 问题，当前 principal 补丁仍有价值。

## 一手来源

- [EasyTier Pro 控制台](https://console.easytier.net/index.html)
- [EasyTier Pro 生产 API](https://api.console.easytier.net/api/v1/releases/latest)
- [EasyTier Pro 生产 OIDC Discovery](https://auth.console.easytier.net/.well-known/openid-configuration)
- [EasyTier Pro 官方客户端仓库](https://github.com/EasyTier-Pro/easytier-pro-app)
- [EasyTier PR #1989：webhook-managed machine access](https://github.com/EasyTier/EasyTier/pull/1989)
- [EasyTier PR #2057：webhook-managed config reconciliation](https://github.com/EasyTier/EasyTier/pull/2057)
- [EasyTier PR #2383：webhook performance](https://github.com/EasyTier/EasyTier/pull/2383)
- [EasyTier v2.6.4 webhook heartbeat mapping](https://github.com/EasyTier/EasyTier/blob/8428a89d2dabc94c97d370ec607c6ca142473626/easytier-web/src/client_manager/session.rs#L331)
