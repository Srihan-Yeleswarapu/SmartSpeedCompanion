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

public final class DebugLogger: ObservableObject {
    public static let shared = DebugLogger()
    
    @Published public private(set) var logs: [LogEntry] = []
    private let maxLogs = 500
    private let queue = DispatchQueue(label: "com.speedsense.debuglogger", qos: .utility)
    
    private init() {}
    
    public func log(_ message: String) {
        #if DEVELOPER_BUILD
        let entry = LogEntry(timestamp: Date(), message: message)
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.logs.append(entry)
                if self.logs.count > self.maxLogs {
                    self.logs.removeFirst()
                }
            }
            
            // Mirror to console for internal debug
            print("[DEBUG] \(entry.formattedTimestamp) - \(message)")
        }
        #endif
    }
    
    public func clear() {
        #if DEVELOPER_BUILD
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
        #endif
    }
}
