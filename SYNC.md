# 与上游同步

本仓库是 [ccch1mneyyy/dsh-go](https://github.com/ccch1mneyyy/dsh-go) 的常规 fork：
`main` 之上只有少量提交，**保留上游完整历史**。所以用 Git 原生方式同步即可，
不需要补丁重放。

```bash
git fetch origin
git rebase origin/main       # 或 git merge origin/main
git push mine main
```

- `origin` 始终指向上游（`ccch1mneyyy/dsh-Go`），不要改成自己的仓库。
- `mine` 指向本仓库（`liconglei/dsh-go`）。

## 本地改动的内容

- **SDK**：`dsh_client` 在 HTTP 请求和 WebSocket 升级上都携带 `Authorization`，
  使 Basic 代理后面的部署也能用 mux 和后台读。
- **App**：HTTP(S) 主机作为一等主机类型——自己的列表分区、表单、密钥存储、
  地址直连（不经过 SSH 隧道）、网页模式与插件岛适配；以及若干状态修复。
- **工具**：`tooling/release-arm64.sh`，内部版本号每包 +1，用户可见版本号
  只有明确决定后才改；打出的 arm64 release **不含本地引擎**。

## 签名

签名材料不进仓库：`app/android/key.properties`、`*.jks`、
`tooling/.release-build-number` 都在 `.gitignore` 里，不要用 `git add -f`。
