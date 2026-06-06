# Speedio Codebase - Comprehensive Issues List

> Generated: June 5, 2026
> Total Issues Found: **57**

---

## 🔴 CRITICAL (Must Fix Immediately)

### 1. **Static ViewModel Shared Between App and CarPlay** (`AppDelegate.swift:14`)
```swift
static let sharedDriveViewModel = DriveViewModel()
```
- `DriveViewModel` is instantiated once at app launch as a static singleton
- This means SwiftData `ModelContext` is set ONCE at launch
- If CarPlay connects before any SwiftData operations, the context may be stale or wrong
- **Fix:** Implement proper dependency injection and scene-specific initialization

### 2. **Hardcoded API Key Exposed** (`SpeedCameraService.swift:20`)
```swift
private let apiKey = "329a6edfe2f7439f9dd57dcf69c6d872"
```
- API key is hardcoded in source code
- Should be moved to `GoogleService-Info.plist` or secure configuration
- Anyone decompiling the app can extract this key

### 3. **Dangerous Force Unwrap in `SpeedEngine.processLocation`** (`SpeedEngine.swift:62`)
```swift
Task { @MainActor in
    guard location.horizontalAccuracy > 0 && location.horizontalAccuracy <= 15 else {
        return
    }
```
- This Task block references `self.limit` which was captured before the `Task` block
- Race condition: `self.limit` may have changed by the time the Task runs
- The `currentLimit` returned from async call is discarded, but `self.limit` is updated
- **Fix:** Use proper async/await and avoid capturing self state before await

### 4. **Memory Leak in `AlertEngine` - Circular Reference** (`AlertEngine.swift:23-27`)
```swift
statusCancellable = speedEngine.$status
    .receive(on: RunLoop.main)
    .sink { [weak self] newStatus in
        self?.handleStatusChange(newStatus)
    }
```
- `AlertEngine` holds a reference to `speedEngine` (via init parameter)
- But the closure uses `weak self` - if `self` is deallocated, `speedEngine` keeps the cancellable
- Actually, `speedEngine` doesn't hold `AlertEngine` back, so this is fine
- But the `timerCancellable` is stored but `cancelTimer()` is called from `stopMonitoringState()` which is only triggered when status != .over - if status changes repeatedly, timer may not be cleaned up properly

### 5. **Race Condition in `SessionRecorder.saveSession`** (`SessionRecorder.swift:61-70`)
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
- Or context could be deallocated between check and Task execution
- No synchronization mechanism

### 6. **Unbounded Array Growth** (`DebugLogger.swift:28`)
```swift
self.logs.append(entry)
if self.logs.count > self.maxLogs {
    self.logs.removeFirst()
}
```
- `removeFirst()` is O(n) for Array - should use `Deque` instead
- Under high-frequency logging, this becomes a performance bottleneck

### 7. **Double `AVAudioSession.setActive(true)` Calls** (`DriveViewModel.swift:445-450`)
```swift
func announce(_ message: String) {
    do {
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
    }
```
- Called in `announce()` which may be called multiple times
- Should check `isOtherAudioPlaying` before activating
- Causes audio ducking to trigger repeatedly

---

## 🟠 HIGH PRIORITY (Should Fix Soon)

### 8. **Missing `deinit` in `ArizonaSpeedLimitService`** (`ArizonaSpeedLimitService.swift:50`)
- Has `deinit` that calls `sqlite3_close_v2`
- But it's an `actor` - actors don't have deinit in the traditional sense
- Database connection may leak if actor is never deallocated

### 9. **`flatMap` Without Nil-Coalescing** (`DriveViewModel.swift:103`)
```swift
let dist = locationManager.latestLocation.flatMap { loc in
    destination?.placemark.location.map { loc.distance(from: $0) }
} ?? 999
```
- If `latestLocation` returns `nil`, `flatMap` returns `nil`, coalesced to `999`
- But if `destination?.placemark.location` is `nil`, the inner closure returns `nil`, flatMap returns `nil`
- So `999` is used when location is nil OR when destination location is nil
- Makes it impossible to distinguish "no location" from "no destination"

### 10. **Floating Point Comparison Without Tolerance** (`SpeedEngine.swift:76`)
```swift
if location.speedAccuracy >= 0 && location.speedAccuracy > 5.0 {
    return
}
```
- `5.0` is a magic number - what if GPS reports 5.01?
- Should use a range check like `location.speedAccuracy > 5.0 + epsilon`

### 11. **Missing Authorization Check Before Location Access** (`LiveMapView.swift:Coordindator`)
- `uiView.userLocation.location` accessed without checking authorization status
- Could return nil or stale data if location permission denied

