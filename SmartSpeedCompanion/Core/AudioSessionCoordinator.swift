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

    /// Keep the audio route alive across adjacent navigation prompts and
    /// speeding beeps, but restore other audio promptly after the final cue.
    private static let releaseDelayNanoseconds: UInt64 = 500_000_000

    private let audioQueue = DispatchQueue(
        label: "com.speedsense.audio-session",
        qos: .userInitiated
    )
    private var activeCueCount = 0
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

        // AVAudioSession.setCategory/setActive can synchronously wait on the
        // audio daemon. The old implementation called them on the main actor
        // from speech and speeding-alert callbacks, which is the AVAudioSession
        // run-loop hang signature in the XR reports. Keep the reference count
        // on the main actor, but do every session operation on a serial audio
        // queue so speech/alerts never stall UIKit.
        activeCueCount += 1
        audioQueue.async {
            Self.activateSessionOnAudioQueue()
        }
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
            self.audioQueue.async {
                Self.deactivateSessionOnAudioQueue()
            }
            self.releaseTask = nil
        }
    }

    /// Re-activates audio only when a cue is still in flight. This is used by
    /// interruption recovery and never starts audio during an idle navigation.
    public func ensureActive() {
        guard activeCueCount > 0 else { return }
        audioQueue.async {
            Self.activateSessionOnAudioQueue()
        }
    }

    // MARK: - Session plumbing

    /// Performs the potentially blocking AVAudioSession work away from the
    /// main actor. Exclusive activation is preferred; if the current route
    /// rejects it, retry with the system-supported ducking policy.
    private nonisolated static func activateSessionOnAudioQueue() {
        let session = AVAudioSession.sharedInstance()
        let interruptOptions: AVAudioSession.CategoryOptions = []
        let duckOptions: AVAudioSession.CategoryOptions = [.duckOthers]
        do {
            // Do not force a sample rate. CarPlay commonly negotiates 48 kHz
            // while iPhone speaker routes commonly use 44.1 kHz.
            try session.setCategory(.playback, mode: .voicePrompt, options: interruptOptions)
            try session.setActive(true)
            DebugLogger.shared.log("Audio Session active (playback / voicePrompt / interrupt)")
        } catch {
            do {
                try session.setCategory(.playback, mode: .voicePrompt, options: duckOptions)
                try session.setActive(true)
                DebugLogger.shared.log("Audio Session active using duck fallback")
            } catch {
                DebugLogger.shared.log("Audio Session ACTIVATE ERROR: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func deactivateSessionOnAudioQueue() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            DebugLogger.shared.log("Audio Session deactivated after cue")
        } catch {
            DebugLogger.shared.log("Audio Session DEACTIVATE ERROR: \(error.localizedDescription)")
        }
    }
}
