//
//  SettingsManager.swift
//  Ham Digital
//
//  Handles persistent settings and GPS-based location.
//  Uses iCloud Key-Value Store for sync across devices and persistence across installs.
//  Falls back to UserDefaults if iCloud is unavailable.
//

import Foundation
import CoreLocation
import Combine

@MainActor
class SettingsManager: NSObject, ObservableObject {
    static let shared = SettingsManager()

    // MARK: - Storage

    /// iCloud Key-Value Store for cross-device sync and persistence across installs
    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard

    /// Save a value to both iCloud and local storage
    private func save<T>(_ value: T, forKey key: String) {
        local.set(value, forKey: key)
        cloud.set(value, forKey: key)
        cloud.synchronize()
    }

    /// Load a string value, preferring iCloud over local
    private func loadString(forKey key: String, default defaultValue: String) -> String {
        if let cloudValue = cloud.string(forKey: key), !cloudValue.isEmpty {
            return cloudValue
        }
        return local.string(forKey: key) ?? defaultValue
    }

    /// Load a double value, preferring iCloud over local
    private func loadDouble(forKey key: String, default defaultValue: Double) -> Double {
        let cloudValue = cloud.double(forKey: key)
        if cloudValue != 0 {
            return cloudValue
        }
        let localValue = local.double(forKey: key)
        return localValue != 0 ? localValue : defaultValue
    }

    /// Load a bool value, preferring iCloud over local
    private func loadBool(forKey key: String, default defaultValue: Bool) -> Bool {
        // Check if key exists in cloud first
        if cloud.object(forKey: key) != nil {
            return cloud.bool(forKey: key)
        }
        if local.object(forKey: key) != nil {
            return local.bool(forKey: key)
        }
        return defaultValue
    }

    // MARK: - Published Properties (persisted via didSet)

    @Published var callsign: String {
        didSet { save(callsign, forKey: "callsign") }
    }

    @Published var operatorName: String {
        didSet { save(operatorName, forKey: "operatorName") }
    }

    @Published var qth: String {
        didSet { save(qth, forKey: "qth") }
    }

    @Published var grid: String {
        didSet { save(grid, forKey: "grid") }
    }

    @Published var useGPSLocation: Bool {
        didSet {
            save(useGPSLocation, forKey: "useGPSLocation")
            if useGPSLocation {
                requestLocationUpdate()
            }
        }
    }

    // GPS-derived values (not persisted - updated from GPS)
    @Published var gpsGrid: String = ""
    @Published var gpsQTH: String = ""
    @Published var locationStatus: LocationStatus = .unknown

    // RTTY Settings
    @Published var rttyBaudRate: Double {
        didSet { save(rttyBaudRate, forKey: "rttyBaudRate") }
    }

    @Published var rttyMarkFreq: Double {
        didSet { save(rttyMarkFreq, forKey: "rttyMarkFreq") }
    }

    @Published var rttyShift: Double {
        didSet { save(rttyShift, forKey: "rttyShift") }
    }

    @Published var rttySquelch: Double {
        didSet { save(rttySquelch, forKey: "rttySquelch") }
    }

    // MARK: - Location

    enum LocationStatus: Equatable {
        case unknown
        case denied
        case updating
        case current
        case error(String)
    }

    private var locationManager: CLLocationManager?
    private let geocoder = CLGeocoder()

    // MARK: - Computed Properties

    /// Returns the effective grid square (GPS or manual based on toggle)
    var effectiveGrid: String {
        useGPSLocation && !gpsGrid.isEmpty ? gpsGrid : grid
    }

    /// Returns the effective QTH (GPS or manual based on toggle)
    var effectiveQTH: String {
        useGPSLocation && !gpsQTH.isEmpty ? gpsQTH : qth
    }

    // MARK: - Initialization

    override init() {
        // Load persisted values (prefer iCloud, fall back to local)
        self.callsign = Self.initialLoadString(forKey: "callsign", default: "N0CALL")
        self.operatorName = Self.initialLoadString(forKey: "operatorName", default: "")
        self.qth = Self.initialLoadString(forKey: "qth", default: "")
        self.grid = Self.initialLoadString(forKey: "grid", default: "")
        self.useGPSLocation = Self.initialLoadBool(forKey: "useGPSLocation", default: true)

        self.rttyBaudRate = Self.initialLoadDouble(forKey: "rttyBaudRate", default: 45.45)
        self.rttyMarkFreq = Self.initialLoadDouble(forKey: "rttyMarkFreq", default: 2125.0)
        self.rttyShift = Self.initialLoadDouble(forKey: "rttyShift", default: 170.0)
        self.rttySquelch = Self.initialLoadDouble(forKey: "rttySquelch", default: 0.3)

        super.init()

        // Listen for iCloud changes from other devices
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )

        // Trigger initial sync
        cloud.synchronize()

