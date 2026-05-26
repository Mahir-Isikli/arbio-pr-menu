import AppKit
import Darwin
import Foundation
import SwiftUI

private func normalizedSetting(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private enum AppSettings {
    static let defaultRepositorySlug = "arbiogroup/arbio-platform"
    static let repositoryDefaultsKey = "ArbioPRMenu.repositorySlug"
    static let autoRebaseDefaultsKey = "ArbioPRMenu.autoRebaseEnabled"
    static let writeActionsDefaultsKey = "ArbioPRMenu.writeActionsEnabled"

    static var repositorySlug: String {
        normalizedSetting(UserDefaults.standard.string(forKey: repositoryDefaultsKey))
            ?? normalizedSetting(ProcessInfo.processInfo.environment["ARBIO_PR_MENU_REPOSITORY"])
            ?? defaultRepositorySlug
    }
}

@main
struct ArbioPRMenuApp: App {
    @NSApplicationDelegateAdaptor(ArbioPRMenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class ArbioPRMenuAppDelegate: NSObject, NSApplicationDelegate {
    private let store = PRStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showWindow()
        }
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: 86)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = nil
            button.title = "PR MENU"
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.toolTip = "Arbio PR Menu"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 580, height: 700)
        popover.contentViewController = NSHostingController(rootView: PRMenuView(store: store))
        self.popover = popover
    }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Arbio PR Menu"
        window.contentViewController = NSHostingController(rootView: PRMenuView(store: store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        store.refreshIfStale()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshIfStale()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PullRequest] = []
    @Published var mergedPRs: [MergedPullRequest] = []
    @Published var reviewPRs: [PullRequest] = []
    @Published var reviewedPRs: [PullRequest] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var mergeStates: [Int: MergeState] = [:]
    @Published var rebaseStates: [Int: RebaseState] = [:]
    @Published var currentUserLogin: String?
    @Published var writeActionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(writeActionsEnabled, forKey: AppSettings.writeActionsDefaultsKey)
        }
    }
    @Published var autoRebaseEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoRebaseEnabled, forKey: AppSettings.autoRebaseDefaultsKey)
        }
    }
    private let syncIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
    private let autoRebaseRetryInterval: TimeInterval = 20 * 60
    private var refreshTask: Task<Void, Never>?
    private var automationTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var lastAutoRebaseAttempt: [Int: Date] = [:]

    init() {
        currentUserLogin = nil
        writeActionsEnabled = UserDefaults.standard.object(forKey: AppSettings.writeActionsDefaultsKey) as? Bool ?? false
        autoRebaseEnabled = UserDefaults.standard.object(forKey: AppSettings.autoRebaseDefaultsKey) as? Bool ?? false
        startAutomation()
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    deinit {
        refreshTask?.cancel()
        automationTask?.cancel()
    }

    func refreshIfStale() {
        guard let lastUpdated else {
            refresh()
            return
        }

        if Date().timeIntervalSince(lastUpdated) > 120 {
            refresh()
        }
    }

    func refresh(force: Bool = false) {
        if isLoading && !force { return }

        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil

        refreshTask = Task {
            do {
                let loaded = try await PRFetcher.fetchPRSnapshot()
                if Task.isCancelled || generation != refreshGeneration { return }
                currentUserLogin = loaded.currentUserLogin
                prs = loaded.open
                mergedPRs = loaded.merged
                reviewPRs = loaded.reviewRequested
                reviewedPRs = loaded.reviewedByMe
                lastUpdated = Date()
                isLoading = false
                autoRebaseBehindBranches(in: loaded.open)
            } catch is CancellationError {
                if generation == refreshGeneration {
                    isLoading = false
                }
            } catch {
                if Task.isCancelled || generation != refreshGeneration { return }
                errorMessage = error.localizedDescription
                lastUpdated = Date()
                isLoading = false
            }
        }
    }

    func squashMerge(_ pr: PullRequest) {
        guard ensureWriteActionAllowed(for: pr, action: "Squash merge") else { return }
        guard mergeStates[pr.number]?.isWorking != true else { return }
        mergeStates[pr.number] = .merging

        Task {
            do {
                try await PRFetcher.squashMerge(pr)
                mergeStates[pr.number] = .merged
                refresh()
            } catch {
                mergeStates[pr.number] = .failed(error.localizedDescription)
            }
        }
    }

    func rebase(_ pr: PullRequest) {
        guard ensureWriteActionAllowed(for: pr, action: "Rebase") else { return }
        startRebase(pr, automatic: false)
    }

    func markReady(_ pr: PullRequest) {
        guard ensureWriteActionAllowed(for: pr, action: "Mark ready") else { return }
        Task {
            try? await PRFetcher.markReady(pr)
            refresh(force: true)
        }
    }

    func convertToDraft(_ pr: PullRequest) {
        guard ensureWriteActionAllowed(for: pr, action: "Convert to draft") else { return }
        Task {
            try? await PRFetcher.convertToDraft(pr)
            refresh(force: true)
        }
    }

    private func startAutomation() {
        let syncIntervalNanoseconds = syncIntervalNanoseconds
        automationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: syncIntervalNanoseconds)
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    private func autoRebaseBehindBranches(in prs: [PullRequest]) {
        guard autoRebaseEnabled, writeActionsEnabled else { return }

        for pr in prs where pr.canAutoRebase {
            guard rebaseStates[pr.number]?.isWorking != true else { continue }
            if let lastAttempt = lastAutoRebaseAttempt[pr.number], Date().timeIntervalSince(lastAttempt) < autoRebaseRetryInterval {
                continue
            }
            startRebase(pr, automatic: true)
        }
    }

    private func startRebase(_ pr: PullRequest, automatic: Bool) {
        guard ensureWriteActionAllowed(for: pr, action: automatic ? "Auto-rebase" : "Rebase") else { return }
        guard rebaseStates[pr.number]?.isWorking != true else { return }
        rebaseStates[pr.number] = automatic ? .autoRebasing : .rebasing
        if automatic {
            lastAutoRebaseAttempt[pr.number] = Date()
        }

        Task {
            do {
                try await PRFetcher.rebase(pr)
                rebaseStates[pr.number] = .rebased
                refresh()
            } catch {
                rebaseStates[pr.number] = .failed(error.localizedDescription)
            }
        }
    }

    private func ensureWriteActionAllowed(for pr: PullRequest, action: String) -> Bool {
        guard writeActionsEnabled else {
            errorMessage = "\(action) is disabled. Turn on Write actions first."
            return false
        }

        guard pr.isMine else {
            errorMessage = "\(action) is only available for your own PRs."
            return false
        }

        return true
    }
}

enum MergeState: Equatable {
    case idle
    case merging
    case merged
    case failed(String)

    var isWorking: Bool {
        if case .merging = self { return true }
        return false
    }
}

enum RebaseState: Equatable {
    case idle
    case rebasing
    case autoRebasing
    case rebased
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .rebasing, .autoRebasing: return true
        case .idle, .rebased, .failed: return false
        }
    }
}

