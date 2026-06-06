# Speedio Codebase - Comprehensive Issues List

> Generated: June 5, 2026
> Total Issues Found: **57**

---

## 🔴 CRITICAL (Must Fix Immediately)

**C1. Static ViewModel Shared Between App and CarPlay** (`AppDelegate.swift:14`)
```swift
static let sharedDriveViewModel = DriveViewModel()
```
- `DriveViewModel` is instantiated once at app launch as a static singleton
- SwiftData `ModelContext` is set ONCE at launch
- If CarPlay connects before any SwiftData operations, the context may be stale or wrong
- **Fix:** Implement proper dependency injection and scene-specific initialization

**C2. Hardcoded API Key Exposed** (`SpeedCameraService.swift:20`)
```swift
private let apiKey = "329a6edfe2f7439f9dd57dcf69c6d872"
```
- API key is hardcoded in source code - anyone decompiling can extract it
- Should be moved to `GoogleService-Info.plist` or secure configuration

**C3. Swift Concurrency Violation: `@MainActor` + `NSObject` Protocol Conformance** (`DriveViewModel.swift`)
```swift
@MainActor
public final class DriveViewModel: NSObject, ... {
extension DriveViewModel: @preconcurrency MKLocalSearchCompleterDelegate {
    public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
```
- `DriveViewModel` is `@MainActor` but `MKLocalSearchCompleterDelegate` requires `nonisolated public func` methods
- Will cause **Swift 6 compilation error** in strict concurrency mode
- The `@preconcurrency` attribute is a workaround, not a proper fix

**C4. Force Unwrap Risk in CarPlay Scene Delegate** (`CarPlaySceneDelegate.swift:42`)
```swift
guard let speedMapTemplate = navigationRoot?.mapTemplate else { return }
```
- If `navigationRoot` is nil, `mapTemplate` access crashes (forced optional chain)
- No nil check before accessing

**C5. Race Condition in `SessionRecorder.saveSession`** (`SessionRecorder.swift:61-70`)
```swift
public func saveSession(_ session: DriveSession) {
    if let context = modelContext {
        Task { @MainActor in
            context.insert(session)
            try context.save()
        }
    }
}
```
- `modelContext` could be `nil` at call time but set before Task runs
- No synchronization mechanism

**C6. Unbounded Array Growth** (`DebugLogger.swift:28`)
```swift
self.logs.append(entry)
if self.logs.count > self.maxLogs {
    self.logs.removeFirst()  // O(n) operation
}
```
- `removeFirst()` is O(n) for Array - should use `Deque` instead
- Under high-frequency logging, this becomes a performance bottleneck

**C7. Double `AVAudioSession.setActive(true)` Calls** (`DriveViewModel.swift:445-450`)
```swift
func announce(_ message: String) {
    do {
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
    }
```
- Called in `announce()` which may be called multiple times
- Should check `isOtherAudioPlaying` before activating

---

## 🟠 HIGH PRIORITY (Should Fix Soon)

**H1. `flatMap` Without Nil-Coalescing** (`DriveViewModel.swift:103`)
```swift
let dist = locationManager.latestLocation.flatMap { loc in
    destination?.placemark.location.map { loc.distance(from: $0) }
} ?? 999
```
- `999` is used when location is nil OR when destination location is nil
- Makes it impossible to distinguish "no location" from "no destination"

**H2. Floating Point Comparison Without Tolerance** (`SpeedEngine.swift:76`)
```swift
if location.speedAccuracy >= 0 && location.speedAccuracy > 5.0 {
    return
}
```
- `5.0` is a magic number - what if GPS reports 5.01?
- Should use a range check with epsilon tolerance

**H3. Missing Authorization Check Before Location Access** (`LiveMapView.swift:Coordinator`)
- `uiView.userLocation.location` accessed without checking authorization status
- Could return nil or stale data if location permission denied

**H4. No Error Handling in `CacheRouteSegments`** (`DriveViewModel.swift:175`)
```swift
await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)
```
- If pre-caching fails, no error is logged or handled
- Navigation may proceed without cached data

