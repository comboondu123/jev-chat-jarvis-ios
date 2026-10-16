# Jev Jarvis 越狱安装指南（TrollStore · 云端编译）

> 适用：iPhone 14 Pro Max / iOS 17.0 / TrollStore（巨魔）  
> 项目：<https://github.com/jev-chat/jev-chat-jarvis-ios> （MIT 开源）

## 0. 这套方案解决了什么

Jev 的 iOS 版**只有源码、没有现成安装包**，官方编译方式需要 Mac + Xcode + Apple ID  
签名（免费账号 7 天过期）。你没有 Mac，所以用**云端编译**绕开全部三个门槛：

```
GitHub Actions 免费 macOS 云服务器
   ├─ 编译出未签名的 .app
   ├─ ldid 写入 App Group entitlements（免签名安装的关键）
   └─ 打包成 .ipa 上传
        ↓
手机端 TrollStore 直接安装（无 7 天过期、无需 Apple ID）
```

**重要前提**：iOS 17.0 是 TrollStore 支持的最后一个系统版本，你的手机正好卡在这，  
**千万不要升级系统**，升级后巨魔会失效。

## 1. 准备工作

- [ ] GitHub 账号（免费；fork 是公开仓库，Actions 免费额度不限）
- [ ] 手机已装 TrollStore（你已具备）
- [ ] 一个模型 API Key，三选一：
  - **智谱**：`glm-4-flash`（有免费档，速度不错）
  - **DeepSeek**：最快，价格低
  - **OpenRouter**：一个 Key 通全部模型
  - ⚠️ **别用思考型模型**（如 o1/R1 类），思考会占满额度导致出 0 条候选

## 2. 云端编译（约 10–15 分钟，第一次配好后随时可重复）

### 2.1 Fork 仓库

浏览器打开 <https://github.com/jev-chat/jev-chat-jarvis-ios> → 右上角 **Fork**  
（直接 Fork 到自己账号即可，不用改任何东西）。

### 2.2 放入两个文件（这是本方案新增的构建配置）

需要放入 fork 的只有 **2 个文件**，路径必须一字不差：

| 文件                         | 放到的路径                                        | 上传方式                                                                               |
| -------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| `build-trollstore-ipa.yml` | `.github/workflows/build-trollstore-ipa.yml` | 仓库根目录点 **Add file → Create new file**，在文件名输入框粘贴完整路径，再把内容粘贴进去                       |
| `make-ipa.sh`              | `tools/trollstore/make-ipa.sh`               | 先进 `tools` 目录 → **Add file → Create new file** → 文件名 `trollstore/make-ipa.sh`，粘贴内容 |

> 提示：文件内容就在本指南同目录的 `.github/workflows/` 和 `tools/trollstore/` 下，  
> 以及随交付的 `fork-files.zip` 里。也可以用 GitHub 网页的  
> **Upload files** 功能逐目录上传。

### 2.3 开启 Actions（首次）

Fork 完成后打开仓库的 **Actions** 标签页，如果出现  
「I understand my workflows, go ahead and enable them」提示，点一下启用。  
（新 fork 默认允许，多数情况不用操作。）

### 2.4 触发构建

**Actions → 左侧 Build TrollStore IPA → 右侧 Run workflow → 绿色按钮**。  
（push 那两个文件时也会自动触发一次，可留意。）

等待约 10 分钟，构建过程能看到：

