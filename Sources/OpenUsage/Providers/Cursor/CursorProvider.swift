import Foundation

@MainActor
final class CursorProvider: ProviderRuntime {
    let provider = Provider(
        id: "cursor",
        displayName: "Cursor",
        icon: .providerMark("cursor"),
        links: [
            .init(label: "Status", url: "https://status.cursor.com/"),
            .init(label: "Dashboard", url: "https://www.cursor.com/dashboard")
        ]
    )

    let authStore: CursorAuthStore
    let accountSession: CursorAccountSession?
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    let spendHistoryBudget: TimeInterval
    let usageHistoryStore: CursorUsageHistoryStore

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        accountSession: CursorAccountSession? = nil,
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        spendHistoryBudget: TimeInterval = 20,
        usageHistoryStore: CursorUsageHistoryStore = CursorUsageHistoryStore()
    ) {
        self.authStore = authStore
        self.accountSession = accountSession
        self.usageClient = usageClient
        self.now = now
        self.pricing = pricing
        self.spendHistoryBudget = spendHistoryBudget
        self.usageHistoryStore = usageHistoryStore
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage")
                .exportingLimit("totalUsage", unit: "percent"),
            .percent(id: "cursor.auto", provider: provider, title: "Cursor Models")
                .exportingLimit("autoUsage", unit: "percent"),
            .percent(id: "cursor.api", provider: provider, title: "Other Models")
                .exportingLimit("apiUsage", unit: "percent"),
            .percent(id: "cursor.grokBot", provider: provider, title: "Grok Bot", metricLabel: "Grok Bot usage")
                .exportingLimit("grokBot", unit: "percent"),
            .boundedDollars(id: "cursor.onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand", limit: 100, valueWord: "spent")
                .exportingLimit("onDemand", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .boundedCount(id: "cursor.requests", provider: provider, title: "Requests", limit: 500,
                          suffix: "requests", periodDurationMs: CursorUsageMapper.billingPeriodMs)
                .exportingLimit("requests", unit: "requests"),
            .dollarBalance(id: "cursor.credits", provider: provider, title: "Credits", valueWord: "left")
                .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .accountWide,
                    estimatedCost: true,
                    sourceNote: "From your Cursor usage history"
                )
        ] + WidgetDescriptor.spendTiles(
            provider: provider,
            valueTooltipNote: WidgetData.cursorUsageHistoryNote
        )
    }

    func hasLocalCredentials() async -> Bool {
        do {
            if try await accountSession?.loadAuthState() != nil { return true }
            return await loadOffMainActor { [authStore] in authStore.loadAuthState() } != nil
        } catch {
            AppLog.error(LogTag.auth("cursor"), "could not read OpenUsage's saved sign-in during detection")
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        var revision = accountSession?.revision
        do {
            let state: CursorAuthState?
            if let owned = try await accountSession?.loadAuthState() {
                state = owned
            } else {
                state = await loadOffMainActor { [authStore] in authStore.loadAuthState() }
            }
            revision = accountSession?.revision
            guard let state else { throw CursorAuthError.notLoggedIn }
            let result = try await probe(authState: state)
            if revision != accountSession?.revision { return await refresh() }
            return result
        } catch {
            if revision != accountSession?.revision { return await refresh() }
            AppLog.warn(LogTag.plugin("cursor"), "usage refresh failed")
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func probe(authState initialState: CursorAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        var accessToken = authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if authStore.needsRefresh(accessToken, source: authState.source) {
            do {
                if let refreshed = try await refreshAccessToken(authState: authState) {
                    authState.accessToken = refreshed
                    accessToken = refreshed
                } else if accessToken == nil {
                    throw CursorAuthError.notLoggedIn
                }
            } catch {
                AppLog.warn(LogTag.auth("cursor"), "token renewal failed; trying the existing access token")
                if accessToken == nil {
                    throw error
                }
            }
        }

        guard let accessToken else {
            throw CursorAuthError.notLoggedIn
        }

        let usageResponse = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        try ProviderAuthRetry.requireSuccess(
            usageResponse,
            authExpired: CursorAuthError.tokenExpired,
            requestFailed: { CursorUsageError.requestFailed($0) }
        )
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.accessToken ?? accessToken
        if authState.source == .openUsage {
            authState.membershipType = await accountSession?.membershipType(client: usageClient, accessToken: currentToken, now: now())
        }

        let (planInfoName, planInfoUnavailable) = await fetchPlanName(accessToken: currentToken)
        let routingPlanName = CursorUsageMapper.routingPlanName(
            planInfoName: planInfoName,
            membershipType: authState.membershipType
        )
        let displayPlanName = CursorUsageMapper.resolvedPlanName(
            planInfoName: planInfoName,
            membershipType: authState.membershipType
        )
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: routingPlanName,
            planInfoUnavailable: planInfoUnavailable
        )
        if fallback.shouldFallback {
            var mapped = try await usageSummaryAndRequestResult(
                accessToken: currentToken,
                planName: displayPlanName ?? routingPlanName,
                unavailableMessage: fallback.message
            )
            await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
            let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
            return snapshot(mapped, usageHistory: history)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            do {
                var mapped = try await requestBasedResult(
                    accessToken: currentToken,
                    planName: displayPlanName ?? routingPlanName,
                    unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
                )
                await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
                let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
                return snapshot(mapped, usageHistory: history)
            } catch {
                AppLog.warn(LogTag.plugin("cursor"), "optional request-based usage fallback failed")
            }
        }

        let creditGrants = await fetchCreditGrants(accessToken: currentToken)
        let stripeBalanceCents = await fetchStripeBalanceCents(accessToken: currentToken)
        var mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planInfoName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripeBalanceCents
        )
        mapped.plan = CursorUsageMapper.resolvedPlanLabel(
            planInfoName: planInfoName,
            membershipType: authState.membershipType
        )
        await enrichPrimaryUsageFromSummaryIfNeeded(
            accessToken: currentToken,
            usage: usage,
            planInfoName: planInfoName,
            membershipType: authState.membershipType,
            mapped: &mapped
        )
        await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
        let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
        return snapshot(mapped, usageHistory: history)
    }

    /// Model-pool Enterprise/team seats often keep a usable primary usage payload but omit on-demand
    /// there. usage-summary still carries Extra Usage for those accounts.
    private func enrichPrimaryUsageFromSummaryIfNeeded(
        accessToken: String,
        usage: [String: Any],
        planInfoName: String?,
        membershipType: String?,
        mapped: inout CursorMappedUsage
    ) async {
        let needsOnDemand = !mapped.lines.contains(where: { $0.label == "On-demand" })
        let facts = CursorPlanUsageFacts(usage: usage)
        let localIsOrg = membershipType.map { CursorUsageMapper.orgMembershipTypes.contains($0) } ?? false
        // Only org / team-shaped seats: personal Pro model pools must not trigger usage-summary.
        guard localIsOrg || facts.isTeamByShape else { return }
        // Local org already fixed the badge; skip the extra call when Extra Usage is present.
        if localIsOrg, !needsOnDemand { return }

        guard let summary = await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        }) else {
            return
        }
        if !CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
            AppLog.warn(LogTag.plugin("cursor"), "optional usage-summary response contained no usable usage fields")
            return
        }
        if needsOnDemand {
            CursorUsageSummaryMapper.appendMissingOnDemand(from: summary, to: &mapped.lines)
        }
        let summaryMembership = (summary["membershipType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        mapped.plan = CursorUsageMapper.resolvedPlanLabel(
            planInfoName: planInfoName,
            membershipType: CursorUsageMapper.preferredMembership(
                local: membershipType,
                summary: summaryMembership
            )
        ) ?? mapped.plan
    }

    /// Grok Bot uses the same Cursor account but keeps a separate weekly allowance. Missing access is
    /// normal for ineligible accounts; malformed data and request failures remain visible in diagnostics.
    private func appendGrokBotUsage(to lines: inout [MetricLine], accessToken: String) async {
        guard let usage = await fetchOptionalJSONObject(label: "Grok Bot usage", request: {
            try await self.usageClient.fetchGrokBotUsage(accessToken: accessToken)
        }) else {
            return
        }
        guard usage["usesPooledEnterpriseAllowance"] as? Bool != true,
              usage["hasNonZeroIncludedLimit"] as? Bool != false,
              usage["includedLimitZero"] as? Bool != true
        else {
            return
        }
        guard let line = CursorUsageMapper.mapGrokBotUsage(usage) else {
            if usage["usagePercent"] != nil || usage["hasNonZeroIncludedLimit"] as? Bool == true ||
                usage["hasAvailableUsage"] as? Bool == true {
                AppLog.warn(LogTag.plugin("cursor"), "optional Grok Bot usage response contained invalid usage metadata")
            }
            return
        }
        lines.append(line)
    }

    /// Spend history is best-effort and never affects the live Cursor usage mapping.
    private func appendSpendLines(to lines: inout [MetricLine], accessToken: String) async -> ProviderUsageHistory? {
        guard let session = CursorUsageClient.session(from: accessToken) else {
            AppLog.warn(LogTag.plugin("cursor"), "usage events could not be prepared from the current session")
            return nil
        }
        let currentTime = now()
        let fetcher = CursorSpendHistoryFetcher(
            client: usageClient,
            store: usageHistoryStore,
            budget: spendHistoryBudget
        )
        guard let days = await fetcher.refresh(
            accessToken: accessToken,
            userID: session.userID,
            now: currentTime
        ) else {
            return nil
        }
        let pricing = await pricing()
        let rows = days.flatMap { dayStart, day in
            day.models.map { model, tokens in
                CursorUsageRow(
                    date: dayStart,
                    model: model,
                    tokens: tokens,
                    imputedCostDollars: pricing.estimatedCostDollars(
                        model: model,
                        tokens: tokens,
                        applyLongContextRates: false
                    )
                )
            }
        }
        return CursorUsageMapper.appendSpendLines(rows: rows, now: currentTime, pricing: pricing, to: &lines)
    }

    private func fetchPlanName(accessToken: String) async -> (String?, Bool) {
        guard let body = await fetchOptionalJSONObject(label: "plan", request: {
            try await self.usageClient.fetchPlan(accessToken: accessToken)
        }) else {
            return (nil, true)
        }
        guard let planInfo = body["planInfo"] as? [String: Any],
              let planName = (planInfo["planName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        else {
            AppLog.warn(LogTag.plugin("cursor"), "optional plan response contained invalid plan metadata")
            return (nil, true)
        }
        return (planName, false)
    }

    private func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard let body = await fetchOptionalJSONObject(label: "credit-grants", request: {
            try await self.usageClient.fetchCredits(accessToken: accessToken)
        }) else {
            return nil
        }
        // Enterprise seats often return a body without grant fields. That is not a schema error —
        // only warn when Cursor claimed grants but the payload cannot be read.
        guard let hasCreditGrants = body["hasCreditGrants"] as? Bool else {
            if body["hasCreditGrants"] != nil {
                AppLog.warn(LogTag.plugin("cursor"), "optional credit-grants response contained invalid grant metadata")
            }
            return nil
        }
        if hasCreditGrants {
            guard let totalCents = ProviderParse.number(body["totalCents"]), totalCents > 0,
                  let usedCents = ProviderParse.number(body["usedCents"]), usedCents >= 0 else {
                AppLog.warn(LogTag.plugin("cursor"), "optional credit-grants response contained invalid grant metadata")
                return nil
            }
        }
        return body
    }

    private func fetchStripeBalanceCents(accessToken: String) async -> Double {
        guard let body = await fetchOptionalJSONObject(label: "prepaid-balance", request: {
            try await self.usageClient.fetchStripeBalance(accessToken: accessToken)
        }) else {
            return 0
        }
        guard ProviderParse.number(body["customerBalance"]) != nil else {
            AppLog.warn(LogTag.plugin("cursor"), "optional prepaid-balance response contained invalid balance metadata")
            return 0
        }
        return CursorUsageMapper.stripeBalanceCents(from: body)
    }

    /// Optional endpoints enrich a usable primary snapshot; they never fail the whole provider. Keep
    /// their boundary handling in one place so transport, preparation, status, and schema failures are
    /// all visible with fixed, credential-free diagnostics.
    private func fetchOptionalJSONObject(
        label: String,
        request: () async throws -> HTTPResponse?
    ) async -> [String: Any]? {
        let response: HTTPResponse?
        do {
            response = try await request()
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request failed")
            return nil
        }
        guard let response else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request could not be prepared from the current session")
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) response was invalid")
            return nil
        }
        return body
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        do {
            guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken),
                  (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body)
            else {
                throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
            }
            return try CursorUsageSummaryMapper.map(
                summary: nil,
                requestUsage: body,
                planName: planName,
                unavailableMessage: unavailableMessage
            )
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
    }

    private func usageSummaryAndRequestResult(
        accessToken: String,
        planName: String?,
        unavailableMessage: String
    ) async throws -> CursorMappedUsage {
        let summary = await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        })
        if let summary, !CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
            AppLog.warn(LogTag.plugin("cursor"), "optional usage-summary response contained no usable usage fields")
        }
        let requestUsage = await fetchOptionalJSONObject(label: "request-based usage", request: {
            try await self.usageClient.fetchRequestBasedUsage(accessToken: accessToken)
        })
        if let requestUsage, !CursorUsageSummaryMapper.hasUsableRequestPayload(requestUsage) {
            AppLog.warn(LogTag.plugin("cursor"), "optional request-based usage response contained no usable usage fields")
        }
        return try CursorUsageSummaryMapper.map(
            summary: summary,
            requestUsage: requestUsage,
            planName: planName,
            unavailableMessage: unavailableMessage
        )
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        CursorPlanUsageFacts(usage: usage).shouldTryGenericRequestFallback
    }

    private func snapshot(_ mapped: CursorMappedUsage, usageHistory: ProviderUsageHistory? = nil) -> ProviderSnapshot {
        ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: accountSession?.persistenceWarning
        )
    }
}
