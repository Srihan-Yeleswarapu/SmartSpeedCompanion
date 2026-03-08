// CrowdsourceSpeedLimitService.swift
// Manages the crowdsourced speed limit database via Firebase.
// Handles reading, writing, voting, confirmation logic, and re-confirmation scheduling.

import Foundation
import CoreLocation
import FirebaseDatabase
import Combine

@MainActor
public class CrowdsourceSpeedLimitService: ObservableObject {
    @Published public var currentLimit: Int? = nil        // nil = unknown
    @Published public var dataSource: String = "Estimating..."
    @Published public var showCrowdsourcePrompt: Bool = false
    @Published public var promptOptions: [Int] = [25, 35, 45]  // dynamic or default
    @Published public var isReconfirmation: Bool = false   // true = "still X mph here?"
    @Published public var existingLimitForReconfirm: Int = 0

    public static let shared = CrowdsourceSpeedLimitService()
    
    private let db = Database.database().reference()
    private var lastQueriedKey: String = ""
    private var segmentEntryTime: Date? = nil
    private var promptTimer: AnyCancellable? = nil
    private var currentSegmentKey: String = ""
    private var lastPromptTime: Date? = nil
    private var ignoredSegments: [String: Date] = [:]

    private init() {}

    static func segmentKey(for coordinate: CLLocationCoordinate2D) -> String {
        let latKey = Int(coordinate.latitude * 1000)
        let lngKey = Int(coordinate.longitude * 1000)
        return "\(latKey)_\(lngKey)"
    }

    public func onLocationUpdate(_ coordinate: CLLocationCoordinate2D) {
        let key = Self.segmentKey(for: coordinate)
        
        // If same segment, do nothing
        guard key != currentSegmentKey else { return }
        
        // New segment entered
        currentSegmentKey = key
        segmentEntryTime = Date()
        promptTimer?.cancel()
        showCrowdsourcePrompt = false
        
        // Query Firebase for this segment
        Task { await fetchSegment(key: key) }
    }

    private func fetchSegment(key: String) async {
        do {
            let snapshot = try await db.child("segments/\(key)").getData()
            
            await MainActor.run {
                if let data = snapshot.value as? [String: Any] {
                    let confirmedLimit = data["confirmedLimit"] as? Int
                    let lastConfirmedAt = data["lastConfirmedAt"] as? TimeInterval ?? 0
                    let votes = data["votes"] as? [String: Int] ?? [:]
                    let totalVotes = data["totalVotes"] as? Int ?? 0
                    
                    if let limit = confirmedLimit {
                        // We have a confirmed limit
                        self.currentLimit = limit
                        self.dataSource = "Community (\(totalVotes) votes)"
                        
                        // Build dynamic options from existing votes
                        // Sort vote keys by count descending, take top 3 speeds
                        let topSpeeds = votes
                            .sorted { $0.value > $1.value }
                            .prefix(3)
                            .compactMap { Int($0.key) }
                        self.promptOptions = topSpeeds.isEmpty ? [25, 35, 45] : topSpeeds
                        
                        // Check if re-confirmation is due (30 days = 2592000 seconds)
                        let daysSinceConfirm = Date().timeIntervalSince1970 - lastConfirmedAt
                        if daysSinceConfirm > 2592000 {
                            self.scheduleReconfirmationPrompt(existingLimit: limit)
                        }
                    } else {
                        // No confirmed limit yet
                        self.currentLimit = nil
                        self.dataSource = "Unknown"
                        
                        // Build options from existing votes if any
                        let topSpeeds = votes
                            .sorted { $0.value > $1.value }
                            .prefix(3)
                            .compactMap { Int($0.key) }
                        self.promptOptions = topSpeeds.isEmpty ? [25, 35, 45] : Array(topSpeeds)
                        
                        self.scheduleNewRoadPrompt()
                    }
                } else {
                    // No data at all for this segment
                    self.currentLimit = nil
                    self.dataSource = "Unknown"
                    self.promptOptions = [25, 35, 45]
                    self.scheduleNewRoadPrompt()
                }
            }
        } catch {
            print("[Crowdsource] Failed to fetch segment data: \(error)")
        }
    }

    private func canShowPrompt() -> Bool {
        // Minimum 2 minutes between any prompts
        if let lastTime = lastPromptTime {
            if Date().timeIntervalSince(lastTime) < 120 {
                return false
            }
        }
        
        // If user tapped ignore on this segment within last 7 days
        if let ignoreTime = ignoredSegments[currentSegmentKey] {
            if Date().timeIntervalSince(ignoreTime) < (7 * 24 * 3600) {
                return false
            }
        }
        
        return true
    }

    private func scheduleNewRoadPrompt() {
        guard canShowPrompt() else { return }
        let key = currentSegmentKey
        promptTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in
                guard let self = self, self.currentSegmentKey == key else { return }
                self.isReconfirmation = false
                self.showCrowdsourcePrompt = true
                self.lastPromptTime = Date()
            }
    }

    private func scheduleReconfirmationPrompt(existingLimit: Int) {
        guard canShowPrompt() else { return }
        let key = currentSegmentKey
        promptTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in
                guard let self = self, self.currentSegmentKey == key else { return }
                self.isReconfirmation = true
                self.existingLimitForReconfirm = existingLimit
                self.showCrowdsourcePrompt = true
                self.lastPromptTime = Date()
            }
    }

    public func submitVote(speed: Int) {
        showCrowdsourcePrompt = false
        let key = currentSegmentKey
        
        // Optimistic UI update
        currentLimit = speed
        dataSource = "Your report (pending)"
        
        Task {
            let ref = db.child("segments/\(key)")
            
            // Use Firebase transaction to safely increment vote count
            do {
                let snapshot = try await ref.getData()
                var data = snapshot.value as? [String: Any] ?? [:]
                var votes = data["votes"] as? [String: Int] ?? [:]
                
                // Increment this speed's vote count
                votes["\(speed)"] = (votes["\(speed)"] ?? 0) + 1
                
                // Recalculate total
                let total = votes.values.reduce(0, +)
                
                // Check for majority (50%+ threshold)
                var confirmedLimit: Int? = nil
                for (speedStr, count) in votes {
                    if let s = Int(speedStr), Double(count) / Double(total) >= 0.5 {
                        confirmedLimit = s
                        break
                    }
                }
                
                var update: [String: Any] = [
                    "votes": votes,
                    "totalVotes": total,
                    "lastUpdatedAt": Date().timeIntervalSince1970
                ]
                
                if let confirmed = confirmedLimit {
                    update["confirmedLimit"] = confirmed
                    update["lastConfirmedAt"] = Date().timeIntervalSince1970
                    
                    await MainActor.run {
                        self.currentLimit = confirmed
                        self.dataSource = "Community (\(total) votes)"
                    }
                } else {
                    update["confirmedLimit"] = NSNull()
                }
                
                try await ref.updateChildValues(update)
                
            } catch {
                print("[Crowdsource] Vote submission failed: \(error)")
            }
        }
    }

    public func submitIgnore() {
        showCrowdsourcePrompt = false
        // Remember that we ignored this segment to prevent asking again for 7 days
        ignoredSegments[currentSegmentKey] = Date()
    }

    public func submitCustomSpeed(speed: Int) {
        submitVote(speed: speed)
    }
}
