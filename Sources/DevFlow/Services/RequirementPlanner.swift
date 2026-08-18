import Foundation

@MainActor
final class RequirementPlanner {
    private unowned let appState: AppState
    private let aiService = AIService()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func start(
        ticket: Ticket,
        repository: RepositoryConfig,
        branch: String,
        provider: AIProvider,
        modelID: String?,
        reasoningEffort: String?,
        helperContext: String,
        navigationMaterialPath: String?,
        intensity: RequirementPlanningIntensity
    ) {
        guard ticket.kind.usesRequirementPlanning else { return }
        guard appState.planningSession(for: ticket.id) == nil else { return }

        let session = RequirementPlanSession(
            ticketID: ticket.id,
            intensity: intensity,
            provider: provider,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            repositoryPath: repository.path,
            branch: branch,
            helperContext: helperContext,
            // Navigation is converted to a bounded evidence block before the session starts.
            navigationMaterialPath: nil,
            phase: .compiling
        )
        appState.addOrUpdate(planningSession: session)
        appState.setTicketStatus(ticket.id, .processing)
        runTurn(sessionID: session.id, ticket: ticket, finishNow: false)
    }

    func submitAnswer(sessionID: UUID, answer: String, finishNow: Bool = false) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || finishNow,
              var session = session(id: sessionID),
              session.phase == .questioning,
              let ticket = appState.tickets.first(where: { $0.id == session.ticketID }) else { return }

        if !trimmed.isEmpty {
            session.messages.append(PlanningMessage(role: .user, content: trimmed))
        } else if finishNow {
            session.messages.append(PlanningMessage(role: .user, content: "剩余问题无需再问，请基于已有回答和合理假设立即输出完整开发文档。"))
        }
        session.phase = .compiling
        session.errorMessage = nil
        session.updatedAt = Date()
        appState.addOrUpdate(planningSession: session)
        runTurn(sessionID: session.id, ticket: ticket, finishNow: finishNow)
    }

    func retry(sessionID: UUID) {
        guard let session = session(id: sessionID),
              session.phase == .failed,
              let ticket = appState.tickets.first(where: { $0.id == session.ticketID }) else { return }
        update(sessionID) {
            $0.phase = .compiling
            $0.errorMessage = nil
            $0.updatedAt = Date()
        }
        runTurn(sessionID: sessionID, ticket: ticket, finishNow: false)
    }

    func reset(ticketID: Int) {
        cancel(ticketID: ticketID)
        if let index = appState.tickets.firstIndex(where: { $0.id == ticketID }),
           appState.tickets[index].status == .processing {
            appState.setTicketStatus(ticketID, .new)
        }
    }

    func cancel(ticketID: Int) {
        if let session = appState.planningSession(for: ticketID) {
            tasks[session.id]?.cancel()
            tasks[session.id] = nil
        }
        appState.removePlanningSession(ticketID: ticketID)
    }

    func handoffToExternalAgent(sessionID: UUID) throws {
        guard let session = session(id: sessionID),
              session.phase == .ready,
              let document = session.developmentDocument,
              let ticket = appState.tickets.first(where: { $0.id == session.ticketID }) else {
            throw ExternalAgentLauncher.LaunchError.launchFailed("还没有完整的开发计划")
        }
        _ = try ExternalAgentLauncher.launch(
            .init(
                ticket: ticket,
                repositoryPath: session.repositoryPath,
                branch: session.branch,
                helperContext: session.helperContext,
                navigationMaterialPath: nil,
                provider: session.provider,
                developmentDocument: document,
                enableWorkGraphMCP: session.provider == .cursor
            )
        )
    }

    private func runTurn(sessionID: UUID, ticket: Ticket, finishNow: Bool) {
        tasks[sessionID]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            guard let session = self.session(id: sessionID) else { return }
            do {
                let execution = try await aiService.run(
                    provider: session.provider,
                    modelID: session.modelID,
                    reasoningEffort: session.reasoningEffort,
                    ticket: ticket,
                    repositoryPath: session.repositoryPath,
                    helperContext: session.helperContext,
                    navigationMaterialPath: nil,
                    mode: .requirementPlanning(
                        intensity: session.intensity,
                        askedCount: session.askedCount,
                        questionTotal: session.questionTotal,
                        messages: session.messages,
                        finishNow: finishNow
                    ),
                    onStarted: { _ in },
                    onEvent: { _ in }
                )
                try apply(execution.finalMessage, to: sessionID)
            } catch is CancellationError {
                tasks[sessionID] = nil
            } catch {
                update(sessionID) {
                    $0.phase = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.updatedAt = Date()
                }
            }
            tasks[sessionID] = nil
        }
        tasks[sessionID] = task
    }

    private func apply(_ finalMessage: String, to sessionID: UUID) throws {
        guard let turn = PromptBuilder.parseRequirementPlanningTurn(finalMessage) else {
            throw AIExecutionError.incompleteProtocolOutput(.planning)
        }
        guard var session = session(id: sessionID) else { return }

        switch turn {
        case let .question(text, index, total):
            session.askedCount = max(session.askedCount + 1, index)
            if let total {
                session.questionTotal = max(total, session.askedCount)
            } else {
                session.questionTotal = nil
            }
            session.messages.append(PlanningMessage(role: .assistant, content: text))
            session.phase = .questioning
            session.errorMessage = nil
        case let .document(document):
            session.developmentDocument = document
            session.phase = .ready
            session.errorMessage = nil
        }
        session.updatedAt = Date()
        appState.addOrUpdate(planningSession: session)
    }

    private func session(id: UUID) -> RequirementPlanSession? {
        appState.planningSessions.first { $0.id == id }
    }

    private func update(_ sessionID: UUID, _ mutate: (inout RequirementPlanSession) -> Void) {
        guard var session = session(id: sessionID) else { return }
        mutate(&session)
        appState.addOrUpdate(planningSession: session)
    }
}
