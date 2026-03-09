// Path: Models/RoadSegment.swift
import Foundation
import SwiftData
import CoreLocation

@Model
public class RoadSegment {
    @Attribute(.unique) public var id: String
    
    public var latKey: Int
    public var lngKey: Int
    public var speedLimit: Int
    public var statusString: String
    public var osmWayID: String?
    public var source: String
    public var verifiedAt: Date
    public var expiresAt: Date?
    public var flagCount: Int
    
    public var status: SegmentStatus {
        get { SegmentStatus(rawValue: statusString) ?? .temporary }
        set { statusString = newValue.rawValue }
    }
    
    public init(
        latKey: Int,
        lngKey: Int,
        speedLimit: Int,
        status: SegmentStatus,
        osmWayID: String? = nil,
        source: String,
        verifiedAt: Date = Date(),
        expiresAt: Date? = nil,
        flagCount: Int = 0
    ) {
        self.id = "\(latKey)_\(lngKey)"
        self.latKey = latKey
        self.lngKey = lngKey
        self.speedLimit = speedLimit
        self.statusString = status.rawValue
        self.osmWayID = osmWayID
        self.source = source
        self.verifiedAt = verifiedAt
        self.expiresAt = expiresAt
        self.flagCount = flagCount
    }
    
    public static func keys(for coordinate: CLLocationCoordinate2D) -> (Int, Int) {
        let latKey = Int(round(coordinate.latitude * 10000))
        let lngKey = Int(round(coordinate.longitude * 10000))
        return (latKey, lngKey)
    }
}

public enum SegmentStatus: String, Codable {
    case verifiedPermanent
    case temporary
    case userFlagged
}
