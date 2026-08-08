// Path: Core/AudioSessionCoordinator.swift
//
// Single owner of the process-wide AVAudioSession.
//
// Audio focus is acquired only while Speedio is actually emitting a tone or
// spoken prompt. A normal playback session (without mix/duck options) asks
// iOS to interrupt and pause interruptible media. If that activation is not
// accepted by the route, the coordinator retries with `.duckOthers`, which is
// the system-supported fallback for sources that cannot be paused. When the
// cue completes, `.notifyOthersOnDeactivation` lets the previous audio app
// restore itself.
//
// A short delayed release bridges back-to-back prompts and beeps without
// holding the user's music/podcast for the entire navigation session.

import Foundation
import AVFoundation

@MainActor
public final class AudioSessionCoordinator {

    public static let shared = AudioSessionCoordinator()

    /// Empty options are intentional: `.playback` then requests exclusive
    /// audio focus, which pauses interruptible media while our cue plays.
    /// `.duckOthers` is used only when exclusive activation is rejected.
    private static let interruptOptions: AVAudioSession.CategoryOptions = []
    private static let duckOptions: AVAudioSession.CategoryOptions = [.duckOthers]

    /// Keep the audio route alive across adjacent navigation prompts and
    /// speeding beeps, but restore other audio promptly after the final cue.
    private static let releaseDelayNanoseconds: UInt64 = 500_000_000

    private var isConfigured = false
    private var activeCueCount = 0
    private var usingDuckFallback = false
    private var releaseTask: Task<Void, Never>?
    private var releaseGeneration: UInt64 = 0

    private init() {}

    // MARK: - Cue lifecycle

    /// Acquires audio focus for one Speedio tone or spoken prompt.
    ///
    /// The method is deliberately reference-counted: a navigation prompt can
    /// overlap the tail of a tone without either subsystem deactivating the
    /// shared session underneath the other.
    public func beginCue() {
        releaseGeneration &+= 1
        releaseTask?.cancel()
        releaseTask = nil

        if activeCueCount == 0 {
            configureIfNeeded(options: Self.interruptOptions)
            activateSessionWithFallback()
        } else {
            // A system interruption (phone call/Siri) can deactivate an
            // otherwise live cue. Reassert focus without changing category
            // while another cue is still rendering.
            activateSessionIfNeeded()
        }
        activeCueCount += 1
    }

    /// Releases one tone/prompt. The delayed final release allows the next
    /// cue to reuse the same route without a CarPlay audio renegotiation.
    public func endCue() {
        activeCueCount = max(0, activeCueCount - 1)
        guard activeCueCount == 0 else { return }

        releaseGeneration &+= 1
        let generation = releaseGeneration
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.releaseDelayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.releaseGeneration == generation,
                  self.activeCueCount == 0 else { return }
            self.deactivateSession()
            self.releaseTask = nil
        }
    }

    /// Re-activates audio only when a cue is still in flight. This is used by
    /// interruption recovery and never starts audio during an idle navigation.
    public func ensureActive() {
        guard activeCueCount > 0 else { return }
        configureIfNeeded(options: usingDuckFallback ? Self.duckOptions : Self.interruptOptions)
        activateSessionIfNeeded()
    }

    // MARK: - Session plumbing

    private func configureIfNeeded(options: AVAudioSession.CategoryOptions) {
        guard !isConfigured else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Do not force a sample rate. CarPlay commonly negotiates 48 kHz
            // while iPhone speaker routes commonly use 44.1 kHz.
            try session.setCategory(.playback, mode: .voicePrompt, options: options)
            isConfigured = true
            usingDuckFallback = options.contains(.duckOthers)
            DebugLogger.shared.log("Audio Session configured (playback / voicePrompt / \(usingDuckFallback ? "duck" : "interrupt"))")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    /// First tries exclusive playback focus. Some routes/apps refuse that
    /// activation; retry with `.duckOthers` so Speedio remains intelligible
    /// over the other source instead of losing its cue entirely. iOS does
    /// not expose another app's pause state, so a successful activation is
    /// the strongest pause request a third-party app can make.
    private func activateSessionWithFallback() {
        guard activateSessionIfNeeded() else {
            guard !usingDuckFallback else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .voicePrompt, options: Self.duckOptions)
                isConfigured = true
                usingDuckFallback = true
                _ = activateSessionIfNeeded()
                DebugLogger.shared.log("Audio Session using duck fallback")
            } catch {
                DebugLogger.shared.log("Audio Session DUCK FALLBACK ERROR: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func activateSessionIfNeeded() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            DebugLogger.shared.log("Audio Session ACTIVATE ERROR: \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            isConfigured = false
            usingDuckFallback = false
            DebugLogger.shared.log("Audio Session deactivated after cue")
        } catch {
            DebugLogger.shared.log("Audio Session DEACTIVATE ERROR: \(error.localizedDescription)")
        }
    }
}