**H5. Timer Not Coordinated Between `DriveViewModel` and `SessionRecorder`**
- `SessionRecorder` has its own `recordingTimer` separate from `DriveViewModel.sessionTimer`
- If `DriveViewModel.endSession()` is called first, cleanup may be inconsistent

**H6. Missing SwiftData Index on `DriveSession.startTime`** (`AnalyticsDashboardView.swift:7`)
```swift
@Query(sort: \/driveSession.startTime, order: .reverse) private var sessions: [DriveSession]
```
- `startTime` is used for sorting but has no index
- As sessions grow, query performance degrades O(n log n) instead of O(n)

**H7. Force Unwrapped `Bundle.main.url`** (`ArizonaSpeedLimitService.swift:89`)
- If sqlite file not found, app silently continues without speed limit data
- No user-facing error, no fallback explanation

**H8. Inefficient `distanceToPolyline` Implementation** (`DriveViewModel.swift:562-573`)
```swift
for i in stride(from: 0, to: polyline.pointCount, by: 5) {
```
- Steps by 5 points - may miss nearest point
- Should use proper point-to-segment distance calculation

**H9. Missing `currentStepIndex` Bounds Check** (`DriveViewModel.swift:298`)
```swift
if self.currentStepIndex >= steps.count { return }
```
- Only checks lower bound, not upper bound

**H10. Hysteresis Logic in SpeedEngine Has Magic Numbers** (`SpeedEngine.swift:89`)
```swift
} else if speed >= (threshold - (isMetric ? 2.0 : 1.0)) {
    self.status = .warning // Yellow only for the top 1 mph of buffer
}
```
- `2.0` for metric vs `1.0` for imperial - where did these numbers come from?
- No constants defined, no explanation

**H11. Geocoding Completion Handler Doesn't Update UI on Main Thread** (`SessionRecorder.swift:79-86`)
```swift
geocoder.reverseGeocodeLocation(location) { placemarks, error in
    // Completion called on background thread
```
- UI updates from this callback could cause issues

**H12. `fetchUserPreferences` Completion Handler on Background Queue** (`AuthenticationManager.swift:174`)
- Firestore callback may come on background queue
- `UserDefaults.standard.set()` is thread-safe but `print()` may interleave

**H13. No Rate Limiting on `updateLastLocation`** (`DriveViewModel.swift:123`)
```swift
AuthenticationManager.shared.updateLastLocation(...)
```
- Called every location update (potentially 1/second)
- Should be throttled to every 30-60 seconds

**H14. `CrashDetectionManager` Crashes If SpeedEngine/SessionRecorder Nil** (`CrashDetectionManager.swift:14`)
```swift
public init(speedEngine: SpeedEngine, sessionRecorder: SessionRecorder) {
    self.speedEngine = speedEngine
    self.sessionRecorder = sessionRecorder
    startCrashDetection()
}
```
- No optional handling - assumes both are always provided

**H15. Missing Availability Check for iOS Features** (`SpeedWidget.swift`)
```swift
@main
struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedWidget()
        SpeedLiveActivityView()  // May not be available on older iOS
    }
}
```
- No `#available` check for iOS 16.1+ requirement

**H16. Hardcoded Colors Not Using DesignSystem** (`SpeedGaugeView.swift:48`)
```swift
context.stroke(trackPath, with: .color(Color(red: 1, green: 1, blue: 1, opacity: 0.05)), ...)
```
- Should use `DesignSystem.bgPanel` or similar

**H17. Actor Lifecycle Issues in `ArizonaSpeedLimitService`** (`ArizonaSpeedLimitService.swift:50`)
- Actor has `deinit` that calls `sqlite3_close_v2`
- But actors don't have traditional deinit - database connection may leak

**H18. Duplicate `nearestPointOnSegment` Implementation** (`DriveViewModel.swift`)
- Implemented in `DriveViewModel` class AND in `SimulationDataSource` extension
- Code duplication - should be extracted to a utility function

---

## 🟡 MEDIUM PRIORITY (Nice to Fix)

**M1. Unused Variable in `CarPlayNavigationManager`** (`CarPlayNavigationManager.swift:91`)
```swift
let avoidHighways = UserDefaults.standard.bool(forKey: "avoidHighways")
if avoidHighways { ... }
```
- Variable created but only used in `if` condition on same line

