# Feature Implementation Prompts — SmartSpeedCompanion (Free Features)

> These 9 features are to be built as **free features** (not gated behind ads). The ad layer will be added later when the app reaches 100+ users. Each prompt references actual files and patterns in the existing codebase.

---

## Table of Contents

1. [Custom Named Locations](#1-custom-named-locations)
2. [Trip Fuel Cost Estimator](#2-trip-fuel-cost-estimator)
3. [Offline Map Region Download](#3-offline-map-region-download)
4. [Extended Trip History Access](#4-extended-trip-history-access)
5. [Custom Vehicle Icon](#5-custom-vehicle-icon)
6. [Personalized Speed Alert Profiles](#6-personalized-speed-alert-profiles)
7. [Alert Snooze / "I Know" Button](#7-alert-snooze--i-know-button)
8. [Drive Focus Mode](#8-drive-focus-mode)
9. [Multi-Car Profiles](#9-multi-car-profiles)

---

## 1. Custom Named Locations

**What to build:** Allow users to assign a custom name to any address ("Mom's House," "My Favorite Trailhead"). The name appears on the map, in search results, and in trip history. Free, no limit on naming slots.

### Architecture

**New Model: `NamedLocation`** (`SmartSpeedCompanion/Models/NamedLocation.swift`)

```swift
@Model
final class NamedLocation {
    @Attribute(.unique) var id: UUID
    var name: String           // e.g. "Mom's House"
    var latitude: Double
    var longitude: Double
    var address: String?       // reverse-geocoded address string
    var createdAt: Date
    
    init(name: String, latitude: Double, longitude: Double, address: String?) { ... }
}
```

Follow the same SwiftData pattern as `DriveSession` and `SpeedReading` — `@Model` macro, `@Attribute(.unique)` on `id`.

**New ViewModel: `LocationNamingViewModel`** (Optional — could live in `DriveViewModel`)

Add these to `DriveViewModel` instead to keep things simple:
- `@Published var namedLocations: [NamedLocation] = []` — loaded from SwiftData on init
- `func saveNamedLocation(name: String, coordinate: CLLocationCoordinate2D)` — creates a NamedLocation, reverse-geocodes for an address string, inserts into model context, saves
- `func deleteNamedLocation(_ id: UUID)` — deletes from context
- `func namedLocation(for coordinate: CLLocationCoordinate2D) -> String?` — checks if a coordinate has a saved name (use a small tolerance, ~20m)

### Views to Create/Modify

**New View: `NameLocationSheet`** — a bottom sheet that appears when the user taps a place:
- Shows the address string
- TextField for entering a custom name
- "Save" button
- Option to delete an existing name
- Follow the styling of `NetworkHelpSheet` / `SessionPickerSheet` (same `DesignSystem.bgDeep`, `DesignSystem.cyan` accent, dark scheme)

**Modify: `BottomTransparentHUD` / `MapWithHUDView`**
- Add a long-press or tap action on the map to present the naming sheet
- Or add a "Name This Place" option in the existing navigation/shortcuts flow

**Modify: SearchBarView** — when displaying search results or recent searches, show saved names with a special icon (e.g., `house.fill` with a small tag).

**Modify: Analytics Dashboard trip title** — in `DriveSession.title`, if the start or end coordinate matches a `NamedLocation`, show the custom name instead of the address.

---

## 2. Trip Fuel Cost Estimator

**What to build:** Let users set their vehicle's fuel efficiency (MPG or L/100km) in Settings, then estimate fuel cost + CO₂ emissions for any completed trip. Free, unlimited estimates.

### Data Model

**New `@AppStorage` properties** (in `SettingsView` or `AppState`):
- `vehicleFuelEfficiency: Double` — stored in UserDefaults (defaults to 25 MPG for Imperial, 9.4 L/100km for Metric)
- `fuelUnit: String` — "MPG" or "L/100km"
- `localFuelPrice: Double` — user-set local price per gallon or per liter (defaults to ~$3.50/gal or ~$0.95/L)

### Logic

**New helper functions** (in `SpeedFormatting.swift` or a new `Core/FuelEstimator.swift`):

```swift
struct FuelEstimator {
    static func estimateFuelUsed(
        distanceMiles: Double,
        mpg: Double
    ) -> Double { distanceMiles / mpg }
    
    static func estimateFuelCost(
        fuelUsedGallons: Double,
        pricePerGallon: Double
    ) -> Double { fuelUsedGallons * pricePerGallon }
    
    static func estimateCO2(
        fuelUsedGallons: Double
    ) -> Double { fuelUsedGallons * 19.6 } // lbs CO2 per gallon

    // Metric variants
    static func estimateFuelUsedMetric(
        distanceKm: Double,
        lPer100km: Double
    ) -> Double { (lPer100km / 100) * distanceKm }
    
    static func estimateCostMetric(
        fuelUsedLiters: Double,
        pricePerLiter: Double
    ) -> Double { fuelUsedLiters * pricePerLiter }
    
    static func estimateCO2Metric(
        fuelUsedLiters: Double
    ) -> Double { fuelUsedLiters * 2.31 } // kg CO2 per liter
}
```

### Views to Create/Modify

**Modify: `AnalyticsDashboardView`** — for a selected session, add a "Fuel Cost" card section below `SummaryStatsView`:
- Shows: distance driven, estimated fuel used, estimated cost, estimated CO₂
- Shows a small disclaimer: "Based on your vehicle's MPG setting"
- Links to Settings to set/change fuel efficiency

**Modify: `SettingsView`** — add a new "VEHICLE" section (or add fuel fields to an existing section):
- `vehicleFuelEfficiency` Stepper (range 10–100 MPG or 2–30 L/100km)
- `localFuelPrice` TextField with currency formatting
- Match the existing `Form` section styling (`Section(header: ...)`, `.listRowBackground(DesignSystem.bgPanel)`)

**New View: `FuelCostCard`** — reusable view showing the 4 metrics in a compact card. Follow the design language of `SummaryStatsView`.

---

## 3. Offline Map Region Download (24h)

**What to build:** Let users download a map region for offline browsing. Since this app uses MKMapView (Apple's vector tiles), Apple handles offline map caching automatically starting in iOS 17+. We mainly need to provide a UI for selecting/caching a region and a visual indicator.

### Architecture

> **Note:** iOS 17+ MKMapView already caches tiles. For explicit offline region management in iOS 17+, use `MKMapView`'s `MKMapTileChecker` or pre-load tiles by panning the map. The simplest approach: provide a "Download Here" button that keeps the map centered on the region for a set period while tiles cache naturally.

**New property in `DriveViewModel`:**
- `@Published var offlineRegions: [String] = []` — simple list of region labels the user has downloaded (stored in UserDefaults via `@AppStorage`)
- `@Published var isDownloadingRegion: Bool = false`
- `func downloadCurrentMapRegion() async` — sets a flag, the map view renders the area at multiple zoom levels to force tile caching
- `func clearOfflineRegion(_ label: String)` — removes from UserDefaults list

**UserDefaults persistence:**
- `@AppStorage("savedOfflineRegions") var savedOfflineRegions: String = "[]"` — JSON-encoded array of `[lat, lon, label, timestamp]`

### Views to Modify

**Modify: `MapWithHUDView` / bottom chrome** — add a small "Download Map" button (maybe in the nearby-amenities area or as a new entry in the Navigation Shortcuts menu):
- "Save Map Area" button
- User names the region (optional, defaults to current location name)
- Shows a progress indicator (use an `ProgressView` or an `AnimatedRingView`)
- After download: "Offline ✓" badge on the map

**Modify: `SettingsView`** — add a new "OFFLINE MAPS" section listing saved regions with a delete button for each. Follow the same section style as "NETWORK & DATA".

**New View: `OfflineRegionRow`** — similar styling to `SessionRow` in AnalyticsDashboardView, but shows region name, date saved, and a delete swipe action.

### Important Note
Since tile caching is handled by MKMapView, the "download" primarily means:
1. Center map on the selected region
2. Programmatically zoom to multiple levels (e.g., z14–z17) across the 50km² area
3. Let MKMapView's built-in tile cache do the rest
4. Store the region bounds in UserDefaults for the "saved offline regions" list

---

## 4. Extended Trip History Access

**What to build:** Free users can browse ALL trip history with no time limit. (The ad gate — which will limit to 7 days — comes later.) Currently, `AnalyticsViewModel.purgeOldSessions()` auto-deletes sessions older than 30 days. For now, make all sessions browsable.

### Changes

**Modify: `AnalyticsViewModel.purgeOldSessions()`**
- No changes needed for now — the 30-day auto-purge stays as-is since it's a space management feature, not a gating feature. The ad gate (limiting visible trips to 7 days) will be added later.

**Modify: `SessionPickerSheet`**
- Remove the "30-day note" line about auto-removal for now (or keep it since it's about storage, not gating — your call)

**Modify: `AnalyticsDashboardView.onAppear`**
- Currently auto-selects most recent session. Keep this behavior.

### Future Ad Gate (Not Implemented Yet)
When ads are added, the gate will:
- Show only last 7 days of trips for free users
- Watch an ad to browse the full archive for 24h
- Add an `@AppStorage("tripHistoryAccessUntil")` date property

---

## 5. Custom Vehicle Icon

**What to build:** Let users pick from a catalog of vehicle icons to replace the default blue dot / arrow on the map. Free, all icons unlocked by default. (Ad gate — watch an ad per icon — comes later.)

### Architecture

**New data** (in a new file or in `DriveViewModel`):

```swift
struct VehicleIcon: Identifiable, Codable, Hashable {
    let id: String          // e.g. "sports_car_red"
    let displayName: String // e.g. "Red Sportscar"
    let systemImageName: String // SF Symbol name
    let isPremium: Bool     // false for now, true when ad-gated later
}

extension VehicleIcon {
    static let catalog: [VehicleIcon] = [
        VehicleIcon(id: "default_blue", displayName: "Default Blue Dot", systemImageName: "circle.fill", isPremium: false),
        VehicleIcon(id: "sports_car_red", displayName: "Red Sportscar", systemImageName: "car.side.fill", isPremium: false),
        VehicleIcon(id: "sports_car_blue", displayName: "Blue Sportscar", systemImageName: "car.side.fill", isPremium: false),
        VehicleIcon(id: "pickup_truck", displayName: "Classic Pickup", systemImageName: "truck.pickup.side.fill", isPremium: false),
        VehicleIcon(id: "suv", displayName: "Electric SUV", systemImageName: "suv.side.fill", isPremium: false),
        VehicleIcon(id: "motorcycle", displayName: "Motorcycle", systemImageName: "motorcycle.fill", isPremium: false),
        VehicleIcon(id: "scooter", displayName: "Scooter", systemImageName: "scooter", isPremium: false),
        VehicleIcon(id: "convertible", displayName: "Retro Convertible", systemImageName: "car.side.fill", isPremium: false),
        // Add more as desired
    ]
}
```

**New `@AppStorage` property** (in `DriveViewModel` or `SettingsView`):
- `selectedVehicleIconId: String` — defaults to `"default_blue"`

### Views to Create

**New View: `VehicleIconPickerSheet`** — a bottom sheet with a grid of icon options:
- Grid layout (e.g., 3 columns) showing each icon
- Selected icon has a cyan border (like the route selector)
- Tap to select
- Each cell shows the SF Symbol and name
- Match the styling of existing sheets (`.presentationDetents([.medium])`, dark scheme)

**Modify: `LiveMapView`** (the MKMapView wrapper) — replace the default user annotation view:
- In `mapView(_:viewFor:)` delegate method, return a custom `MKAnnotationView` with the selected SF Symbol
- Read `driveViewModel.selectedVehicleIconId` to pick the right SF Symbol
- For the default blue dot, return `nil` to let MKMapView use the native blue dot

**Modify: `SettingsView`** — add a "VEHICLE ICON" row under "MAP" section:
- Shows the currently selected icon preview
- Tap to open `VehicleIconPickerSheet`
- Follow the same section styling as existing rows

---

## 6. Personalized Speed Alert Profiles

**What to build:** Let users create multiple speed alert profiles with custom per-road-type thresholds. Free to create any number of profiles. (Ad gate — capped at 1 free profile, watch ad for more — comes later.)

### Data Model

**New Model: `SpeedAlertProfile`** (`SmartSpeedCompanion/Models/SpeedAlertProfile.swift`)

```swift
@Model
final class SpeedAlertProfile {
    @Attribute(.unique) var id: UUID
    var name: String                      // "Daily Commute", "Weekend Cruise"
    var isActive: Bool                    // currently selected profile
    var createdAt: Date
    
    // Thresholds per road type (in mph or km/h — stored as mph, converted for display)
    var highwayBuffer: Int               // e.g. +5
    var residentialBuffer: Int           // e.g. +3
    var schoolZoneBuffer: Int            // e.g. 0 (exactly at limit)
    var workZoneBuffer: Int              // e.g. 0
    var arterialBuffer: Int              // e.g. +5
    var defaultBuffer: Int              // fallback for unknown road types
    
    init(...) { ... }
}
```

### ViewModel Changes

**Add to `DriveViewModel`:**
- `@Published var alertProfiles: [SpeedAlertProfile] = []` — loaded from SwiftData
- `@Published var activeProfileId: UUID?`
- `func createNewProfile(name: String) -> SpeedAlertProfile`
- `func activateProfile(_ id: UUID)` — sets the active profile and applies its buffers to `SpeedEngine.userBuffer`
- `func deleteProfile(_ id: UUID)` — deletes from context
- `func applyProfileToEngine(_ profile: SpeedAlertProfile)` — maps road-type buffers to the appropriate SpeedEngine properties

**Modify `SpeedEngine`:**
- Currently uses a single `userBuffer: Int` (stored in `@AppStorage("userBuffer")`)
- We'll need to either:
  - a) Keep the single buffer for the "Default" mode and override per-road-type when a custom profile is active
  - b) Add per-road-type buffer logic that queries the road type from the current GPS context
- The simpler approach (a): When a custom profile is active, `SpeedEngine` reads the profile's buffer for the current road type. Road type can be determined from `MKMapItem` attributes or `RoadGeocoder`.

### Views to Create

**New View: `AlertProfilesListView`** — accessible from Settings → ALERTS:
- List of saved profiles
- "Add New Profile" button
- Swipe to delete
- Tap to edit
- Show active profile with a checkmark

**New View: `AlertProfileEditorView`** — form for configuring a profile:
- `name` TextField
- Steppers/sliders for each road type buffer
- Same styling as `SettingsView` sections

**Modify: `SettingsView`** — add a "Speed Alert Profiles" row under "ALERTS":
- Shows the currently active profile name
- Tap to open `AlertProfilesListView`
- After the existing buffer slider, add: "Active Profile: [name]"

**Modify: `BufferSliderView`** — when a custom profile is active, show the profile name and individual road-type sliders instead of the single slider.

---

## 7. Alert Snooze / "I Know" Button

**What to build:** When a speeding alert fires, show an "I Know" button that silences the alert for 15 seconds. Free, unlimited snoozes. (Ad gate — capped at 1 snooze per ad watched — comes later.)

### Architecture

**New `@AppStorage` property:**
- `@Published var snoozedUntil: Date?` — in `DriveViewModel` or `AlertEngine`
- `@Published var isSnoozed: Bool = false` — computed from `snoozedUntil > Date.now`

**Modify: `AlertEngine`**

Add snooze logic:
- `var snoozedUntil: Date?` — when set, the engine skips `triggerAlert()` until the date passes
- `func snoozeFor(_ seconds: TimeInterval)` — sets `snoozedUntil = Date().addingTimeInterval(seconds)`
- In `startMonitoring()`, check `snoozedUntil` before triggering: if the current time is before `snoozedUntil`, skip `triggerAlert()`
- Add a `@Published var isSnoozed: Bool` so the UI can react

**Key behavior:**
- Default free behavior: unlimited snoozes, each lasting 15 seconds
- After 15 seconds, if still speeding, the beep resumes
- Only one snooze at a time (can't stack)
- Snooze auto-expires if the car stops (speed drops below 2 m/s for >30 seconds)
- The consecutive-seconds counter keeps ticking during snooze (so when the beep resumes, the user sees the correct "seconds over limit" count)

### Views to Modify

**Modify: `SpeedDisplayView`** — when status is `.over` and `isSnoozed == false`, show an "I Know" button:
- Position it below the "SECONDS OVER LIMIT" alert box
- Cyan outlined button, similar styling to the existing alert box
- Text: "I Know" with a small SF Symbol like `hand.raised.slash`
- Tapping calls `driveViewModel.alertEngine.snoozeFor(15)`
- When snoozing is active, show remaining snooze time: "Snoozed (12s remaining)" with a progress ring or countdown
- Use a `Timer.publish(every: 1)` to update the countdown display

**Optional: Modify `MapWithHUDView`** — show a small "Snoozed" indicator in the top area when an alert is snoozed, so the user knows even if they're not looking at the speed display.

---

## 8. Drive Focus Mode

**What to build:** A distraction-free dashboard showing ONLY speed and speed limit. No map, no buttons, no navigation bar. Free, always accessible. (Ad gate — 24h unlock per ad — comes later.)

### Architecture

**New `@AppStorage` property:**
- `@Published var isDriveFocusMode: Bool = false` — in `DriveViewModel`

**New View: `DriveFocusView`** (`SmartSpeedCompanion/Views/Drive/DriveFocusView.swift`)

A full-screen view with:
- Background: solid black (max readability, minimal battery drain)
- Speed number: huge, centered, in the status color (like `SpeedReadout` but even larger — think 160pt font)
- Speed limit: smaller, just below or to the side
- Unit label: small, dimmed
- Status dot: small colored dot in top-right corner (green/amber/red)
- That's it. No map, no buttons, no anything else.

```swift
struct DriveFocusView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @State private var showExitHint = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 10) {
                Spacer()
                
                // Big speed
                Text("\(Int(driveViewModel.speed))")
                    .font(.system(size: 160, weight: .black, design: .rounded))
                    .foregroundColor(DesignSystem.colorForStatus(driveViewModel.status))
                    .contentTransition(.numericText())
                
                // Limit + unit
                HStack(spacing: 12) {
                    let measurementSystem = SpeedFormatting.measurementSystem()
                    let limitValue = SpeedFormatting.displayLimit(forMph: driveViewModel.limit, measurementSystem: measurementSystem)
                    Text(limitValue == 0 ? "--" : "\(limitValue)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                // Recording indicator (existing)
                if driveViewModel.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(DesignSystem.alertRed).frame(width: 8, height: 8)
                        Text("REC")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(DesignSystem.alertRed)
                    }
                    .padding(.top, 8)
                }
                
                Spacer()
                
                // Exit hint — appears after a short delay
                if showExitHint {
                    Text("Long-press anywhere to exit Focus Mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.bottom, 40)
                }
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showExitHint = true }
            }
        }
        .onLongPressGesture(minimumDuration: 1.5) {
            driveViewModel.isDriveFocusMode = false
        }
        .animation(.easeInOut(duration: 0.3), value: driveViewModel.speed)
        .animation(.easeInOut(duration: 0.3), value: driveViewModel.status)
    }
}
```

### Views to Modify

**Modify: `MapWithHUDView` / `BottomTransparentHUD`**
- Add a small "Focus" button (e.g., an icon `eye.fill` or `target`) near the START/STOP pill
- Tapping sets `driveViewModel.isDriveFocusMode = true`
- The button should be visible even during recording

**Modify: `DriveRootView`** (or `AppRootView`)
- When `driveViewModel.isDriveFocusMode == true`, present `DriveFocusView` as a full-screen cover
- Use `.fullScreenCover(isPresented: $driveViewModel.isDriveFocusMode)` 
- In DriveFocusMode, the existing `MapWithHUDView` tab bar is hidden

**CarPlay Consideration:**
- For now, Drive Focus Mode on phone only. CarPlay Focus Mode can be a future enhancement.

---

## 9. Multi-Car Profiles

**What to build:** Let users create multiple vehicle profiles with separate buffer settings, alert preferences, and stats. Free, up to 5 profiles. (Ad gate — second profile costs 1 ad, third costs another, etc. — comes later.)

### Data Model

**New Model: `VehicleProfile`** (`SmartSpeedCompanion/Models/VehicleProfile.swift`)

```swift
@Model
final class VehicleProfile {
    @Attribute(.unique) var id: UUID
    var name: String                    // "Work Truck", "Family SUV"
    var isActive: Bool
    var createdAt: Date
    
    // Settings (mirrors what's in @AppStorage today)
    var userBuffer: Int                 // replaces the global userBuffer
    var audioAlertsEnabled: Bool
    var hapticAlertsEnabled: Bool
    var hapticAlertStyle: String
    var avoidHighways: Bool
    var vehicleIconId: String           // references the vehicle icon picker
    var measurementSystem: String
    
    // Stats (separate tracking per vehicle)
    var totalTrips: Int
    var totalDistanceMiles: Double
    var totalDurationSeconds: TimeInterval
    
    init(...) { ... }
}
```

### ViewModel Changes

**Add to `DriveViewModel`:**
- `@Published var vehicleProfiles: [VehicleProfile] = []` — loaded from SwiftData
- `@Published var activeVehicleId: UUID?`
- `func createVehicleProfile(name: String) -> VehicleProfile`
- `func activateVehicleProfile(_ id: UUID)` — applies the profile's settings to all relevant UserDefaults keys + toggles
- `func deleteVehicleProfile(_ id: UUID)` — can't delete the last profile
- `func loadProfiles()` — called on init

**Migration Strategy:**
- On first launch with this feature, create a default "Primary Vehicle" profile populated from the existing `@AppStorage` values
- The profile's `isActive = true`
- Existing UserDefaults keys (`userBuffer`, `audioAlertsEnabled`, etc.) become "mirrored" from the active profile

### Views to Create/Modify

**Modify: `SettingsView`** — replace the top-level "ALERTS" + "NAVIGATION" sections so their values come from the active VehicleProfile rather than `@AppStorage`:
- Add a "VEHICLE PROFILES" section at the top
- Show the active vehicle name as a tappable row that opens `VehicleProfilePickerView`
- All subsequent settings sections read from the active profile

**New View: `VehicleProfilePickerView`** — a picker/list of vehicles:
- Each row shows vehicle name, a small icon, and a checkmark if active
- "Add Vehicle" button at the bottom (capped at 5)
- Swipe to delete (can't delete if only one remains)
- Tap to switch active vehicle

**New View: `VehicleProfileEditorView`** — form for editing a vehicle's settings:
- Name TextField
- All the same controls as the current Settings view (buffer slider, audio toggle, haptics, avoid highways, measurement system, vehicle icon)
- Same section styling as SettingsView

**Modify: `AnalyticsViewModel`** — when filtering sessions, also filter by active vehicle:
- Add a `vehicleProfileId` property to `DriveSession` (optional, set when session starts)
- In the analytics dashboard, show sessions only for the currently active vehicle
- Add a vehicle filter toggle if the user wants to see all vehicles' data

**Modify: `DriveSession`** model — add optional `vehicleProfileId`:
```swift
var vehicleProfileId: UUID?
var vehicleName: String?
```
Set these when `startSession()` is called, from the active profile.

---

## Implementation Order Recommendation

I recommend building features in this order, from simplest to most complex:

| Order | Feature | Dependencies | Estimated Effort |
|-------|---------|-------------|-----------------|
| 1 | **Custom Named Locations** | New model, new sheet UI, search integration | ~2-3 days |
| 2 | **Alert Snooze** | AlertEngine modification, small UI addition | ~1-2 days |
| 3 | **Custom Vehicle Icon** | Icon catalog data, LiveMapView modification, picker sheet | ~2-3 days |
| 4 | **Trip Fuel Cost Estimator** | New core logic, analytics card UI, settings fields | ~2-3 days |
| 5 | **Drive Focus Mode** | New full-screen view, toggle in HUD | ~1-2 days |
| 6 | **Personalized Alert Profiles** | New model, SpeedEngine changes, settings UI | ~4-5 days |
| 7 | **Multi-Car Profiles** | New model, Settings rewrite, session association | ~5-7 days |
| 8 | **Offline Map Region Download** | MKMapView tile caching, settings management | ~3-4 days |
| 9 | **Extended Trip History** | Already mostly free; minimal changes | ~1 day |

---

## Technical Patterns to Follow

### SwiftData
- All new persistent models use `@Model` macro, same as `DriveSession` and `SpeedReading`
- Context accessed via `@Environment(\.modelContext) private var modelContext`
- Queries use `@Query` property wrapper in views

### ViewModel Pattern
- `@MainActor` classes conforming to `ObservableObject`
- `@Published` properties for reactive UI
- Services injected in `init()`
- Same pattern as `DriveViewModel` and `AnalyticsViewModel`

### UI Patterns
- Dark color scheme throughout (`.preferredColorScheme(.dark)`)
- `DesignSystem.bgDeep` for backgrounds, `DesignSystem.bgPanel` for card backgrounds
- `DesignSystem.cyan` for accent color
- `DesignSystem.colorForStatus(...)` for speed status colors
- `.liquidGlass(...)` and `.liquidGlassChip(...)` for glass-morphism effects
- Full-screen covers and sheets follow existing patterns in `SettingsView`

### UserDefaults / @AppStorage
- Non-sensitive settings use `@AppStorage` (same as existing `userBuffer`, `audioAlertsEnabled`, etc.)
- UserDefaults keys are string constants defined alongside the property
- Settings sync to Firebase via `AuthenticationManager.shared.syncUserPreferences()` (the existing mechanism)

### Safety Rule
None of these features gate anything safety-critical. Core speed display, speeding alerts, and emergency functionality remain untouched and always free.
