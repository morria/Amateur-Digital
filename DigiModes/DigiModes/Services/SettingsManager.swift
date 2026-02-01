//
//  SettingsManager.swift
//  DigiModes
//
//  Handles persistent settings and GPS-based location
//

import Foundation
import CoreLocation
import Combine

@MainActor
class SettingsManager: NSObject, ObservableObject {
    static let shared = SettingsManager()

    // MARK: - Published Properties (persisted via didSet)

    @Published var callsign: String {
        didSet { UserDefaults.standard.set(callsign, forKey: "callsign") }
    }

    @Published var operatorName: String {
        didSet { UserDefaults.standard.set(operatorName, forKey: "operatorName") }
    }

    @Published var qth: String {
        didSet { UserDefaults.standard.set(qth, forKey: "qth") }
    }

    @Published var grid: String {
        didSet { UserDefaults.standard.set(grid, forKey: "grid") }
    }

    @Published var useGPSLocation: Bool {
        didSet {
            UserDefaults.standard.set(useGPSLocation, forKey: "useGPSLocation")
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
        didSet { UserDefaults.standard.set(rttyBaudRate, forKey: "rttyBaudRate") }
    }

    @Published var rttyMarkFreq: Double {
        didSet { UserDefaults.standard.set(rttyMarkFreq, forKey: "rttyMarkFreq") }
    }

    @Published var rttyShift: Double {
        didSet { UserDefaults.standard.set(rttyShift, forKey: "rttyShift") }
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
        // Load persisted values
        self.callsign = UserDefaults.standard.string(forKey: "callsign") ?? "N0CALL"
        self.operatorName = UserDefaults.standard.string(forKey: "operatorName") ?? ""
        self.qth = UserDefaults.standard.string(forKey: "qth") ?? ""
        self.grid = UserDefaults.standard.string(forKey: "grid") ?? ""
        self.useGPSLocation = UserDefaults.standard.object(forKey: "useGPSLocation") as? Bool ?? true

        self.rttyBaudRate = UserDefaults.standard.object(forKey: "rttyBaudRate") as? Double ?? 45.45
        self.rttyMarkFreq = UserDefaults.standard.object(forKey: "rttyMarkFreq") as? Double ?? 2125.0
        self.rttyShift = UserDefaults.standard.object(forKey: "rttyShift") as? Double ?? 170.0

        super.init()

        setupLocationManager()

        if useGPSLocation {
            requestLocationUpdate()
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
