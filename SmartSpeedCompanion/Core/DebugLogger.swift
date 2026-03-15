import Foundation
import Combine

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String
    
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

@MainActor
public final class DebugLogger: ObservableObject {
    public static let shared = DebugLogger()
    
    @Published public private(set) var logs: [LogEntry] = []
    private let maxLogs = 500
    
    private init() {}
    
    public func log(_ message: String) {
        #if DEVELOPER_BUILD
        let entry = LogEntry(timestamp: Date(), message: message)
        logs.append(entry)
        
        // Keep memory usage sane
        if logs.count > maxLogs {
            logs.removeFirst()
        }
        
        // Mirror to console for internal debug
        print("[DEBUG] \(entry.formattedTimestamp) - \(message)")
        #endif
    }
    
    public func clear() {
        #if DEVELOPER_BUILD
        logs.removeAll()
        #endif
    }
}