        setupLocationManager()

        if useGPSLocation {
            requestLocationUpdate()
        }
    }

    // Static helpers for init (before self is available)
    private static func initialLoadString(forKey key: String, default defaultValue: String) -> String {
        let cloud = NSUbiquitousKeyValueStore.default
        let local = UserDefaults.standard
        if let cloudValue = cloud.string(forKey: key), !cloudValue.isEmpty {
            return cloudValue
        }
        return local.string(forKey: key) ?? defaultValue
    }

    private static func initialLoadDouble(forKey key: String, default defaultValue: Double) -> Double {
        let cloud = NSUbiquitousKeyValueStore.default
        let local = UserDefaults.standard
        let cloudValue = cloud.double(forKey: key)
        if cloudValue != 0 { return cloudValue }
        let localValue = local.double(forKey: key)
        return localValue != 0 ? localValue : defaultValue
    }

    private static func initialLoadBool(forKey key: String, default defaultValue: Bool) -> Bool {
        let cloud = NSUbiquitousKeyValueStore.default
        let local = UserDefaults.standard
        if cloud.object(forKey: key) != nil { return cloud.bool(forKey: key) }
        if local.object(forKey: key) != nil { return local.bool(forKey: key) }
        return defaultValue
    }

    // MARK: - iCloud Sync

    @objc private func cloudDidChange(_ notification: Notification) {
        Task { @MainActor in
            // Reload values when iCloud data changes from another device
            self.callsign = loadString(forKey: "callsign", default: "N0CALL")
            self.operatorName = loadString(forKey: "operatorName", default: "")
            self.qth = loadString(forKey: "qth", default: "")
            self.grid = loadString(forKey: "grid", default: "")
            self.useGPSLocation = loadBool(forKey: "useGPSLocation", default: true)
            self.rttyBaudRate = loadDouble(forKey: "rttyBaudRate", default: 45.45)
            self.rttyMarkFreq = loadDouble(forKey: "rttyMarkFreq", default: 2125.0)
            self.rttyShift = loadDouble(forKey: "rttyShift", default: 170.0)
            self.rttySquelch = loadDouble(forKey: "rttySquelch", default: 0.3)
        }
    }

    // MARK: - Location Manager

    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocationUpdate() {
        guard let manager = locationManager else { return }

        switch manager.authorizationStatus {
        case .notDetermined:
            locationStatus = .unknown
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationStatus = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            locationStatus = .updating
            manager.requestLocation()
        @unknown default:
            locationStatus = .unknown
        }
    }

    // MARK: - Grid Square Calculation

    /// Convert latitude/longitude to Maidenhead grid square (6 characters)
    func coordinatesToGrid(latitude: Double, longitude: Double) -> String {
        let lon = longitude + 180
        let lat = latitude + 90

        let field1 = Int(lon / 20)
        let field2 = Int(lat / 10)
        let square1 = Int((lon - Double(field1 * 20)) / 2)
        let square2 = Int(lat - Double(field2 * 10))
        let subsquare1 = Int((lon - Double(field1 * 20) - Double(square1 * 2)) * 12)
        let subsquare2 = Int((lat - Double(field2 * 10) - Double(square2)) * 24)

        let chars1 = "ABCDEFGHIJKLMNOPQR"
        let chars2 = "abcdefghijklmnopqrstuvwx"

        let f1 = chars1[chars1.index(chars1.startIndex, offsetBy: field1)]
        let f2 = chars1[chars1.index(chars1.startIndex, offsetBy: field2)]
        let s1 = "\(square1)"
        let s2 = "\(square2)"
        let ss1 = chars2[chars2.index(chars2.startIndex, offsetBy: subsquare1)]
        let ss2 = chars2[chars2.index(chars2.startIndex, offsetBy: subsquare2)]

        return "\(f1)\(f2)\(s1)\(s2)\(ss1)\(ss2)".uppercased()
    }
}

// MARK: - CLLocationManagerDelegate

extension SettingsManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            // Calculate grid square
            gpsGrid = coordinatesToGrid(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )

            // Reverse geocode for QTH
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first {
                    let city = placemark.locality ?? ""
                    let state = placemark.administrativeArea ?? ""
                    if !city.isEmpty && !state.isEmpty {
                        gpsQTH = "\(city), \(state)"
                    } else if !city.isEmpty {
                        gpsQTH = city
                    } else {
                        gpsQTH = placemark.name ?? ""
                    }
                }
            } catch {
                print("[SettingsManager] Geocoding error: \(error)")
            }

            locationStatus = .current
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            print("[SettingsManager] Location error: \(error)")
            locationStatus = .error(error.localizedDescription)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if useGPSLocation {
                    requestLocationUpdate()
                }
            case .denied, .restricted:
                locationStatus = .denied
            default:
                break
            }
        }
    }
}
