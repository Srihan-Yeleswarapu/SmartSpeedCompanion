// Path: Core/AudioSessionCoordinator.swift
//
// Single owner of the process-wide AVAudioSession.
//
// Before this type existed, TWO subsystems configured and tore down the
// shared session independently:
//   • DefaultVoiceAnnouncer (nav voice)   → .playback / .spokenAudio
//   • AlertEngine (speed-alert tones)     → .playback / .default with
//     `.mixWithOthers` AND `.duckOthers` combined
//
// That tug-of-war was the root cause of the "glitchy audio" reports:
// every category/mode change or setActive(false) forced CarPlay's audio
// pipeline to re-negotiate mid-drive, and the contradictory
// `.mixWithOthers` + `.duckOthers` options made the head-unit DSP
// oscillate between mixing and ducking.
//
// The coordinator:
//   • Configures the session ONCE (lazily) with a single stable policy.
//   • Reference-counts activations, so a speeding alert ending can no
//     longer tear down the session underneath an active navigation
//     prompt (or vice versa).
//   • Never changes category/mode while audio is in flight.
//
// This also pairs with the CarPlay Audio App entitlement
// (`com.apple.developer.carplay-audio`): a recognized CarPlay audio app
// keeps its AVAudioSession in a stable, first-class state, so the
// `.spokenAudio` mode routes prompts through the car's dedicated
// navigation-voice channel instead of fighting the media pipeline.

import Foundation
import AVFoundation

@MainActor
public final class AudioSessionCoordinator {

    public static let shared = AudioSessionCoordinator()

    /// CarPlay-friendly audio session policy.
    ///
    /// • `.playback` + `.spokenAudio` routes audio through CarPlay's
    ///   dedicated navigation-voice channel (separate volume control,
    ///   lower latency) instead of the media A2DP channel — the same
    ///   configuration Apple Maps uses for turn-by-turn voice.
    /// • `.duckOthers` lowers music volume while our alerts are active.
    /// • NO `.mixWithOthers`, `.interruptSpokenAudioAndMixWithOthers`, or
    ///   `.defaultToSpeaker`:
    ///     - `.mixWithOthers` contradicts `.duckOthers`.
    ///     - `.interruptSpokenAudioAndMixWithOthers` tells the head unit to
    ///       treat our audio as mixable spoken audio (podcast-style) instead
    ///       of ducking-and-cutting-through. Combined with `.duckOthers` the
    ///       CarPlay DSP oscillated and chopped AVSpeechSynthesizer output
    ///       into syllable fragments over the car speakers (TestFlight
    ///       report: nav voice "breaks apart" on the car while the phone is
    ///       clean; Apple Maps is unaffected, so the car and phone are fine
    ///       and the defect is this session policy).
    ///     - `.defaultToSpeaker` is inert on CarPlay (a route always
    ///       exists); pure `.playback` already defaults to the speaker on
    ///       iPhone with no route.
    private static let sessionOptions: AVAudioSession.CategoryOptions = [
        .duckOthers
    ]

    private var isConfigured = false
    private var navigationHolders = 0
    private var alertHolders = 0

    private init() {}

    // MARK: - Holders

    /// Nav voice holds the session for the ENTIRE navigation — not per
    /// utterance. Per-utterance teardown was the glitch that made CarPlay
    /// speech arrive late and sound cut off.
    public func beginNavigation() {
        configureIfNeeded()
        navigationHolders += 1
        activateSession()
    }

    public func endNavigation() {
        navigationHolders = max(0, navigationHolders - 1)
        deactivateIfIdle()
    }

    /// Speed alerts hold the session (with ducking) while the car is over
    /// the limit. Acquiring/releasing this slot never changes the
    /// category/mode, so it cannot interrupt an active nav prompt.
    public func beginAlertDucking() {
        configureIfNeeded()
        alertHolders += 1
        activateSession()
    }

    public func endAlertDucking() {
        alertHolders = max(0, alertHolders - 1)
        deactivateIfIdle()
    }

    /// Ensure the session is active before a beep or utterance. Calling
    /// `setActive(true)` on an already-active session is a harmless no-op;
    /// when the session was silently deactivated (e.g. by a phone call /
    /// Siri interruption), this reliably re-activates it.
    public func ensureActive() {
        configureIfNeeded()
        activateSession()
    }

    // MARK: - Session plumbing

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // CARPLAY TTS FIX v2: prefer 44.1 kHz so AVSpeechSynthesizer's
            // native render rate matches the hardware, avoiding live
            // resampling of the speech stream over CarPlay's digital link.
            // `setPreferredSampleRate(_:)` is a throwing preference — the
            // system uses the closest supported rate, so this is a safe
            // no-op on devices that only accept 48 kHz. The alert-tone
            // buffer already reads the negotiated session rate, so beeps are
            // unaffected (and were always clean through the same session).
            try? session.setPreferredSampleRate(44100)
            try session.setCategory(.playback, mode: .spokenAudio, options: Self.sessionOptions)
            isConfigured = true
            DebugLogger.shared.log("Audio Session configured (playback / spokenAudio)")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("Audio Session ACTIVATE ERROR: \(error.localizedDescription)")
        }
    }

    /// Deactivates the session ONLY when no subsystem still needs it.
    /// `.notifyOthersOnDeactivation` tells the previously-interrupted app
    /// (Music, Spotify, YouTube) that it can restore its volume.
    private func deactivateIfIdle() {
        guard navigationHolders == 0, alertHolders == 0 else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // Re-apply the policy on the next begin. Safe to do while
            // nothing is playing — the churn that caused glitches happened
            // while audio was in flight, never while idle.
            isConfigured = false
            DebugLogger.shared.log("Audio Session deactivated (idle)")
        } catch {
            DebugLogger.shared.log("Audio Session DEACTIVATE ERROR: \(error.localizedDescription)")
        }
    }
}
