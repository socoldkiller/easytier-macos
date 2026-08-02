# Star History README 图表故障调查

调查日期：2026-08-01（最后实测：2026-08-01 12:33 UTC / 20:33 CST）

调查对象：Star History 官方站点与 API、官方 GitHub Issue、GitHub 官方变更公告与 Community Discussion，以及近期受影响仓库的公开 Issue/PR。

## 结论

这是 **Star History 嵌入图表 API 的大面积故障/严重退化**，不是 `socoldkiller/easytier-macos` 单仓库的问题；但也不是整个 Star History 网站完全宕机。

- `www.star-history.com` 首页仍返回 HTTP 200。
- `api.star-history.com/svg` 在 9 个互不相关的仓库抽样中全部失败：8 个返回 HTTP 500 和 `timeout of 10000ms exceeded`，1 个返回 HTTP 503 和 `All GitHub API tokens are rate-limited`。
- Star History 维护者已对完全相同的超时错误确认：这是其服务器过载导致的、会不时发生的问题。
- 2026 年 7 月以来，官方仓库和多个外部仓库持续出现 README 图表空白、HTTP 500/504、改用静态图或自托管图表的报告；截至 7 月 31 日仍有人追问“Still no fix?”。
- 背后还有一个长期性原因：GitHub 自 2026-06-30 起限制公开 `stargazers` API，只允许仓库管理员和协作者访问。Star History 依赖这个接口取得每个 Star 的时间，维护者表示旧体验很可能无法完全恢复，目前仍在等待 GitHub 的正式反馈。

因此当前现象最好描述为：

> Star History 主站可访问，但 README 使用的图表生成 API 正在广泛失败；即时错误来自 Star History 后端过载、超时和 token 限流，而服务容量问题又叠加了 GitHub `stargazers` API 的平台级限制。

## 1. 2026-08-01 横向实测

对以下公开端点并行请求：

```text
https://api.star-history.com/svg?repos=<owner>/<repo>&type=Date
```

结果如下：

| 仓库 | HTTP | 响应摘要 |
| --- | ---: | --- |
| `socoldkiller/easytier-macos` | 500 | `timeout of 10000ms exceeded` |
| `star-history/star-history` | 500 | `timeout of 10000ms exceeded` |
| `facebook/react` | 500 | `timeout of 10000ms exceeded` |
| `vercel/next.js` | 500 | `timeout of 10000ms exceeded` |
| `vuejs/core` | 500 | `timeout of 10000ms exceeded` |
| `rust-lang/rust` | 500 | `timeout of 10000ms exceeded` |
| `sub-store-org/sub-store` | 500 | `timeout of 10000ms exceeded` |
| `subboost/subboost` | 500 | `timeout of 10000ms exceeded` |
| `fossui/fossui` | 503 | `All GitHub API tokens are rate-limited, try again later` |

同一时段访问 <https://www.star-history.com/> 返回 HTTP 200。因此故障集中在图表数据抓取/生成 API，而不是网站入口整体离线。

这组抽样不是正式的全球可用性监控，但仓库规模、所有者和生态各不相同，且 Star History 自己的仓库也失败，足以排除 easytier-macos 的 README 语法或仓库属性是主要原因。

## 2. Star History 官方 Issue 已有同类报告

### 完全相同的 10 秒超时