**M2. Commented Out Code Left in `SignInView.swift:68-105`**
- Large block of Sign in with Apple code is commented out
- Should be removed or properly implemented

**M3. `searchDestination` Returns Empty on Error Silently** (`DriveViewModel.swift:339`)
```swift
} catch {
    searchResults = []
}
```
- Errors are swallowed, user never knows search failed

**M4. No `break` in Switch-Like `getImageForManeuver`** (`DriveViewModel.swift:481`)
- Checks in order but doesn't return early on first match
- "u-turn" check comes first (good), but structure is fragile

**M5. Inconsistent Naming: `destination` vs `destinationItem`** (`DriveViewModel.swift:68-72`)
```swift
@Published public var destination: MKMapItem? = nil
@Published public var destinationItem: MKMapItem? = nil
```
- Both hold the same type, unclear which to use
- Causes confusion and potential bugs

**M6. Magic Numbers Everywhere** - Multiple files
- `150` meters off-route threshold
- `35.0` meters off-route in `checkOffRouteStatus`
- `20.0` minimum fetch distance
- `60.0` snapping distance
- All should be named constants

**M7. No Nullability Handling for `placemark.location`** (`DriveViewModel.swift:98-99`)
```swift
let dist = locationManager.latestLocation.flatMap { loc in
    destination?.placemark.location.map { loc.distance(from: $0) }
} ?? 999
```
- `destination?.placemark.location` can be nil
- Entire expression returns 999 when nil

**M8. Circular Cache Not Thread-Safe** (`ArizonaSpeedLimitService.swift:56-57`)
```swift
private var circularCache: [RoadSegment] = []
private var lastCacheCenter: CLLocationCoordinate2D?
```
- Modified in `refreshCircularCache()` but read in `updateSpeedLimit()`
- Actor provides isolation, but within the actor, no additional synchronization

**M9. `formatDecimalForSpeech` Returns Wrong Format** (`DriveViewModel.swift:439`)
```swift
let fracPart = Int((rounded - Double(intPart)) * 10 + 0.5)
```
- For `2.5`, gives "2 point 5"
- For `2.0`, returns "2"
- But for `2.15`, rounding to 1 decimal gives `2.2`, not "2 point 2"
- Logic seems off

**M10. No Cleanup of `stepStageFlags`** (`DriveViewModel.swift:308`)
- `stepStageFlags` dictionary grows unbounded as new steps are encountered
- Old steps aren't removed, causing memory leak over long routes

**M11. `DriveViewModel` Has Two Different Off-Route Thresholds** (`DriveViewModel.swift:118` vs `547`)
```swift
private let offRouteThreshold: CLLocationDistance = 20.0 // Defined but never used
```
- `150` used in `updateNavigationProgress`
- `35` used in `checkOffRouteStatus`
- Inconsistent behavior

**M12. LiveMapView Uses Deprecated `mapType` Property** (`LiveMapView.swift:23`)
```swift
map.mapType = .mutedStandard
```
- Only used as fallback for iOS < 16
- Fine for compatibility, but deprecation should be noted

**M13. No User Feedback When API Key Invalid** (`SpeedCameraService.swift:31-36`)
- HTTP error codes returned but only print to console
- User has no indication camera data fetch failed

**M14. KeychainHelper Ignores Error Status** (`KeychainHelper.swift:27`)
```swift
SecItemUpdate(query, attributesToUpdate)
```
- Return value not checked
- If update fails, silent failure

**M15. Inconsistent `public` access modifier usage**
- Many classes marked `public` but properties `internal`
- Makes API surface unclear

**M16. No Unit Tests**
- Zero test files found
- High-risk code (speed calculations, crash detection) has no test coverage

**M17. Missing Default Value for `audioAlertsEnabled`** (`AlertEngine.swift:21`)
```swift
private var audioAlertsEnabled: Bool {
    return UserDefaults.standard.bool(forKey: "audioAlertsEnabled")
}
```
- UserDefaults returns `false` if key doesn't exist
- If user never toggled the setting, audio alerts silently disabled
- Should explicitly set default `true` on first access

