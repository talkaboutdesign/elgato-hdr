import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

enum ColorMode: String { case pq, hlg, sdr }
/// smooth: frames paced onto an even vsync grid (adds a ~34 ms cushion). game: drawn on arrival, shown at the next
/// vsync (no tearing). immediate: drawn on arrival without vsync (lowest latency, can tear in full screen).
enum Presentation: String { case smooth, game, immediate }
struct Mode { let name: String; let frame: Int; let fps: Double }
let modes: [Mode] = [
    Mode(name: "4K 30", frame: 5, fps: 30),
    Mode(name: "1440p 60", frame: 4, fps: 60),
    Mode(name: "2560×1080 60", frame: 3, fps: 60),
    Mode(name: "1080p 120", frame: 2, fps: 120),
    Mode(name: "1080p 60", frame: 2, fps: 60),
    Mode(name: "1080p 30", frame: 2, fps: 30),
    Mode(name: "720p 120", frame: 1, fps: 120),
]