2026-07-22，用户在 [Issue #546：API timeout of 10000ms exceeded](https://github.com/star-history/star-history/issues/546) 报告生成的嵌入 API 对 `sub-store-org/sub-store` 返回：

```text
Repo sub-store-org/sub-store: timeout of 10000ms exceeded
```

维护者 `tianzhou` 当天回复：

> This happens from time to time. Due to our server overload.

来源：[维护者回复](https://github.com/star-history/star-history/issues/546#issuecomment-5043552840)。Issue 随后由维护者以 `not planned` 关闭，并没有对应修复提交。

### 7 月以来持续影响多个仓库

[Issue #539：Empty star history chart since July 1st, 2026](https://github.com/star-history/star-history/issues/539) 是目前最集中的跟踪帖：

- 7 月 5 日有用户表示其所有仓库都无法正常显示，另有用户回复 `same`。
- 维护者 7 月 6 日确认 GitHub 正在限制 stargazers API，并表示旧式无 token 嵌入“目前不再工作”，团队在寻找替代方案：[维护者说明](https://github.com/star-history/star-history/issues/539#issuecomment-4890194504)。
- 7 月 27 日，用户报告 `subboost/subboost` 的 `/chart` 仍返回 HTTP 500 和同样的 10 秒超时，而 GitHub Camo 返回 504：[报告](https://github.com/star-history/star-history/issues/539#issuecomment-5091510745)。
- 7 月 28 日另一用户确认“Same as me”：[报告](https://github.com/star-history/star-history/issues/539#issuecomment-5102504609)。
- 7 月 31 日仍有人追问“Still no fix?”：[最新跟进](https://github.com/star-history/star-history/issues/539#issuecomment-5142782013)。

其他官方 Issue 也显示这不是孤例：

- [Issue #540](https://github.com/star-history/star-history/issues/540) 收到多个“same issue”报告，描述主站能画图而 API/README 只显示空图；维护者将其作为重复 Issue 关闭。
- [Issue #541](https://github.com/star-history/star-history/issues/541) 有两个不同仓库报告“几天前还正常、现在 README 不显示”，维护者确认是 GitHub API 突然变化并正在研究替代方案：[回复](https://github.com/star-history/star-history/issues/541#issuecomment-4891255518)。
- [Issue #547](https://github.com/star-history/star-history/issues/547) 创建于 7 月 31 日，报告暗色主题嵌入图无法渲染并显示 `Error Fetching Resource`；截至调查时仍开放。

## 3. 外部仓库和论坛式讨论也有近期报告

GitHub 全站搜索在 2026 年 7 月以来找到多项独立仓库对 `api.star-history.com` 的修复、移除或自托管变更。较直接的近期例子包括：

- [elementalsouls/Claude-BugHunter PR #54](https://github.com/elementalsouls/Claude-BugHunter/pull/54)，创建于 2026-07-31 22:30 UTC：连续三次复现 HTTP 500，同组织的小仓库也失败，因此改为仓库内生成静态 SVG。
- [alshedivat/al-folio PR #3684](https://github.com/alshedivat/al-folio/pull/3684)，创建于 2026-07-28：5/5 次请求失败，并在 `octocat/Hello-World` 这种极小仓库复现，作者将其判断为服务级后端失败。
- [wesammustafa/wesammustafa PR #6](https://github.com/wesammustafa/wesammustafa/pull/6)，创建于 2026-07-26：记录“live API is down again”，两个 README 图表均返回 500，恢复为自托管图表。
- [SamurAIGPT/llm-wiki-agent Issue #58](https://github.com/SamurAIGPT/llm-wiki-agent/issues/58)，创建于 2026-07-10：在自身仓库和 `facebook/react` 上都复现同样超时，随后以 Shields badge 替换。

这些并非 Star History 官方状态公告，但它们是受影响仓库维护者留下的可核对现场记录，并覆盖不同日期和不同仓库。

## 4. 更深层原因：GitHub 限制 stargazers API

GitHub 在 [2026-06-30 官方 Changelog](https://github.blog/changelog/2026-06-30-upcoming-access-restrictions-to-public-api-endpoints-and-ui-views/) 宣布：

- `/repos/{owner}/{repo}/stargazers` 将只允许仓库管理员和协作者访问；
- 过渡期可能返回空响应、403，之后再完全移除公开访问；
- 原因是公开 stargazer 列表被用于抓取用户数据和发送垃圾信息。

Star History 依靠 stargazer 列表中的 `starred_at` 时间构建历史曲线，因此该变化直接破坏了其原有的无状态公共图表模式。

Star History 在 [2026-07-06 官方博客](https://www.star-history.com/blog/github-stargazer-api-restriction/) 中把影响范围写得很明确：README 中的实时历史图表会影响到“essentially every repository”，因为请求由 Star History 服务器发出，而这些服务器并不是各仓库的协作者；对无权访问的仓库，“these charts are broken for now”，仍在探索绕过方法。官方目前建议仓库所有者使用能够读取自己仓库的 token 生成带加密 `sealed_token` 的嵌入链接。

维护者在 [Issue #542](https://github.com/star-history/star-history/issues/542) 中说明：

- 7 月 7 日：鉴于 GitHub 新限制，旧体验“unlikely”能够完全恢复，正在研究绕过办法：[回复](https://github.com/star-history/star-history/issues/542#issuecomment-4902967826)。
- 7 月 21 日：已经与 GitHub 团队开会，仍在等待解决方案：[回复](https://github.com/star-history/star-history/issues/542#issuecomment-5031659953)。
- 7 月 26 日：再次表示仍在等待 GitHub 回复，并链接其公开 X 帖子：[回复](https://github.com/star-history/star-history/issues/542#issuecomment-5082047675)。

GitHub Community 的 [Discussion #201209：Impacts of removing /stargazers](https://github.com/orgs/community/discussions/201209) 也直接点名 Star History 会被这项改动“killed”。该讨论创建于 7 月 7 日，截至 7 月 30 日仍有用户持续反馈；调查时没有 GitHub 员工给出解决方案或选定答案。

## 5. 对 easytier-macos 的判断

当前 README 图表无法加载，不值得继续从 Markdown、大小写、`Date`/`Timeline` 或暗色主题参数方向排查。现有证据表明：

1. 你的请求与官方 Issue #546 的错误文本完全一致；
2. 同一时间多个知名和无关仓库全部失败；
3. API 还直接暴露了 Star History 的 GitHub token 全部限流；
4. 维护者尚未宣布恢复，也没有正式状态页或已发布修复可供引用。

如果 README 需要稳定展示，短期最可靠方案仍是仓库内静态 SVG/PNG，并通过 GitHub Actions 定期刷新；继续热链接当前 Star History API，只能等待其服务容量和 GitHub API 访问问题缓解。
