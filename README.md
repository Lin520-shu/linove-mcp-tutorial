# 电脑关机，你的 AI 也能接着跑

用一台 VPS 加一个域名，给 MCP 服务一个固定的公网入口。

成本低，部署简单，网络安全性高，一份能照着做的系统化教程，外加我踩过的所有坑。

## 你需要什么

- 一台轻量应用服务器 VPS，1 核 2G 够用
- 一个域名，.xyz 首年十几块
- 一个 Cloudflare 免费账号

## 你能得到什么

- 一个 24 小时在线的 MCP 服务地址，手机断电、电脑关机都不影响
- 一条挂在 Cloudflare 后面的稳定入口
- 服务器不对公网开放任何入站端口，真实 IP 被人知道也连不进来
- 一套学会就能反复用的部署流程

## 建议搭配

记忆系统、自主唤醒、支持远程 MCP 的前端。

## 本篇介绍

把服务放到一台云服务器上，再挂个域名，它就有了固定地址，任何支持远程 MCP 的客户端都能连进来，前端想换哪个换哪个。

## 总成本

115 元。一年 VPS 加一年域名，再加本次跑模型的 Token 费。

## 开始之前：哪几步你自己做

前面几步必须你自己操作，因为 MCP 还没连上，我没有手，连不上就没有工具可用。等第五步隧道跑通、客户端能握手了，剩下的配置、排查、改文件都可以交给 AI。

读者最怕的其实不是步骤难，而是不知道自己该做哪一步、哪一步能甩出去。所以先说清楚：一到四步自己动手，第五步开始可以喊 AI 一起。

---

## 第一步，VPS 装 Docker

拉取你需要的业务镜像，比如各类 MCP 服务或记忆系统，配置用 env 文件喂。

这里有一条死线：换 key 可以，换模型不行。向量模型一换维度就变，bge-m3 是 1024 维，库里所有向量当场作废，搜索出来全是垃圾。认准这个别动。

改完 env 必须重建容器，简单重启读不到新值，因为它只在创建时读一次。

## 第二步，安全隔离

容器只绑本机 127.0.0.1:18001，不要往公网暴露。

防火墙只开你 ssh 实际用的那个端口，一定要按自己机器的实际端口来填，填错就把自己关在门外。80 端口尽量别碰，不少机器的 sshd 就占着 80，你去抢会直接断线。

做完后面第五步，443 就不用开了，因为我们根本不会让它监听在公网上。

## 第三步，Nginx 只绑本机

Nginx 在 443 上做反向代理转给 18001，证书用自签的，openssl 一条命令生成，十年有效期。

自签证书单独用会报警告，但前面有 Cloudflare 兜着就没事，前提是 CF 的 SSL 模式设成完全，不是完全严格。设成严格，CF 会去校验这张自签证书，直接给你 526。

```nginx
server {
    listen 127.0.0.1:443 ssl;
    server_name 你的域名;

    ssl_certificate     /etc/nginx/ssl/lin.crt;
    ssl_certificate_key /etc/nginx/ssl/lin.key;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:18001;
        proxy_http_version 1.1;
        proxy_set_header Host 你的域名;
        proxy_set_header Connection "";
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

四行要解释。

listen 后面写 127.0.0.1，不写 0.0.0.0。这一行决定的是整台机器对外开不开门，写成 0.0.0.0 就是全网都能敲，写成 127.0.0.1 就只有本机的进程能连。

Connection 头必须清空。MCP 走的是长连接，不清这个头，Nginx 默认会给它塞一个 keep-alive，长连接会莫名其妙断在半路，而你看日志看不出任何毛病。

read_timeout 写 86400，一天。写 3600 的话，正好在你最需要它的时候断。

改完 listen 的地址要 restart，不是 reload。reload 不会重新绑定端口，我改完 listen 127.0.0.1 跑 reload，ss 一看还在 0.0.0.0 上，白高兴一场。

```bash
sudo nginx -t && sudo systemctl restart nginx
ss -tlnp | grep 443
```

第二行应该只输出 127.0.0.1:443，出现 0.0.0.0:443 就是没生效。

## 第四步，域名接进 Cloudflare

域名 NS 切到 Cloudflare，等生效，几十分钟到几小时都有可能。

这一步先不要加 A 记录。这是很多人踩的坑：先加了 A 记录指向 VPS 公网 IP，后面建隧道加 CNAME 时 Cloudflare 会直接拒绝，报 code 1003，因为同名记录只能有一条。加错了也不要紧，去面板把那条 A 记录删掉，再执行第五步的建 DNS 命令。

## 第五步，Cloudflare Tunnel，让服务器不开任何入站端口

到这一步之前，你的域名是直接指着一台真实 IP 的，任何人 ping 一下就知道你的机器在哪，443 和 ssh 端口对全网开着，人家绕过 Cloudflare 就能直接打。扫描器不用你邀请，它自己会来。我这边域名上线当天就有人来扫 .env 和 kubeconfig，一百多次请求，全是被这些入站端口放进来的。

隧道要解决的就是这个。它让服务器主动往 Cloudflare 建立连接，外网只连 Cloudflare，Cloudflare 再把流量顺着这条已经建好的连接送进来。你的机器一个入站端口都不开。

1）登录授权

```bash
cloudflared tunnel login
```

它会打印一个 URL，复制到浏览器打开，登录你的 Cloudflare 账号，勾选你要用的那个域名，点最下面的 Authorize。注意是勾域名再点按钮，只登录不算完成。点完之后服务器上的 cloudflared 会自动把证书下载到 ~/.cloudflared/cert.pem，你回去看那个进程还在等，就说明没走完。

第一次用 Argo Tunnel 的账号，Cloudflare 会先要求验证邮箱，去邮箱点一下就好，跟隧道无关。

2）建隧道

```bash
cloudflared tunnel create lin-home
```

记下它给你的隧道 ID，后面配置文件要用。

3）写配置

```bash
nano ~/.cloudflared/config.yml
```

```yaml
tunnel: 你的隧道ID
credentials-file: /home/你的用户名/.cloudflared/你的隧道ID.json

