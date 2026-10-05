# 街舞拆解 · iPhone 原生 App

把一段舞蹈视频丢进来，App 会：

1. **逐帧提取人体骨架**（Apple Vision，本机跑，不联网、不上传）
2. **听音乐数拍子**（1024 点 FFT → 谱通量 → 自相关；没音频就用骨架运动能量反推）
3. **按 8 拍自动切成小段**，每段单独循环
4. **算出这一段在练什么、哪里最容易做错**（速度 / 重心起伏 / 横向移动 / 膝盖角度 / 左右对称 / 手的高度 / 是否离地翻滚 / 脚部可见率）
5. **可选：开摄像头跟着跳，实时打分**，并把「姿势不对」和「没跟上拍」分开告诉你

这是原生 SwiftUI + AVFoundation + Vision 的实现，**不是网页**。
界面、手势、摄像头都是 iOS 原生的。

---

## 一、你不需要 Mac，也不需要 99 美元

iOS 的 App 必须在 macOS 上用 Xcode 编译，这是苹果的限制，绕不过去。
但编译这一步可以**借 GitHub 的 macOS 机器**来做，全程免费：

```
你的 Windows 电脑                 GitHub 的 macOS 机器              你的 iPhone
──────────────                   ──────────────────────            ───────────
git push  ───────────────────▶   自动跑 xcodebuild
                                  产出未签名的 DanceCoach.ipa
下载 ipa  ◀───────────────────
用 Sideloadly + 免费 Apple ID
签名并安装 ───────────────────────────────────────────────────▶  装上就能用
```

