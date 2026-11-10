# 把域名闸口交给 parent proxy

`network.parentProxy.delegateDomainPolicy` 打开之后，SRT 只在自己真正会直连的目的地上做域名过滤。下一跳是配置的 parent proxy 时，目标域名不再经过 `allowedDomains` / `deniedDomains`，由这个 parent proxy 决定能不能出网。

这是给「出口已经是我们自己的代理」用的。SRT 仍然接住沙箱里的流量，再 `CONNECT` 到 parent proxy；parent proxy（例如 sdk-daemon 里的 proxyserver）用自己的闸口判断目标域名。默认关闭。只配了 parent proxy、没有这个字段时，SRT 的域名名单照旧对每一跳生效，包括已经转给 parent 的流量。

## 配置

```json
{
  "network": {
    "allowedDomains": [],
    "deniedDomains": [],
    "parentProxy": {
      "http": "http://127.0.0.1:9",
      "https": "http://127.0.0.1:9",
      "delegateDomainPolicy": true
    }
  }
}
```

`http` / `https` 写成 parent proxy 的地址。两个都可以不写：SRT 进程自己的 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`（及小写形式）仍会解析成 parent proxy，只要配置里显式写了 `delegateDomainPolicy: true`。只靠环境变量、配置里没有这个字段时，不会把域名策略交出去。

沙箱子进程里的 `HTTP_PROXY` 会被 SRT 改成指向自己的代理，不能拿来当 parent proxy。parent 地址来自 SRT 进程启动时的环境，或来自上面的配置。

## 什么时候跳过 SRT 的域名名单

同时满足才跳过：

1. `delegateDomainPolicy` 为 `true`。
2. 这次请求的出口就是这个 parent proxy，和实际拨号用的是同一条规则。
3. 主机名是合法的 DNS 名或 IP 字面量。

跳过的是 `filterNetworkRequest` 里的这些判断：

- `network.allowedDomains`
- `network.deniedDomains`（含 `deniedDomainReasons`）
- `registerCommandNetworkLists` 登记的按命令名单
- ask 回调

HTTP `CONNECT` 和 SOCKS 按 HTTPS 那条 parent URL 选出口：`https`，没有则回落到 `http`。明文 HTTP 只看 `http`。三条路径用的是同一份、代理启动时捕获的 `parentProxy`。`updateConfig` 会重新解析配置，但正在跑的代理要 `reset()` 再 `initialize()` 之后才换出口和这个开关。

## 仍然走 SRT 域名名单的情况

这些请求的出口不是 parent proxy，开关不生效：

| 情况 | 原因 |
| --- | --- |
| 回环地址，且这次用到的 parent URL 不是环回地址 | 远端 parent 不能代拨本机回环，SRT 直连 |
| `noProxy` 命中的主机（后缀和 CIDR；`host:port` 只按主机名匹配） | 直连 |
| `network.mitmProxy` 命中的主机 | 出口是 MITM 的 Unix socket，不是 parent proxy |
| 这个 scheme 没有 parent URL | 会直连。只配了 `https`（或只有 `HTTPS_PROXY`）时，明文 HTTP 没有 `http` URL，不跳过名单 |
| 畸形主机名 | 控制字符、空字节、IPv6 zone id 等在交给 parent 之前拒绝，避免写进 `CONNECT` |

这次用到的 parent URL 自己在环回地址上时（`127.0.0.1`、`localhost`、`::1`），回环目的地不再直连。CONNECT、SOCKS 和明文 HTTP 都按各自选中的那条 parent URL 判断。`delegateDomainPolicy` 打开时，这些目的地同样跳过 SRT 的域名名单，由 parent 决定。显式写进 `noProxy` 的主机仍然直连，包括回环。

子进程的 `NO_PROXY` 默认含 `localhost`、`127.0.0.1`、`::1`。配置里每一条 parent URL 都是环回地址时，这三项会从子进程的 `NO_PROXY` 里拿掉，客户端才会把回环目的地发给 SRT，再由 SRT 转给 parent。只配了其中一条、另一条是远端代理时，子进程仍把回环排除在代理之外。内网段（`10/8`、`172.16/12`、`192.168/16`、链路本地）始终留在 `NO_PROXY` 里。

`allowedDomains: []` 在这些路径上仍然是全部拒绝。开关打开后，空名单只表示「不经 parent 的目的地都不允许」，不表示经 parent 的目的地也不允许。

## 这个开关不动的东西

- **解析地址检查**本来就不覆盖 parent proxy 和 mitmProxy 的连接。交给 parent 之后，名字解析到哪、能不能打到回环或内网，由 parent 负责。
- **`network.filterRequest`** 仍在域名判断之后执行。明文 HTTP 和 TLS 终结后的内层请求还会进这个回调。只想把域名闸口挪走时，不要再在这里按域名拒绝。
- **凭据注入**仍看各凭据的 `injectHosts`。没写时默认等于 `allowedDomains`。名单里没有的主机，即使 parent 放行了连接，也不会做 sentinel 替换。要给 parent 放行的域名注入凭据，得单独加宽 `injectHosts`。
- **操作系统沙箱**仍然只让子进程连 SRT 自己的本机代理。出网连接是宿主机上的 SRT 进程打到 parent proxy，不要求把目标域名写进 seatbelt / netns 规则。
- **`network.httpProxyPort`** 是另一条路：不启动 SRT 自己的代理，把子进程直接指到外部端口。TLS 终结和凭据替换会一起绕开。本开关是留在 SRT 代理后面，只移交域名判断。
- **`srt-proxy` 的 decider hello**（`docs/srt-proxy.md`）自带一份 `allowedDomains`，不匹配就 403、不再问 decider。那条链路不读 `network.parentProxy`。
