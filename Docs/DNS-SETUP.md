# ScreenPeers 域名接入指南

ScreenPeers 发布当前 Mac 主网络的 IPv4 地址，支持内网地址；不通过外部网站查询公网出口地址。

## 腾讯云 / 阿里云

1. 在服务商中托管域名，建立一条启用的 A 记录，例如 mac.example.com。
2. 创建可查询域名记录、修改目标记录的 API 账户：腾讯 DNSPod API 3.0 使用 SecretId、SecretKey（DescribeRecordList、ModifyRecord）；阿里云 DNS 使用 AccessKey ID、AccessKey Secret（DescribeDomainRecords、UpdateDomainRecord）。
3. 打开 ScreenPeers → 设置，选择服务商，填写域名 example.com、主机记录 mac（根域填 @）和密钥。
4. 点击“测试并保存”。测试只查询记录；唯一匹配时自动保存记录 ID。存在多条同名 A 记录时填写目标记录 ID。
5. 勾选“自动更新域名”，或点击“立即更新”。

云端建域名、建记录和创建账户只需一次，可交给自己的 agent 通过官方控制台完成。把本指南交给 agent，并说明域名、主机记录、服务商和目标记录。用户直接把密钥填入 App，避免写入项目或聊天。App 不创建、删除云端记录，更新时保留已有 TTL 和解析线路。

配置保存在 ~/Library/Application Support/ScreenPeers/dns.json，密钥保存在 macOS 钥匙串。设置负责生成和修改配置，无需手写 JSON。旧版腾讯 tccli 账户可继续使用；在设置填写新的 ID 和密钥即可改用内置 API。

## 网络和运行方式

- 系统主网络拥有唯一可用 IPv4 时直接使用，包括系统选中的 VPN 接口。
- 主网络缺失、无可用 IPv4 或有多个地址时，使用备用规则，在活动以太网和 Wi-Fi 中选择。不默认绑定网卡或 DHCP 域。
- 网络配置变化通过 macOS SystemConfiguration 通知触发，合并 2 秒内连续事件。仅所选 IP 变化时同步；启动、唤醒也核对一次。
- 每小时核对云端记录。失败按 15、30、60 秒逐步重试，最长间隔 15 分钟。
- App 退出或 Mac 睡眠时不更新；登录启动后恢复。不需要 cron、LaunchAgent 或常驻 Python。
- VNC 来源计数每 5 秒原生读取一次，不触发 DNS 请求或 Python。

## 给用户 agent 的自定义适配器任务

请为目标服务商编写本地可执行文件，实现以下协议。用户在设置选择“自定义”，填写域名及主机记录，选择文件，然后“测试并保存”。

App 直接执行文件，不经过 shell，不传命令行参数。脚本需有正确 shebang 和可执行权限，路径可包含空格。每次执行从 stdin 读取一条 JSON，然后退出：

```json
{"version":1,"operation":"probe","domain":"example.com","subdomain":"mac","hostname":"mac.example.com","record_id":"","address":null}
```

- probe：只查询，准确匹配启用的 A 记录，返回当前地址及稳定记录 ID。已有 record_id 时验证其属于指定域名及主机。
- sync：address 是要发布的 IPv4，record_id 是已保存的绑定 ID。只更新这条记录；地址相同则不写。保留 TTL、线路等属性，更新后从服务商 API 读回确认。
- 成功只向 stdout 输出一条 JSON，退出码 0：

```json
{"success":true,"record_id":"12345","address":"192.168.1.20"}
```

- 失败返回非零退出码或 success:false。诊断写 stderr，不输出密钥；App 显示通用失败信息。
- 40 秒超时，stdout 限制 64 KiB。HTTP 调用应有更短超时。不 fork 后台任务，不安装定时任务。
- 自定义账户由适配器从钥匙串等本机存储读取，不硬编码到脚本。
- 分别测试 probe 与 sync，覆盖多条匹配、错误记录 ID、网络失败和读回不一致。

### 本地模拟示例

仓库 Examples/mock-dns-adapter.py 使用临时文件模拟 DNS，不连接服务商。先赋予可执行权限，再在自定义设置选择它，域名填 example.com，主机记录填 mac。真实接入时将示例读写替换为官方 API，并验证域名、主机及记录 ID。

## 官方参考

- 腾讯 DNSPod：https://cloud.tencent.com/document/api/1427/56166
- 腾讯签名：https://cloud.tencent.com.cn/document/product/1427/56188
- 阿里云 DNS：https://www.alibabacloud.com/help/en/dns/quick-start-1
- 阿里查询记录：https://help.aliyun.com/en/dns/api-alidns-2015-01-09-describedomainrecords
