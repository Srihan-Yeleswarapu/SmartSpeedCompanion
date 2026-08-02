// CarPlayNowPlayingController.swift
//
// Now that the team's account holds the CarPlay Audio App entitlement
// (`com.apple.developer.carplay-audio`), Speedio is a first-class CarPlay
// audio app: its AVAudioSession is treated as audio, background audio
// keeps working, and the Now Playing template (CPNowPlayingTemplate)
// becomes available. CarPlay audio apps MUST expose the Now Playing
// template, so this controller:
//   • Presents CPNowPlayingTemplate.shared from the map root.
//   • Mirrors live drive state (speed / road / status) into
//     MPNowPlayingInfoCenter so the head-unit screen shows real content.
//   • Wires the head-unit play/pause/toggle controls to the audio-alert
//     toggle — the only "playback" this app has.
//
// Remote commands are registered ONLY when the template is presented, so
// the app never hijacks hardware play/pause while another app is the
// active audio source.

import CarPlay
import MediaPlayer
import UIKit

@MainActor
final class CarPlayNowPlayingController {

    static let shared = CarPlayNowPlayingController()

    private weak var viewModel: DriveViewModel?
    private var remoteCommandsRegistered = false
    // Artwork cache: `refresh()` runs on every HUD tick (~1/sec) while the
    // drive is active, and re-rendering a 512×512 tile each tick is wasted
    // work on the head-unit side. Re-render only when speed/status (the two
    // values the artwork shows) actually change.
    private var cachedArtworkKey: String?
    private var cachedArtwork: MPMediaItemArtwork?
    // Last snapshot pushed to MPNowPlayingInfoCenter. `refresh()` is called
    // on every HUD tick (~1/sec); rewriting nowPlayingInfo every tick made
    // some CarPlay head units re-evaluate the audio session mid-speech,
    // which chopped in-flight AVSpeechSynthesizer output into fragments.
    // Only push when a displayed value actually changed.
    private var lastPushedKey: String?

    private init() {}

    /// The map root keeps this in sync with the live DriveViewModel.
    func bind(viewModel: DriveViewModel) {
        self.viewModel = viewModel
    }

    /// Called right before CPNowPlayingTemplate is pushed: register the
    /// head-unit controls and push the latest snapshot so the screen never
    /// renders a stale/blank state.
    func prepareForPresentation() {
        registerRemoteCommandsIfNeeded()
        refresh()
    }

    /// Called from the HUD update sink whenever speed/limit/status/road
    /// change, so the Now Playing screen (if on screen) always mirrors the
    /// live drive. Cheap when the template isn't visible.
    ///
    /// CARPLAY-AUDIO FIX: the sink fires ~1/sec, and rewriting
    /// `MPNowPlayingInfoCenter.default().nowPlayingInfo` on every tick made
    /// the head unit re-evaluate the audio session while speech was in
    /// flight, chopping AVSpeechSynthesizer into syllables over the car
    /// speakers (phone clean, Apple Maps clean — the metadata churn was the
    /// difference). Pushes are now deduplicated by the displayed snapshot so
    /// metadata only changes when speed/road/status actually change.
    func refresh() {
        guard let vm = viewModel else { return }
        let system = SpeedFormatting.measurementSystem()
        let unit = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let speedText = "\(Int(vm.speed)) \(unit)"
        let road = (vm.currentRoadName?.isEmpty == false) ? vm.currentRoadName! : "Speedio Drive"
        let statusText = vm.status.rawValue.uppercased()
        let alertsOn = audioAlertsEnabled

        // Deduplicate: don't rewrite identical snapshots on every tick.
        // `sessionDuration` is intentionally excluded from the key — it
        // changes every second and would defeat dedup; the head unit
        // auto-advances elapsed time from playbackState .playing + rate 1.0,
        // so the Now Playing progress stays live without per-tick pushes.
        let key = "\(speedText)|\(road)|\(statusText)|\(alertsOn)"
        if key == lastPushedKey { return }
        lastPushedKey = key

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: speedText,
            MPMediaItemPropertyArtist: road,
            MPMediaItemPropertyAlbumTitle: statusText,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: vm.sessionDuration,
            MPMediaItemPropertyPlaybackDuration: max(vm.sessionDuration + 1, 1)
        ]
        if let artwork = artwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = alertsOn ? .playing : .paused
    }

    // MARK: - Audio-alert toggle (the app's "playback")

    private var audioAlertsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "audioAlertsEnabled") == nil {
            defaults.set(true, forKey: "audioAlertsEnabled")
        }
        return defaults.bool(forKey: "audioAlertsEnabled")
    }

    private func setAudioAlertsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "audioAlertsEnabled")
        refresh()
    }

    // MARK: - Remote commands (head-unit play/pause)

    private func registerRemoteCommandsIfNeeded() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.setAudioAlertsEnabled(true) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.setAudioAlertsEnabled(false) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setAudioAlertsEnabled(!self.audioAlertsEnabled)
            }
            return .success
        }
    }

    // MARK: - Artwork

    /// A big colored speed tile matching the app's visual language, so the
    /// Now Playing screen reads like a real "track" instead of an empty
    /// placeholder. Cached per (speed, status) pair — see `cachedArtworkKey`.
    private func artwork() -> MPMediaItemArtwork? {
        guard let vm = viewModel else { return nil }
        let key = "\(Int(vm.speed))|\(vm.status.rawValue)"
        if key == cachedArtworkKey, let cachedArtwork { return cachedArtwork }

        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let speed = "\(Int(vm.speed))"
        let statusColor = CarPlayUI.statusColor(vm.status)
        let image = renderer.image { _ in
            statusColor.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 112).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 220, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
            let str = NSAttributedString(string: speed, attributes: attrs)
            let strSize = str.size()
            str.draw(at: CGPoint(x: (size.width - strSize.width) / 2,
                                 y: (size.height - strSize.height) / 2))
        }
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
        cachedArtworkKey = key
        cachedArtwork = artwork
        return artwork
    }
}
