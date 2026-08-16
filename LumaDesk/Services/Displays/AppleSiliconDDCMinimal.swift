// Adapted from waydabber/AppleSiliconDDC, MIT License.
// Only the DDC discovery/read/write path required by LumaDesk is vendored here.

import CoreGraphics
import Foundation
import IOKit

private let ddc7BitAddress: UInt8 = 0x37
private let ddcDataAddress: UInt8 = 0x51

struct AppleSiliconDDCDisplay {
    var id: String
    var edidUUID: String
    var manufacturerID: String
    var productName: String
    var serialNumber: Int64
    var alphanumericSerialNumber: String
    var ioDisplayLocation: String
    var transportUpstream: String
    var transportDownstream: String
    var service: IOAVService?

    var displayName: String {
        if !productName.isEmpty {
            return productName
        }

        if !manufacturerID.isEmpty {
            return "\(manufacturerID) Display"
        }

        return "External Display"
    }
}

enum AppleSiliconDDCMinimal {
    private static let maxMatchScore = 20

    struct DDCValue {
        var current: UInt16
        var max: UInt16
    }

    struct IORegistryDisplayService {
        var edidUUID = ""
        var manufacturerID = ""
        var productName = ""
        var serialNumber: Int64 = 0
        var alphanumericSerialNumber = ""
        var location = ""
        var ioDisplayLocation = ""
        var transportUpstream = ""
        var transportDownstream = ""
        var service: IOAVService?
        var serviceLocation = 0
        var displayAttributes: NSDictionary?
    }

    static var isSupportedPlatform: Bool {
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }

    static func discoverDisplays() -> [AppleSiliconDDCDisplay] {
        guard isSupportedPlatform else { return [] }

        return getIORegistryServicesForMatching()
            .filter { service in
                service.service != nil
                    && (!service.edidUUID.isEmpty
                        || !service.manufacturerID.isEmpty
                        || !service.productName.isEmpty
                        || !service.transportUpstream.isEmpty
                        || !service.transportDownstream.isEmpty)
            }
            .map { service in
                let stableID = [
                    service.edidUUID,
                    service.alphanumericSerialNumber,
                    service.ioDisplayLocation
                ]
                    .first { !$0.isEmpty } ?? UUID().uuidString

                return AppleSiliconDDCDisplay(
                    id: stableID,
                    edidUUID: service.edidUUID,
                    manufacturerID: service.manufacturerID,
                    productName: service.productName,
                    serialNumber: service.serialNumber,
                    alphanumericSerialNumber: service.alphanumericSerialNumber,
                    ioDisplayLocation: service.ioDisplayLocation,
                    transportUpstream: service.transportUpstream,
                    transportDownstream: service.transportDownstream,
                    service: service.service
                )
            }
    }

    static func read(service: IOAVService?, command: UInt8) -> DDCValue? {
        var send: [UInt8] = [command]
        var reply = [UInt8](repeating: 0, count: 11)

        guard performDDCCommunication(service: service, send: &send, reply: &reply) else {
            return nil
        }

        return DDCValue(
            current: (UInt16(reply[8]) << 8) + UInt16(reply[9]),
            max: (UInt16(reply[6]) << 8) + UInt16(reply[7])
        )
    }

