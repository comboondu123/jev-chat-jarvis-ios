import Foundation

// MARK: - 判断层：TypeSafe Jev / System One 客户端
//
// Jev 是结构化决策模型：给它一个 state 加一组带类型的题目，返回校准过的概率而不是文字。
// 与 macOS 版 src/judge_jev.py 同一请求形状：
//   POST {base}/v1/systemone   Authorization: Bearer <key>
//   {"model": …, "state": …, "questions": {intent: choice, risk: score}}
// 排序只是又一道 choice 题：把候选文本当选项，哪条最合适。

struct JudgeResult: Equatable {
    var intent: String
    var confidence: Double
    var intentProbs: [String: Double]
    var risk: Double
    var riskProbs: [String: Double]
    var actions: [String]

    var riskLevelText: String { riskLabel(for: risk) }
}

struct RankedCandidate: Equatable {
    var text: String
    var prob: Double
}

/// 判断结果的内存缓存。实测判断一次要一秒多，而「换一批」是对同一条消息反复分析——
/// 判断结论不会变，没必要每次重付一次往返。只在进程内、不落盘；换了消息自然失效。
final class JevJudgeCache {
    static let shared = JevJudgeCache()

    private struct Key: Hashable {
        let message: String
        let context: String
    }

    private var store: [Key: (result: JudgeResult, at: Date)] = [:]
    private let ttl: TimeInterval = 300
    private let lock = NSLock()

    func get(message: String, context: String?) -> JudgeResult? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(message: message, context: context ?? "")
        guard let hit = store[key], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.result
    }

    func put(_ result: JudgeResult, message: String, context: String?) {
        lock.lock()
        defer { lock.unlock() }
        if store.count > 8 { store.removeAll() }
        store[Key(message: message, context: context ?? "")] = (result, Date())
    }
}

final class JevJudge {
    private let base: String
    private let key: String
    private let model: String
    private let kind: JudgeKind
    private let extraJSON: String

    init(cfg: JevConfig) {
        self.base = cfg.judgeBase.trimmingCharacters(in: .whitespaces)
        self.key = cfg.judgeKey.trimmingCharacters(in: .whitespaces)
        self.model = cfg.judgeModel.trimmingCharacters(in: .whitespaces)
        self.kind = cfg.judgeKind
        self.extraJSON = cfg.judgeExtraJSON.trimmingCharacters(in: .whitespaces)
    }

    var isConfigured: Bool { !key.isEmpty && !base.isEmpty && !model.isEmpty }

    // MARK: URL 拼接（与 macOS 版 #42 单一规则一致）
    //
    // 三种填法等价可用：只到主机（…/v1/systemone 自动补）、带版本段（…/v1 只补动作段）、
    // 完整动作路径（原样使用）。网关可以改名动作段（Vercel 是 /v1/evaluate、
    // OpenRouter 是 /api/alpha/decisions）。

    static func requestURL(_ rawBase: String) -> String {
        let b = rawBase.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let segs = b.split(separator: "/").map(String.init)
        guard let last = segs.last?.lowercased() else { return b }
        let actionSegs: Set<String> = ["systemone", "evaluate", "decisions"]
        if actionSegs.contains(last) { return b }
        if last.range(of: #"^v\d+$"#, options: .regularExpression) != nil { return b + "/systemone" }
        return b + "/v1/systemone"
    }

    // MARK: 聊天兼容模式（DeepSeek / 豆包方舟等 OpenAI 兼容端点）
    //
    // 判断层原生是 System One 题型，通用聊天端点不吃 state+questions。
    // 这里把题目翻译成提示词，要求模型只回一个 JSON，再解析成同样的 answers 形状，
    // 下游（意图/风险/排序解析）与 systemone 完全一致。

    static func chatURL(_ rawBase: String) -> String {
        let b = rawBase.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let segs = b.split(separator: "/").map(String.init)
        guard let last = segs.last?.lowercased() else { return b + "/chat/completions" }
        if last == "completions" { return b }
        return b + "/chat/completions"
    }

    /// 判断题提示词：意图 8 选 1 + 风险 0-9 打分，要求只回 JSON。
    private var judgeSystemPrompt: String {
        let intents = INTENTS.map { "\($0.key)（\($0.value)）" }.joined(separator: "；")
        let risks = RISK_LEVELS.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: "；")
        return """
        你是 Jev 的判断引擎。根据用户输入完成两道题，只输出一个 JSON 对象，不要输出任何其他文字，不要用 markdown 代码块：
        {"answers":{"intent":{"choice":"意图标签","confidence":0到1的小数,"probabilities":{"意图标签":概率,…每个意图都要}},"risk":{"score":0到9的整数,"probabilities":{"风险级别文案":概率,…每个级别都要}}}}
        题目1 意图（单选）：\(intents)
        题目2 风险（0-9 打分，score 取 0-9 的整数）：\(risks)
        """
    }