- `brew install xcodegen ldid`
- `xcodegen generate`
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`（编译 App + 键盘扩展）
- `Sign with ldid and package IPA`（输出 `OK: 两个二进制均已写入 group.com.jevchat.jarvis` 和 `完成: ...ipa`）
- `unzip -l` 列出的 IPA 内容清单

### 2.5 下载 IPA

构建完成后回到该次运行的页面，底部 **Artifacts** 区域 → 下载  
`jev-jarvis-trollstore-ipa`，解压得到 `jev-jarvis-trollstore.ipa`。

## 3. 安装到 iPhone（TrollStore）

1. 把 `.ipa` 传到手机：隔空投送 / 微信「文件传输助手」/ 手机浏览器下载均可
2. 打开 iPhone 的 **文件** App，找到这个 `.ipa`
3. 点它 → 分享菜单 → **TrollStore** → **Install**
4. 等一两秒，桌面出现 **Jev Jarvis** 图标即安装成功

## 4. 配置与使用

### 4.1 配置模型（App 内完成，改完即存，键盘即时生效）

打开 Jev Jarvis → **模型** 页：

- **生成层（必配）**：预设里直接选「**豆包（火山方舟）**」——已内置方舟端点
  `ark.cn-beijing.volces.com`、默认模型 `doubao-seed-2-1-lite`，并自动带上
  `{"thinking":{"type":"disabled"}}` 关闭深度思考（否则思考会吃光额度出 0 条候选）。
  你只需到 **火山方舟控制台**（https://ark.volcengine.com → API Key 管理）创建一个
  API Key，粘贴到「API Key」栏，点「测试连接」。模型 ID 也可改成
  `doubao-seed-2-1-pro-260915` 等（你的账号若某模型不可用，换列表里的 ID 即可）
- 其他生成层选项：选 OpenAI 兼容（`/chat/completions`）或 Anthropic 兼容（`/v1/messages`），  
  填你自己的 API Key 和模型名。本项目不提供任何生成服务或中转，Key 必须是你自己的
- **判断层（核心）**：界面内置两类预设——  
  - Jev 原生（systemone 题型）：TypeSafe 直连 / OpenRouter / Vercel AI Gateway 三个预设
  - 通用聊天模型：**DeepSeek 官方（判断）** 与 **豆包（火山方舟）（判断）**，  
    与生成层用同一类 Key（DeepSeek 用 `platform.deepseek.com` 的 sk-…；豆包用方舟 API Key），  
    题目会自动翻译成提示词走 `/chat/completions`，无需额外配置
  网关地址、模型、Key 都可自定义。  
  **不配 Key 时自动退化为「盲起草」**（只出候选、不出意图/风险），这是兜底不是开关
- 点 **测试连接**，通了再继续

### 4.2 启用键盘（手机上操作）

1. **设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选「Jev 键盘」**
2. 回到键盘列表，点 **Jev 键盘** → 打开 **允许完全访问**  
   （联网 + 读剪贴板必须，否则分析不了）
3. 回 App 的 **试一试** 页跑一条消息，通了就是全通了

### 4.3 聊天 App 里使用

1. 长按对方那条消息 → **复制**
2. 点输入框，键盘切到 Jev（长按地球键切换）
3. 点 **「分析剪贴板」**
4. 键盘上显示：**意图 + 风险 0-9 + 行动建议 + 每话术 2 条候选**（前稳后放）
5. 点中意的候选 → 文字直接进输入框 → **发送由你手动完成**（本项目永不自动发送）

另有「分析输入框文字」按钮：分析你打到一半拿不准的话。

### 4.4 越狱插件：屏幕读取（微信 / Soul 自动喂料，需完整越狱）

> **为什么需要插件**：iOS 键盘扩展没有读屏幕 / OCR 的系统权限，键盘自身看不到聊天记录。  
> 你的手机是**完整越狱**（Dopamine rootless），所以用越狱插件注入微信 / Soul 进程：  
> 键盘出现 → 通知插件截屏 → Vision OCR（中文优先）识别聊天内容 → 写剪贴板 →  
> 键盘 3 秒后自动拾取分析。全程在手机本地完成，不经过任何服务器。

**配套文件（已随本指南交付）**：

| 文件                                     | 用途                       |
| -------------------------------------- | ------------------------ |
| `jev-jarvis-trollstore.ipa`            | 新版键盘（含「剪贴板无新内容时自动请求扫描」） |
| `jev-screenreader_1.0.6_iphoneos-arm64.deb` | 插件安装包（Sileo / Zebra 装）    |
| `jev-screenreader-1.0.6-manual.zip`    | 插件兜底包（Filza 手动装）         |

**第一步：更新键盘版 IPA**（旧版没有自动扫描逻辑）

1. 按第 3 节用 TrollStore 覆盖安装新的 `jev-jarvis-trollstore.ipa`
2. 完成后重开一次 Jev Jarvis App（让键盘扩展加载新代码）

**第二步：安装插件（二选一）**

- 方式 A（推荐，Sileo）：把 `.deb` 传到手机 → 用文件 App 打开 → 分享到 **Sileo**（或
  Zebra）→ 确认安装 → 自动 `respring` 生效
- 方式 B（Filza）：解压 `manual.zip`，把 `jev-screenreader.dylib` 和
  `jev-screenreader.plist` 两个文件复制到
  `/var/jb/Library/MobileSubstrate/DynamicLibraries/`，然后
  **设置 → 通用 → 关机重启**（或 Sileo 里 respring）

**第三步：验证插件已注入**

1. 打开**微信**，随便进入一个聊天
2. 把系统键盘切到 Jev（长按地球键）
3. 键盘待机页应显示「剪贴板：xxx〔分析〕」或自动开始分析——出现分析即插件生效
4. 没有反应时：打开 **Dopamine → 设置**，确认插件列表里有 **Jev ScreenReader**，
   且「SpringBoard / 微信 / Soul」未被打包进排除列表

**使用方式（两种，插件都参与）**

- 自动：进聊天 → 切到 Jev 键盘 → 键盘自动请求扫描 → 几秒后自动出现候选回复
- 手动兜底：长按对方消息 → 复制 → 切到 Jev 键盘（键盘发现剪贴板变了会直接分析）

> 插件只在「Jev 键盘在场且剪贴板没新内容」时截屏 OCR；识别文本只写进剪贴板并
> 发往你自己配的模型接口，同第 6 节隐私口径。OCR 取聊天区最近最多 14 行，
> 滤掉顶部导航和底部输入栏，界面改版也不受影响。

### 4.5 打字键盘 + 剪贴板「只同意一次」（本版新增）

**顶栏 ⌨️/✨ 切换**

- 顶栏最右侧一排：`⌨️`（进打字键盘）· 地球（系统键盘切换）· 删除
- 在打字键盘里点 `✨` 回到 AI 回复面板；AI 面板里点 `⌨️` 回到打字键盘

**打字键盘（拼音 + 中英 + 符号，全部本地、不联网）**

- 中文模式（默认）：直接打拼音，候选条即时出词/字
  - 词优先（内置 500+ 常用词，多音字已修正：`什么`=shenme、`睡觉`=shuijiao、
    `银行`=yinhang、`快乐`=kuaile…），再补单字（内置 GB2312 一二级全字库 6763 字）
  - 点候选直接上屏；**空格/回车 = 上屏第一个候选**
  - 候选没有想要的字 → 继续打（前缀匹配）或按删除键回退拼音
- `中/EN`：一键切英文直输（大写走 shift）
- `123/ABC`：数字 + 常用符号 + 中文标点（`，。？！`）
- 键盘永不自动发送，发送仍由聊天 App 的发送按钮完成

**剪贴板「只同意一次」**

iOS 系统没有给键盘扩展关闭「粘贴询问」的 API（弹窗由系统隐私策略决定，App 无法代答），
能做到的「只同意一次」= **控制读取频率**：

- 待机页新增开关「**自动分析剪贴板**」（默认开）
  - 开：键盘出现时自动读剪贴板分析 + 自动请求越狱插件屏幕扫描（屏幕读取全流程不受影响）
  - 关：键盘出现时不读、不扫描，只有你手动点「分析剪贴板」时才读一次——系统粘贴提示明显变少
- 第一次弹「允许粘贴」时选**允许**，对同一来源（微信/Soul 的键盘使用）系统会记住；
  之后手动点击也只在必要时提示
- 若弹的是「**微信**想要粘贴」这类**宿主 App 弹窗**（长按复制后微信自己读剪贴板），
  那是微信的权限，与键盘无关：系统设置 → 隐私与安全性 → 粘贴 → 微信 → 改为「询问」或「允许」

## 5. 常见问题

| 现象                            | 处理                                                                                                                                                      |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 键盘里候选为空 / 提示未配置               | ① App 模型页已配置并测试连接通过 ② 已打开「允许完全访问」③ 重启一次键盘（切走再切回）                                                                                                        |
| App 配好了、键盘读不到配置（App Group 不通） | 先从 TrollStore 卸载重装一次；仍不行就在 fork 里把 `group.com.jevchat.jarvis` 换成一个全局唯一的新值（如 `group.com.你的名字.jevjarvis`），要同步改 `project.yml` 与两份 entitlements 共 4 处，再重新构建 |
| 出 0 条候选                       | 你用的模型是思考型（o1/R1 类），思考占满额度；换 glm-4-flash / DeepSeek 等非思考模型                                                                                               |
| 键盘没出现在添加列表                    | 确认 App 已安装；重启手机一次再试                                                                                                                                     |
| 密码框 / 安全输入框强制系统键盘             | 系统行为，不是 bug，无解                                                                                                                                          |
| Actions 构建失败                  | 点开失败步骤看日志；常见是 xcodegen/ldid 安装超时（重跑一次）或签名校验失败（贴日志到项目 Issue）                                                                                             |
| 想换话术 / 加自定义话术                 | 全部在 App 内配置：2 个生效槽位，内置 13 种话术（含集成的「狗头军师」恋爱军师），支持自定义（写「什么语气 + 别变成什么」最管用）                                                                                 |

## 6. 隐私与合规（摘自项目 README）

- 聊天内容只在点「分析」那一刻发往**你自己配置**的模型接口；无自建服务器、不落盘、不进日志
- API Key 存在本机 App Group 私有容器，仅 App 与键盘可读
- 键盘不监听、不上传按键；「允许完全访问」随时可在系统设置里关闭
- 本项目**永不自动发送**，发送由你手动完成
- 只处理你自己设备上、你自己有权查看的聊天；严禁用于诈骗（杀猪盘/婚恋诈骗等）、  
  冒充他人、骚扰、垃圾营销等违法违规用途
- MIT 开源，可商用，分发须保留 LICENSE 与 NOTICE 并注明出处

## 7. 复现与升级

- 以后上游更新源码：fork 仓库点 **Sync fork → Update branch**，再跑一次 Actions 即可拿到新版
- 本方案不修改任何项目源码，只新增了 2 个构建文件，与上游保持同步零冲突

---

*配套文件：`.github/workflows/build-trollstore-ipa.yml`（云端编译）、  
`tools/trollstore/make-ipa.sh`（ldid 签名 + 打包）。*