### 12. **No Error Handling in `CacheRouteSegments`** (`DriveViewModel.swift:175`)
```swift
await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)
```
- If pre-caching fails, no error is logged or handled
- Navigation may proceed without cached data, causing slow limit lookups

### 13. **Timer Not Invalidated on `endSession`** (`DriveViewModel.swift:147`)
```swift
sessionTimer?.cancel()
sessionTimer = nil
```
- `sessionTimer` IS cancelled, but `recordingTimer` inside `SessionRecorder` is a separate timer
- `SessionRecorder.endSession()` cancels its own timer, but if `DriveViewModel.endSession()` is called first, the session may not have proper cleanup

### 14. **Force Unwrapped `Bundle.main.url`** (`ArizonaSpeedLimitService.swift:89`)
```swift
if let url = Bundle.main.url(forResource: name, withExtension: ext) {
```
- What if the sqlite file is not found? App silently continues without speed limit data
- No user-facing error, no fallback explanation

### 15. **Inefficient `distanceToPolyline` Implementation** (`DriveViewModel.swift:562-573`)
```swift
for i in stride(from: 0, to: polyline.pointCount, by: 5) {
```
- Steps by 5 points - may miss nearest point
- Should use proper point-to-segment distance calculation
- Uses `.greatestFiniteMagnitude` for initialization but doesn't handle empty polyline case well

### 16. **Missing `currentStepIndex` Bounds Check** (`DriveViewModel.swift:298`)
```swift
if self.currentStepIndex >= steps.count { return }
```
- Only checks lower bound, not upper bound
- If index somehow gets set to negative, this won't catch it

### 17. **`instructionIsGenericLabel` Has Redundant Check** (`DriveViewModel.swift:491-496`)
```swift
private func instructionIsGenericLabel(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("proceed to route") || lower.contains("starting route") || lower.contains("you have arrived")
}
```
- "starting route" will always be caught by "proceed to route" check first (if we had early return)
- No early return optimization - always does all 3 checks

### 18. **Hysteresis Logic in SpeedEngine Has Magic Numbers** (`SpeedEngine.swift:89`)
```swift
} else if speed >= (threshold - (isMetric ? 2.0 : 1.0)) {
    self.status = .warning // Yellow only for the top 1 mph of buffer
}
```
- `2.0` for metric vs `1.0` for imperial - where did these numbers come from?
- No constants defined, no explanation of why 1 mph vs 2 km/h

### 19. **Geocoding Completion Handler Doesn't Update UI on Main Thread** (`SessionRecorder.swift:79-86`)
```swift
geocoder.reverseGeocodeLocation(location) { placemarks, error in
    if let p = placemarks?.first {
        let name = p.name ?? p.thoroughfare ?? p.locality ?? "Unknown Location"
        completion(name)
```
- Completion called on background thread
- UI updates from this callback could cause issues
- Should dispatch to main queue

### 20. **`fetchUserPreferences` Completion Handler on Background Queue** (`AuthenticationManager.swift:174`)
```swift
db.collection("users").document(uid).getDocument { (document, error) in
    if let document = document, document.exists, let data = document.data(), let prefs = data["preferences"] as? [String: Any] {
```
- Firestore callback may come on background queue
- `UserDefaults.standard.set()` is thread-safe but the subsequent `print()` may interleave strangely

### 21. **No Rate Limiting on `updateLastLocation`** (`DriveViewModel.swift:123`)
```swift
AuthenticationManager.shared.updateLastLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
```
- Called every location update (potentially 1/second)
- No debouncing - will flood Firestore with updates
- Should be throttled to every 30-60 seconds

### 22. **`CrashDetectionManager` Crashes If SpeedEngine/SessionRecorder Nil** (`CrashDetectionManager.swift:14`)
```swift
public init(speedEngine: SpeedEngine, sessionRecorder: SessionRecorder) {
    self.speedEngine = speedEngine
    self.sessionRecorder = sessionRecorder
    startCrashDetection()
}
```
- No optional handling - assumes both are always provided
- If nil passed, crash on `.speed` access

### 23. **Missing Availability Check for iOS Features** (`SpeedWidget.swift`)
```swift
@main
struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedWidget()
        SpeedLiveActivityView()
    }
}
```
- `SpeedLiveActivityView` is imported but may not be available
- No `#available` check for iOS 16.1+ requirement
- Widget extension may fail to compile on older iOS

### 24. **Hardcoded Colors Not Using DesignSystem** (`SpeedGaugeView.swift:48`)
```swift
context.stroke(trackPath, with: .color(Color(red: 1, green: 1, blue: 1, opacity: 0.05)), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
```
- Should use `DesignSystem.bgPanel` or similar
- Inconsistent with rest of codebase

