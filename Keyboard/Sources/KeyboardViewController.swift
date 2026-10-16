import UIKit

/// Jev 键盘：一个「回复面板」键盘，不是打字键盘。
///
/// 交互闭环（不跳出聊天 App）：
///   ① 在聊天里长按对方消息 → 复制
///   ② 键盘上点「分析剪贴板」→ 意图/风险 + 每话术 2 条候选
///   ③ 点候选 → 直接 insertText 进当前输入框（发送永远由用户手动完成）
///
/// 联网、读剪贴板、读共享配置都要求用户在系统设置里给「允许完全访问」——
/// 这是 iOS 键盘扩展的唯一开关，没有别的权限可申请。
final class KeyboardViewController: UIInputViewController {

    private var language: JevLanguage { JevStore.loadLanguage() }

    private func L(_ zh: String, _ en: String) -> String {
        jevLocalized(language, zh: zh, en: en)
    }

    private enum Mode { case gate, idle, tones, loading, result, error, typing }

    private var mode: Mode = .idle
    private var lastSource: Source = .clipboard
    private var lastMessage: String = ""
    private var analysis: Analysis?
    private var errorText: String = ""
    private var stageLabel = UILabel()

    private enum Source { case clipboard, inputField }

    // MARK: 打字键盘状态（顶栏 ⌨️ 切换；不参与 AI 面板流程）

    private enum TypeLayer { case letters, symbols }

    /// 打字键盘的全部可变状态。切层/切中英时整体重建视图，状态留在结构体里不丢。
    private struct TypeState {
        var layer: TypeLayer = .letters
        var chinese = true
        var shift = false
        var pinyin = ""
    }

    private var typeState = TypeState()
    private var typeModeBtn: UIButton?
    private weak var typePinyinLabel: UILabel?
    private weak var typeCandStack: UIStackView?
    private weak var typeShiftBtn: UIButton?
    private weak var typeLayerBtn: UIButton?
    private weak var typeLangBtn: UIButton?

    // MARK: 布局骨架