    static func write(
        service: IOAVService?,
        command: UInt8,
        value: UInt16,
        packetSourceAddress: UInt8 = ddcDataAddress,
        writeSleepTime: UInt32 = 10_000,
        writeCycles: UInt8 = 2,
        retryAttempts: UInt8 = 4,
        retrySleepTime: UInt32 = 20_000
    ) -> Bool {
        var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 0xFF)]
        var reply: [UInt8] = []
        return performDDCCommunication(
            service: service,
            send: &send,
            reply: &reply,
            packetSourceAddress: packetSourceAddress,
            writeSleepTime: writeSleepTime,
            writeCycles: writeCycles,
            retryAttempts: retryAttempts,
            retrySleepTime: retrySleepTime
        )
    }

    private static func performDDCCommunication(
        service: IOAVService?,
        send: inout [UInt8],
        reply: inout [UInt8],
        packetSourceAddress: UInt8 = ddcDataAddress,
        writeSleepTime: UInt32 = 10_000,
        writeCycles: UInt8 = 2,
        readSleepTime: UInt32 = 50_000,
        retryAttempts: UInt8 = 4,
        retrySleepTime: UInt32 = 20_000
    ) -> Bool {
        guard let service else { return false }

        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = checksum(
            chk: send.count == 1 ? ddc7BitAddress << 1 : ddc7BitAddress << 1 ^ packetSourceAddress,
            data: &packet,
            start: 0,
            end: packet.count - 2
        )

        for _ in 0 ... retryAttempts {
            var success = false

            for _ in 0 ..< max(Int(writeCycles), 1) {
                usleep(writeSleepTime)
                success = IOAVServiceWriteI2C(
                    service,
                    UInt32(ddc7BitAddress),
                    UInt32(packetSourceAddress),
                    &packet,
                    UInt32(packet.count)
                ) == KERN_SUCCESS
            }

            if !reply.isEmpty {
                usleep(readSleepTime)

                if IOAVServiceReadI2C(
                    service,
                    UInt32(ddc7BitAddress),
                    UInt32(ddcDataAddress),
                    &reply,
                    UInt32(reply.count)
                ) == KERN_SUCCESS {
                    success = checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
                } else {
                    success = false
                }
            }

            if success {
                return true
            }

            usleep(retrySleepTime)
        }

        return false
    }

    private static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
        var result = chk
        guard start <= end else { return result }

        for index in start ... end {
            result ^= data[index]
        }

        return result
    }

    private static func getIORegistryServicesForMatching() -> [IORegistryDisplayService] {
        var serviceLocation = 0
        var services: [IORegistryDisplayService] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        defer { IOObjectRelease(iterator) }

        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return services
        }

        let avServiceProxyKey = "DCPAVServiceProxy"
        let framebufferKeys = ["AppleCLCD2", "IOMobileFramebufferShim"]
        var currentService = IORegistryDisplayService()

        while true {
            guard let object = iterateToNextObjectOfInterest(interests: [avServiceProxyKey] + framebufferKeys, iterator: &iterator) else {
                break
            }
            defer { IOObjectRelease(object.entry) }

            if framebufferKeys.contains(object.name) {
                currentService = ioRegistryDisplayProperties(entry: object.entry)
                serviceLocation += 1
                currentService.serviceLocation = serviceLocation
            } else if object.name == avServiceProxyKey {
                attachAVService(entry: object.entry, to: &currentService)
                services.append(currentService)
            }
        }

        return services
    }

    private static func iterateToNextObjectOfInterest(
        interests: [String],
        iterator: inout io_iterator_t
    ) -> (name: String, entry: io_service_t)? {
        let namePointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { namePointer.deallocate() }

        while true {
            let entry = IOIteratorNext(iterator)

            guard entry != MACH_PORT_NULL else {
                break
            }

            guard IORegistryEntryGetName(entry, namePointer) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                break
            }

            let name = String(cString: namePointer)
            if interests.contains(where: { name.contains($0) }) {
                return (name, entry)
            }

            IOObjectRelease(entry)
        }

        return nil
    }

    private static func ioRegistryDisplayProperties(entry: io_service_t) -> IORegistryDisplayService {
        var service = IORegistryDisplayService()

        if
            let unmanaged = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
            let edidUUID = unmanaged.takeRetainedValue() as? String
        {
            service.edidUUID = edidUUID
        }

        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { pathPointer.deallocate() }

        if IORegistryEntryGetPath(entry, kIOServicePlane, pathPointer) == KERN_SUCCESS {
            service.ioDisplayLocation = String(cString: pathPointer)
        }

        if
            let unmanaged = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
            let displayAttributes = unmanaged.takeRetainedValue() as? NSDictionary
        {
            service.displayAttributes = displayAttributes

            if let productAttributes = displayAttributes.value(forKey: "ProductAttributes") as? NSDictionary {
                service.manufacturerID = productAttributes.value(forKey: "ManufacturerID") as? String ?? ""
                service.productName = productAttributes.value(forKey: "ProductName") as? String ?? ""
                service.serialNumber = productAttributes.value(forKey: "SerialNumber") as? Int64 ?? 0
                service.alphanumericSerialNumber = productAttributes.value(forKey: "AlphanumericSerialNumber") as? String ?? ""
            }
        }

        if
            let unmanaged = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
            let transport = unmanaged.takeRetainedValue() as? NSDictionary
        {
            service.transportUpstream = transport.value(forKey: "Upstream") as? String ?? ""
            service.transportDownstream = transport.value(forKey: "Downstream") as? String ?? ""
        }

        return service
    }

    private static func attachAVService(entry: io_service_t, to service: inout IORegistryDisplayService) {
        guard
            let unmanaged = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
            let location = unmanaged.takeRetainedValue() as? String
        else {
            return
        }

        service.location = location

        guard location == "External" else { return }
        service.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
    }
}