---

## 🟢 LOW PRIORITY (Technical Debt)

**L1. Unused Import in `DriveViewModel.swift`**
```swift
import FirebaseFirestore
```
- `DriveViewModel` doesn't use Firestore directly

**L2. Commented Code Blocks Not Removed**
- Multiple large blocks of commented code throughout
- Should be removed or integrated

**L3. Naming Inconsistency: `isMetric` Variable** (`SpeedEngine.swift:44`)
```swift
let isMetric = measurementSystem == "Metric"
```
- `"Metric"` is a magic string
- Should be a constant

**L4. No Documentation for Public APIs**
- Most files lack doc comments
- Hard for new developers to understand API surface

**L5. `.gitignore` May Not Cover All Build Artifacts**
- `.sqlite` files tracked?
- Derived data might be committed accidentally

**L6. `SimulationManager` Only Exists in DEBUG Builds** (`SimulationManager.swift:1`)
```swift
#if DEBUG || DEVELOPER_BUILD
```
- Production code never uses this class
- Could cause issues if `DEVELOPER_BUILD` is set in Release

**L7. No `@discardableResult` for Async Functions**
```swift
Task {
    await ArizonaSpeedLimitService.shared.loadDataIfNeeded()
}
```
- Return value discarded
- If it throws, error is silently ignored

**L8. Inconsistent Error Types**
- Some places use `URLError.resourceUnavailable`
- Others print to console
- No unified error handling strategy

**L9. UserDefaults Keys Duplicated as Strings**
- `"userBuffer"`, `"audioAlertsEnabled"` etc. used as string literals
- Should be `static let` constants in a `Keys` enum

**L10. `AppState.setupSettingsSync` Observes All Keys** (`AppState.swift:28-38`)
```swift
for _ in settingsKeys {
    UserDefaults.standard
        .publisher(for: \\.self)
```
- Observes entire UserDefaults object for changes to ANY key
- Very inefficient - should observe specific keys

**L11. `LocationManager` Heading Filter Hardcoded** (`LocationManager.swift:28`)
```swift
manager.headingFilter = 2.0 // Update every 2 degrees
```
- 2 degrees may be too fine or too coarse depending on use case

**L12. No Background Task Expiration Handling**
- If app suspended during session, `recordingTimer` may not fire
- Data loss possible

**L13. `SpeedEngine.smoothedSpeed` Never Reset**
- If speed goes to 0, `smoothedSpeed` gradually decays
- If car stops for 10 minutes, then moves, initial reading might be smoothed from old data

**L14. `AnalyticsViewModel.purgeOldSessions` Called on Every Appear** (`AnalyticsDashboardView.swift:70`)
```swift
.onAppear {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.purgeOldSessions(...)
```
- Adds 100ms delay unnecessarily
- Called every time view appears, not just once

**L15. No Validation That `DriveSession.endTime > startTime`** (`DriveSession.swift`)
- If endTime set to before startTime, duration calculation would be negative
- No validation in setter or init

---

## 📋 SUMMARY BY CATEGORY

| Category | Count |
|----------|-------|
| Critical Bugs | 7 |
| Swift Concurrency Violations | 1 |
| Memory/Performance Issues | 4 |
| Security Issues | 1 |
| Data Integrity Issues | 2 |
| Code Quality | 16 |
| Missing Error Handling | 6 |
| Magic Numbers/Strings | 6 |
| Architecture Issues | 4 |
| UI/UX Issues | 2 |
| Missing Tests | 1 |
| Documentation | 4 |
| **TOTAL** | **57** |

---

## 🚀 RECOMMENDED PRIORITY ORDER

1. **Fix Swift concurrency violation** (C3) - Compilation error in Swift 6
2. **Fix API key exposure** (C2) - Security critical
3. **Fix static ViewModel singleton** (C1) - Architecture critical
4. **Fix race conditions** (C5) - Data integrity
5. **Implement rate limiting** (H13) - Performance
6. **Remove magic numbers** (H6, H10, M6) - Maintainability
7. **Add unit tests** (M16) - Confidence
8. **Clean up technical debt** - Ongoing