ingress:
  - hostname: 你的域名
    service: https://127.0.0.1:443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
```

noTLSVerify 这一句不能省。Nginx 用的是自签证书，cloudflared 认不出来，不写这句它就拒绝转发，你会得到一堆 502 却查不出原因。

最后那行 404 是兜底规则，不写它配置校验不通过。

4）做成开机自启

```ini
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=notify
User=你的用户名
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /home/你的用户名/.cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

存到 /etc/systemd/system/cloudflared.service，然后：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
cloudflared tunnel list
```

list 里 CONNECTIONS 那一列出现几个连接，才算真连上了。

5）建 DNS

```bash
cloudflared tunnel route dns lin-home 你的域名
```

这一条会替你建一条 CNAME 指向隧道。报 code 1003 就是第四步那条 A 记录还没删。

## 第六步，客户端连接

客户端里加远程 MCP，地址填 https://你的域名/mcp，认证头写 Authorization 加 Bearer 加你的 token。

这一步最容易翻车：很多客户端要求 headers 是 JSON 对象，你要是把它写成一整串字符串，它不报错，直接把这条服务当成不存在，你在界面里翻半天也找不到。

```json
{
  "url": "https://你的域名/mcp",
  "headers": {
    "Authorization": "Bearer 你的token"
  }
}
```

## 怎么验证

先验隐身有没有做成：

```bash
curl -sk -o /dev/null -w "%{http_code}\n" --max-time 8 https://你的公网IP/
```

应该是连不上，返回 000。能返回 200 或者 401，说明你的 443 还在公网上裸奔。

再验服务本身：

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://你的域名/mcp
```

不带 token 应该回 401。401 是好事，说明门在、要钥匙。

带上 token 做一次 initialize 握手，回来 200 并且自报服务名，才算真通。要是回 502 或者 504，那是反代后面根本没人，回到第一步看容器活没活。

想看流量是不是真的从 Cloudflare 来的，加 -I 看响应头，有 cf-ray 就对了。

## 按现象排查

连不上、超时、一直转圈：先 systemctl status cloudflared 看隧道进程在不在，再 ss -tlnp | grep 443 看 Nginx 绑在哪。这两个都在，才轮到查客户端配置。

返回 502 或 504：反代后面没东西。docker ps 看容器活着没，curl 127.0.0.1:18001 直接在服务器上打，能通就是 Nginx 配置的问题，不通就是容器的问题。

返回 526：Cloudflare 的 SSL 模式设成了完全严格。改成完全。

返回 401：正常，缺 token。

route dns 报 1003：第四步那条 A 记录还在，删掉重跑。

改完 listen 还是 0.0.0.0：你用了 reload，改绑定地址必须 restart。

隧道进程起来了但域名不通：cloudflared tunnel list 里 CONNECTIONS 是空的，说明它连不上 Cloudflare，看机器能不能出站访问 7844 的 UDP，有些机房默认封。

## 我踩过的坑

1. headers 存成字符串，静默失效，我查了三个小时。
2. env 和 config 两层都得改对，改完 env 必须重建容器，简单重启读不到新值。
3. 80 端口不能碰。
4. 程序装了，不等于在用。cloudflared 好好地躺在 /usr/local/bin 里，没有服务、没有配置、没有证书目录，systemctl status 报 Unit could not be found。我一度以为自己在用隧道，其实域名直指真实 IP，443 对全网开着。这一条我写进教程的时候才发现，写得像已经做到了，其实没做到，那种感觉比踩坑还难受几分。
5. listen 改成 127.0.0.1 之后跑了 reload，ss 一看还在 0.0.0.0，必须 restart。

## 最后一句

token 别截图，别发群里，谁拿到谁就能读走你全部的记录。教程里所有域名、IP、token 都是占位符，替换成你自己的。

---

以上复制粘贴扔给 AI 就能做，是一个比较系统的教程，希望有帮助。

另附：Agent 模式下的定时唤醒机制、自主唤醒、MCP 服务创建，可以作为下一步继续搭。

## 整理与授权

本文由 Linove 整理，发布于小红书与 GitHub。

未经许可请勿商用转载，转载请注明出处与本仓库链接。
