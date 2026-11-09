import XCTest
import Metal
@testable import StudioKit

final class CompositorGoldenTests: XCTestCase {
    static let canvas = CGSize(width:128,height:72)
    var recording: Bool { ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" }

    func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ data: Data, _ row: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
        d.storageMode = .shared; d.usage = [.shaderRead,.renderTarget]
        let t = MetalCore.shared.device.makeTexture(descriptor:d)!
        data.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:row) }
        return t
    }
    /// Test sources: 64x36 10-bit game bars, 32x32 8-bit camera bars.
    func sources() -> (screen: (MTLTexture, MTLTexture), camera: (MTLTexture, MTLTexture)) {
        let y10 = (0..<64*36).map { UInt16([128,400,700,900][($0 % 64)/16]) << 6 }
        let c10 = (0..<32*18*2).map { UInt16([400,600,512,512][($0/16)%4]) << 6 }
        let y8 = (0..<32*32).map { UInt8([32,100,180,230][($0%32)/8]) }
        let c8 = (0..<16*16*2).map { UInt8([90,180,128,128][($0/8)%4]) }
        return ((texture(.r16Unorm,64,36,y10.withUnsafeBytes { Data($0) },128), texture(.rg16Unorm,32,18,c10.withUnsafeBytes { Data($0) },128)),
                (texture(.r8Unorm,32,32,Data(y8),32), texture(.rg8Unorm,16,16,Data(c8),32)))
    }
    /// Renders into a 128x72 half-float target and samples a 16x9 grid of pixel centres.
    func render(_ encode: (MTLCommandBuffer, MTLTexture) -> Void) -> [Float] {
        let target = texture(.rgba16Float,128,72,Data(count:128*72*8),128*8)
        let cb = MetalCore.shared.queue.makeCommandBuffer()!
        encode(cb, target)
        cb.commit(); cb.waitUntilCompleted()
        XCTAssertEqual(cb.status,.completed)
        var raw = [UInt16](repeating:0,count:128*72*4)
        raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:128*8,from:MTLRegionMake2D(0,0,128,72),mipmapLevel:0) }
        var grid: [Float] = []
        for y in 0..<9 { for x in 0..<16 { for c in 0..<4 {
            grid.append(Float(Float16(bitPattern:raw[((y*8+4)*128+x*8+4)*4+c])))
        } } }
        return grid
    }
    /// Compares with Fixtures/golden/<name>.json, or writes it when RECORD_GOLDENS=1 and `record` is set.
    func check(_ grid: [Float], _ name: String, record: Bool = true) throws {
        if recording {
            guard record else { return }
            let dir = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/golden")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            try enc.encode(grid).write(to:dir.appendingPathComponent(name+".json"))
        } else {
            let url = try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/golden"))
            let expected = try JSONDecoder().decode([Float].self,from:Data(contentsOf:url))
            XCTAssertEqual(grid.count,expected.count)
            for (i,pair) in zip(grid,expected).enumerated() { XCTAssertEqual(pair.0,pair.1,accuracy:0.002,"\(name) channel \(i)") }
        }
    }

    /// The four fixed layouts in PQ, HLG and SDR output, through the old shader and through the layer compositor,
    /// against the same goldens.
    func testGoldens() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let core = MetalCore.shared
        let (screen, camera) = sources()
        for kind in LayoutKind.allCases {
            for transfer: Int32 in 0...2 {
                var layout = CanvasLayout(kind:kind); layout.camera.border = true; layout.camera.shadow = true
                let params = LayoutMath.params(layout:layout,canvas:Self.canvas,screen:CGSize(width:64,height:36),
                                               camera:CGSize(width:32,height:32),mirror:false,screenTransfer:0,outTransfer:transfer)
                let name = "\(kind.rawValue)-\(transfer)"
                try check(render { cb, target in core.encodeComposite(cb,target:target,screen:screen,camera:camera,params:params) }, name)

                let comp = Composition.from(layout:layout,canvas:Self.canvas,hasCamera:true,mirror:false)
                let resolved = SceneResolver.resolve(comp,canvas:Self.canvas,sources:[.game:SourceInfo(size:CGSize(width:64,height:36)),
                                                                                       .camera:SourceInfo(size:CGSize(width:32,height:32))])
                let layers = DrawLayer.pair(resolved,[.game:.biplanar(y:screen.0,c:screen.1,bits:10,transfer:0,bt709:false),
                                                      .camera:.biplanar(y:camera.0,c:camera.1,bits:8,transfer:2,bt709:true)])
                try check(render { cb, target in
                    core.encodeLayers(cb,target:target,canvas:Self.canvas,background:comp.backgroundColor,outTransfer:transfer,layers:layers)
                }, name, record: false)
            }
        }
    }
}
