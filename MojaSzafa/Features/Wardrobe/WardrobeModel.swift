import Combine
import Foundation

@MainActor
final class WardrobeModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, empty, loaded([Garment]), backendNotConfigured, offline, failed
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var items: [Garment] = []
    @Published private(set) var nextOffset: Int?
    @Published private(set) var cached = false
    @Published private(set) var loadingMore = false
    @Published private(set) var pageFailed = false
    @Published private(set) var pageOffline = false
    @Published var query = WardrobeQuery()
    let repository: any WardrobeRepository
    private var generation = UUID()
    private var activeQuery = WardrobeQuery()

    init(repository: any WardrobeRepository) { self.repository = repository }

    func load() async {
        // A changed query supersedes an in-flight page. A duplicate refresh does not.
        guard !Task.isCancelled, state != .loading || activeQuery != query else { return }
        await reload()
    }

    func loadQuery() async {
        // Initial display, navigation returns and filter changes load immediately.
        // Only typing is debounced; SwiftUI cancels this task for newer queries.
        let requested = query
        if requested.search != activeQuery.search {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard requested == query, !Task.isCancelled else { return }
        // A new view task replaces its cancelled predecessor, including a return
        // from navigation while the old repository call has not finished yet.
        await reload()
    }

    func reload() async {
        let requestID = UUID()
        generation = requestID
        activeQuery = query
        let previousState = state
        state = .loading
        items = []; nextOffset = nil; pageFailed = false; pageOffline = false; loadingMore = false; cached = false
        do {
            let page = try await repository.page(query: query, offset: 0, limit: 40)
            try Task.checkCancellation()
            guard generation == requestID else { return }
            items = page.items; nextOffset = page.nextOffset; cached = page.cached
            state = items.isEmpty ? .empty : .loaded(items)
        } catch {
            guard generation == requestID else { return }
            if Task.isCancelled || error is CancellationError {
                state = previousState
                if case .loaded(let old) = previousState { items = old }
            } else if error as? RepositoryError == .backendNotConfigured { state = .backendNotConfigured }
            else if let error = error as? URLError,
                    [.notConnectedToInternet, .networkConnectionLost].contains(error.code) { state = .offline }
            else { state = .failed }
        }
    }

    func loadMore() async {
        guard activeQuery == query, !loadingMore, let offset = nextOffset else { return }
        let requestID = generation
        loadingMore = true; pageFailed = false; pageOffline = false
        do {
            let page = try await repository.page(query: query, offset: offset, limit: 40)
            try Task.checkCancellation()
            guard generation == requestID else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            nextOffset = page.nextOffset; cached = page.cached
            state = .loaded(items)
        } catch {
            guard generation == requestID else { return }
            if !Task.isCancelled && !(error is CancellationError) {
                pageFailed = true
                if let network = error as? URLError {
                    pageOffline = [.notConnectedToInternet, .networkConnectionLost].contains(network.code)
                }
            }
        }
        if generation == requestID { loadingMore = false }
    }
}