struct PullRequest: Identifiable, Decodable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String?
    let reviewDecision: String?
    let mergeStateStatus: String?
    let mergeable: String?
    let statusCheckRollup: [StatusCheck]
    let latestReviews: [Review]
    let updatedAt: Date?
    let createdAt: Date?
    let author: GitHubActor?
    let reviewRequests: [GitHubActor]?
    let commits: [Commit]?
    var threadSummary: ThreadSummary?
    var currentUserLogin: String?

    var id: Int { number }

    private var currentUser: String? {
        normalizedSetting(currentUserLogin)
    }

    var isMine: Bool {
        guard let currentUser else { return false }
        return author?.login == currentUser
    }

    var authorName: String {
        let login = author?.login ?? "unknown"
        if login == currentUser { return "you" }
        return author?.name?.isEmpty == false ? author?.name ?? login : login
    }

    var reviewRequestNames: String {
        let names = (reviewRequests ?? []).compactMap { actor -> String? in
            if actor.login == currentUser { return "you" }
            return actor.name?.isEmpty == false ? actor.name : actor.login
        }
        return names.isEmpty ? "reviewers" : names.joined(separator: ", ")
    }

    var latestCommitDate: Date? {
        commits?.compactMap(\.committedDate).max()
    }

    var latestMyReviewDate: Date? {
        latestReviews
            .filter { $0.author.login == currentUser }
            .compactMap(\.submittedAt)
            .max()
    }

    var hasNewCommitsAfterMyReview: Bool {
        guard let latestMyReviewDate, let latestCommitDate else { return false }
        return latestCommitDate > latestMyReviewDate
    }

    var needsMyAction: Bool {
        if isDraft && isStaleDraft { return true }
        if isDraft { return false }
        if ciSummary.kind == .failing { return true }
        if reviewDecision == "CHANGES_REQUESTED" { return true }
        if (threadSummary?.unresolved ?? 0) > 0 { return true }
        if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" { return true }
        if needsRebase { return true }
        return false
    }

    var isWaitingOnReview: Bool {
        !isDraft && reviewSummary.kind == .waiting && !needsMyAction
    }

    var isStaleDraft: Bool {
        guard isDraft, let createdAt else { return false }
        return Date().timeIntervalSince(createdAt) > 2 * 24 * 60 * 60
    }

    var isStaleOpen: Bool {
        guard let createdAt else { return false }
        return Date().timeIntervalSince(createdAt) > 3 * 24 * 60 * 60
    }

    var actionReason: String {
        if ciSummary.kind == .failing { return "CI failed" }
        if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        if (threadSummary?.unresolved ?? 0) > 0 { return "Resolve review threads" }
        if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" { return "Fix conflicts" }
        if needsRebase { return "Rebase needed" }
        if isStaleDraft { return "Draft is stale" }
        if hasNewCommitsAfterMyReview { return "New commits after your review" }
        return mergeReadinessLabel
    }

    var primaryCheckURL: String? {
        statusCheckRollup.first(where: \.isFailure)?.detailsUrl ?? statusCheckRollup.first(where: \.isPending)?.detailsUrl
    }

    var ciSummary: BadgeSummary {
        guard !statusCheckRollup.isEmpty else {
            return BadgeSummary(kind: .unknown, title: "Checking", subtitle: "GitHub is updating")
        }

        let failures = statusCheckRollup.filter { $0.isFailure }.count
        let pending = statusCheckRollup.filter { $0.isPending }.count

        if failures > 0 {
            return BadgeSummary(kind: .failing, title: "\(failures) failing", subtitle: "CI needs attention")
        }

        if pending > 0 {
            return BadgeSummary(kind: .running, title: "\(pending) running", subtitle: "Checks in progress")
        }

        return BadgeSummary(kind: .passing, title: "CI green", subtitle: "All required checks passed")
    }

    var reviewSummary: BadgeSummary {
        if isDraft {
            return BadgeSummary(kind: .unknown, title: "Draft", subtitle: "Not ready for review")
        }

        switch reviewDecision ?? "" {
        case "APPROVED":
            return BadgeSummary(kind: .passing, title: "Approved", subtitle: latestApprovalSubtitle)
        case "CHANGES_REQUESTED":
            return BadgeSummary(kind: .failing, title: "Changes", subtitle: "Review requested changes")
        case "REVIEW_REQUIRED":
            return BadgeSummary(kind: .waiting, title: "Review needed", subtitle: latestReviewSubtitle)
        default:
            return BadgeSummary(kind: .waiting, title: "Review needed", subtitle: latestReviewSubtitle)
        }
    }

    var mergeSummary: BadgeSummary {
        if isDraft {
            return BadgeSummary(kind: .unknown, title: "Draft", subtitle: "Auto-rebase paused")
        }

        if mergeable == "CONFLICTING" {
            return BadgeSummary(kind: .failing, title: "Conflicts", subtitle: "Needs rebase or fix")
        }

        switch mergeStateStatus ?? "" {
        case "CLEAN":
            return BadgeSummary(kind: .passing, title: "Mergeable", subtitle: "Branch protection clear")
        case "UNSTABLE":
            return BadgeSummary(kind: .running, title: "Mergeable", subtitle: "Waiting on checks")
        case "BLOCKED":
            return BadgeSummary(kind: .waiting, title: "Blocked", subtitle: "Review or checks needed")
        case "BEHIND":
            return BadgeSummary(kind: .waiting, title: "Behind", subtitle: "Rebase on main")
        case "DIRTY":
            return BadgeSummary(kind: .failing, title: "Dirty", subtitle: "Merge conflict")
        default:
            if mergeable == "MERGEABLE" {
                return BadgeSummary(kind: .running, title: "Mergeable", subtitle: "GitHub updating")
            }
            return BadgeSummary(kind: .unknown, title: "Checking", subtitle: "Merge state unknown")
        }
    }

    var threadBadge: BadgeSummary {
        guard let threadSummary else {
            return BadgeSummary(kind: .unknown, title: "Threads", subtitle: "Not loaded")
        }

        if threadSummary.unresolved == 0 {
            return BadgeSummary(kind: .passing, title: "Resolved", subtitle: "0 open threads")
        }

        return BadgeSummary(kind: .waiting, title: "\(threadSummary.unresolved) open", subtitle: "Review threads")
    }

    var needsRebase: Bool {
        mergeStateStatus == "BEHIND"
    }

    var canAutoRebase: Bool {
        isMine && !isDraft && needsRebase && mergeable != "CONFLICTING"
    }

    var isSquashMergeReady: Bool {
        !isDraft &&
            mergeable == "MERGEABLE" &&
            !needsRebase &&
            ciSummary.kind == .passing &&
            reviewSummary.kind == .passing &&
            (threadSummary?.unresolved ?? 0) == 0
    }

    var mergeReadinessLabel: String {
        if isDraft { return "Draft PR" }
        if mergeable == "CONFLICTING" { return "Conflicts" }
        if ciSummary.kind == .failing { return "CI failing" }
        if ciSummary.kind == .running || ciSummary.kind == .unknown { return "Waiting on CI" }
        if reviewSummary.kind != .passing { return "Needs review" }
        if (threadSummary?.unresolved ?? 0) > 0 { return "Resolve threads" }
        if needsRebase { return "Rebase needed" }
        if mergeable != "MERGEABLE" { return "Checking merge" }
        return "Ready"
    }

    private var latestApprovalSubtitle: String {
        if let review = latestReviews.first(where: { $0.state == "APPROVED" }) {
            return review.author.login
        }
        return "Reviewer approved"
    }

    private var latestReviewSubtitle: String {
        if let review = latestReviews.first {
            return "\(review.author.login) · \(review.state.capitalized.lowercased())"
        }
        return "Waiting for teammate"
    }
}

struct StatusCheck: Decodable {
    let typename: String?
    let name: String?
    let context: String?
    let status: String?
    let conclusion: String?
    let state: String?
    let detailsUrl: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name
        case context
        case status
        case conclusion
        case state
        case detailsUrl
    }

    var isPending: Bool {
        if typename == "StatusContext" {
            return state == "PENDING" || state == "EXPECTED"
        }

        return status != nil && status != "COMPLETED"
    }

    var isFailure: Bool {
        if typename == "StatusContext" {
            return state == "ERROR" || state == "FAILURE"
        }

        return ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion ?? "")
    }
}

