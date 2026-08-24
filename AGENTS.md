# AGENTS.md

> "Programs must be written for people to read, and only incidentally for machines to execute." -- Harold Abelson, SICP

## 1. 仓库定位与核心架构 (Scope & Architecture)

- **主仓库路径**：`~/work/projects/omarchy-plugins` (`/home/eipi10/work/projects/omarchy-plugins`)
- **远程开源地址**：[`forbidden-game/omarchy-plugins`](https://github.com/forbidden-game/omarchy-plugins)
- **运行环境路径**：`~/.config/omarchy/plugins` (`/home/eipi10/.config/omarchy/plugins`)
- **运行宿主**：单实例长驻进程 `omarchy-shell`（位于 `/usr/share/omarchy/shell/`），所有挂件、面板、覆盖层均作为插件运行。
- **单点真实源原则 (Single Source of Truth)**：
  - **所有插件的源码、Manifest、文档、静态资源均在本项目 `plugins/<plugin-id>/` 下集中维护**。
  - 运行环境 `~/.config/omarchy/plugins/<plugin-id>` **一律通过符号链接（Symlink）** 指向本仓库对应子目录。
  - **严禁** 直接在 `~/.config/omarchy/plugins/` 下直接修改代码或存放未受控的静态副本文件。

---

## 2. 仓库目录树与插件清单 (Repository Structure)

```
omarchy-plugins/
├── AGENTS.md                # 本指导规范 (AI Agent & 开发者核心指引)
├── agents.md -> AGENTS.md   # 兼容大小写软链接
├── LICENSE                  # MIT License (Copyright 2026 Xiezhao Pan)
├── README.md                # 插件合集总览、Plugin Matrix 与安装指南
├── install.sh               # 自动化安装与软链接管理脚本
└── plugins/
    ├── eipi10.agents/       # [AI] Claude, Codex, Antigravity, Fireworks 用量与配额监控
    ├── eipi10.battery-info/ # [System] 电池实时充放电功率与日/周/月历史电量统计
    ├── eipi10.cpu-ram/      # [System] CPU/内存/Swap/温度与进程负载弹窗
    ├── eipi10.netrate/      # [Network] 极轻量上下行实时网速监控 (定长防抖)
    └── qwen-asr/            # [Utility] Qwen Audio 3.0 Push-to-Talk 录音与实时转写
```

---

## 3. 核心准则：坚决杜绝 UI/UX 与工程设计中的“AI 泔水”（Zero AI Slop Directive）

在编写任何 QML 界面、交互逻辑、样式与架构方案时，**必须坚决杜绝“AI 泔水”（AI Slop）**：

### 3.1 坚决摒弃 UI 视觉陈词滥调
- **严禁滥用“AI 标配渐变与发光”**：禁止无脑堆砌紫青（Purple-to-Cyan）、蓝紫渐变，禁止滥用无实际语义的霓虹外发光（Neon Glows）与暗色悬浮投影。
- **严禁滥用毛玻璃与漂浮卡片**：禁止无节制使用磨砂玻璃（Glassmorphism）、半透明漂浮卡片、发光边框等廉价炫技特效。
- **严禁刻板套路化布局**：严禁机械套用“3 列功能卡片（1 个通用图标 + 1 句标题 + 2 行占位废话）”的模板套路。
- **杜绝平庸与无主见的排版**：严格遵循 Omarchy 系统字阶与排版规范，确保字阶清晰、层级分明。

### 3.2 杜绝浮于表面的伪设计
- **绝不只做 Happy Path 静态假图**：必须完整设计并实现真实业务状态——**空状态（Empty States）、加载中（Loading/Skeletons）、错误处理（Error States）、焦点/激活态（Focus Rings）、极端长文本溢出与响应式尺寸适配**。
- **基于设计系统（Design Tokens）**：严格遵循 Omarchy 主题色系、间距标尺（Spacing Scale）与圆角规范，严禁硬编码魔数与随意定义不协调的调色板。
- **功能语义与信息密度优先**：每一个组件、按钮、图标和微动效必须有明确的用户价值与交互意图，严禁为了“显得现代”而堆砌空洞容器与装饰胶囊（Pills），核心业务数据与高频操作绝不能被装饰性元素深埋。

---

## 4. 日常开发、维护与提交工作流 (Development Workflow)

### 4.1 修改与调试现有插件
1. **修改代码**：直接在 `plugins/<plugin-id>/` 目录下编辑 QML / JS / Shell 脚本。
2. **实时生效**：由于 `~/.config/omarchy/plugins/` 均为软链接，保存后 `omarchy-shell` 会自动监听重载。
3. **强制刷新与重载**：
   ```bash
   # 重新扫描所有插件
   omarchy-shell shell rescanPlugins

   # 重新加载 shell 配置 (~/.config/omarchy/shell.json)
   omarchy-shell shell reloadConfig
   ```
4. **规范校验**：
   ```bash
   omarchy plugin validate plugins/<plugin-id>
   ```
5. **提交与推送**：
   ```bash
   git add plugins/<plugin-id>/
   git commit -m "feat(<plugin-id>): add your feature description"
   git push
   ```

### 4.2 添加新插件的标准流程
1. **新建子插件目录**：`mkdir -p plugins/<author>.<plugin-name>`
2. **编写核心文件**（每个子插件必须自包含）：
   - `manifest.json`：符合 `schemaVersion: 1` 规范。
   - `README.md`：详尽的使用说明、配置项、快捷键及前置依赖。
   - `<EntryPoint>.qml`：入口组件。
3. **软链接至本地运行环境**：
   ```bash
   ./install.sh <author>.<plugin-name>
   omarchy-shell shell rescanPlugins
   ```
4. **更新根目录文档**：在根目录 `README.md` 的 Plugin Matrix 表格中添加新插件。
5. **提交发布**：`git add . && git commit -m "feat: add <plugin-name>" && git push`。

---

## 5. 安全与隐私防线 (Secrets & Security Directives)

- **严禁硬编码任何 API Key、Token、OAuth Secret 或敏感凭据**。
- 涉及 OAuth 流程的插件（如 `eipi10.agents`），必须支持动态从环境变量（如 `ANTIGRAVITY_CLIENT_ID`）或用户本地专属配置文件（如 `~/.config/omarchy/agents/antigravity/oauth.json`）中读取，绝不提交至 Git 仓库。
- 提交前主动运行代码扫描，确保无敏感泄露。

---

## 6. QML / JS 编码最佳实践 (Code Quality & Performance)

1. **响应式与声明式绑定**：
   - 优先使用 QML 声明式属性绑定（Declarative Property Binding），避免在 JavaScript 中滥用命令式状态赋值。
   - 警惕并杜绝 **Binding Loop**（绑定死循环）。
2. **异步与非阻塞执行**：
   - 严禁在 UI 渲染主线程中执行耗时的同步阻塞操作。
   - 外部进程与命令调用使用 Quickshell 提供的异步 `Process` 或 `Quickshell.execDetached`。
3. **资源生命周期与内存管理**：
   - 定时器（`Timer`）与后台进程必须在组件销毁（`Component.onDestruction`）或不可见时正确暂停/停止，防止后台空转消耗 CPU 与电量。
4. **主题与暗色适配**：
   - 适配 Omarchy 统一主题调色盘（通过 Theme 单例注入），确保在切换明暗主题或调色板时 UI 无缝刷新。
5. **健壮的错误处理**：
   - 外部进程退出码异常、JSON 解析失败、网络超时等场景必须提供防御性容错处理（Try-Catch & Error Fallbacks），严禁导致界面卡死或空白崩溃。

---

## 7. 变更与验证清单 (Verification & Delivery Checklist)

Agent 在完成任何插件修改后，需遵循以下交付流程：

- [ ] **1. Manifest 校验**：运行 `omarchy plugin validate plugins/<plugin-id>` 确保返回码为 0。
- [ ] **2. 运行时无报错**：检查 Shell 日志或运行输出，确认无 QML 语法错误、TypeError 或未捕获异常。
- [ ] **3. 状态覆盖自测**：检查初始加载态、空状态、异常状态、极端文本溢出等表现。
- [ ] **4. 检查 Git Diff**：在仓库根目录执行 `git diff` 与 `git status`，确认变更精准无误且无敏感凭据。
- [ ] **5. 提交并推送**：遵循 Conventional Commits 提交并 `git push` 到 GitHub。
