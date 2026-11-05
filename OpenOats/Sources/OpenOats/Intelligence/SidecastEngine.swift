import Foundation
import Observation

@Observable
@MainActor
final class SidecastEngine {
    @ObservationIgnored nonisolated(unsafe) private var _messagesByPersona: [UUID: [SidecastMessage]] = [:]
    private(set) var messagesByPersona: [UUID: [SidecastMessage]] {
        get { access(keyPath: \.messagesByPersona); return _messagesByPersona }
        set { withMutation(keyPath: \.messagesByPersona) { _messagesByPersona = newValue } }
    }

    // Full session history per persona, capped at max(50, sidecastHistoryPerPersona).
    // `messagesByPersona` is trimmed to the card display count; this backing store keeps
    // the full depth so the pop-open history view has access to the whole session.
    @ObservationIgnored nonisolated(unsafe) private var _fullHistoryByPersona: [UUID: [SidecastMessage]] = [:]
    private(set) var fullHistoryByPersona: [UUID: [SidecastMessage]] {
        get { access(keyPath: \.fullHistoryByPersona); return _fullHistoryByPersona }
        set { withMutation(keyPath: \.fullHistoryByPersona) { _fullHistoryByPersona = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    var suggestions: [Suggestion] {
        messagesByPersona.values
            .flatMap { $0 }
            .sorted { $0.timestamp > $1.timestamp }
            .map { Suggestion(text: "\($0.personaName): \($0.text)") }
    }

    private let client = OpenRouterClient()
    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings

    private var generationTask: Task<Void, Never>?
    private var activeGenerationID: UUID?
    private var lastProcessedUtteranceID: UUID?
    private var lastGenerationStartedAt: Date = .distantPast
    private var recentBubbleTexts: [String] = []
    private var lastSpokenAtByPersona: [UUID: Date] = [:]

    private static let liveGenerationTimeout: TimeInterval = 45

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
    }

    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        guard settings.sidebarMode == .sidecast else { return }
        let personas = settings.enabledSidecastPersonas
        guard !personas.isEmpty else { return }
        guard canCallLLM else { return }

        let now = Date.now
        guard now.timeIntervalSince(lastGenerationStartedAt) >= settings.sidecastIntensity.generationCooldownSeconds else {
            return
        }
        lastGenerationStartedAt = now

        generationTask?.cancel()
        let generationID = UUID()
        activeGenerationID = generationID
        isGenerating = true

        let recentExchange = transcriptStore.recentExchange
        let recentUtterances = transcriptStore.recentUtterances
        let conversationState = transcriptStore.conversationState
        let recentTexts = recentBubbleTexts
        let lastSpoken = lastSpokenAtByPersona

        generationTask = Task { [weak self] in
            guard let self else { return }

            let evidence = await self.loadEvidence(
                for: utterance.text,
                recentExchange: recentExchange,
                conversationState: conversationState
            )
            let prompt = self.buildPrompt(
                utterance: utterance,
                recentExchange: recentExchange,
                recentUtterances: recentUtterances,
                state: conversationState,
                personas: personas,
                evidence: evidence
            )

            do {
                let useWebSearch = self.shouldUseWebSearch(for: personas)
                let response = try await self.client.complete(
                    apiKey: self.llmApiKey,
                    model: self.settings.activeRealtimeModel,
                    messages: prompt,
                    maxTokens: self.settings.sidecastMaxTokens,
                    temperature: self.settings.sidecastTemperature,
                    baseURL: self.llmBaseURL,
                    webSearch: useWebSearch,
                    transport: self.settings.activeLLMTransport,
                    requestTimeout: Self.liveGenerationTimeout
                )
                let decoded = try self.decodeResponse(response)

                await MainActor.run {
                    self.apply(
                        decoded,
                        personas: personas,
                        evidence: evidence,
                        utterance: utterance,
                        recentTexts: recentTexts,
                        lastSpokenAtByPersona: lastSpoken
                    )
                    self.finishGeneration(generationID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishGeneration(generationID)
                }
            } catch {
                Log.sidecast.error("Generation failed: \(error, privacy: .public)")
                await MainActor.run {
                    self.finishGeneration(generationID)
                }
            }
        }
    }

    func messages(for personaID: UUID) -> [SidecastMessage] {
        messagesByPersona[personaID] ?? []
    }

    func message(for personaID: UUID) -> SidecastMessage? {
        messages(for: personaID).first
    }

    /// All messages kept for this persona during the session (up to max(50, sidecastHistoryPerPersona)),
    /// newest first. Used by the pop-open history view.
    func allMessages(for personaID: UUID) -> [SidecastMessage] {
        fullHistoryByPersona[personaID] ?? []
    }

    func clear() {
        generationTask?.cancel()
        generationTask = nil
        messagesByPersona.removeAll()
        fullHistoryByPersona.removeAll()
        isGenerating = false
        activeGenerationID = nil
        lastProcessedUtteranceID = nil
        lastGenerationStartedAt = .distantPast
        recentBubbleTexts.removeAll()
        lastSpokenAtByPersona.removeAll()
    }

    private func finishGeneration(_ generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        activeGenerationID = nil
        isGenerating = false
    }

    private func apply(
        _ response: SidecastResponse,
        personas: [SidecastPersona],
        evidence: [KBContextPack],
        utterance: Utterance,
        recentTexts: [String],
        lastSpokenAtByPersona: [UUID: Date]
    ) {
        let personaByID = Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0) })
        let topBreadcrumb = evidence.first?.displayBreadcrumb ?? ""
        let now = utterance.timestamp