struct Review: Decodable {
    let author: ReviewAuthor
    let state: String
    let submittedAt: Date?
}

struct ReviewAuthor: Decodable {
    let login: String
}

struct GitHubActor: Decodable {
    let login: String?
    let name: String?
}

struct Commit: Decodable {
    let committedDate: Date?
}

struct MergedPullRequest: Identifiable, Decodable {
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let mergedAt: Date?
    let updatedAt: Date?
    let mergeCommit: MergeCommit?
    var deploymentSummary: DeploymentSummary?

    var id: Int { number }

    var isDeploying: Bool {
        deploymentSummary?.kind == .running
    }

    var needsDeploymentAttention: Bool {
        guard let deploymentSummary else { return false }
        return deploymentSummary.kind == .running || deploymentSummary.kind == .failing
    }

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case url
        case headRefName
        case mergedAt
        case updatedAt
        case mergeCommit
    }

}

struct MergeCommit: Decodable {
    let oid: String?
}

struct DeploymentSummary {
    let kind: BadgeKind
    let title: String
    let subtitle: String
    let url: String?
}

struct DeployJobStatus {
    let key: String
    let kind: BadgeKind
    let title: String
    let subtitle: String
    let url: String?
    let observedAt: Date?

    var summary: DeploymentSummary {
        DeploymentSummary(kind: kind, title: title, subtitle: subtitle, url: url)
    }

    func isNewer(than date: Date?) -> Bool {
        guard let observedAt else { return false }
        guard let date else { return true }
        return observedAt > date
    }
}

struct ThreadSummary: Decodable {
    let unresolved: Int
    let total: Int
}

struct BadgeSummary: Equatable {
    let kind: BadgeKind
    let title: String
    let subtitle: String
}

enum BadgeKind: Equatable {
    case passing
    case running
    case waiting
    case failing
    case unknown