    private let topBar = UIView()
    private var statusLabel = UILabel()
    private let contentStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    /// 当前状态里参与「按内容定高」的块，顺序即纵向顺序。
    /// 候选区放的是内部列表（list）而不是滚动视图（scroll）——滚动视图没有固有高度，
    /// 量它会得到 0，面板就会被算矮、候选被压没。
    private var fitBlocks: [UIView] = []
    private var lastFit: (mode: Mode, width: CGFloat)?
    /// 反馈要落在当前页面的那行小字上（结果页是脚注，初始页是顶部提示行）
    private weak var flashTarget: UILabel?
    /// 系统容器比我们视图高出的那一截（露出来就是顶部那条「色块」）；每次出现只量一次
    private var containerGap: CGFloat = 0
    private var didMeasureContainerGap = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 面板底色交给系统，不要自己设：这个视图本身就是 UIInputView（.keyboard 样式），
        // 系统会给它画与键盘容器同一套底材。之前用自定义的 KB.bg 盖掉了它，于是我们面板
        // 和键盘顶部露出的那层底衬颜色对不上，看着就像多了一条"灰带"。
        // 不设背景色后两边同源同色，深色模式也跟着系统走。
        view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        buildTopBar()
        buildContentStack()
        mode = hasFullAccess ? .idle : .gate
#if DEBUG
        // 自检探针：任何落到面板上的点按都记一笔，并报告命中的视图类型。
        // 用来区分「触摸压根没进来」和「进来了但没送到候选行」。
        let probe = UITapGestureRecognizer(target: self, action: #selector(diagProbe(_:)))
        probe.cancelsTouchesInView = false
        view.addGestureRecognizer(probe)
#endif
        render()
    }

#if DEBUG
    @objc private func diagProbe(_ g: UITapGestureRecognizer) {
        let p = g.location(in: view)
        let hit = view.hitTest(p, with: nil)
        JevStore.diag(String(format: "面板点按 (%.0f,%.0f) 命中=%@", p.x, p.y,
                             String(describing: type(of: hit ?? UIView())))
            + " 状态=\(mode)")
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        statusLabel.text = hasFullAccess ? L("Jev · 已连接", "Jev · Connected")
            : L("Jev · 需要完全访问", "Jev · Full Access required")
        render()
        // 回写状态：主 App「开始」页据此显示键盘是否已启用、是否给了完全访问
        JevStore.saveKeyboardStatus(KeyboardStatus(lastSeen: Date(), hasFullAccess: hasFullAccess))
        prewarm()
        // 只有停在 AI 待机页且开着「自动分析」时才自动拾取/请求屏幕扫描；
        // 打字模式或关掉自动分析时，剪贴板只在手动点按钮时读（粘贴提示更少）。
        if mode == .idle, JevStore.loadConfig().autoClipboard {
            let picked = autoPickClipboard()
            if !picked {
                // 剪贴板没新内容：通知越狱插件截屏 OCR（微信/Soul 聊天界面）写入剪贴板，
                // 等它写完（插件内部约 1.2s）再拾取一次
                postScanRequest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    _ = self?.autoPickClipboard()
                }
            }
        }
        // 刚出现时 frame 还没定，等键盘铺开后再量容器间隙
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.coverContainerGap()
        }
    }

    /// 复制即回复：键盘出现时剪贴板自上次记录后变过，且当前停在待机页 →
    /// 自动开始分析，不用再点按钮。首次使用（从未记录过）只记数不自动跑，
    /// 避免把手机里残留的旧剪贴板内容误当成刚复制的新消息。
    /// 返回是否已开始分析（true 时不再走屏幕 OCR 兜底，防止 OCR 结果覆盖刚复制的消息）。
    private func autoPickClipboard() -> Bool {
        guard mode == .idle || mode == .gate else { return false }
        guard JevStore.loadConfig().autoClipboard else { return false }
        let count = UIPasteboard.general.changeCount
        let last = JevStore.lastClipboardCount()
        guard let last, count != last else {
            // 没有新复制（或首次）：把当前计数记下，保证「复制后才触发」的语义
            JevStore.saveClipboardCount(count)
            return false
        }
        JevStore.saveClipboardCount(count)
        guard hasFullAccess,
              let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        run(message: text)
        return true
    }

    /// 通知越狱插件（com.jevchat.screenreader）截屏 OCR 聊天内容写入剪贴板。
    /// 键盘扩展运行在宿主 App（微信/Soul）进程内，插件也注入同一进程，
    /// 用进程内 NotificationCenter 通信即可；没装插件时无人监听，完全无害。
    private func postScanRequest() {
        NotificationCenter.default.post(name: Notification.Name("com.jevchat.ask-scan"),
                                        object: nil)
    }

    /// 预热生成层连接。实测同一条起草请求，第二次能从 ~1.9 秒降到 ~0.5 秒——
    /// 连接和模型服务都要热身。键盘一出现就用一个不消耗额度的 `GET /models` 把连接建起来，
    /// 结果直接丢掉（失败也无所谓，真分析时该走的路径照走）。
    private func prewarm() {
        guard hasFullAccess else { return }
        let g = JevStore.loadConfig().generation
        guard !g.key.isEmpty, !g.base.isEmpty else { return }
        let base = g.base.hasSuffix("/") ? String(g.base.dropLast()) : g.base
        guard let url = URL(string: base + "/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(g.key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        view.layer.borderColor = KB.cardBorder.cgColor
        // 重建各状态视图以刷新动态色
        if mode == .idle || mode == .gate || mode == .typing { render() }
    }

    // MARK: 顶栏：品牌 + 状态 + 系统键盘切换 + 删除

    private func buildTopBar() {
        let dot = UIView()
        dot.backgroundColor = hasFullAccess ? KB.riskColor(0) : .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusLabel = KB.label(hasFullAccess ? L("Jev · 已连接", "Jev · Connected") : L("Jev · 需要完全访问", "Jev · Full Access required"),
                               font: .systemFont(ofSize: 12, weight: .medium), color: KB.secondaryText)

        let title = UIStackView(arrangedSubviews: [dot, statusLabel])
        title.axis = .horizontal
        title.spacing = 6
        title.alignment = .center

        // ⌨️/✨：在「AI 回复面板」和「打字键盘」之间切换（打字的日常入口）
        let typeBtn = KB.button("", icon: "keyboard")
        typeBtn.accessibilityLabel = L("切换打字键盘", "Switch to typing keyboard")
        typeBtn.addTarget(self, action: #selector(toggleTypeMode), for: .touchUpInside)
        NSLayoutConstraint.activate([
            typeBtn.widthAnchor.constraint(equalToConstant: 44),
            typeBtn.heightAnchor.constraint(equalToConstant: 36),
        ])
        typeModeBtn = typeBtn

        let globe = KB.button("", icon: "globe")
        globe.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        NSLayoutConstraint.activate([
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 36),
        ])

        let backspace = KB.button("", icon: "delete.left")
        backspace.addTarget(self, action: #selector(deleteBackwardTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            backspace.widthAnchor.constraint(equalToConstant: 44),
            backspace.heightAnchor.constraint(equalToConstant: 36),
        ])

        topBar.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        let hstack = UIStackView(arrangedSubviews: [UIView(), typeBtn, globe, backspace])
        hstack.axis = .horizontal
        hstack.spacing = 8
        topBar.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 36),
            title.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            hstack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            hstack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
        ])
    }

    private func buildContentStack() {
        contentStack.axis = .vertical
        contentStack.spacing = 6
        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heightConstraint,
        ])
    }

    /// 面板高度按内容实测定，而不是把 320 写死。
    ///
    /// 写死一个高度 + UIStackView 默认的 .fill：多余的垂直空间会被平分下去，卡片被拉伸出
    /// 一大片空白（卡片底色和键盘底色几乎一样白，看着就是"空白太多"），该占空间的候选滚动区
    /// 反被挤成一条（"就只有一个东西"）。这里把各块在真实宽度下的高度加起来定高，190 起、470 封顶，
    /// 超出的部分才交给滚动。
    private func refit() {
        let avail = view.bounds.width - 24
        guard avail > 60, !fitBlocks.isEmpty else { return }
        var height: CGFloat = 6 + 36 + 6 + 8      // 上边距 + 顶栏 + 间距 + 下边距
        for (i, block) in fitBlocks.enumerated() {
            height += block.systemLayoutSizeFitting(
                CGSize(width: avail, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            if i < fitBlocks.count - 1 { height += 6 }
        }
        heightConstraint.constant = min(max(height, Self.minPanelHeight), maxPanelHeight) + containerGap
    }

    /// 面板高度下限。**不能低于系统键盘的最小高度**：实测请求 190pt 时，系统按自己的最小值
    /// （约 204pt）给键盘区域，我们的视图只有 190 又被贴底，上方那 14pt 就露出系统的圆角底衬
    /// ——看起来就是键盘顶上多了一条灰带（结果态高度够大，所以不带这个问题）。
    private static let minPanelHeight: CGFloat = 210

    /// 键盘面板上方那条"灰带"的成因排查（结论：不是缝隙，量出来容器与视图**等高**）。
    /// 这段保留作兜底：万一某个 App/机型上容器真的比视图高，就把视图补到容器高度、用背景盖住。
    /// 关键点：**必须等 frame 铺开后再量**——刚出现时 frame 是整屏尺寸（390x844），
    /// 拿它算会得到 0 并误标"已量过"，于是永远不再量（上一版就是这么失效的）。
    private func coverContainerGap() {
        guard !didMeasureContainerGap, let container = view.superview else { return }
        let containerHeight = container.bounds.height
        let viewHeight = view.bounds.height
        guard containerHeight > 0, viewHeight > 0,
              containerHeight < 600, viewHeight < 600 else { return }  // 还没铺开，下次再看
        didMeasureContainerGap = true
        let gap = containerHeight - viewHeight
        guard gap > 1, gap <= 60 else { return }
        containerGap = gap
        lastFit = nil
        refit()
#if DEBUG
        JevStore.diag(String(format: "补容器间隙 %.0fpt（容器 %.0f / 视图 %.0f）",
                             gap, containerHeight, viewHeight))
#endif
    }

    /// 面板上限跟着屏幕走：小屏（SE 667pt）上写死 470 会盖掉大半个屏幕，
    /// 大屏（Pro Max 932pt）上又不该浪费空间。取可用高度的 45%，夹在 [220, 470] 之间。
    /// 用窗口场景的坐标系而不是 UIScreen.bounds——后者恒为竖屏尺寸，横屏时会算多。
    private var maxPanelHeight: CGFloat {
        let scene = view.window?.windowScene
        let available = scene?.coordinateSpace.bounds.height ?? UIScreen.main.bounds.height
        return min(470, max(220, available * 0.45))
    }

#if DEBUG
    private func frameText(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
#endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        coverContainerGap()               // 铺开后如果容器比视图高，就补高盖住（通常量到的是等高）
        let width = view.bounds.width
        guard width > 0, lastFit == nil || lastFit!.mode != mode || lastFit!.width != width else { return }
        lastFit = (mode, width)
        refit()
#if DEBUG
        // 顶部那条「色块」的取证（1）：我们视图与直接父视图的几何关系
        let supFrame = view.superview.map { frameText($0.frame) } ?? "nil"
        let supBounds = view.superview.map { frameText($0.bounds) } ?? "nil"
        JevStore.diag("几何 view=\(frameText(view.frame)) 父frame=\(supFrame) 父bounds=\(supBounds) 兄弟数=\(view.superview?.subviews.count ?? -1)")

        // 取证（2）：等键盘真正铺开后再往上数三层容器——iOS 26 的键盘容器自己画圆角底衬，
        // 得知道那一层是什么类、多大、什么颜色，才能判断那条带子是它的还是我们的
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var parts: [String] = []
            var node: UIView? = self.view
            for _ in 0..<4 {
                guard let cur = node else { break }
                let bg = cur.backgroundColor.map { "\($0)" } ?? "nil"
                parts.append("\(type(of: cur)) \(frameText(cur.frame)) bg=\(bg)")
                node = cur.superview
            }
            JevStore.diag("容器链 " + parts.joined(separator: " | "))
        }
#endif
    }

    @objc private func switchKeyboard() { advanceToNextInputMode() }

    @objc private func deleteBackwardTapped() {
        textDocumentProxy.deleteBackward()
    }

#if DEBUG
    /// 自检入口：把面板直接切到某个状态渲染出来。
    /// 键盘本体不走这条路径；这是给独立预览壳工程用的——键盘扩展没法用脚本唤起，
    /// 靠它才能在模拟器上按不同机型尺寸看布局（见 /tmp 的 PanelPreview 壳）。
    func previewPanel(_ kind: String, analysis: Analysis? = nil, errorText: String = "") {
        self.analysis = analysis
        self.errorText = errorText
        switch kind {
        case "gate": mode = .gate
        case "tones": mode = .tones
        case "loading": mode = .loading
        case "result": mode = .result
        case "error": mode = .error
        default: mode = .idle
        }
        render()
    }
#endif

    // MARK: 状态渲染

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fitBlocks = []
        lastFit = nil
        // 顶栏 ⌨️/✨ 图标跟着当前模式走
        typeModeBtn?.configuration?.image = UIImage(systemName: mode == .typing ? "sparkles" : "keyboard")
        switch mode {
        case .gate: contentStack.addArrangedSubview(gateView())
        case .idle: contentStack.addArrangedSubview(idleView())
        case .tones: contentStack.addArrangedSubview(tonesView())
        case .loading: contentStack.addArrangedSubview(loadingView())
        case .result: contentStack.addArrangedSubview(resultView())
        case .error: contentStack.addArrangedSubview(errorView())
        case .typing: contentStack.addArrangedSubview(typingView())
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        render()
    }

    /// 顶栏 ⌨️：AI 面板 ↔ 打字键盘。进入打字时清空拼音缓冲，回到面板时恢复待机页。
    @objc private func toggleTypeMode() {
        typeState = TypeState()
        setMode(mode == .typing ? .idle : .typing)
    }

    // MARK: 门禁视图（没有完全访问时）

    private func gateView() -> UIView {
        let card = KB.cardView()
        let title = KB.label(L("需要「允许完全访问」", "Full Access required"), font: .systemFont(ofSize: 16, weight: .bold),
                             color: .systemRed)
        let steps = KB.label(
            L("Jev 键盘要联网调用模型、读取剪贴板，这两项都要求完全访问：\n\n① 打开系统「设置」→「通用」→「键盘」→「键盘」\n② 点「添加新键盘」→ 选「Jev 键盘」\n③ 点「Jev 键盘」→ 打开「允许完全访问」\n\n完全访问意味着键盘能传输按键与剪贴板内容——本项目开源、只用你自己填的 API Key，不用时可以在同页一键移除。", "Jev needs Full Access to call the model and read the clipboard:\n\n① Open Settings → General → Keyboard → Keyboards\n② Tap Add New Keyboard → Jev Keyboard\n③ Select Jev Keyboard → turn on Full Access\n\nFull Access lets the keyboard transmit keystrokes and clipboard content. The project is open source and uses only the API key you provide; you can remove it anytime."),
            font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let vstack = UIStackView(arrangedSubviews: [title, steps])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 待机视图

    private func idleView() -> UIView {
        let cfg = JevStore.loadConfig()

        let guide = KB.label(
            L("在聊天里长按消息 → 复制，键盘会自动分析", "Long-press a message → Copy; the keyboard analyzes automatically"),
            font: .systemFont(ofSize: 12), color: KB.secondaryText)

        let clipBtn = KB.button(L("分析剪贴板", "Analyze Clipboard"), icon: "doc.on.clipboard", primary: true,
                                font: .systemFont(ofSize: 14, weight: .semibold))
        clipBtn.addTarget(self, action: #selector(analyzeClipboard), for: .touchUpInside)

        let inputBtn = KB.button(L("AI 分析输入框文字", "Analyze Input"), icon: "text.cursor",
                                 font: .systemFont(ofSize: 14, weight: .semibold))
        inputBtn.addTarget(self, action: #selector(analyzeInputField), for: .touchUpInside)

        // 两个分析入口并排：左边读剪贴板（主路径，主色），右边读当前输入框
        let btnRow = UIStackView(arrangedSubviews: [clipBtn, inputBtn])
        btnRow.axis = .horizontal
        btnRow.spacing = 8
        btnRow.distribution = .fillEqually
        btnRow.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // 话术：点进去直接在键盘上选（写回共享配置，App 的「话术」页看到的是同一份）
        let tonesBtn = KB.button(
            cfg.activeSlots.isEmpty
                ? L("话术：都没选（点这里选）", "Tones: none selected")
                : L("话术：", "Tones: ") + cfg.activeSlots.map { localizedToneName($0, language: language) }.joined(separator: " · "),
            icon: "theatermasks")
        tonesBtn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        tonesBtn.addTarget(self, action: #selector(openTonePicker), for: .touchUpInside)

        var blocks: [UIView] = [guide]
        // 剪贴板有内容但这次弹出没自动触发（键盘一直开着时复制的）：给个显式入口
        if hasFullAccess,
           let t = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            let preview = t.count > 22 ? String(t.prefix(22)) + "…" : t
            let chip = KB.button(L("剪贴板：\(preview) 〔分析〕", "Clipboard: \(preview) 〔Analyze〕"),
                                 icon: "doc.on.clipboard", font: .systemFont(ofSize: 12))
            chip.heightAnchor.constraint(equalToConstant: 34).isActive = true
            chip.addTarget(self, action: #selector(analyzeClipboard), for: .touchUpInside)
            blocks.append(chip)
        }
        blocks.append(btnRow)

        // 自动分析开关：关掉后键盘出现时不读剪贴板、不请求屏幕扫描，
        // 只在手动点「分析剪贴板」时读取——系统粘贴提示会明显变少（「只同意一次」的实现方式）
        let autoRow = UIStackView()
        autoRow.axis = .horizontal
        autoRow.spacing = 8
        autoRow.alignment = .center
        let autoLabel = KB.label(L("自动分析剪贴板", "Auto-analyze clipboard"), font: .systemFont(ofSize: 13))
        autoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let autoSwitch = UISwitch()
        autoSwitch.isOn = cfg.autoClipboard
        autoSwitch.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        autoSwitch.addTarget(self, action: #selector(autoClipboardToggled(_:)), for: .valueChanged)
        autoRow.addArrangedSubview(autoLabel)
        autoRow.addArrangedSubview(autoSwitch)
        autoRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let autoHint = KB.label(
            L("关闭后只在手动点击时读取，系统粘贴提示更少", "Off: read only on manual tap — fewer system paste prompts"),
            font: .systemFont(ofSize: 11), color: KB.secondaryText, lines: 0)
        blocks.append(autoRow)
        blocks.append(autoHint)
        blocks.append(tonesBtn)

        let vstack = UIStackView(arrangedSubviews: blocks)
        vstack.axis = .vertical
        vstack.spacing = 8

        if JevDraft(cfg: cfg).isConfigured {
            // 配置完整时不占行
        } else {
            let warn = KB.label(L("⚠️ 还没配置生成层：打开 Jev Jarvis App →「模型」页填 API Key", "⚠️ Generation is not configured: open Jev Jarvis → Models and add an API key"),
                                font: .systemFont(ofSize: 12), color: .systemOrange, lines: 0)
            vstack.addArrangedSubview(warn)
        }
        fitBlocks = [vstack]
        return vstack
    }

    @objc private func autoClipboardToggled(_ sw: UISwitch) {
        var cfg = JevStore.loadConfig()
        cfg.autoClipboard = sw.isOn
        JevStore.saveConfig(cfg)
    }

    // MARK: 话术选择视图（直接在键盘上配）

    @objc private func openTonePicker() { setMode(.tones) }

    /// 话术选择：内置 + 自定义全列出来，点一下选中/取消，最多 3 个槽。
    /// 每次从共享配置重新读（App 那边改过也能立刻看到），选中即落盘，下一次分析就生效。
    private func tonesView() -> UIView {
        let cfg = JevStore.loadConfig()
        let names = orderedToneNames(custom: cfg.customTones)
        let active = cfg.activeSlots

        let title = KB.label(L("选话术（最多 \(MAX_SLOTS) 个 · 每个每次出 2 条）", "Choose tones (up to \(MAX_SLOTS) · 2 suggestions each)"),
                             font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0)
        var blocks: [UIView] = [title]

        // 每行 3 个等宽格子：话术名长短不一，等宽比按内容排更好点、也更整齐
        var row: [UIButton] = []
        for name in names {
            let btn = KB.button(localizedToneName(name, language: language), primary: active.contains(name),
                                font: .systemFont(ofSize: 13, weight: .medium))
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
            btn.accessibilityIdentifier = name
            btn.addTarget(self, action: #selector(toneChipTapped(_:)), for: .touchUpInside)
            row.append(btn)
            if row.count == 3 {
                blocks.append(gridRow(row))
                row = []
            }
        }
        if !row.isEmpty {
            // 补齐到 3 个：不加空位的话，最后一行的单个话术会被 .fillEqually 拉成整行宽
            var cells: [UIView] = row
            while cells.count < 3 { cells.append(UIView()) }
            blocks.append(gridRow(cells))
        }

        let done = KB.button(L("好了", "Done"), icon: "checkmark", primary: true)
        done.heightAnchor.constraint(equalToConstant: 36).isActive = true
        done.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        blocks.append(done)

        let outer = UIStackView(arrangedSubviews: blocks)
        outer.axis = .vertical
        outer.spacing = 6
        fitBlocks = blocks
        return outer
    }

    private func gridRow(_ cells: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: cells)
        s.axis = .horizontal
        s.spacing = 6
        s.distribution = .fillEqually
        return s
    }

    @objc private func toneChipTapped(_ sender: UIButton) {
        guard let name = sender.accessibilityIdentifier else { return }
        var cfg = JevStore.loadConfig()
        var slots = cfg.slots
        while slots.count < MAX_SLOTS { slots.append(NONE_LABEL) }
        if let i = slots.firstIndex(of: name) {
            slots[i] = NONE_LABEL                      // 再点一下 = 取消
        } else if let free = slots.firstIndex(where: { $0.isEmpty || $0 == NONE_LABEL }) {
            slots[free] = name                         // 填进第一个空槽
        } else {
            slots[MAX_SLOTS - 1] = name                // 槽满了就顶掉最后一个
        }
        cfg.slots = Array(slots.prefix(MAX_SLOTS))
        JevStore.saveConfig(cfg)                       // 立刻落盘：下一次分析就用新槽位
        render()                                       // 重画刷新高亮
    }

    // MARK: 加载视图

    private func loadingView() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stageLabel = KB.label(L("分析中…", "Analyzing…"), font: .systemFont(ofSize: 14), color: KB.secondaryText)
        let hstack = UIStackView(arrangedSubviews: [spinner, stageLabel])
        hstack.axis = .horizontal
        hstack.spacing = 10
        hstack.alignment = .center
        let card = KB.cardView()
        card.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            hstack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            card.heightAnchor.constraint(equalToConstant: 96),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 结果视图

    private func resultView() -> UIView {
        guard let a = analysis else { return UIView() }
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 5

        // 判断头
        let header = KB.cardView()
        var headerItems: [UIView] = []
        if let jr = a.judge {
            // 风险等级文案跟徽章同一行——它单独占一行太浪费高度（键盘面板寸土寸金）
            let riskText = KB.label(localizedRiskLabel(jr.risk, language: language), font: .systemFont(ofSize: 12),
                                    color: KB.riskColor(jr.risk), lines: 1)
            riskText.setContentHuggingPriority(.required, for: .horizontal)
            let chipRow = UIStackView(arrangedSubviews: [
                KB.badge(localizedIntent(jr.intent, language: language), color: KB.brand),
                KB.badge(L(String(format: "风险 %.0f/9", jr.risk), String(format: "Risk %.0f/9", jr.risk)), color: KB.riskColor(jr.risk)),
                riskText,
                UIView(),   // 占位：吃掉余量，徽章和文案各自按内容 hug
            ])
            chipRow.axis = .horizontal
            chipRow.spacing = 8
            headerItems.append(chipRow)
            if !jr.actions.isEmpty {
                headerItems.append(KB.label(L("建议：", "Next: ") + localizedActions(jr.actions, language: language).joined(separator: " · "),
                                            font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0))
            }
        } else {
            headerItems.append(KB.label(L("未配置判断层，直接生成（可在 App 里开启）", "Judge not configured; drafting directly (enable it in the app)"),
                                        font: .systemFont(ofSize: 12), color: KB.secondaryText))
        }
        let quoted = KB.label("「" + (a.message.count > 40 ? String(a.message.prefix(40)) + "…" : a.message) + "」",
                              font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 1)
        headerItems.append(quoted)
        let hstack = UIStackView(arrangedSubviews: headerItems)
        hstack.axis = .vertical
        hstack.spacing = 4
        hstack.isLayoutMarginsRelativeArrangement = true
        hstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        header.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: header.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        outer.addArrangedSubview(header)

        // 时间脚注（先建好：插入/发送的反馈要临时改它）
        let footer = KB.label(a.rankingPending
                                ? L("候选已出 · 排序中…（现在就能点）", "Suggestions ready · ranking… (you can tap now)")
                                : L(String(format: "%.1f 秒 · 点候选插入，点「发送」发出", a.elapsed), String(format: "%.1f s · tap a suggestion to insert, then Send", a.elapsed)),
                              font: .systemFont(ofSize: 10), color: KB.secondaryText)
        flashTarget = footer

        // 候选列表（可滚动）。真没有候选时也要说一句话，别留给用户一片空白。
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        if a.candidates.isEmpty {
            list.addArrangedSubview(KB.label(L("这次没出候选，点「换一批」再试一次", "No suggestions this time. Tap Regenerate to try again."),
                                             font: .systemFont(ofSize: 13),
                                             color: KB.secondaryText, lines: 0))
        }
        for c in a.candidates {
            let row = CandidateRow(candidate: c)
            row.onInsert = { [weak self] candidate in
                guard let self else { return }
#if DEBUG
                JevStore.diag("准备插入：话术=\(candidate.tone) 字数=\(candidate.text.count)")
#endif
                self.textDocumentProxy.insertText(candidate.text)
#if DEBUG
                let ctx = self.textDocumentProxy.documentContextBeforeInput ?? "<拿不到>"
                JevStore.diag("插入后输入框尾部=「\(ctx.suffix(24))」")
#endif
                self.flashFooter(self.L("已插入 · 点「发送」发出", "Inserted · tap Send to submit"), color: KB.riskColor(0))
            }
            list.addArrangedSubview(row)
        }
        for n in a.notices.prefix(2) {
            list.addArrangedSubview(KB.label("· " + n, font: .systemFont(ofSize: 11),
                                             color: .systemOrange, lines: 0))
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        // 别让滚动视图拖延把触摸交给候选行——延迟投递正是"点了没反应"的常见来源
        scroll.delaysContentTouches = false
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        outer.addArrangedSubview(scroll)

        // 底部操作：发送挪到右下角，左边留给换一批/返回
        let send = KB.button(L("发送", "Send"), icon: "paperplane.fill", primary: true)
        send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        send.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let regen = KB.button(L("换一批", "Regenerate"), icon: "arrow.clockwise")
        regen.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button(L("返回", "Back"), icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [regen, close, UIView(), send])
        actions.axis = .horizontal
        actions.spacing = 8
        outer.addArrangedSubview(actions)
        outer.addArrangedSubview(footer)

        // 只让候选区伸缩：卡片/按钮都按内容 hug，否则会被多余的垂直空间拉出空白。
        header.setContentHuggingPriority(.required, for: .vertical)
        actions.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        fitBlocks = [header, list, actions, footer]
        return outer
    }

    /// 即时反馈：目标那行小字短暂变色改字。用户要一眼能确认「点到了 / 插进去了 / 发出去了」。
    private func flashFooter(_ text: String, color: UIColor) {
        guard let target = flashTarget else { return }
        let base = target.text
        target.textColor = color
        target.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak target] in
            target?.textColor = KB.secondaryText
            target?.text = base
        }
    }

    /// 发送。键盘扩展**点不了宿主 App 的发送按钮**（iOS 没这个 API），唯一能用的杠杆是插一个换行：
    /// 对「把回车当发送」的聊天 App 有效（输入框是文本视图、在 shouldChangeTextInRange 里拦换行的那些），
    /// 对单行输入框无效。所以发完回读输入框，按实际结果如实反馈，不假装成功。
    @objc private func sendMessage() {
        guard hasFullAccess else { setMode(.gate); return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        textDocumentProxy.insertText("\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let after = self.textDocumentProxy.documentContextBeforeInput ?? ""
            if before.isEmpty && after.isEmpty {
                self.flashFooter(self.L("输入框是空的：先点一条候选", "The input is empty: tap a suggestion first"), color: .systemOrange)
            } else if after.isEmpty {
                self.flashFooter(self.L("已发送 ✓", "Sent ✓"), color: KB.riskColor(0))
            } else {
                self.flashFooter(self.L("这个 App 不吃键盘换行，请点它的发送按钮", "This app does not send on Return; tap its Send button"), color: .systemOrange)
            }
        }
    }

    // MARK: 错误视图

    private func errorView() -> UIView {
        let card = KB.cardView()
        let title = KB.label(L("出错了", "Something went wrong"), font: .systemFont(ofSize: 15, weight: .bold), color: .systemRed)
        let body = KB.label(errorText, font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let retry = KB.button(L("重试", "Retry"), icon: "arrow.clockwise")
        retry.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button(L("返回", "Back"), icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let btns = UIStackView(arrangedSubviews: [retry, close])
        btns.axis = .horizontal
        btns.spacing = 8
        let vstack = UIStackView(arrangedSubviews: [title, body, btns])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 动作

    @objc private func analyzeClipboard() {
        lastSource = .clipboard
        guard hasFullAccess else { setMode(.gate); return }
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            errorText = L("剪贴板是空的。先在聊天里长按要回的消息 →「复制」，再回来点分析。", "The clipboard is empty. Long-press a message in your chat, copy it, then tap Analyze.")
            setMode(.error)
            return
        }
        run(message: text)
    }

    @objc private func analyzeInputField() {
        lastSource = .inputField
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let text = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = L("输入框里没有文字。这个按钮分析的是当前输入框里已输入的内容（比如你打了一半拿不准的话）。", "The input is empty. This button analyzes text already typed in the field.")
            setMode(.error)
            return
        }
        run(message: text)
    }

    @objc private func regenerate() { run(message: lastMessage) }
    @objc private func backToIdle() { setMode(.idle) }

    private func run(message: String) {
        lastMessage = message
        setMode(.loading)
        stageLabel.text = L("判断中…", "Judging…")
        let pipeline = JevPipeline(cfg: JevStore.loadConfig())

        Task { @MainActor [weak self] in
            let analysis = await pipeline.analyze(
                message: message, context: nil,
                onStage: { [weak self] stage in
                    Task { @MainActor in
                        switch stage {
                        case .judging: self?.stageLabel.text = self?.L("判断中…", "Judging…")
                        case .drafting(let done, let total):
                            self?.stageLabel.text = self?.L("生成中 \(done)/\(total)…", "Drafting \(done)/\(total)…")
                        case .ranking: self?.stageLabel.text = self?.L("排序中…", "Ranking…")
                        case .done: self?.stageLabel.text = self?.L("完成", "Done")
                        }
                    }
                },
                onPartial: { [weak self] partial in
                    // 第一条话术的候选一到就先出面板，不等其余话术、更不等排序。
                    // 用消息文本挡一下，别让上一轮的迟到结果盖掉新一轮。
                    Task { @MainActor in
                        guard let self, self.lastMessage == partial.message else { return }
                        self.analysis = partial
                        self.setMode(.result)
                    }
                })
            guard let self else { return }
            self.analysis = analysis
            if let fatal = analysis.fatalError {
                self.errorText = fatal
                self.setMode(.error)
            } else {
                self.setMode(.result)
            }
        }
    }

    // MARK: 打字键盘（顶栏 ⌨️ 进入）

    /// 打字键盘整体视图。状态都存在 typeState 里，切层/切中英时整个重建不丢内容。
    /// 固定行高（状态行 34 + 4 行键 × 42 + 间距），比 AI 面板矮，配合 refit() 定高。
    private func typingView() -> UIView {
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 5

        // 状态行：左拼音缓冲/模式，右候选滚动条
        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .center

        let langBtn = KB.button(typeState.chinese ? "中" : "EN", font: .systemFont(ofSize: 12, weight: .semibold))
        langBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        langBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        langBtn.addTarget(self, action: #selector(typeLangTapped), for: .touchUpInside)
        typeLangBtn = langBtn

        let pyLabel = KB.label(L("中 · 直接打拼音", "ZH · type pinyin"), font: .systemFont(ofSize: 12), color: KB.secondaryText)
        pyLabel.setContentHuggingPriority(.required, for: .horizontal)
        pyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        typePinyinLabel = pyLabel

        let candScroll = UIScrollView()
        candScroll.showsHorizontalScrollIndicator = false
        candScroll.delaysContentTouches = false
        let candStack = UIStackView()
        candStack.axis = .horizontal
        candStack.spacing = 6
        candStack.alignment = .center
        candScroll.addSubview(candStack)
        candStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candStack.topAnchor.constraint(equalTo: candScroll.contentLayoutGuide.topAnchor),
            candStack.bottomAnchor.constraint(equalTo: candScroll.contentLayoutGuide.bottomAnchor),
            candStack.leadingAnchor.constraint(equalTo: candScroll.contentLayoutGuide.leadingAnchor),
            candStack.trailingAnchor.constraint(equalTo: candScroll.contentLayoutGuide.trailingAnchor),
            candStack.heightAnchor.constraint(equalTo: candScroll.heightAnchor),
        ])
        typeCandStack = candStack

        statusRow.addArrangedSubview(langBtn)
        statusRow.addArrangedSubview(pyLabel)
        statusRow.addArrangedSubview(candScroll)
        statusRow.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let keyRows = UIStackView(arrangedSubviews: typeState.layer == .symbols ? symbolsRows() : letterRows())
        keyRows.axis = .vertical
        keyRows.spacing = 5

        outer.addArrangedSubview(statusRow)
        outer.addArrangedSubview(keyRows)
        refreshTypeCandidates()
        updateTypeKeyAppearance()
        fitBlocks = [outer]
        return outer
    }

    private func typeRow(_ chars: [String], leadingPad: CGFloat = 0, trailingPad: CGFloat = 0,
                         action: Selector = #selector(typeKeyTapped(_:))) -> UIStackView {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 4
        s.distribution = .fillEqually
        if leadingPad > 0 {
            let sp = UIView()
            sp.widthAnchor.constraint(equalToConstant: leadingPad).isActive = true
            s.addArrangedSubview(sp)
        }
        for ch in chars {
            let b = KB.button(ch, font: .systemFont(ofSize: 16, weight: .medium))
            b.heightAnchor.constraint(equalToConstant: 42).isActive = true
            b.accessibilityIdentifier = ch            // 字符走 identifier，不依赖 configuration 渲染的 title
            b.addTarget(self, action: action, for: .touchUpInside)
            s.addArrangedSubview(b)
        }
        if trailingPad > 0 {
            let sp = UIView()
            sp.widthAnchor.constraint(equalToConstant: trailingPad).isActive = true
            s.addArrangedSubview(sp)
        }
        return s
    }

    /// 字母层：QWERTY + shift + 删除。
    private func letterRows() -> [UIView] {
        let pad: CGFloat = 16
        var rows: [UIView] = [
            typeRow(["Q","W","E","R","T","Y","U","I","O","P"]),
            typeRow(["A","S","D","F","G","H","J","K","L"], leadingPad: pad, trailingPad: pad),
        ]

        // 第三行：shift + Z..M + 删除
        let r3 = UIStackView()
        r3.axis = .horizontal
        r3.spacing = 4
        r3.distribution = .fillEqually
        let shift = KB.button("", icon: typeState.shift ? "shift.fill" : "shift")
        shift.heightAnchor.constraint(equalToConstant: 42).isActive = true
        shift.addTarget(self, action: #selector(typeShiftTapped), for: .touchUpInside)
        typeShiftBtn = shift
        r3.addArrangedSubview(shift)
        for ch in ["Z","X","C","V","B","N","M"] {
            let b = KB.button(ch, font: .systemFont(ofSize: 16, weight: .medium))
            b.heightAnchor.constraint(equalToConstant: 42).isActive = true
            b.accessibilityIdentifier = ch
            b.addTarget(self, action: #selector(typeKeyTapped(_:)), for: .touchUpInside)
            r3.addArrangedSubview(b)
        }
        let del = KB.button("", icon: "delete.left")
        del.heightAnchor.constraint(equalToConstant: 42).isActive = true
        del.addTarget(self, action: #selector(typeDeleteTapped), for: .touchUpInside)
        r3.addArrangedSubview(del)
        rows.append(r3)
        rows.append(bottomRow())
        return rows
    }

    /// 符号层：数字 + 常用符号 + 中文标点。
    private func symbolsRows() -> [UIView] {
        var rows: [UIView] = [
            typeRow(["1","2","3","4","5","6","7","8","9","0"]),
            typeRow(["-","/",":",";","(",")","$","&","@","\""]),
        ]
        let r3 = UIStackView()
        r3.axis = .horizontal
        r3.spacing = 4
        r3.distribution = .fillEqually
        let abc = KB.button("ABC", font: .systemFont(ofSize: 14, weight: .semibold))
        abc.heightAnchor.constraint(equalToConstant: 42).isActive = true
        abc.addTarget(self, action: #selector(typeLayerTapped), for: .touchUpInside)
        typeLayerBtn = abc
        r3.addArrangedSubview(abc)
        for ch in ["，","。","？","！","%","+","="] {
            let b = KB.button(ch, font: .systemFont(ofSize: 16, weight: .medium))
            b.heightAnchor.constraint(equalToConstant: 42).isActive = true
            b.accessibilityIdentifier = ch
            b.addTarget(self, action: #selector(typeKeyTapped(_:)), for: .touchUpInside)
            r3.addArrangedSubview(b)
        }
        let del = KB.button("", icon: "delete.left")
        del.heightAnchor.constraint(equalToConstant: 42).isActive = true
        del.addTarget(self, action: #selector(typeDeleteTapped), for: .touchUpInside)
        r3.addArrangedSubview(del)
        rows.append(r3)
        rows.append(bottomRow())
        return rows
    }

    /// 底行：123/ABC · 逗号 · 空格 · 句号 · 回车。手工约束，空格按比例拉宽。
    private func bottomRow() -> UIView {
        let row = UIView()

        let layerBtn = KB.button(typeState.layer == .letters ? "123" : "ABC", font: .systemFont(ofSize: 14, weight: .semibold))
        typeLayerBtn = layerBtn
        layerBtn.addTarget(self, action: #selector(typeLayerTapped), for: .touchUpInside)

        let comma = KB.button(typeState.chinese ? "，" : ",", font: .systemFont(ofSize: 15, weight: .medium))
        comma.accessibilityIdentifier = typeState.chinese ? "，" : ","
        comma.addTarget(self, action: #selector(typeKeyTapped(_:)), for: .touchUpInside)

        let space = KB.button(L("空格", "space"), font: .systemFont(ofSize: 13, weight: .medium))
        space.addTarget(self, action: #selector(typeSpaceTapped), for: .touchUpInside)

        let dot = KB.button(typeState.chinese ? "。" : ".", font: .systemFont(ofSize: 15, weight: .medium))
        dot.accessibilityIdentifier = typeState.chinese ? "。" : "."
        dot.addTarget(self, action: #selector(typeKeyTapped(_:)), for: .touchUpInside)

        let ret = KB.button("", icon: "return")
        ret.addTarget(self, action: #selector(typeReturnTapped), for: .touchUpInside)

        [layerBtn, comma, space, dot, ret].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.heightAnchor.constraint(equalToConstant: 42).isActive = true
            row.addSubview($0)
        }
        NSLayoutConstraint.activate([
            layerBtn.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            layerBtn.widthAnchor.constraint(equalToConstant: 52),
            comma.leadingAnchor.constraint(equalTo: layerBtn.trailingAnchor, constant: 4),
            comma.widthAnchor.constraint(equalToConstant: 46),
            space.leadingAnchor.constraint(equalTo: comma.trailingAnchor, constant: 4),
            space.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -4),
            space.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            dot.widthAnchor.constraint(equalToConstant: 46),
            dot.trailingAnchor.constraint(equalTo: ret.leadingAnchor, constant: -4),
            ret.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            ret.widthAnchor.constraint(equalToConstant: 58),
        ] + [layerBtn, comma, space, dot, ret].map { $0.centerYAnchor.constraint(equalTo: row.centerYAnchor) })
        return row
    }

    /// 拼音/英文候选：词优先（最多 5），再补字（合计最多 10）。
    private func typingCandidates() -> [String] {
        let p = typeState.pinyin.lowercased()
        guard !p.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for k in PinyinData.sortedWordKeys where k.hasPrefix(p) {
            for w in PinyinData.wordMap[k] ?? [] where seen.insert(w).inserted {
                out.append(w)
                if out.count >= 5 { return out }
            }
        }
        for k in PinyinData.sortedCharKeys where k.hasPrefix(p) {
            for c in PinyinData.charMap[k] ?? [] where seen.insert(c).inserted {
                out.append(c)
                if out.count >= 10 { return out }
            }
        }
        return out
    }

    /// 刷新拼音缓冲标签 + 候选条（原地更新，不重建整个打字视图）。
    private func refreshTypeCandidates() {
        guard let label = typePinyinLabel, let stack = typeCandStack else { return }
        let p = typeState.pinyin
        label.text = typeState.chinese
            ? (p.isEmpty ? L("中 · 直接打拼音", "ZH · type pinyin") : L("拼 ", "PY ") + p)
            : "EN"
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cands = typingCandidates()
        for c in cands {
            let b = KB.button(c, font: .systemFont(ofSize: 13, weight: .medium))
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            b.accessibilityIdentifier = c
            b.addTarget(self, action: #selector(typeCandidateTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        if !p.isEmpty, !cands.isEmpty {
            let tip = KB.label(L("空格上屏①", "SPC ①"), font: .systemFont(ofSize: 11), color: KB.secondaryText)
            tip.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(tip)
        } else if !p.isEmpty {
            let hint = KB.label(L("没有匹配，删掉重打", "no match"), font: .systemFont(ofSize: 11), color: KB.secondaryText)
            hint.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(hint)
        }
    }

    private func updateTypeKeyAppearance() {
        let keyBG = UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.06)
        }
        typeShiftBtn?.configuration?.image = UIImage(systemName: typeState.shift ? "shift.fill" : "shift")
        typeShiftBtn?.configuration?.baseBackgroundColor = typeState.shift ? KB.brand : keyBG
        typeLayerBtn?.configuration?.title = typeState.layer == .letters ? "123" : "ABC"
        typeLangBtn?.configuration?.title = typeState.chinese ? "中" : "EN"
    }

    /// 打字键：字母层 + 中文模式 → 进拼音缓冲（统一转小写，按键显示大写不影响）；
    /// 其余（英文/数字/符号）直接上屏，shift 只对下一个英文字母生效。
    @objc private func typeKeyTapped(_ sender: UIButton) {
        guard let ch = sender.accessibilityIdentifier, ch.count == 1, let first = ch.first else { return }
        if typeState.chinese && typeState.layer == .letters && first.isLetter {
            typeState.pinyin.append(Character(String(first).lowercased()))
            refreshTypeCandidates()
            return
        }
        let out = first.isLetter
            ? (typeState.shift ? String(first).uppercased() : String(first).lowercased())
            : ch
        textDocumentProxy.insertText(out)
        typeState.shift = false
        updateTypeKeyAppearance()
    }

    @objc private func typeCandidateTapped(_ sender: UIButton) {
        guard let t = sender.accessibilityIdentifier else { return }
        commit(t)
    }

    private func commit(_ s: String) {
        textDocumentProxy.insertText(s)
        typeState.pinyin = ""
        refreshTypeCandidates()
    }

    private func commitFirstCandidate() {
        if let first = typingCandidates().first {
            commit(first)
        } else {
            typeState.pinyin = ""
            refreshTypeCandidates()
        }
    }

    @objc private func typeShiftTapped() {
        typeState.shift.toggle()
        updateTypeKeyAppearance()
    }

    @objc private func typeLayerTapped() {
        typeState.layer = typeState.layer == .letters ? .symbols : .letters
        setMode(.typing)
    }

    @objc private func typeLangTapped() {
        typeState.chinese.toggle()
        typeState.pinyin = ""
        setMode(.typing)
    }

    @objc private func typeDeleteTapped() {
        if typeState.chinese && !typeState.pinyin.isEmpty {
            typeState.pinyin.removeLast()
            refreshTypeCandidates()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    @objc private func typeSpaceTapped() {
        if typeState.chinese && !typeState.pinyin.isEmpty {
            commitFirstCandidate()
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    @objc private func typeReturnTapped() {
        if typeState.chinese && !typeState.pinyin.isEmpty {
            commitFirstCandidate()
        } else {
            textDocumentProxy.insertText("\n")
        }
    }
}