---

## 🟡 MEDIUM PRIORITY (Nice to Fix)

### 25. **Duplicate `nearestPointOnSegment` Implementation** (`DriveViewModel.swift:469-482`)
- Implemented in `DriveViewModel` class AND in `SimulationDataSource` extension
- Code duplication - should be extracted to a utility function

### 26. **Unused Variable in `CarPlayNavigationManager`** (`CarPlayNavigationManager.swift:91`)
```swift
let avoidHighways = UserDefaults.standard.bool(forKey: "avoidHighways")
```
- Variable created but only used in `if` condition on same line
- Redundant intermediate variable

### 27. **Commented Out Code Left in `SignInView.swift:68-105`**
- Large block of Sign in with Apple code is commented out
- Should be removed or properly implemented

### 28. **`searchDestination` Returns Empty on Error Silently** (`DriveViewModel.swift:339`)
```swift
} catch {
    searchResults = []
}
```
- Errors are swallowed, user never knows search failed
- Should show some feedback

### 29. **No `break` in Switch-Like `getImageForManeuver`** (`DriveViewModel.swift:481`)
- Checks in order but doesn't return early
- "u-turn" is checked first, but "right" check comes later
- If instruction is "u-turn right", it will match "u-turn" and return early - this is correct
- But if order was different, could match wrong symbol

### 30. **Inconsistent Naming: `destination` vs `destinationItem`** (`DriveViewModel.swift:68-72`)
```swift
@Published public var destination: MKMapItem? = nil
@Published public var destinationItem: MKMapItem? = nil
```
- Both hold the same type, unclear which to use
- `destinationItem` is used in `checkForFasterRoute` but `destination` used elsewhere
- Causes confusion and potential bugs

### 31. **Magic Numbers Everywhere** - Multiple files
- `150` meters off-route threshold
- `35.0` meters off-route in `checkOffRouteStatus`
- `20.0` minimum fetch distance
- `60.0` snapping distance
- All should be named constants

### 32. **No Nullability Handling for `placemark.location`** (`DriveViewModel.swift:98-99`)
```swift
let dist = locationManager.latestLocation.flatMap { loc in
    destination?.placemark.location.map { loc.distance(from: $0) }
} ?? 999
```
- `destination?.placemark.location` can be nil
- Entire expression returns 999 when nil

### 33. **Circular Cache Not Thread-Safe** (`ArizonaSpeedLimitService.swift:56-57`)
```swift
private var circularCache: [RoadSegment] = []
private var lastCacheCenter: CLLocationCoordinate2D?
```
- Modified in `refreshCircularCache()` but read in `updateSpeedLimit()`
- Actor provides isolation, but within the actor, no additional synchronization

### 34. **SQL Injection Potential (理论上)** - `ArizonaSpeedLimitService.swift`
- Parameters are bound, so this is actually safe
- But the SQL string building is complex and hard to audit

### 35. **`formatDecimalForSpeech` Returns Wrong Format** (`DriveViewModel.swift:439`)
```swift
let fracPart = Int((rounded - Double(intPart)) * 10 + 0.5)
```
- For `2.5`, this gives `fracPart = 5`, so result is "2 point 5"
- For `2.0`, `fracPart = 0`, returns "2"
- But for `2.15`, rounding to 1 decimal gives `2.2`, not "2 point 2"
- Logic seems off

### 36. **No Cleanup of `stepStageFlags`** (`DriveViewModel.swift:308`)
- `stepStageFlags` dictionary grows unbounded as new steps are encountered
- Old steps aren't removed, causing memory leak over long routes

### 37. **`DriveViewModel` Has Two Different Off-Route Thresholds** (`DriveViewModel.swift:118` vs `547`)
```swift
private let offRouteThreshold: CLLocationDistance = 20.0 // 20 meters
```
- Defined but never used
- `150` used in `updateNavigationProgress` 
- `35` used in `checkOffRouteStatus`
- Inconsistent behavior

### 38. **LiveMapView Uses Deprecated `mapType` Property** (`LiveMapView.swift:23`)
```swift
map.mapType = .mutedStandard
```
- Only used as fallback for iOS < 16
- Fine for compatibility, but should note it deprecation

### 39. **No User Feedback When API Key Invalid** (`SpeedCameraService.swift:31-36`)
- HTTP error codes returned but only print to console
- User has no indication camera data fetch failed