- **不需要** 99 美元的开发者账号
- **不需要** Mac
- 仓库设置成 **Public**（公开）就行 —— 公开仓库用标准托管运行器**完全免费**
  （[GitHub 官方计费文档](https://docs.github.com/zh/billing/concepts/product-billing/github-actions)：*usage is free for public repositories that use standard GitHub-hosted runners*）

### 开工前：你这台电脑现在的状态

我检查过了，结论是**只差三个软件，都能一条命令装好**：

| 东西 | 状态 |
|---|---|
| `git 2.56.0` | ✅ 已装 |
| 项目代码 | ✅ 已提交（分支已改成 `main`） |
| `winget v1.29` | ✅ 已装 → 所以下面能用命令一键装软件 |
| git 远程地址 | ✅ 已指向 `github.com/Ggbond123abc/dance-coach-ios` |
| iTunes / iPhone 驱动 | ❌ 没装（第四节装） |
| Sideloadly | ❌ 没装（第四节装） |
| 手机 | ❓ 需要你准备一根能传数据的线 |

按顺序做完 **二 → 三 → 四** 就能在手机上用上了。全程大概 30~40 分钟，
其中大部分时间是等编译和等下载。

---

## 二、把代码推到 GitHub（一次性，约 5 分钟）

### 2.1 先注册 / 登录 GitHub

打开 https://github.com ，没账号就点 **Sign up** 注册（免费，邮箱 + 密码即可）。
已经有账号就登录。

### 2.2 建一个空仓库

1. 打开 https://github.com/new
2. **Repository name** 填：`dance-coach-ios`
3. 下面选 **Public** ← 这一步很关键，选 Private 会消耗付费额度
4. **不要**勾 "Add a README file"，其它都别动
5. 点绿色按钮 **Create repository**
6. 建好后网页会显示一堆命令，**先别管它**，往下看

### 2.3 记住你的用户名

网页右上角头像旁边就是。比如你的主页是 `https://github.com/zhangsan`，
那用户名就是 `zhangsan`。下面命令里的 `你的用户名` 换成它。

### 2.4 在这个文件夹里打开终端

1. 打开文件夹 `C:\Users\A\Desktop\Agent\dance-coach-ios`
2. 在**地址栏**（显示路径的那一条）里点一下，把内容全删掉
3. 输入 `powershell` 然后按回车

会弹出一个蓝色/黑色窗口，路径就停在这个文件夹。

### 2.5 推送

远程地址已经设好了（指向 `github.com/Ggbond123abc/dance-coach-ios`），
本地分支也已经是 `main`，所以只要**一条命令**：

```powershell
git push -u origin main
```

> ⚠️ 会弹浏览器让你登录 GitHub 授权**一次**，之后 git 会记住，不用再登。
> 屏幕上看不到弹窗时，检查任务栏有没有闪烁的浏览器图标。

> 提交身份已经设成 `Ggbond123` / `3096972826@qq.com`，
> 想改就在这个文件夹里跑：
> ```powershell
> git config user.name "新名字"
> git config user.email "新邮箱"
> ```

### 2.6 第一次推送会弹登录窗口

- 会跳出一个浏览器窗口让你授权 GitHub，点 **Continue / Authorize**
- 可能要求你**验证邮箱**：去邮箱点一下 GitHub 发来的确认链接，回来再推一次
- 推成功的标志是最后一句类似：
  ```
  * [new branch]      main -> main
  branch 'main' set up to track 'origin/main'.
  ```

<details>
<summary>如果报错 <code>remote origin already exists</code></summary>

说明你用了 `add`。改成 `set-url` 再来一次：
```powershell
git remote set-url origin https://github.com/你的用户名/dance-coach-ios.git
git push -u origin main
```
</details>

---

## 三、等它在云端编译（3~8 分钟）

### 3.1 看进度

推送完，打开：

```
https://github.com/你的用户名/dance-coach-ios/actions
```

- 会看到一条叫 **原生 iOS 版街舞拆解 App** 的记录，旁边一个**黄点**在转 = 正在编译
- 点进去，左边有一项 **build**，再点开看实时日志
- **绿勾 ✅** = 成功（通常 3~8 分钟）
- **红叉 ❌** = 失败 → 跳到第十四节，把报错发给我

第一次编译会 `brew install xcodegen`（装一个工具），所以会花得久一点。

### 3.2 下载 ipa

编译成功后，在同一次运行的页面里：

1. 往下拉到 **Artifacts** 区域
2. 点 **DanceCoach-unsigned-ipa** 下载
3. 得到 `DanceCoach-unsigned-ipa.zip`
4. 解压，里面是 **`DanceCoach.ipa`** ← 这就是要装的东西

> 建议解压到桌面，等下 Sideloadly 要用这个文件。
> Artifact 默认保留 30 天，过期了重新跑一次构建就有（网页上点 **Re-run all jobs**）。

### 3.3 以后改了代码，怎么重新装

如果哪天你让我改了 App 的代码（或者你自己动手改），更新流程就是：

1. 在 `dance-coach-ios` 文件夹里开 PowerShell，跑：
   ```powershell
   git add -A
   git commit -m "改了点什么"
   git push
   ```
   （`git push` 不带参数即可，2.5 步的 `-u` 已经记住推哪儿了）
2. GitHub 会自动重新编译（不用你点任何东西）
3. 编译好之后**重新下载 ipa**，再用 Sideloadly 装一次覆盖掉旧的

> 注意：Sideloadly 装的时候会**覆盖**同名 App。App 里的数据（导入的视频）不会保留，
> 反正视频每次重新选就行。

---

## 四、装到 iPhone 上（Windows + 免费 Apple ID）

### 4.1 装三个软件（一条命令一个，约 10 分钟）

你的电脑上**现在这三样都没装**（我检查过了）。好消息是都有 `winget`，不用去网站上找：

在开始菜单搜 **PowerShell**，**右键 → 以管理员身份运行**（要管理员，否则装不上驱动），
然后一条一条粘：

```powershell
winget install --id Apple.AppleMobileDeviceSupport -e --accept-package-agreements --accept-source-agreements
winget install --id Apple.iTunes -e --accept-package-agreements --accept-source-agreements
winget install --id iOSGods.Sideloadly -e --accept-package-agreements --accept-source-agreements
```

| 装的是 | 干什么用的 |
|---|---|
| **Apple Mobile Device Support** | iPhone 驱动。**Sideloadly 必需**，缺了会连不上手机 |
| **iTunes** | 提供苹果的签名组件（anisette）。这个 winget 装的是**苹果官网桌面版**，不是微软商店版，能正常用 |
| **Sideloadly** | 真正签名 + 装 App 的工具 |

> ⚠️ 如果你自己跑去下了**微软商店版 iTunes**，Sideloadly 会连不上手机。
> 必须用上面这条命令（或在 apple.com 下 win64 版）。

装完**重启一次电脑**，让驱动生效。

### 4.2 手机上的准备

1. 用数据线把 iPhone 连到电脑（要能传数据的线，纯充电线不行）
2. 手机上会弹「要信任此电脑吗？」→ 点 **信任** → 输入锁屏密码
3. 如果没弹：拔掉重插，或设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私
4. 设置 → 通用 → 关于本机，记住「名称」（比如 `张三的 iPhone`）

### 4.3 用 Sideloadly 装

1. 打开 **Sideloadly**（会弹一个小窗口）
2. **IPA 那一栏**：把解压出来的 `DanceCoach.ipa` 拖进去
3. 上面的设备下拉框里应该出现你的 iPhone（没出现就是驱动/信任的问题，看 4.1、4.2）
4. **Apple ID 那一栏**：填你的 Apple ID（普通免费账号就行，不用开发者账号）
5. 点 **Start**
6. 会弹出输入 Apple ID 密码 —— 这是在你**本机**直接和苹果服务器换签名证书，
   密码不会经过 GitHub，也不会经过我
7. 进度条走完，出现 `Done` 就好

### 4.4 手机上信任它（**必须做，不然点开就闪退**）

1. 设置 → 通用 → **VPN 与设备管理** → 开发者 App → 点你的 Apple ID → **信任**
2. iOS 16 及以上：设置 → 隐私与安全性 → 拉到最底 → **开发者模式** → 打开 → 重启手机 → 重启后点确认
3. 回到桌面，点开「**街舞拆解**」

### 4.5 七天之后

免费 Apple ID 签出来的证书**只有 7 天有效期**，第 8 天点开会提示「无法验证 App」。
**重装一次就行**：重复 4.3 + 4.4 两步（`DanceCoach.ipa` 还在电脑上，不用重新编译）。

嫌每周手动重装麻烦，可以上 **AltStore**（https://altstore.io/）：
它在你电脑上跑一个小服务，手机连同一个 Wi-Fi 就自动续签。
免费账号同时最多只能装 3 个自签 App。

---

## 五、App 怎么用

### 1) 导入
- **从相册选视频**（推荐）：一段只放一个动作或一个小组合，10~60 秒最好
- **或者贴视频直链**：只支持直接指向视频文件的链接（`.mp4` / `.mov`）。
  抖音 / B站 那种网页链接不行 —— 先存到相册再走第一条路

### 2) 等分析
逐帧提骨架 → 数拍子 → 切段 → 算易错点。
**别切走 App、别锁屏**，iOS 会把后台的画面处理停掉。1 分钟视频大约 20~60 秒。

### 3) 跟着练
- **分段卡片**：横着滑，点一段就跳到那一段
- **拍子小方块**：点第几拍就从第几拍开始循环。上方的原点 = 强拍
- **从第 N 拍 到 第 M 拍**：精确到某两拍之间反复磨，解决"总是在第一个节拍循环"
- **只循环这一拍 / 循环整段**
- **拍子减半 / 拍子加倍**：自动数拍偶尔会数成两倍或一半，点一下就能修正，分段会重算
- **上一拍 / 进一帧 / 退一帧 / 下一拍**：动作快看不清就一帧一帧抠
- **速度 0.25x ~ 原速**：先 0.25x 定住点位，再 0.5x、0.75x 提上去

### 4) 脚步看不懂
- **下半身**：自动把画面推近到腿脚活动的那块区域，转成特写
- **脚部轨迹**：左脚画蓝线、右脚画橙线，能看出脚是走直线、划线还是转圈
- 两者叠加 + 0.25x，基本没有看不明白的脚步

### 5) 避免做错
「动作要点 · 易错点」里每条都是骨架量出来的，会直接说你容易犯什么错，比如
*膝盖尖对着脚尖方向（别内扣）*、*下沉要压在拍点上*、*手腕要过肩线才算到位*。

### 6) 摄像头实时比对
架好手机、点「开启摄像头」，跟着跳：
- 右上角**分数**：只看姿势像不像，跟你站得远近、身材高矮、手机怎么摆**无关**
- **抢拍 / 慢 xx 毫秒**：这一项专门管节奏，不混进分数里
- **对比图**：青色虚线是参考动作，实线是你，绿=对得上，红=差得多
- **最偏的部位**：直接点名哪里不到位
- 左右方向反了（参考背对镜头）会单独提示

---

## 六、隐私 / 联网

- 视频、摄像头画面、骨架数据**全部只在这台手机上处理**，App 里没有任何上传代码
- 第一次安装需要联网（签名），之后**不联网也能用**
- 只有一处例外：你自己主动贴 URL 下载视频时才走网络

---

## 七、已知限制（说清楚比较好）

| 事项 | 说明 |
|---|---|
| 动作**名字** | 不识别。没有公开的大规模"街舞动作名"数据集，硬猜会错得离谱。App 只说这一段在练什么（快/慢、有没有位移、哪边是主力…） |
| 单目相机 | 只有一个镜头，没有深度。所以「手在前还是在后」这类前后差异看不太出来 |
| Vision 的 19 个关节 | 只有髋、膝、踝、腕，**没有脚跟、脚尖、手指**。所以精确的脚掌朝向、手指细节做不了（打分用的 12 个关节它全都有，不受影响） |
| Popping 的 pop | 肌肉绷紧的震，骨架看不出来 |
| Breaking 的大招 | 倒立、翻滚时 Vision 容易跟丢，这一类动作建议只用来看节拍和慢放，别信骨架 |
| 拍速 | 自动数拍是猜的，会有一两拍的误差，用「拍子加倍/减半」和手动选起拍修 |
| 必须 60fps | 用 30fps 拍的视频，快速动作会糊成一团 |

---

## 八、卡住了怎么办

### 8.1 编译失败（红叉）

代码是照着一套已验证的算法重写过来的（原型见 `..\dance-coach\index.html`），
但这个 iOS 工程**还没在真机上编译过**（本机没有 macOS / Swift 工具链）。
第一次云端编译大概率要修 1~2 轮小错，这是正常的，不是你的问题。

**怎么把错误给我**：

1. 打开失败的那次 Actions 运行
2. 点左边红色的 **build**
3. 展开 **编译（不签名）** 这一步
4. 从下往上找第一行 `error:` 开头的，把它**连同上面 10 行、下面 5 行**一起复制给我

有它我就能直接定位并改好，你再 push 一次即可。

### 8.2 其它常见问题

| 症状 | 原因 / 怎么办 |
|---|---|
| `git push` 报 `Authentication failed` | 需要先在 GitHub 网页登录，并去邮箱点验证链接 |
| `git push` 报 `remote origin already exists` | 改成 `git remote set-url origin <网址>` 再推 |
| Actions 页面啥也没有 | 确认推的是 `main` 分支，且仓库是 **Public** |
| Sideloadly 里看不到手机 | ① 没装 Apple Mobile Device Support ② 手机上没点「信任」③ 换根数据线 ④ 重启电脑 |
| Sideloadly 报 `Invalid anisette` | 打开一次 iTunes，让手机连上 iTunes 认证，再回 Sideloadly 重试 |
| Sideloadly 报 `Provision.cpp:81` / 证书已满 | 免费账号最多同时 3 个自签 App，去设置里删掉旧的 |
| 装好了但点开闪退 | 没做 4.4 的「信任」或「开发者模式」 |
| 第 8 天提示「无法验证 App」 | 证书过期了，重做 4.3 + 4.4 |
| App 里分析卡在 0% | 别切走 App、别锁屏，iOS 会停掉后台画面处理 |
| 分析完没有骨架 | 视频里人太小 / 太黑 / 动作太快拖影，换一段重拍 |

---

## 九、代码结构

```
project.yml                      Xcode 工程定义（唯一真相，.xcodeproj 不入库）
.github/workflows/ios-build.yml  GitHub 上的编译流水线
DanceCoach/
  DanceCoachApp.swift            程序入口
  Info.plist                     由 project.yml 生成（不入库）
  Assets.xcassets/               图标
  Models/Pose.swift              33 点关键点常量、分段、诊断项的数据结构
  Core/
    PoseMath.swift               身体坐标系归一化 + 逐关节误差 + 打分
    Diagnostics.swift            8 个易错点指标
    FFT.swift                    vDSP 实数 FFT
    BeatDetector.swift           节拍检测（音频 + 骨架运动两级兜底）
  Video/MediaIO.swift            视频解析、Vision 提骨架、音频混单声道
  Camera/
    CameraTracker.swift          前置摄像头 + 实时骨架
    PoseComparator.swift         ±0.35 秒窗口内的最优匹配
  Audio/ClickPlayer.swift        每拍提示音
  UI/
    StudioModel.swift            全部状态与分析编排
    ContentView.swift            导入页 / 练习页切换
    ImportView.swift             选视频
    PracticeView.swift           视频舞台 + 播放控制 + 分段拍子 + 显示设置
    SkeletonView.swift           骨架叠加层 + 脚部轨迹
    CameraPanelView.swift        摄像头预览 + 对比图
    DiagnosticsView.swift        易错点列表
    Theme.swift                  配色与卡片样式
```

## 十、关键算法说明（为什么分数可信）

- **身体坐标系**：原点 = 髋部中点，长度单位 = 躯干长。
  所以分数跟你在画面里的位置、离镜头远近、身材大小完全无关。
- **先摆正再比**：摄像头缓冲方向可能和参考视频不一致，
  比对前两边都会先旋转成"躯干朝上"，避免对齐上限被顶住导致恒为 0 分。
- **姿势 vs 节奏分开算**：
  在参考动作里搜 ±0.35 秒，找跟你**最合拍**的那一帧比姿势。
  于是"动作做错了"体现在逐关节误差，"没跟上拍"体现在时间偏移，互不污染。
- **分数 = 整体像不像 + 最偏的三个部位**：
  `0.4 × (1 - 平均误差/0.6) + 0.6 × (1 - 最差三点平均/0.3)`。
  只看平均值的话，12 个点错 1 个也才掉几分，太松。