    /// 排序题提示词：候选文本当选项。
    private func rankSystemPrompt(candidates: [String]) -> String {
        let opts = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        你是 Jev 的排序引擎。从候选中选一条最合适的回复，只输出一个 JSON 对象，不要输出任何其他文字，不要用 markdown 代码块：
        {"answers":{"best":{"choice":"所选候选原文（一字不差）","confidence":0到1的小数,"probabilities":{"候选原文":概率,…每条候选都要}}}}
        候选回复：
        \(opts)
        """
    }

    /// 聊天模式请求：OpenAI 兼容 /chat/completions，temperature 0 + 强制 JSON。
    private func postChat(systemPrompt: String, user: String, budget: Double) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
            "temperature": 0,
            "max_tokens": 800,
            "stream": false,
        ]
        let extra = extraJSON.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty, let data = extra.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj { body[k] = v }
        }
        let data = try await JevHTTP.postJSON(
            body,
            url: Self.chatURL(base),
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(key)",
            ],
            budget: budget,
            stage: "判断"
        )
        guard let content = ((data["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String else {
            throw JevError.badJSON("chat 判断响应缺 choices[0].message.content")
        }
        guard let obj = parseAnswersJSON(content) else {
            throw JevError.badJSON("chat 判断响应不是可解析的 JSON")
        }
        // 提示词要求的顶层是 {"answers": {…}}，直接剥出内层 answers 给下游解析
        return obj["answers"] as? [String: Any] ?? [:]
    }

    /// 聊天模型偶尔把 JSON 包在 ```json …``` 里或前后加说明文字：
    /// 先剥围栏，再取第一个 { 到最后一个 } 的区间解析。
    private func parseAnswersJSON(_ raw: String) -> [String: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: 判断（意图 + 风险，一次调用出全分布）

    func judge(message: String, context: String?) async throws -> JudgeResult {
        let state = context != nil && !context!.isEmpty ? "\(context!)\n\n\(message)" : message
        let answers: [String: Any]
        switch kind {
        case .systemone:
            let payload: [String: Any] = [
                "model": model,
                "state": state,
                "questions": [
                    "intent": [
                        "type": "choice",
                        "instructions": "这句话的真实意图是什么？",
                        "criteria": INTENTS,
                    ] as [String: Any],
                    "risk": [
                        "type": "score",
                        "instructions": "如果直接回复这句话，风险有多大？",
                        "criteria": RISK_LEVELS,
                    ] as [String: Any],
                ],
            ]
            let data = try await post(payload, stage: "判断")
            answers = data["answers"] as? [String: Any] ?? [:]
        case .chat:
            answers = try await postChat(systemPrompt: judgeSystemPrompt, user: state, budget: 15)
        }
        let intentAns = answers["intent"] as? [String: Any] ?? [:]
        let riskAns = answers["risk"] as? [String: Any] ?? [:]

        var intent = intentAns["choice"] as? String ?? "闲聊"
        if !INTENTS.keys.contains(intent) {
            // 网关偶尔回显下标或近似标签
            intent = INTENTS.keys.first { intent.contains($0) } ?? "闲聊"
        }
        let confidence = doubleValue(intentAns["confidence"])
        let risk = doubleValue(riskAns["score"])
        return JudgeResult(
            intent: intent,
            confidence: confidence,
            intentProbs: doubleDict(intentAns["probabilities"]),
            risk: risk,
            riskProbs: doubleDict(riskAns["probabilities"]),
            actions: ACTION_MAP[intent] ?? []
        )
    }

    // MARK: 排序（候选文本当 choice 选项）

    func rank(message: String, intent: String, candidates: [String]) async throws -> [RankedCandidate] {
        guard !candidates.isEmpty else { return [] }
        // 去重后再当选项：两个槽位选了同一个话术时，模型很可能给出两条一模一样的候选，
        // 而字典键不能重复（用 uniqueKeysWithValues 会直接 trap 崩掉键盘）。
        let criteria = Dictionary(candidates.map { ($0, NSNull()) }, uniquingKeysWith: { first, _ in first })
        let ans: [String: Any]
        switch kind {
        case .systemone:
            let payload: [String: Any] = [
                "model": model,
                "state": "收到的消息：\(message)\n判断出的意图：\(intent)",
                "questions": [
                    "best": [
                        "type": "choice",
                        "instructions": "哪一条回复最合适？",
                        "criteria": criteria,
                    ] as [String: Any],
                ],
            ]
            let data = try await post(payload, stage: "排序")
            ans = (data["answers"] as? [String: Any])?["best"] as? [String: Any] ?? [:]
        case .chat:
            let options = Array(criteria.keys)
            let answers = try await postChat(
                systemPrompt: rankSystemPrompt(candidates: options),
                user: "收到的消息：\(message)\n判断出的意图：\(intent)",
                budget: 12)
            ans = answers["best"] as? [String: Any] ?? [:]
        }
        let probs = doubleDict(ans["probabilities"])
        var ranked = candidates.map { c -> RankedCandidate in
            var p = probs[c] ?? 0
            if p == 0, let choice = ans["choice"] as? String, choice == c {
                p = doubleValue(ans["confidence"])   // 网关可能只回显选中项
            }
            return RankedCandidate(text: c, prob: p)
        }
        ranked.sort { $0.prob > $1.prob }
        return ranked
    }

    // MARK: transport

    private func post(_ payload: [String: Any], stage: String) async throws -> [String: Any] {
        try await JevHTTP.postJSON(
            payload,
            url: Self.requestURL(base),
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(key)",
            ],
            budget: stage == "判断" ? 15 : 12,
            stage: stage
        )
    }

    private func doubleValue(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private func doubleDict(_ v: Any?) -> [String: Double] {
        guard let d = v as? [String: Any] else { return [:] }
        return d.mapValues(doubleValue)
    }
}
