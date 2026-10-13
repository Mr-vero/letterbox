import Foundation

enum NetError: LocalizedError {
    case connectionFailed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): return "Couldn’t reach the server. \(reason)"
        case .closed: return "The connection to the server was closed."
        }
    }
}

/// FIFO async lock so one connection only ever runs one command at a time.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