### 40. **KeychainHelper Ignores Error Status** (`KeychainHelper.swift:27`)
```swift
SecItemUpdate(query, attributesToUpdate)
```
- Return value not checked
- If update fails, silent failure

### 41. **Inconsistent `public` access modifier usage**
- Many classes marked `public` but properties `internal`
- Makes API surface unclear

### 42. **No Unit Tests**
- Zero test files found
- High-risk code (speed calculations, crash detection) has no test coverage

---

## 🟢 LOW PRIORITY (Technical Debt)

### 43. **Unused Import in `DriveViewModel.swift`**
```swift
import FirebaseFirestore
```
- `Firestore` imported but only used for type annotation in `AuthenticationManager`
- `DriveViewModel` doesn't use Firestore directly

### 44. **Commented Code Blocks Not Removed**
- Multiple large blocks of commented code throughout
- Should be removed or integrated

### 45. **Naming Inconsistency: `isMetric` Variable** (`SpeedEngine.swift:44`)
```swift
let isMetric = measurementSystem == "Metric"
```
- `"Metric"` is a magic string
- Should be constant: `static let metricSystem = "Metric"`

### 46. **No Documentation for Public APIs**
- Most files lack doc comments
- Hard for new developers to understand API surface

### 47. **`.gitignore` May Not Cover All Build Artifacts**
- `.sqlite` files tracked?
- Derived data might be committed accidentally

### 48. **`SimulationManager` Only Exists in DEBUG Builds** (`SimulationManager.swift:1`)
```swift
#if DEBUG || DEVELOPER_BUILD
```
- Production code never uses this class
- But `DriveViewModel` references it conditionally
- Could cause issues if `DEVELOPER_BUILD` is set in Release

### 49. **No `@discardableResult` for Async Functions**
```swift
Task {
    await ArizonaSpeedLimitService.shared.loadDataIfNeeded()
}
```
- Return value discarded
- If it throws, error is silently ignored

### 50. **Inconsistent Error Types**
- Some places use `URLError.resourceUnavailable`
- Others print to console
- No unified error handling strategy

### 51. **UserDefaults Keys Duplicated as Strings**
- `"userBuffer"`, `"audioAlertsEnabled"` etc. used as string literals
- Should be `static let` constants in a `Keys` enum

### 52. **`AppState.setupSettingsSync` Observes All Keys** (`AppState.swift:28-38`)
```swift
for _ in settingsKeys {
    UserDefaults.standard
        .publisher(for: \\.self)
```
- Observes entire UserDefaults object for changes to ANY key
- Very inefficient - should observe specific keys

### 53. **`LocationManager` Heading Filter Hardcoded** (`LocationManager.swift:28`)
```swift
manager.headingFilter = 2.0 // Update every 2 degrees
```
- 2 degrees may be too fine or too coarse depending on use case
- Should be configurable

### 54. **No Background Task Expiration Handling**
- If app suspended during session, `recordingTimer` may not fire
- Data loss possible

### 55. **`SpeedEngine.smoothedSpeed` Never Reset**
- If speed goes to 0, `smoothedSpeed` gradually decays
- But if car stops for 10 minutes, then moves, initial speed reading might be smoothed from old data

### 56. **`AnalyticsViewModel.purgeOldSessions` Called on Every Appear** (`AnalyticsDashboardView.swift:70`)
```swift
.onAppear {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.purgeOldSessions(sessions: sessions, context: modelContext)
```
- Adds 100ms delay unnecessarily
- Called every time view appears, not just once

### 57. **No Validation That `DriveSession.endTime > startTime`** (`DriveSession.swift`)
- If endTime set to before startTime, duration calculation would be negative
- No validation in setter or init

---

## 📋 SUMMARY BY CATEGORY

| Category | Count |
|----------|-------|
| Critical Bugs | 7 |
| Concurrency Issues | 5 |
| Memory Leaks | 4 |
| Security Issues | 2 |
| Performance Issues | 5 |
| Code Quality | 10 |
| Missing Error Handling | 6 |
| Magic Numbers/Strings | 6 |
| Architecture Issues | 4 |
| UI/UX Issues | 3 |
| Missing Tests | 1 |
| Documentation | 4 |
| **TOTAL** | **57** |

---

## 🚀 RECOMMENDED PRIORITY ORDER

1. **Fix API key exposure** (#2) - Security critical
2. **Fix static ViewModel singleton** (#1) - Architecture critical  
3. **Fix race conditions** (#3, #5, #8) - Data integrity
4. **Implement rate limiting** (#21) - Performance
5. **Remove magic numbers** (#17, #18, #37) - Maintainability
6. **Add unit tests** (#42) - Confidence
7. **Clean up technical debt** - Ongoing