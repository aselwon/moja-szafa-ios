import Combine
import Foundation

@MainActor
final class WardrobeModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case empty
        case loaded([Garment])
        case backendNotConfigured
        case offline
        case failed
    }

    @Published private(set) var state: State = .idle
    private let repository: any WardrobeRepository

    init(repository: any WardrobeRepository) {
        self.repository = repository
    }

    func load() async {
        guard state != .loading else { return }
        let previousState = state
        state = .loading
        do {
            let garments = try await repository.garments()
            try Task.checkCancellation()
            state = garments.isEmpty ? .empty : .loaded(garments)
        } catch {
            // Disappearing views cancel their task; cancellation is not a UI error.
            if Task.isCancelled || error is CancellationError {
                state = previousState
            } else if error as? RepositoryError == .backendNotConfigured {
                state = .backendNotConfigured
            } else if let error = error as? URLError,
                      [.notConnectedToInternet, .networkConnectionLost].contains(error.code) {
                state = .offline
            } else {
                state = .failed
            }
        }
    }
}
