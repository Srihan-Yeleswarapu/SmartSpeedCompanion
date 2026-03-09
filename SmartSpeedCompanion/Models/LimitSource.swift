// Path: Models/LimitSource.swift
import Foundation

public enum LimitSource: String, Codable {
    case localVerified = "Verified"    // cyan
    case localTemporary = "HERE"       // cyan
    case adot = "ADOT"                 // amber
    case estimating = "..."            // gray
}