        let ranked = response.messages
            .filter { $0.speak }
            .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }

        var accepted: [SidecastMessage] = []
        var dedupeCorpus = recentTexts

        for candidate in ranked {
            guard accepted.count < settings.sidecastIntensity.maxMessagesPerTurn else { break }
            guard let persona = personaByID[candidate.personaID] else { continue }

            if !settings.sidecastIntensity.skipPersonaCooldowns,
               let lastSpoken = lastSpokenAtByPersona[persona.id],
               now.timeIntervalSince(lastSpoken) < persona.cadence.cooldownSeconds {
                continue
            }

            let cleanedText = sanitize(candidate.text, limit: persona.verbosity.characterLimit)
            guard !cleanedText.isEmpty else { continue }

            if dedupeCorpus.contains(where: { TextSimilarity.jaccard($0, cleanedText) > 0.62 }) {
                continue
            }

            let value = max(0, min(1, candidate.value ?? 0.5))
            if value < settings.sidecastMinValueThreshold { continue }

            let evidenceRequired = persona.evidencePolicy == .required
            if evidenceRequired && !persona.webSearchEnabled && evidence.isEmpty {
                continue
            }

            let confidence = max(0, min(1, candidate.confidence ?? 0.55))
            if evidenceRequired && !persona.webSearchEnabled && confidence < 0.35 {
                continue
            }

            let message = SidecastMessage(
                personaID: persona.id,
                personaName: persona.name,
                text: cleanedText,
                timestamp: now,
                confidence: confidence,
                priority: candidate.priority ?? 0.5,
                value: value,
                sourceBreadcrumb: topBreadcrumb
            )

            accepted.append(message)
            dedupeCorpus.append(cleanedText)
        }

        guard !accepted.isEmpty else { return }

        var updated = messagesByPersona
        var updatedFull = fullHistoryByPersona
        for message in accepted {
            var history = updated[message.personaID] ?? []
            history.insert(message, at: 0)
            let limit = settings.sidecastHistoryPerPersona
            if history.count > limit { history = Array(history.prefix(limit)) }
            updated[message.personaID] = history

            var fullHistory = updatedFull[message.personaID] ?? []
            fullHistory.insert(message, at: 0)
            let fullLimit = max(50, limit)
            if fullHistory.count > fullLimit { fullHistory = Array(fullHistory.prefix(fullLimit)) }
            updatedFull[message.personaID] = fullHistory

            self.lastSpokenAtByPersona[message.personaID] = message.timestamp
            recentBubbleTexts.append(message.text)
        }
        if recentBubbleTexts.count > 12 {
            recentBubbleTexts.removeFirst(recentBubbleTexts.count - 12)
        }

        messagesByPersona = updated
        fullHistoryByPersona = updatedFull
    }

    private static let sanitizePatterns: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"\[([^\]]*)\]\([^)]+\)"#, "$1"),                             // [text](url) → text
            (#"https?://\S+"#, ""),                                         // bare URLs
            (#"\b\w+\.(com|org|net|io|ai|app|dev|co|edu|gov)\b"#, ""),     // bare domains
            (#"\([^)]*\b(source|via|per|from|according)\b[^)]*\)"#, ""),   // (source: …) parentheticals
            (#"\[\s*\]"#, ""),                                              // leftover empty []
        ]
        return patterns.compactMap { (pattern, template) in
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { ($0, template) }
        }
    }()

    private func sanitize(_ text: String, limit: Int) -> String {
        var result = text
        for (regex, template) in Self.sanitizePatterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        let collapsed = result
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a deduplicated set of queries from the available conversation context and
    /// runs a single multi-query KB search with score fusion (max-cosine, built into searchRaw).
    /// Returns up to 8 packs, deduped by relativePath keeping the highest-score entry.
    private func loadEvidence(
        for utteranceText: String,
        recentExchange: [Utterance],
        conversationState: ConversationState
    ) async -> [KBContextPack] {
        guard !settings.kbFolderURLs.isEmpty else { return [] }

        var queries: [String] = []

        // 1. Latest utterance (as before)
        let trimmedUtterance = utteranceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUtterance.isEmpty { queries.append(trimmedUtterance) }

        // 2. Recent exchange joined (last ~6 utterances, both speakers)
        let exchangeText = recentExchange.suffix(6).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !exchangeText.isEmpty && exchangeText != trimmedUtterance {
            queries.append(exchangeText)
        }

        // 3. Conversation state topic / summary
        let topic = conversationState.currentTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { queries.append(topic) }
        let summary = conversationState.shortSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty && summary != topic { queries.append(summary) }

        // 4. Capitalized multi-word phrases and ALLCAPS acronyms from recent exchange
        let phraseQueries = Self.extractProperNounQueries(from: exchangeText, cap: 6)
        queries.append(contentsOf: phraseQueries)

        // Dedupe while preserving insertion order
        var seen = Set<String>()
        let uniqueQueries = queries.filter { seen.insert($0).inserted }

        let raw = await knowledgeBase.searchContextPacks(queries: uniqueQueries, topK: 8)

        // Dedupe by relativePath: keep highest-score pack per path, then re-sort by score
        var bestByPath: [String: KBContextPack] = [:]
        for pack in raw {
            if let existing = bestByPath[pack.relativePath] {
                if pack.score > existing.score { bestByPath[pack.relativePath] = pack }
            } else {
                bestByPath[pack.relativePath] = pack
            }
        }
        return bestByPath.values.sorted { $0.score > $1.score }
    }

    /// Extracts short queries from capitalized multi-word runs and ALLCAPS tokens (acronyms).
    /// E.g. "OpenAI GPT-4 launched" → ["OpenAI GPT-4"], "NASA" → ["NASA"].
    /// Returns at most `cap` unique non-empty strings, each ≤ 60 chars.
    private static func extractProperNounQueries(from text: String, cap: Int) -> [String] {
        guard !text.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()

        // Pass 1: runs of Capitalized words (including hyphenated tokens)
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var runStart: Int? = nil
        func flushRun(endExclusive: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let runLength = endExclusive - start
            guard runLength >= 2 else { return }
            let phrase = words[start..<endExclusive]
                .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let truncated = phrase.count > 60 ? String(phrase.prefix(60)) : phrase
            guard !truncated.isEmpty, seen.insert(truncated).inserted else { return }
            results.append(truncated)
        }
        for (i, word) in words.enumerated() {
            let stripped = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            guard !stripped.isEmpty, let first = stripped.unicodeScalars.first else {
                flushRun(endExclusive: i); continue
            }
            if CharacterSet.uppercaseLetters.contains(first) {
                if runStart == nil { runStart = i }
            } else {
                flushRun(endExclusive: i)
            }
        }
        flushRun(endExclusive: words.count)

        // Pass 2: ALLCAPS tokens of 2+ letters as standalone queries (if not already captured)
        for word in words {
            guard results.count < cap else { break }
            let stripped = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            guard stripped.count >= 2 else { continue }
            let upper = stripped.uppercased()
            guard stripped == upper, stripped.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { continue }
            if seen.insert(stripped).inserted { results.append(stripped) }
        }

        return Array(results.prefix(cap))
    }

    private func buildPrompt(
        utterance: Utterance,
        recentExchange: [Utterance],
        recentUtterances: [Utterance],
        state: ConversationState,
        personas: [SidecastPersona],
        evidence: [KBContextPack]
    ) -> [OpenRouterClient.Message] {
        let personaText = personas.map { persona in
            """
            - id: \(persona.id.uuidString)
              name: \(persona.name)
              subtitle: \(persona.subtitle)
              prompt: \(persona.prompt)
              verbosity: \(persona.verbosity.displayName) (max \(persona.verbosity.characterLimit) chars)
              cadence: \(persona.cadence.displayName)
              evidence: \(persona.evidencePolicy.displayName)
            """
        }.joined(separator: "\n")

        let transcriptText = recentExchange
            .map { "\($0.speaker.displayLabel): \($0.text)" }
            .joined(separator: "\n")

        let widerContext = recentUtterances
            .map { "\($0.speaker.displayLabel): \($0.text)" }
            .joined(separator: "\n")

        let evidenceText: String
        if evidence.isEmpty {
            evidenceText = "No KB evidence retrieved for this turn."
        } else {
            evidenceText = evidence.enumerated().map { index, pack in
                """
                [\(index + 1)] \(pack.displayBreadcrumb) (score \(String(format: "%.2f", pack.score)))
                \(pack.matchedText)
                """
            }.joined(separator: "\n\n")
        }

        let stateSummary = state.shortSummary.isEmpty ? "No structured state yet." : state.shortSummary
        let openQuestions = state.openQuestions.isEmpty ? "None" : state.openQuestions.joined(separator: "; ")

        let systemTemplate = settings.sidecastSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system: String
        if systemTemplate.isEmpty {
            system = """
            You are Sidecast, a live multi-persona producer for a host-assist sidebar.
            Decide which personas should speak right now in response to the latest utterance.

            Quality bar:
            - Only speak when you have genuine insight — a non-obvious fact, a sharp reframe, a useful correction, or a punchy callback.
            - Silence is better than filler. If nothing clears the bar, return {"messages":[]}.
            - Every bubble should make the host think "glad I saw that." If it wouldn't, don't send it.

            Rules:
            - Return valid JSON only.
            - Use at most \(settings.sidecastIntensity.maxMessagesPerTurn) persona messages.
            - Never include URLs, links, citations, or source references in the text. The text is the insight itself, nothing else.
            - No markdown, no emoji, no stage directions, no quotes around the text.
            - Keep text extremely dense — every word must earn its place.
            - Fact-heavy personas must lead with specific numbers, percentages, dates, or named sources. Never say "X is higher" — say "X is 42% higher." Avoid vague qualifiers like "significantly", "increasingly", "many" — replace them with the actual number. If no precise data is available, stay silent rather than generalizing.
            - Humor and chaos personas can be sharp, but never hateful or unusably toxic.
            - Set priority (0.0–1.0) honestly: 0.9+ means "the host needs to see this right now." Most messages should be 0.4–0.7.
            - Set confidence (0.0–1.0) based on how sure you are the claim is correct. Below 0.5 means you're guessing.
            - Set value (0.0–1.0): how much this message would genuinely help the host. Be brutally honest.
              0.0–0.3: generic, obvious, or hollow — anyone could say this. Do not send.
              0.4–0.5: mildly interesting but not actionable.
              0.6–0.7: solid insight the host probably didn't know or hadn't considered.
              0.8–1.0: genuinely surprising, corrects a misconception, or provides a killer reframe.

            Output schema:
            {"messages":[{"persona_id":"UUID","speak":true,"text":"string","priority":0.0,"confidence":0.0,"value":0.0}]}
            """
        } else {
            system = systemTemplate
                .replacingOccurrences(of: "{{maxMessagesPerTurn}}", with: "\(settings.sidecastIntensity.maxMessagesPerTurn)")
        }

        let user = """
        Latest utterance:
        \(utterance.speaker.displayLabel): \(utterance.text)

        Recent exchange:
        \(transcriptText)

        Wider context:
        \(widerContext)

        Conversation summary:
        \(stateSummary)

        Open questions:
        \(openQuestions)

        Personas:
        \(personaText)

        Evidence:
        \(evidenceText)
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user),
        ]
    }

    private func decodeResponse(_ response: String) throws -> SidecastResponse {
        let json = extractJSON(from: response)
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8 response"))
        }
        return try JSONDecoder().decode(SidecastResponse.self, from: data)
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCallLLM: Bool {
        switch settings.llmProvider {
        case .openRouter:
            return !settings.openRouterApiKey.isEmpty
        case .requesty:
            return !settings.requestyApiKey.isEmpty && llmBaseURL != nil
        case .openAI:
            return !settings.openAIApiKey.isEmpty && llmBaseURL != nil
        case .anthropic:
            return !settings.anthropicApiKey.isEmpty && llmBaseURL != nil
        case .ollama, .lmStudio, .mlx, .openAICompatible:
            return llmBaseURL != nil
        }
    }

    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .requesty:
            settings.requestyApiKey.isEmpty ? nil : settings.requestyApiKey
        case .openAI:
            settings.openAIApiKey.isEmpty ? nil : settings.openAIApiKey
        case .anthropic:
            settings.anthropicApiKey.isEmpty ? nil : settings.anthropicApiKey
        case .ollama: nil
        case .lmStudio:
            settings.lmStudioApiKey.isEmpty ? nil : settings.lmStudioApiKey
        case .mlx: nil
        case .openAICompatible:
            settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    /// Web search is enabled when the provider is OpenRouter and any enabled persona has it on.
    private func shouldUseWebSearch(for personas: [SidecastPersona]) -> Bool {
        settings.llmProvider == .openRouter && personas.contains(where: { $0.webSearchEnabled })
    }

    private var llmBaseURL: URL? {
        switch settings.llmProvider {
        case .openRouter: nil
        case .requesty:
            OpenRouterClient.chatCompletionsURL(from: settings.requestyBaseURL)
        case .openAI:
            OpenRouterClient.chatCompletionsURL(from: settings.openAIBaseURL)
        case .anthropic:
            OpenRouterClient.anthropicMessagesURL(from: settings.anthropicBaseURL)
        case .ollama:
            OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .lmStudio:
            OpenRouterClient.chatCompletionsURL(from: settings.lmStudioBaseURL)
        case .mlx:
            OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }
}

private struct SidecastResponse: Codable {
    let messages: [SidecastResponseMessage]
}

private struct SidecastResponseMessage: Codable {
    let personaID: UUID
    let speak: Bool
    let text: String
    let priority: Double?
    let confidence: Double?
    let value: Double?

    enum CodingKeys: String, CodingKey {
        case personaID = "persona_id"
        case speak
        case text
        case priority
        case confidence
        case value
    }
}
