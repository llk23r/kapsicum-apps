import Foundation

actor ImportCoordinator {
    struct Outcome: Sendable {
        let importedCount: Int
        let screenshotCount: Int
        let gapMessage: String?
    }

    private let database: ActivityDatabase
    private let media: MediaStore
    private let subject = ActivitySubjectScope.configured
    private var remainingSearchCalls = 0
    private var retryableGaps: [String] = []
    private var earliestIncompleteSearchStart: Date?
    private let minimumSlice: TimeInterval = 15 * 60
    private let overlap: TimeInterval = 5 * 60

    init(database: ActivityDatabase, media: MediaStore) {
        self.database = database
        self.media = media
    }

    func synchronize(now: Date = Date()) async throws -> Outcome {
        remainingSearchCalls = 48
        retryableGaps = []
        earliestIncompleteSearchStart = nil
        let prior = try await database.historyStatus()
        let liveStart = now.addingTimeInterval(-86_400)
        let irreversibleGap: String?
        if let previous = prior.lastSuccessfulImport, previous < liveStart {
            irreversibleGap = L10n.format(
                "import.gap.offline",
                fallback: "Import gap: the Kapp was not open between %@ and the current live window.",
                previous.formatted(date: .abbreviated, time: .shortened))
        } else {
            irreversibleGap = nil
        }
        let requestedStart = max(liveStart, (prior.lastSuccessfulImport ?? liveStart).addingTimeInterval(-overlap))
        let hits = try await fetchWindow(start: requestedStart, end: now)
        let deduplicated = Dictionary(
            hits.lazy.filter { self.subject.matches($0) && $0.recordType != nil }.map { ($0.id, $0) },
            uniquingKeysWith: { current, replacement in current.timestamp >= replacement.timestamp ? current : replacement })
            .values.sorted { $0.timestamp < $1.timestamp }

        var offset = 0
        while offset < deduplicated.count {
            let end = min(offset + 200, deduplicated.count)
            try await database.upsert(Array(deduplicated[offset..<end]), ingestedAt: now)
            offset = end
        }

        let hashes = try await database.missingScreenshotHashes(limit: 100)
        let mediaResult = await fetchMissingMedia(hashes)
        for stored in mediaResult.media { try await database.upsertMedia(stored, storedAt: now) }
        if mediaResult.failures > 0 {
            let key = mediaResult.failures == 1
                ? "import.gap.screenshot.one"
                : "import.gap.screenshot.many"
            let fallback = mediaResult.failures == 1
                ? "%lld screenshot could not be cached locally; retry import to complete it."
                : "%lld screenshots could not be cached locally; retry import to complete them."
            retryableGaps.append(L10n.format(
                key,
                fallback: fallback,
                Int64(mediaResult.failures)))
        }
        let orphaned = try await database.enforceRetention()
        try await media.delete(relativePaths: orphaned)
        let retryableGap = retryableGaps.isEmpty ? nil : retryableGaps.joined(separator: " ")
        let isContiguous = prior.lastSuccessfulImport.map { $0 >= liveStart } ?? false
        let mayClearPriorRetryableGap = prior.hasRetryableGap && retryableGap == nil && isContiguous
        // Records beyond an incomplete slice are still useful, but they are
        // not proof of contiguous coverage. Keep the cursor at the earliest
        // unresolved boundary so the next synchronization retries that slice.
        let successfulEnd = earliestIncompleteSearchStart ?? now
        try await database.recordSuccessfulImport(
            start: requestedStart,
            end: successfulEnd,
            retryableGap: retryableGap,
            irreversibleGap: irreversibleGap,
            clearExistingRetryableGap: mayClearPriorRetryableGap)
        let currentGaps = [irreversibleGap, retryableGap].compactMap { $0 }
        return Outcome(
            importedCount: deduplicated.count,
            screenshotCount: mediaResult.media.count,
            gapMessage: currentGaps.isEmpty ? nil : currentGaps.joined(separator: " "))
    }

    private func fetchWindow(start: Date, end: Date) async throws -> [MemoryHit] {
        guard remainingSearchCalls >= 2 else {
            preserveRetryBoundary(at: start)
            retryableGaps.append(L10n.string(
                "import.gap.request_budget",
                fallback: "Coverage is incomplete because the bounded import request budget was reached."))
            return []
        }
        remainingSearchCalls -= 2
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let after = formatter.string(from: start)
        let before = formatter.string(from: end)
        let kinds = ["clipboard", "links", "notes", "screenshots", "typedText"]
        async let provenance: [MemoryHit] = KapsicumRuntime.invoke(
            descriptorID: "archive.searchTextSnippets",
            arguments: SearchInput(tokens: [], domains: subject.domains, afterISO: after, beforeISO: before, contentKinds: kinds, limit: 100),
            as: [MemoryHit].self)
        async let mentions: [MemoryHit] = KapsicumRuntime.invoke(
            descriptorID: "archive.searchTextSnippets",
            arguments: SearchInput(tokens: subject.mentionTokens, afterISO: after, beforeISO: before, contentKinds: kinds, limit: 100),
            as: [MemoryHit].self)
        let (domainHits, mentionHits) = try await (provenance, mentions)
        let saturated = domainHits.count >= 100 || mentionHits.count >= 100
        if saturated {
            let duration = end.timeIntervalSince(start)
            if duration > minimumSlice, remainingSearchCalls >= 4 {
                let midpoint = start.addingTimeInterval(duration / 2)
                async let first = fetchWindow(start: start, end: midpoint)
                async let second = fetchWindow(start: midpoint, end: end)
                return try await first + second
            }
            preserveRetryBoundary(at: start)
            retryableGaps.append(L10n.format(
                "import.gap.saturated",
                fallback: "Coverage may be incomplete near %@ because a minimum import slice reached 100 results.",
                start.formatted(date: .abbreviated, time: .shortened)))
        }
        return domainHits + mentionHits
    }

    private func preserveRetryBoundary(at start: Date) {
        earliestIncompleteSearchStart = min(
            earliestIncompleteSearchStart ?? start,
            start)
    }

    private func fetchMissingMedia(_ hashes: [String]) async -> (media: [StoredMedia], failures: Int) {
        guard !hashes.isEmpty else { return ([], 0) }
        return await withTaskGroup(of: Result<StoredMedia, Error>.self) { group in
            var iterator = hashes.prefix(100).makeIterator()
            func add(_ hash: String) {
                group.addTask { [media] in
                    do {
                        let screenshot = try await KapsicumRuntime.invoke(
                            descriptorID: "archive.getScreenshot",
                            arguments: ScreenshotInput(archiveHash: hash),
                            as: StoredScreenshot.self)
                        guard screenshot.archiveHash == hash else { throw MediaError.invalidData }
                        return .success(try await media.persist(screenshot))
                    } catch { return .failure(error) }
                }
            }
            for _ in 0..<3 { if let hash = iterator.next() { add(hash) } }
            var stored: [StoredMedia] = []
            var failures = 0
            while let result = await group.next() {
                switch result {
                case .success(let media): stored.append(media)
                case .failure: failures += 1
                }
                if let hash = iterator.next() { add(hash) }
            }
            return (stored, failures)
        }
    }
}
