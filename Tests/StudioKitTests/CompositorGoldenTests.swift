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
    /// Compares with Fixtures/golden/<name>.json, or writes it when RECORD_GOLDENS=1.
    func check(_ grid: [Float], _ name: String) throws {
        if recording {
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

    /// The four fixed layouts in PQ, HLG and SDR output, rendered as layer templates. The goldens were recorded from
    /// the former fixed two-layer shader; the layer compositor must keep matching them.
    func testGoldens() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let core = MetalCore.shared
        let (screen, camera) = sources()
        for kind in LayoutKind.allCases {
            for transfer: Int32 in 0...2 {
                var layout = CanvasLayout(kind:kind); layout.camera.border = true; layout.camera.shadow = true
                let comp = Composition.from(layout:layout,canvas:Self.canvas,hasCamera:true,mirror:false)
                let resolved = SceneResolver.resolve(comp,canvas:Self.canvas,sources:[.game:SourceInfo(size:CGSize(width:64,height:36)),
                                                                                       .camera:SourceInfo(size:CGSize(width:32,height:32))])
                let layers = DrawLayer.pair(resolved,[.game:.biplanar(y:screen.0,c:screen.1,bits:10,transfer:0,bt709:false),
                                                      .camera:.biplanar(y:camera.0,c:camera.1,bits:8,transfer:2,bt709:true)])
                try check(render { cb, target in
                    core.encodeLayers(cb,target:target,canvas:Self.canvas,background:comp.backgroundColor,outTransfer:transfer,layers:layers)
                }, "\(kind.rawValue)-\(transfer)")
            }
        }
    }

    /// Layers under an opaque full-canvas layer are skipped; the picture must be the one drawing them would give.
    func testOpaqueLayerHidesWhatIsBeneath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let (screen, camera) = sources()
        func grid(gameOpacity: Double, transfer: Int32) -> [Float] {
            let comp = Composition(background:[1,0,1,1],layers:[
                Layer(source:LayerSource(type:"color",color:[0,1,0,1])),
                Layer(source:.game,opacity:gameOpacity),
                Layer(source:.camera,frame:NRect(x:0.6,y:0.5,w:0.3,h:0.4),roundness:0.2,shadow:true)])
            let layers = DrawLayer.pair(SceneResolver.resolve(comp,canvas:Self.canvas,sources:[.game:SourceInfo(size:CGSize(width:64,height:36)),
                                                                                                .camera:SourceInfo(size:CGSize(width:32,height:32))]),
                                        [.game:.biplanar(y:screen.0,c:screen.1,bits:10,transfer:0,bt709:false),
                                         .camera:.biplanar(y:camera.0,c:camera.1,bits:8,transfer:2,bt709:true)])
            XCTAssertEqual(layers[1].covers(CGRect(origin:.zero,size:Self.canvas)),gameOpacity == 1)
            return render { cb, target in
                MetalCore.shared.encodeLayers(cb,target:target,canvas:Self.canvas,background:comp.backgroundColor,outTransfer:transfer,layers:layers)
            }
        }
        for transfer: Int32 in 0...2 {
            for (i,pair) in zip(grid(gameOpacity:1,transfer:transfer),grid(gameOpacity:0.9999,transfer:transfer)).enumerated() {
                XCTAssertEqual(pair.0,pair.1,accuracy:0.002,"transfer \(transfer) channel \(i)")
            }
        }
    }

    /// What the fixed layouts could not express. `RECORD_GOLDENS=1 swift test --filter CompositorGoldenTests/testLayerGoldens`
    /// records only these.
    func testLayerGoldens() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let core = MetalCore.shared
        let (screen, camera) = sources()
        // 16x16 premultiplied RGBA: left half red at alpha 128/255, right half opaque dark green.
        let rgba = texture(.rgba8Unorm,16,16,Data((0..<16*16).flatMap { $0 % 16 < 8 ? [128,0,0,128] as [UInt8] : [0,64,0,255] }),64)
        func color(_ c: [Double], _ f: NRect, opacity: Double = 1, roundness: Double = 0, border: Bool = false, shadow: Bool = false) -> Layer {
            Layer(source:LayerSource(type:"color",color:c),frame:f,roundness:roundness,border:border,shadow:shadow,opacity:opacity)
        }
        let logo = Layer(name:"Logo",source:LayerSource(type:"image",file:"logo.png"),frame:NRect(x:0.25,y:0.25,w:0.5,h:0.5))
        let scenes: [(String, Composition)] = [
            ("overlap", Composition(layers:[
                Layer(source:.game,frame:NRect(x:0,y:0,w:0.7,h:0.75),opacity:0.9),
                Layer(source:.camera,frame:NRect(x:0.3,y:0.2,w:0.5,h:0.6),roundness:0.25,shadow:true,opacity:0.6),
                color([0.2,0.8,0.3,1],NRect(x:0.55,y:0.45,w:0.4,h:0.5),opacity:0.35,border:true)])),
            ("color", Composition(background:[0.9,0.85,0.2,1],layers:[
                color([0.2,0.4,0.6,1],NRect(x:0.05,y:0.1,w:0.4,h:0.8)),
                color([1,0.5,0,0.5],NRect(x:0.5,y:0.2,w:0.45,h:0.6),roundness:0.5,border:true,shadow:true)])),
            ("rgba", Composition(layers:[Layer(source:.game),logo])),
            ("gameWindow", Composition(layers:[
                Layer(source:.camera,mirror:true),
                Layer(source:.game,frame:NRect(x:0.55,y:0.5,w:0.4,h:0.4),roundness:0.3,border:true,shadow:true)])),
        ]
        let sizes: [SourceKey: SourceInfo] = [.game:SourceInfo(size:CGSize(width:64,height:36)),.camera:SourceInfo(size:CGSize(width:32,height:32)),
                                              .layer(logo.id):SourceInfo(size:CGSize(width:16,height:16))]
        let textures: [SourceKey: LayerTextures.Kind] = [.game:.biplanar(y:screen.0,c:screen.1,bits:10,transfer:0,bt709:false),
                                                         .camera:.biplanar(y:camera.0,c:camera.1,bits:8,transfer:2,bt709:true),.layer(logo.id):.rgba(rgba)]
        var sdr: [String: [Float]] = [:]
        for (name, comp) in scenes {
            let layers = DrawLayer.pair(SceneResolver.resolve(comp,canvas:Self.canvas,sources:sizes),textures)
            XCTAssertEqual(layers.count,comp.layers.count,name)
            for transfer: Int32 in 0...2 {
                let grid = render { cb, target in
                    core.encodeLayers(cb,target:target,canvas:Self.canvas,background:comp.backgroundColor,outTransfer:transfer,layers:layers)
                }
                if transfer == 2 { sdr[name] = grid }
                try check(grid,"layers-\(name)-\(transfer)")
            }
        }
        // In SDR output colours pass through unconverted, so blends can be checked by hand at grid points (x, y).
        func px(_ g: [Float]?, _ x: Int, _ y: Int) -> [Float] { Array(g![(y*16+x)*4..<(y*16+x)*4+3]) }
        func near(_ a: [Float], _ b: [Float], _ what: String) { for (u, v) in zip(a, b) { XCTAssertEqual(u,v,accuracy:0.002,what) } }
        near(px(sdr["color"],2,4),[0.2,0.4,0.6],"opaque color layer")
        // Half-alpha orange over its own full-strength shadow (0.45): cc·a + bg·(1 − a)(1 − s).
        near(px(sdr["color"],11,4),[0.5+0.9*0.275,0.25+0.85*0.275,0.2*0.275],"half-alpha color with shadow over background")
        near(px(sdr["color"],0,0),[0.9,0.85,0.2],"background")
        let screenOnly = try JSONDecoder().decode([Float].self,from:Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"screenOnly-2",withExtension:"json",subdirectory:"Fixtures/golden"))))
        let a: Float = 128.0/255
        near(px(sdr["rgba"],5,3),zip(px(screenOnly,5,3),[1,0,0]).map { $0 * (1-a) + $1 * a },"premultiplied red at half alpha over game")
        near(px(sdr["rgba"],10,5),[0,64.0/255,0],"opaque rgba texel")
        near(px(sdr["rgba"],1,1),px(screenOnly,1,1),"game outside the image layer")
    }
}
