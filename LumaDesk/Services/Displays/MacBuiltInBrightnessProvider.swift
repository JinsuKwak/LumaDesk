import CoreGraphics
import Darwin
import Foundation
import IOKit

final class MacBuiltInBrightnessProvider: BuiltInBrightnessProvider {
    func readBuiltInBrightness() async throws -> Double {
        try await Task.detached(priority: .utility) {
            try autoreleasepool {
                try Self.readBrightnessSynchronously()
            }
        }.value
    }

    private static func readBrightnessSynchronously() throws -> Double {
        let signatures = builtInDisplaySignatures()
        guard !signatures.isEmpty else {
            throw DisplayBrightnessError.noBuiltInDisplay
        }

        for signature in signatures {
            if let brightness = DisplayServicesBrightnessReader.readBrightness(displayID: signature.displayID) {
                return brightness
            }
        }

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            throw DisplayBrightnessError.noReadableBrightness
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            var brightness: Float = 0
            guard IODisplayGetFloatParameter(service, IOOptionBits(0), kIODisplayBrightnessKey as CFString, &brightness) == KERN_SUCCESS else {
                continue
            }

            if signatures.contains(where: { matchesBuiltInSignature(service: service, signature: $0) })
                || ioDisplayServiceLooksBuiltIn(service)
            {
                return Double(brightness).clamped(to: 0 ... 1)
            }
        }

        throw DisplayBrightnessError.noReadableBrightness
    }

    private struct DisplaySignature {
        var displayID: CGDirectDisplayID
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
        var ioDisplayLocation: String?
    }

    private static func builtInDisplaySignatures() -> [DisplaySignature] {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return []
        }

        return displays.prefix(Int(count)).compactMap { display in
            let infoDictionary = CoreDisplay_DisplayCreateInfoDictionary(display)?.takeRetainedValue() as NSDictionary?
            let ioDisplayLocation = infoDictionary?[kIODisplayLocationKey] as? String
                ?? infoDictionary?["IODisplayLocation"] as? String

            guard CGDisplayIsBuiltin(display) != 0 || coreDisplayInfoLooksBuiltIn(infoDictionary) else {
                return nil
            }

            return DisplaySignature(
                displayID: display,
                vendor: CGDisplayVendorNumber(display),
                model: CGDisplayModelNumber(display),
                serial: CGDisplaySerialNumber(display),
                ioDisplayLocation: ioDisplayLocation
            )
        }
    }

    private static func matchesBuiltInSignature(service: io_service_t, signature: DisplaySignature) -> Bool {
        if
            let ioDisplayLocation = signature.ioDisplayLocation,
            let servicePath = ioRegistryPath(for: service),
            (servicePath == ioDisplayLocation || servicePath.contains(ioDisplayLocation) || ioDisplayLocation.contains(servicePath))
        {
            return true
        }

        let vendor = uint32Property(service: service, key: "DisplayVendorID")
        let product = uint32Property(service: service, key: "DisplayProductID")
        let serial = uint32Property(service: service, key: "DisplaySerialNumber")

        guard vendor == signature.vendor, product == signature.model else {
            return false
        }

        return signature.serial == 0 || serial == 0 || serial == signature.serial
    }

    private static func coreDisplayInfoLooksBuiltIn(_ infoDictionary: NSDictionary?) -> Bool {
        guard let infoDictionary else { return false }

        if let location = infoDictionary[kIODisplayLocationKey] as? String ?? infoDictionary["IODisplayLocation"] as? String {
            if location.localizedCaseInsensitiveContains("AppleCLCD2") {
                return true
            }
        }

        return productNameLooksBuiltIn(productName(from: infoDictionary))
    }

    private static func ioDisplayServiceLooksBuiltIn(_ service: io_service_t) -> Bool {
        if let servicePath = ioRegistryPath(for: service), servicePath.localizedCaseInsensitiveContains("AppleCLCD2") {
            return true
        }

        guard
            let unmanaged = IODisplayCreateInfoDictionary(service, IOOptionBits(0))
        else {
            return false
        }

        let infoDictionary = unmanaged.takeRetainedValue() as NSDictionary
        return productNameLooksBuiltIn(productName(from: infoDictionary))
    }

    private static func productName(from infoDictionary: NSDictionary) -> String {
        if let name = infoDictionary["DisplayProductName"] as? String {
            return name
        }

        if let names = infoDictionary["DisplayProductName"] as? [String: String] {
            return names["en_US"] ?? names.first?.value ?? ""
        }

        if let names = infoDictionary[kDisplayProductName] as? [String: String] {
            return names["en_US"] ?? names.first?.value ?? ""
        }

        return ""
    }

    private static func productNameLooksBuiltIn(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("built-in")
            || name.contains("color lcd")
            || name.contains("liquid retina")
    }

    private static func ioRegistryPath(for service: io_service_t) -> String? {
        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { pathPointer.deallocate() }

        guard IORegistryEntryGetPath(service, kIOServicePlane, pathPointer) == KERN_SUCCESS else {
            return nil
        }

        return String(cString: pathPointer)
    }

    private static func uint32Property(service: io_service_t, key: String) -> UInt32 {
        guard
            let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0),
            let number = unmanaged.takeRetainedValue() as? NSNumber
        else {
            return 0
        }

        return number.uint32Value
    }
}

private enum DisplayServicesBrightnessReader {
    typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let function: GetBrightnessFunction? = {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
            let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else {
            return nil
        }

        return unsafeBitCast(symbol, to: GetBrightnessFunction.self)
    }()

    static func readBrightness(displayID: CGDirectDisplayID) -> Double? {
        guard let function else { return nil }

        var brightness: Float = 0
        guard function(displayID, &brightness) == 0 else { return nil }

        return Double(brightness).clamped(to: 0 ... 1)
    }
}