    var dotColor: Color {
        switch self {
        case .passing: return Color(nsColor: .systemGreen)
        case .running: return Color(nsColor: .systemOrange)
        case .waiting: return Color(nsColor: .secondaryLabelColor)
        case .failing: return Color(nsColor: .systemRed)
        case .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var symbolName: String {
        switch self {
        case .passing: return "checkmark.circle.fill"
        case .running: return "ellipsis.circle.fill"
        case .waiting: return "clock.fill"
        case .failing: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct SearchPullRequest: Decodable {
    let number: Int
}

struct PRSnapshot {
    let currentUserLogin: String
    let open: [PullRequest]
    let merged: [MergedPullRequest]
    let reviewRequested: [PullRequest]
    let reviewedByMe: [PullRequest]
}

enum PRFetcher {
    private static let detailedPRFields = "number,title,url,isDraft,headRefName,baseRefName,reviewDecision,mergeStateStatus,mergeable,statusCheckRollup,latestReviews,updatedAt,createdAt,author,reviewRequests,commits"
    private static var repositoryParts: (owner: String, name: String) {
        let parts = AppSettings.repositorySlug.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "arbiogroup", parts.dropFirst().first ?? "arbio-platform")
    }

    static func fetchPRSnapshot() async throws -> PRSnapshot {
        let currentUserLogin = try fetchCurrentUserLogin()
        async let open = fetchOpenPRs(currentUserLogin: currentUserLogin)
        async let merged = fetchMergedPRs()
        async let reviewRequested = fetchReviewRequestedPRs(currentUserLogin: currentUserLogin)
        async let reviewedByMe = fetchReviewedByMePRs(currentUserLogin: currentUserLogin)
        return try await PRSnapshot(currentUserLogin: currentUserLogin, open: open, merged: merged, reviewRequested: reviewRequested, reviewedByMe: reviewedByMe)
    }

    private static func fetchCurrentUserLogin() throws -> String {
        let output = try Shell.runGitHub(["api", "user", "--jq", ".login"], timeout: 15)
        let login = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !login.isEmpty else {
            throw NSError(domain: "ArbioPRMenu.GitHub", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine current GitHub user. Run gh auth login."])
        }
        return login
    }

    private static func attachCurrentUserLogin(_ login: String, to prs: inout [PullRequest]) {
        for index in prs.indices {
            prs[index].currentUserLogin = login
        }
    }

    static func fetchOpenPRs(currentUserLogin: String) async throws -> [PullRequest] {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let output = try Shell.runGitHub([
                "pr", "list",
                "--repo", AppSettings.repositorySlug,
                "--author", "@me",
                "--state", "open",
                "--limit", "30",
                "--json", detailedPRFields
            ], timeout: 30)

            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var prs = try decoder.decode([PullRequest].self, from: output)
            attachCurrentUserLogin(currentUserLogin, to: &prs)

            let threadSummaries = await withTaskGroup(of: (Int, ThreadSummary?).self) { group in
                for pr in prs {
                    group.addTask {
                        (pr.number, try? fetchThreadSummary(number: pr.number))
                    }
                }

                var summaries: [Int: ThreadSummary] = [:]
                for await (number, summary) in group {
                    if let summary {
                        summaries[number] = summary
                    }
                }
                return summaries
            }

            try Task.checkCancellation()
            for index in prs.indices {
                prs[index].threadSummary = threadSummaries[prs[index].number]
            }

            return prs.sorted { lhs, rhs in
                if lhs.isDraft != rhs.isDraft { return !lhs.isDraft }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func fetchReviewRequestedPRs(currentUserLogin: String) async throws -> [PullRequest] {
        try await fetchSearchPRDetails(arguments: [
            "search", "prs",
            "--repo", AppSettings.repositorySlug,
            "--state", "open",
            "--review-requested", "@me",
            "--limit", "20",
            "--json", "number"
        ], currentUserLogin: currentUserLogin)
        .filter { !$0.isDraft && $0.author?.login != currentUserLogin }
    }

    static func fetchReviewedByMePRs(currentUserLogin: String) async throws -> [PullRequest] {
        try await fetchSearchPRDetails(arguments: [
            "search", "prs",
            "--repo", AppSettings.repositorySlug,
            "--state", "open",
            "--reviewed-by", "@me",
            "--limit", "20",
            "--json", "number"
        ], currentUserLogin: currentUserLogin)
        .filter { !$0.isDraft && $0.author?.login != currentUserLogin }
        .sorted { lhs, rhs in
            if lhs.hasNewCommitsAfterMyReview != rhs.hasNewCommitsAfterMyReview { return lhs.hasNewCommitsAfterMyReview }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    private static func fetchSearchPRDetails(arguments: [String], currentUserLogin: String) async throws -> [PullRequest] {
        let task = Task.detached(priority: .userInitiated) {
            let output = try Shell.runGitHub(arguments, timeout: 20)
            let searchResults = try JSONDecoder().decode([SearchPullRequest].self, from: output)
            var prs: [PullRequest] = []

            for startIndex in stride(from: 0, to: searchResults.count, by: 4) {
                try Task.checkCancellation()
                let endIndex = min(startIndex + 4, searchResults.count)
                let batch = Array(searchResults[startIndex..<endIndex])
                let batchPRs = await withTaskGroup(of: PullRequest?.self) { group in
                    for result in batch {
                        group.addTask {
                            do {
                                var pr = try loadPullRequest(number: result.number, currentUserLogin: currentUserLogin)
                                pr.threadSummary = try? fetchThreadSummary(number: result.number)
                                return pr
                            } catch {
                                return nil
                            }
                        }
                    }

                    var loaded: [PullRequest] = []
                    for await pr in group {
                        if let pr { loaded.append(pr) }
                    }
                    return loaded
                }
                prs.append(contentsOf: batchPRs)
            }

            return prs
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func loadPullRequest(number: Int, currentUserLogin: String) throws -> PullRequest {
        let output = try Shell.runGitHub([
            "pr", "view", "\(number)",
            "--repo", AppSettings.repositorySlug,
            "--json", detailedPRFields
        ], timeout: 25)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var pr = try decoder.decode(PullRequest.self, from: output)
        pr.currentUserLogin = currentUserLogin
        return pr
    }

    static func fetchMergedPRs() async throws -> [MergedPullRequest] {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let latestDeployJobs = (try? fetchLatestDeploymentJobs()) ?? [:]
            let output = try Shell.runGitHub([
                "pr", "list",
                "--repo", AppSettings.repositorySlug,
                "--author", "@me",
                "--state", "merged",
                "--limit", "50",
                "--json", "number,title,url,headRefName,mergedAt,updatedAt,mergeCommit"
            ], timeout: 20)

            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let merged = try decoder.decode([MergedPullRequest].self, from: output)
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            var candidates = Array(
                merged
                    .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
                    .prefix(20)
            )

            var deploymentSummaries: [Int: DeploymentSummary] = [:]
            for startIndex in stride(from: 0, to: candidates.count, by: 4) {
                try Task.checkCancellation()
                let endIndex = min(startIndex + 4, candidates.count)
                let batch = Array(candidates[startIndex..<endIndex])
                let batchSummaries = await withTaskGroup(of: (Int, DeploymentSummary).self) { group in
                    for pr in batch {
                        group.addTask {
                            guard let sha = pr.mergeCommit?.oid, !sha.isEmpty else {
                                return (pr.number, DeploymentSummary(kind: .unknown, title: "Deploy", subtitle: "No merge commit", url: nil))
                            }

                            do {
                                return (pr.number, try fetchDeploymentSummary(sha: sha, latestDeployJobs: latestDeployJobs))
                            } catch {
                                return (pr.number, DeploymentSummary(kind: .unknown, title: "Deploy", subtitle: "Could not load deploy", url: nil))
                            }
                        }
                    }

                    var summaries: [Int: DeploymentSummary] = [:]
                    for await (number, summary) in group {
                        summaries[number] = summary
                    }
                    return summaries
                }
                deploymentSummaries.merge(batchSummaries) { current, _ in current }
            }

            for index in candidates.indices {
                candidates[index].deploymentSummary = deploymentSummaries[candidates[index].number]
            }

            return candidates
                .filter { pr in
                    let isRecent = (pr.mergedAt ?? .distantPast) >= cutoff
                    return isRecent || pr.needsDeploymentAttention
                }
                .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func fetchLatestDeploymentJobs() throws -> [String: DeployJobStatus] {
        let output = try Shell.runGitHub([
            "run", "list",
            "--repo", AppSettings.repositorySlug,
            "--branch", "main",
            "--limit", "60",
            "--json", "databaseId,workflowName,status,conclusion,createdAt,headSha"
        ], timeout: 20)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = try decoder.decode([WorkflowRun].self, from: output)
        var latest: [String: DeployJobStatus] = [:]
        let deployRuns = runs
            .filter { ($0.workflowName ?? "").lowercased().hasPrefix("deploy") }
            .prefix(24)
        var seenShas = Set<String>()
        let shas = deployRuns.compactMap { run -> String? in
            guard let sha = run.headSha, !sha.isEmpty, !seenShas.contains(sha) else { return nil }
            seenShas.insert(sha)
            return sha
        }.prefix(8)

        for sha in shas {
            let checks = (try? fetchCommitCheckRuns(sha: sha)) ?? []
            for check in checks where check.isDeploymentRelated && !check.isSkipped {
                let status = check.deployJobStatus
                guard !status.key.isEmpty else { continue }
                if let current = latest[status.key], let currentDate = current.observedAt, let statusDate = status.observedAt, currentDate >= statusDate {
                    continue
                }
                latest[status.key] = status
            }
        }

        return latest
    }

    private static func fetchCommitCheckRuns(sha: String) throws -> [CommitCheckRun] {
        let output = try Shell.runGitHub([
            "api", "repos/\(AppSettings.repositorySlug)/commits/\(sha)/check-runs?per_page=100"
        ], timeout: 20)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CheckRunsResponse.self, from: output).checkRuns
    }

    private static func fetchDeploymentSummary(sha: String, latestDeployJobs: [String: DeployJobStatus]) throws -> DeploymentSummary {
        let deployChecks = try fetchCommitCheckRuns(sha: sha).filter(\.isDeploymentRelated)

        guard !deployChecks.isEmpty else {
            return DeploymentSummary(kind: .unknown, title: "Deploy", subtitle: "Waiting for deploy checks", url: nil)
        }

        var recoveredTargets: [String] = []
        var effectiveProblems: [DeployJobStatus] = []

        for check in deployChecks where check.isFailed || check.isRunning {
            let original = check.deployJobStatus
            if let latest = latestDeployJobs[original.key], latest.isNewer(than: original.observedAt) {
                if latest.kind == .passing {
                    recoveredTargets.append(original.key)
                    continue
                }
                if latest.kind == .failing || latest.kind == .running {
                    effectiveProblems.append(latest)
                    continue
                }
            }
            effectiveProblems.append(original)
        }

        if let failed = effectiveProblems.first(where: { $0.kind == .failing }) {
            return failed.summary
        }

        if let running = effectiveProblems.first(where: { $0.kind == .running }) {
            return running.summary
        }

        if let recovered = recoveredTargets.first {
            return DeploymentSummary(
                kind: .passing,
                title: "Recovered",
                subtitle: "Latest \(recovered) deploy succeeded",
                url: latestDeployJobs[recovered]?.url
            )
        }

        let successful = deployChecks.filter(\.isSuccessful)
        if let firstSuccess = successful.first {
            let subtitle = successful.count == 1 ? firstSuccess.displayName : "\(successful.count) deploy jobs succeeded"
            return DeploymentSummary(kind: .passing, title: "Deployed", subtitle: subtitle, url: firstSuccess.htmlUrl)
        }

        if deployChecks.allSatisfy(\.isSkipped) {
            return DeploymentSummary(kind: .unknown, title: "No deploy", subtitle: "No affected deploy jobs", url: deployChecks.first?.htmlUrl)
        }

        return DeploymentSummary(kind: .unknown, title: "Deploy", subtitle: "Waiting for deploy result", url: deployChecks.first?.htmlUrl)
    }

    static func squashMerge(_ pr: PullRequest) async throws {
        try ensureOwnPR(pr, action: "Squash merge")
        let task = Task.detached(priority: .userInitiated) {
            _ = try Shell.runGitHub([
                "pr", "merge", "\(pr.number)",
                "--repo", AppSettings.repositorySlug,
                "--squash",
                "--delete-branch",
                "--subject", pr.title,
                "--body", ""
            ], timeout: 120)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func rebase(_ pr: PullRequest) async throws {
        try ensureOwnPR(pr, action: "Rebase")
        let task = Task.detached(priority: .userInitiated) {
            _ = try Shell.runGitHub([
                "pr", "update-branch", "\(pr.number)",
                "--repo", AppSettings.repositorySlug,
                "--rebase"
            ], timeout: 120)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func markReady(_ pr: PullRequest) async throws {
        try ensureOwnPR(pr, action: "Mark ready")
        let task = Task.detached(priority: .userInitiated) {
            _ = try Shell.runGitHub([
                "pr", "ready", "\(pr.number)",
                "--repo", AppSettings.repositorySlug
            ], timeout: 45)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func convertToDraft(_ pr: PullRequest) async throws {
        try ensureOwnPR(pr, action: "Convert to draft")
        let task = Task.detached(priority: .userInitiated) {
            _ = try Shell.runGitHub([
                "pr", "ready", "\(pr.number)",
                "--repo", AppSettings.repositorySlug,
                "--undo"
            ], timeout: 45)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func ensureOwnPR(_ pr: PullRequest, action: String) throws {
        guard pr.isMine else {
            throw NSError(domain: "ArbioPRMenu.GitHub", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(action) is only available for your own PRs."])
        }
    }

    private static func fetchThreadSummary(number: Int) throws -> ThreadSummary {
        let query = """
        query($owner:String!, $name:String!, $number:Int!) {
          repository(owner:$owner, name:$name) {
            pullRequest(number:$number) {
              reviewThreads(first:100) {
                nodes { isResolved isOutdated }
              }
            }
          }
        }
        """

        let repository = repositoryParts
        let output = try Shell.runGitHub([
            "api", "graphql",
            "-f", "owner=\(repository.owner)",
            "-f", "name=\(repository.name)",
            "-F", "number=\(number)",
            "-f", "query=\(query)"
        ], timeout: 20)

        let response = try JSONDecoder().decode(ThreadResponse.self, from: output)
        let nodes = response.data.repository.pullRequest.reviewThreads.nodes
        let unresolved = nodes.filter { !$0.isResolved && !$0.isOutdated }.count
        return ThreadSummary(unresolved: unresolved, total: nodes.count)
    }
}

struct ThreadResponse: Decodable {
    let data: ThreadData
}

struct ThreadData: Decodable {
    let repository: ThreadRepository
}

struct ThreadRepository: Decodable {
    let pullRequest: ThreadPullRequest
}

struct ThreadPullRequest: Decodable {
    let reviewThreads: ReviewThreadConnection
}

struct ReviewThreadConnection: Decodable {
    let nodes: [ReviewThreadNode]
}

struct ReviewThreadNode: Decodable {
    let isResolved: Bool
    let isOutdated: Bool
}

struct CheckRunsResponse: Decodable {
    let checkRuns: [CommitCheckRun]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

struct WorkflowRun: Decodable {
    let databaseId: Int64?
    let workflowName: String?
    let status: String?
    let conclusion: String?
    let createdAt: Date?
    let headSha: String?
}

struct WorkflowJobsResponse: Decodable {
    let jobs: [WorkflowJob]
}

struct WorkflowJob: Decodable {
    let name: String?
    let status: String?
    let conclusion: String?
    let url: String?
    let startedAt: Date?
    let completedAt: Date?

    var displayName: String {
        truncateDeployName(name ?? "Deploy")
    }

    var observedAt: Date? {
        completedAt ?? startedAt
    }

    var isDeploymentRelated: Bool {
        isDeployName(name)
    }

    var isRunning: Bool {
        (status ?? "").lowercased() != "completed"
    }

    var isFailed: Bool {
        isFailedConclusion(conclusion)
    }

    var isSuccessful: Bool {
        (status ?? "").lowercased() == "completed" && (conclusion ?? "").lowercased() == "success"
    }

    var isSkipped: Bool {
        (status ?? "").lowercased() == "completed" && (conclusion ?? "").lowercased() == "skipped"
    }

    var deployJobStatus: DeployJobStatus {
        let kind: BadgeKind
        let title: String
        if isFailed {
            kind = .failing
            title = "Deploy failed"
        } else if isRunning {
            kind = .running
            title = "Deploying"
        } else if isSuccessful {
            kind = .passing
            title = "Deployed"
        } else {
            kind = .unknown
            title = "Deploy"
        }

        return DeployJobStatus(
            key: deployTargetKey(from: name),
            kind: kind,
            title: title,
            subtitle: displayName,
            url: url,
            observedAt: observedAt
        )
    }
}

struct CommitCheckRun: Decodable {
    let name: String?
    let status: String?
    let conclusion: String?
    let htmlUrl: String?
    let startedAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case conclusion
        case htmlUrl = "html_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    var displayName: String {
        truncateDeployName(name ?? "Deploy")
    }

    var observedAt: Date? {
        completedAt ?? startedAt
    }

    var isDeploymentRelated: Bool {
        isDeployName(name)
    }

    var isRunning: Bool {
        let value = (status ?? "").lowercased()
        return value != "completed"
    }

    var isFailed: Bool {
        isFailedConclusion(conclusion)
    }

    var isSuccessful: Bool {
        (status ?? "").lowercased() == "completed" && (conclusion ?? "").lowercased() == "success"
    }

    var isSkipped: Bool {
        (status ?? "").lowercased() == "completed" && (conclusion ?? "").lowercased() == "skipped"
    }

    var deployJobStatus: DeployJobStatus {
        let kind: BadgeKind
        let title: String
        if isFailed {
            kind = .failing
            title = "Deploy failed"
        } else if isRunning {
            kind = .running
            title = "Deploying"
        } else if isSuccessful {
            kind = .passing
            title = "Deployed"
        } else {
            kind = .unknown
            title = "Deploy"
        }

        return DeployJobStatus(
            key: deployTargetKey(from: name),
            kind: kind,
            title: title,
            subtitle: displayName,
            url: htmlUrl,
            observedAt: observedAt
        )
    }
}

private func truncateDeployName(_ value: String) -> String {
    value.count > 44 ? String(value.prefix(41)) + "..." : value
}

private func isFailedConclusion(_ conclusion: String?) -> Bool {
    ["failure", "cancelled", "timed_out", "action_required", "startup_failure"].contains((conclusion ?? "").lowercased())
}

private func isDeployName(_ name: String?) -> Bool {
    let value = (name ?? "").lowercased()
    if value.contains("detect affected deployables") { return false }
    return value.contains("deploy") || value.contains("deployment") || value.contains("vercel")
}

private func deployTargetKey(from name: String?) -> String {
    let raw = (name ?? "deploy").lowercased()
    let normalized = " " + raw.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression) + " "

    if normalized.contains(" deploy backend legacy ") || normalized.contains(" backend legacy ") { return "backend-legacy" }

    for target in ["pms", "dms", "rms", "nms", "nas", "tos"] {
        if normalized.contains(" deploy \(target) ") || normalized.contains(" \(target) to ") || normalized.contains(" \(target) ") {
            return target
        }
    }

    if normalized.contains(" deploy nexus ") || normalized.contains(" nexus ") { return "nexus" }
    if normalized.contains(" infra ") { return "infra" }

    return normalized.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
}

enum Shell {
    static func runGitHub(_ arguments: [String], timeout: TimeInterval = 45) throws -> Data {
        try runExecutable(findGitHubCLI(), arguments, timeout: timeout)
    }

    static func runCommand(_ command: String, _ arguments: [String], currentDirectory: URL? = nil, timeout: TimeInterval = 45) throws -> Data {
        try runExecutable("/usr/bin/env", [command] + arguments, currentDirectory: currentDirectory, timeout: timeout)
    }

    private static func runExecutable(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil, timeout: TimeInterval) throws -> Data {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = NSHomeDirectory()
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputLock = NSLock()
        let errorLock = NSLock()
        var output = Data()
        var error = Data()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            output.append(chunk)
            outputLock.unlock()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errorLock.lock()
            error.append(chunk)
            errorLock.unlock()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()

        var didTimeout = false
        var didCancel = false
        let deadline = Date().addingTimeInterval(timeout)

        waitLoop: while true {
            switch finished.wait(timeout: .now() + .milliseconds(200)) {
            case .success:
                break waitLoop
            case .timedOut:
                if Task.isCancelled {
                    didCancel = true
                    break waitLoop
                }
                if Date() >= deadline {
                    didTimeout = true
                    break waitLoop
                }
            }
        }

        if didTimeout || didCancel {
            stop(process: process, finished: finished)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let finalOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let finalError = errorPipe.fileHandleForReading.readDataToEndOfFile()
        outputLock.lock()
        output.append(finalOutput)
        outputLock.unlock()
        errorLock.lock()
        error.append(finalError)
        errorLock.unlock()

        if didCancel {
            throw CancellationError()
        }

        if didTimeout {
            throw NSError(
                domain: "ArbioPRMenu.Shell",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "\(commandDescription(executable, arguments)) timed out after \(Int(timeout))s"]
            )
        }

        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            let message = String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ArbioPRMenu.Shell",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "\(executable) exited with status \(process.terminationStatus)"]
            )
        }

        return output
    }

    private static func stop(process: Process, finished: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }

        if finished.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + .seconds(2))
        }
    }

    private static func commandDescription(_ executable: String, _ arguments: [String]) -> String {
        let command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        return command.count > 180 ? String(command.prefix(177)) + "..." : command
    }

    private static func findGitHubCLI() -> String {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return "/opt/homebrew/bin/gh"
    }
}

enum PRListScope: String, CaseIterable, Identifiable, Hashable {
    case action
    case active
    case review
    case waiting
    case drafts
    case merged

    var id: String { rawValue }

    func title(count: Int) -> String {
        switch self {
        case .action: return "Action \(count)"
        case .active: return "Mine \(count)"
        case .review: return "Review \(count)"
        case .waiting: return "Wait \(count)"
        case .drafts: return "Drafts \(count)"
        case .merged: return "Merged \(count)"
        }
    }
}

struct PRMenuView: View {
    @ObservedObject var store: PRStore
    @State private var selectedScope: PRListScope = .action

    private var activePRs: [PullRequest] { store.prs.filter { !$0.isDraft } }
    private var draftPRs: [PullRequest] { store.prs.filter { $0.isDraft } }
    private var waitingReviewPRs: [PullRequest] { activePRs.filter(\.isWaitingOnReview) }
    private var actionPRs: [PullRequest] { store.prs.filter(\.needsMyAction) }
    private var stalePRs: [PullRequest] { store.prs.filter { ($0.isStaleOpen || $0.isStaleDraft) && !$0.needsMyAction } }
    private var deploymentWatchPRs: [MergedPullRequest] { store.mergedPRs.filter(\.needsDeploymentAttention) }
    private var reviewRadarPRs: [PullRequest] { store.reviewPRs + store.reviewedPRs.filter(\.hasNewCommitsAfterMyReview) }
    private var visibleOpenPRs: [PullRequest] { selectedScope == .active ? activePRs : draftPRs }
    private var hasAnyData: Bool { !store.prs.isEmpty || !store.mergedPRs.isEmpty || !store.reviewPRs.isEmpty || !store.reviewedPRs.isEmpty }
    private var openCount: Int { activePRs.count }
    private var draftCount: Int { draftPRs.count }
    private var mergedCount: Int { store.mergedPRs.count }
    private var actionCount: Int { actionPRs.count + stalePRs.count + deploymentWatchPRs.count + reviewRadarPRs.count }
    private var reviewCount: Int { reviewRadarPRs.count }
    private var waitingCount: Int { waitingReviewPRs.count }
    private var approvedCount: Int { activePRs.filter { $0.reviewSummary.kind == .passing }.count }
    private var runningCount: Int { activePRs.filter { $0.ciSummary.kind == .running }.count + store.mergedPRs.filter(\.isDeploying).count }
    private var blockedCount: Int { activePRs.filter { $0.mergeSummary.kind == .waiting || $0.mergeSummary.kind == .failing }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            SoftDivider()
            content
            SoftDivider()
            footer
        }
        .frame(width: 580, height: 700)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arbio PRs")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .tracking(-0.5)
                    Text(lastUpdatedText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Label(headerStatusText, systemImage: headerStatusSymbol)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(headerStatusColor)
                }

                Spacer()

                Button {
                    store.refresh(force: true)
                } label: {
                    HStack(spacing: 7) {
                        if store.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.62)
                                .frame(width: 13, height: 13)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        Text(store.isLoading ? "Syncing" : "Sync")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .frame(width: 82, height: 30)
                }
                .buttonStyle(.plain)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                SummaryPill(value: "\(actionCount)", label: "Action")
                SummaryPill(value: "\(openCount)", label: "Mine")
                SummaryPill(value: "\(reviewCount)", label: "Review")
                SummaryPill(value: "\(waitingCount)", label: "Waiting")
                SummaryPill(value: "\(mergedCount)", label: "Merged")
                SummaryPill(value: "\(draftCount)", label: "Drafts")
            }

            Picker("PR scope", selection: $selectedScope) {
                ForEach(PRListScope.allCases) { scope in
                    Text(scope.title(count: count(for: scope))).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var headerStatusText: String {
        let user = store.currentUserLogin ?? "GitHub user"
        let write = store.writeActionsEnabled ? "write actions on" : "read-only"
        let rebase = store.writeActionsEnabled && store.autoRebaseEnabled ? "auto-rebase on" : "auto-rebase off"
        return "\(user) · \(write) · \(rebase)"
    }

    private var headerStatusSymbol: String {
        store.writeActionsEnabled ? "bolt.horizontal.circle.fill" : "lock.circle.fill"
    }

    private var headerStatusColor: Color {
        store.writeActionsEnabled ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
    }

    private func count(for scope: PRListScope) -> Int {
        switch scope {
        case .action: return actionCount
        case .active: return activePRs.count
        case .review: return reviewCount
        case .waiting: return waitingReviewPRs.count
        case .drafts: return draftPRs.count
        case .merged: return store.mergedPRs.count
        }
    }

    private var activeEmptySubtitle: String {
        if draftCount > 0 { return "Only draft PRs are open right now." }
        if mergedCount > 0 { return "No open active PRs. Check Merged for the last 24h." }
        return "No active PRs are open right now."
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = store.errorMessage, !hasAnyData {
            errorState(message: errorMessage)
        } else if !hasAnyData && store.isLoading {
            loadingState
        } else {
            VStack(spacing: 0) {
                if let errorMessage = store.errorMessage {
                    ErrorBanner(message: errorMessage) {
                        store.refresh(force: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                }

                if !hasAnyData {
                    emptyState(
                        icon: "checkmark.seal",
                        color: Color(nsColor: .systemGreen),
                        title: "No PRs",
                        subtitle: "No open PRs, review requests, or merged PRs from the last 24 hours."
                    )
                } else {
                    scopedContent
                }
            }
        }
    }

    @ViewBuilder
    private var scopedContent: some View {
        switch selectedScope {
        case .action:
            actionContent
        case .active, .drafts:
            openPRContent
        case .review:
            reviewContent
        case .waiting:
            waitingContent
        case .merged:
            mergedContent
        }
    }

    private var actionContent: some View {
        let hasActions = !actionPRs.isEmpty || !deploymentWatchPRs.isEmpty || !reviewRadarPRs.isEmpty || !stalePRs.isEmpty
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !hasActions {
                    emptyState(
                        icon: "checkmark.seal",
                        color: Color(nsColor: .systemGreen),
                        title: "No action needed",
                        subtitle: "Nothing is red, stuck, stale, or waiting for you right now."
                    )
                    .frame(height: 360)
                } else {
                    if !actionPRs.isEmpty {
                        SectionHeader(title: "Your action needed", subtitle: "CI, rebase, conflicts, threads, or stale drafts")
                        ForEach(actionPRs) { pr in
                            PRRow(pr: pr, store: store, contextLabel: pr.actionReason)
                        }
                    }
                    if !deploymentWatchPRs.isEmpty {
                        SectionHeader(title: "Post-merge deploy watch", subtitle: "Merged PRs not safely deployed yet")
                        ForEach(deploymentWatchPRs) { pr in
                            MergedPRRow(pr: pr)
                        }
                    }
                    if !reviewRadarPRs.isEmpty {
                        SectionHeader(title: "Review radar", subtitle: "PRs waiting for you or updated after your review")
                        ForEach(reviewRadarPRs) { pr in
                            ReviewPRRow(pr: pr)
                        }
                    }
                    if !stalePRs.isEmpty {
                        SectionHeader(title: "Stale cleanup", subtitle: "Old open or draft PRs worth closing out")
                        ForEach(stalePRs) { pr in
                            PRRow(pr: pr, store: store, contextLabel: pr.isDraft ? "Draft older than 2d" : "Open older than 3d")
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var openPRContent: some View {
        if visibleOpenPRs.isEmpty {
            emptyState(
                icon: selectedScope == .active ? "checkmark.seal" : "doc.badge.clock",
                color: selectedScope == .active ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor),
                title: selectedScope == .active ? "No active PRs" : "No draft PRs",
                subtitle: selectedScope == .active ? activeEmptySubtitle : "Draft PRs will show here when they are not ready for review yet."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleOpenPRs) { pr in
                        PRRow(pr: pr, store: store)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if reviewRadarPRs.isEmpty {
            emptyState(
                icon: "person.crop.circle.badge.checkmark",
                color: Color(nsColor: .systemGreen),
                title: "No review work",
                subtitle: "No open teammate PRs are waiting for your review."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !store.reviewPRs.isEmpty {
                        SectionHeader(title: "Needs your review", subtitle: "Review requested from you")
                        ForEach(store.reviewPRs) { pr in
                            ReviewPRRow(pr: pr)
                        }
                    }
                    let updated = store.reviewedPRs.filter(\.hasNewCommitsAfterMyReview)
                    if !updated.isEmpty {
                        SectionHeader(title: "Updated after your review", subtitle: "Author pushed commits after your last review")
                        ForEach(updated) { pr in
                            ReviewPRRow(pr: pr)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var waitingContent: some View {
        if waitingReviewPRs.isEmpty {
            emptyState(
                icon: "clock.badge.checkmark",
                color: Color(nsColor: .secondaryLabelColor),
                title: "Nothing waiting",
                subtitle: "None of your active PRs are only waiting on human review."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(waitingReviewPRs) { pr in
                        PRRow(pr: pr, store: store, contextLabel: "Waiting on \(pr.reviewRequestNames)")
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var mergedContent: some View {
        if store.mergedPRs.isEmpty {
            emptyState(
                icon: "arrow.triangle.merge",
                color: Color(nsColor: .secondaryLabelColor),
                title: "No merged PRs",
                subtitle: "Your merged PRs from the last 24 hours, plus any still-broken deploys, will show here."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.mergedPRs) { pr in
                        MergedPRRow(pr: pr)
                    }
                }
                .padding(12)
            }
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Syncing with GitHub", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Loading open PRs, checks, reviews, and thread status.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text("Could not load PRs")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Try again") { store.refresh(force: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: .secondaryLabelColor))
                .frame(width: 5, height: 5)
            Text("Repo: \(AppSettings.repositorySlug) · rows open GitHub")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Toggle("Write actions", isOn: $store.writeActionsEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11, weight: .medium))
            Toggle("Auto-rebase", isOn: $store.autoRebaseEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11, weight: .medium))
                .disabled(!store.writeActionsEnabled)
            Button("Open repo") {
                openURL("https://github.com/\(AppSettings.repositorySlug)/pulls")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var lastUpdatedText: String {
        if store.isLoading && store.lastUpdated == nil { return "Connecting to GitHub..." }
        guard let lastUpdated = store.lastUpdated else { return "Not updated yet" }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Updated \(formatter.string(from: lastUpdated))"
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Last sync failed")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
        }
        .padding(10)
        .background(Color(nsColor: .systemOrange).opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color(nsColor: .systemOrange).opacity(0.18), lineWidth: 0.5)
        )
    }
}

struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }
}

struct SummaryPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DraftBadge: View {
    var body: some View {
        Text("DRAFT")
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .secondaryLabelColor).opacity(0.11), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .secondaryLabelColor).opacity(0.18), lineWidth: 0.5)
            )
    }
}

private func relativeTimeDescription(since date: Date?) -> String {
    guard let date else { return "recently" }
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    return "\(hours)h ago"
}

private func shortTimeDescription(_ date: Date?) -> String {
    guard let date else { return "unknown time" }
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

struct ReviewPRRow: View {
    let pr: PullRequest
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                openURL(pr.url)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 3) {
                        Text("#\(pr.number)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Circle()
                            .fill(pr.hasNewCommitsAfterMyReview ? Color(nsColor: .systemOrange) : Color(nsColor: .controlAccentColor))
                            .frame(width: 5, height: 5)
                    }
                    .frame(width: 48)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pr.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("by \(pr.authorName) · \(pr.headRefName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                StatusChip(summary: BadgeSummary(
                    kind: pr.hasNewCommitsAfterMyReview ? .running : .waiting,
                    title: pr.hasNewCommitsAfterMyReview ? "Updated" : "Review needed",
                    subtitle: pr.hasNewCommitsAfterMyReview ? "New commits after review" : "Requested from you"
                ))
                StatusChip(summary: pr.ciSummary)
            }

            HStack(spacing: 8) {
                Button("Open PR") { openURL(pr.url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .controlAccentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let checkURL = pr.primaryCheckURL {
                    Button("Open check") { openURL(checkURL) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }

                Spacer(minLength: 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(isHovering ? 0.11 : 0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 12 : 7, x: 0, y: isHovering ? 6 : 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open PR") { openURL(pr.url) }
            if let checkURL = pr.primaryCheckURL {
                Button("Open check") { openURL(checkURL) }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
        }
    }
}

struct MergedPRRow: View {
    let pr: MergedPullRequest
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                openURL(pr.url)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 3) {
                        Text("#\(pr.number)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Circle()
                            .fill(Color(nsColor: .systemGreen))
                            .frame(width: 5, height: 5)
                    }
                    .frame(width: 48)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pr.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(pr.headRefName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                StatusChip(summary: BadgeSummary(
                    kind: .passing,
                    title: "Merged \(relativeTimeDescription(since: pr.mergedAt))",
                    subtitle: shortTimeDescription(pr.mergedAt)
                ))
                DeploymentStatusChip(summary: pr.deploymentSummary)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 8)

                Button("Open PR") {
                    openURL(pr.url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlAccentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .controlAccentColor).opacity(0.18), lineWidth: 0.5)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(isHovering ? 0.11 : 0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 12 : 7, x: 0, y: isHovering ? 6 : 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open PR") { openURL(pr.url) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
        }
    }

    private var rowBackground: Color {
        isHovering ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.7)
    }
}

struct PRRow: View {
    let pr: PullRequest
    @ObservedObject var store: PRStore
    var contextLabel: String? = nil
    @State private var isHovering = false
    @State private var isConfirmingMerge = false
    @State private var isConfirmingRebase = false

    private var mergeState: MergeState { store.mergeStates[pr.number] ?? .idle }
    private var rebaseState: RebaseState { store.rebaseStates[pr.number] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                openURL(pr.url)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 3) {
                        Text("#\(pr.number)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Circle()
                            .fill(pr.ciSummary.kind.dotColor)
                            .frame(width: 5, height: 5)
                    }
                    .frame(width: 48)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(pr.title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if pr.isDraft {
                                DraftBadge()
                            }
                        }
                        Text(pr.headRefName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                StatusChip(summary: pr.ciSummary)
                StatusChip(summary: pr.reviewSummary)
                StatusChip(summary: pr.mergeSummary)
                StatusChip(summary: pr.threadBadge)
            }

            if let contextLabel {
                Label(contextLabel, systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                mergeStatusView
                Spacer(minLength: 8)
                Button {
                    guard !mergeState.isWorking else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        isConfirmingRebase = false
                        isConfirmingMerge.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if mergeState.isWorking {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: pr.isDraft ? "doc.badge.clock" : (pr.isSquashMergeReady ? "arrow.triangle.merge" : "lock"))
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(mergeButtonTitle)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canUseWriteActions && pr.isSquashMergeReady ? Color.white : Color(nsColor: .secondaryLabelColor))
                .background(mergeButtonBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(pr.isSquashMergeReady ? 0 : 0.55), lineWidth: 0.5)
                )
                .disabled(mergeState.isWorking)

                if shouldShowRebaseButton {
                    Button {
                        guard !rebaseState.isWorking else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            isConfirmingMerge = false
                            isConfirmingRebase.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if rebaseState.isWorking {
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            Text(rebaseButtonTitle)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canUseWriteActions ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor))
                    .background((canUseWriteActions ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor)).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(nsColor: .controlAccentColor).opacity(0.18), lineWidth: 0.5)
                    )
                    .disabled(rebaseState.isWorking || mergeState.isWorking)
                }
            }

            if isConfirmingRebase {
                rebaseConfirmationPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isConfirmingMerge {
                mergeConfirmationPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(isHovering ? 0.11 : 0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 12 : 7, x: 0, y: isHovering ? 6 : 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open PR") { openURL(pr.url) }
            Button("Open checks") { openURL("\(pr.url)/checks") }
            if let checkURL = pr.primaryCheckURL {
                Button("Open failing or running check") { openURL(checkURL) }
            }
            Button("Copy review request") {
                copyToPasteboard("Review request: #\(pr.number) \(pr.title)\n\(pr.url)")
            }
            if pr.isMine {
                if pr.isDraft {
                    Button("Mark ready for review") { store.markReady(pr) }
                        .disabled(!store.writeActionsEnabled)
                } else {
                    Button("Convert to draft") { store.convertToDraft(pr) }
                        .disabled(!store.writeActionsEnabled)
                }
            }
            Button("Copy URL") {
                copyToPasteboard(pr.url)
            }
        }
    }

    private var rowBackground: Color {
        if isHovering { return Color(nsColor: .windowBackgroundColor) }
        if pr.isDraft { return Color(nsColor: .controlBackgroundColor).opacity(0.52) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.78)
    }

    private var mergeButtonTitle: String {
        switch mergeState {
        case .idle:
            if !store.writeActionsEnabled { return "Read-only" }
            if !pr.isMine { return "Not yours" }
            if pr.isDraft { return "Draft" }
            return pr.isSquashMergeReady ? "Squash merge" : "Details"
        case .merging:
            return "Merging"
        case .merged:
            return "Merged"
        case .failed:
            return "Retry merge"
        }
    }

    private var shouldShowRebaseButton: Bool {
        pr.needsRebase || rebaseState != .idle
    }

    private var rebaseButtonTitle: String {
        switch rebaseState {
        case .idle:
            return "Rebase"
        case .rebasing:
            return "Rebasing"
        case .autoRebasing:
            return "Auto-rebasing"
        case .rebased:
            return "Rebased"
        case .failed:
            return "Retry rebase"
        }
    }

    private var canUseWriteActions: Bool {
        store.writeActionsEnabled && pr.isMine
    }

    private var mergeButtonBackground: Color {
        if canUseWriteActions && pr.isSquashMergeReady {
            return Color(nsColor: .controlAccentColor)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(0.72)
    }

    @ViewBuilder
    private var rebaseConfirmationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(canUseWriteActions ? "Rebase branch" : "Write actions disabled", systemImage: canUseWriteActions ? "arrow.triangle.2.circlepath" : "lock.fill")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(canUseWriteActions ? Color(nsColor: .controlAccentColor) : Color(nsColor: .systemOrange))

            Text(canUseWriteActions ? "This asks GitHub to rebase #\(pr.number) onto \(pr.baseRefName ?? "main") using branch protection aware update-branch." : "Turn on Write actions in the footer before rebasing. Actions are limited to your own PRs.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = rebaseState {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        isConfirmingRebase = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                if canUseWriteActions {
                    Button {
                        isConfirmingRebase = false
                        store.rebase(pr)
                    } label: {
                        Label("Confirm rebase", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .controlAccentColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .padding(12)
        .background((canUseWriteActions ? Color(nsColor: .controlAccentColor) : Color(nsColor: .systemOrange)).opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke((canUseWriteActions ? Color(nsColor: .controlAccentColor) : Color(nsColor: .systemOrange)).opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var mergeConfirmationPanel: some View {
        if !canUseWriteActions {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Read-only mode")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text("Turn on Write actions in the footer to merge, rebase, or change draft state. Actions are limited to your own PRs.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .systemOrange).opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(nsColor: .systemOrange).opacity(0.18), lineWidth: 0.5)
            )
        } else if pr.isSquashMergeReady {
            VStack(alignment: .leading, spacing: 10) {
                Label("Confirm squash merge", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(nsColor: .systemOrange))

                Text("This will squash #\(pr.number) into main and delete the branch.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Cancel") {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            isConfirmingMerge = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button {
                        isConfirmingMerge = false
                        store.squashMerge(pr)
                    } label: {
                        Label("Confirm squash", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .systemRed), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(12)
            .background(Color(nsColor: .systemOrange).opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(nsColor: .systemOrange).opacity(0.18), lineWidth: 0.5)
            )
        } else {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Can’t merge yet")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text(pr.mergeReadinessLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open checks") {
                    openURL("\(pr.url)/checks")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var mergeStatusView: some View {
        switch mergeState {
        case .idle:
            if pr.isDraft {
                Label("Draft", systemImage: "doc.badge.clock")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } else {
                Label(pr.isSquashMergeReady ? "Ready" : "Blocked", systemImage: pr.isSquashMergeReady ? "checkmark.seal.fill" : "hourglass")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(pr.isSquashMergeReady ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
            }
        case .merging:
            Label("Squash merging…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
        case .merged:
            Label("Merged", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(nsColor: .systemRed))
                .lineLimit(1)
        }
    }
}

struct DeploymentStatusChip: View {
    let summary: DeploymentSummary?

    private var badge: BadgeSummary {
        guard let summary else {
            return BadgeSummary(kind: .unknown, title: "Deploy", subtitle: "Checking deployment")
        }
        return BadgeSummary(kind: summary.kind, title: summary.title, subtitle: summary.subtitle)
    }

    var body: some View {
        Button {
            if let url = summary?.url {
                openURL(url)
            }
        } label: {
            StatusChip(summary: badge)
        }
        .buttonStyle(.plain)
    }
}

struct StatusChip: View {
    let summary: BadgeSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: summary.kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(summary.kind.dotColor)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(summary.kind.dotColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(summary.kind.dotColor.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
