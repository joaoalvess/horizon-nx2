import CoreGraphics
import Foundation
import HorizonPlayer
import ImageIO
import UniformTypeIdentifiers

final class Snapshots: Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.receiver.png", qos: .utility)

    init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func write(_ snapshot: PlayerSnapshot, elapsed: Double) {
        let url = directory.appendingPathComponent(String(format: "t%06.1f-link%07u-dm%07llu.png", elapsed, snapshot.frame, snapshot.dmFrame))
        queue.async {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                Console.error("could not create \(url.path)")
                return
            }
            CGImageDestinationAddImage(destination, snapshot.image, nil)
            if !CGImageDestinationFinalize(destination) { Console.error("could not write \(url.path)") }
        }
    }
}
