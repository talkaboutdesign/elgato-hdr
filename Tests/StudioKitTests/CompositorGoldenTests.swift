import XCTest
import Metal
@testable import StudioKit

final class CompositorGoldenTests: XCTestCase {
    func testGoldens() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let core = MetalCore.shared
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ data: Data, _ row: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
            d.storageMode = .shared; d.usage = [.shaderRead,.renderTarget]
            let t = core.device.makeTexture(descriptor:d)!
            data.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:row) }
            return t
        }
        let y10 = (0..<64*36).map { UInt16([128,400,700,900][($0 % 64)/16]) << 6 }
        let c10 = (0..<32*18*2).map { UInt16([400,600,512,512][($0/16)%4]) << 6 }
        let y8 = (0..<32*32).map { UInt8([32,100,180,230][($0%32)/8]) }
        let c8 = (0..<16*16*2).map { UInt8([90,180,128,128][($0/8)%4]) }
        let screen = (texture(.r16Unorm,64,36,y10.withUnsafeBytes { Data($0) },128),
                      texture(.rg16Unorm,32,18,c10.withUnsafeBytes { Data($0) },128))
        let camera = (texture(.r8Unorm,32,32,Data(y8),32), texture(.rg8Unorm,16,16,Data(c8),32))
        for kind in LayoutKind.allCases {
            for transfer: Int32 in 0...2 {
                var layout = CanvasLayout(kind:kind); layout.camera.border = true; layout.camera.shadow = true
                let params = LayoutMath.params(layout:layout,canvas:CGSize(width:128,height:72),screen:CGSize(width:64,height:36),
                                               camera:CGSize(width:32,height:32),mirror:false,screenTransfer:0,outTransfer:transfer)
                let target = texture(.rgba16Float,128,72,Data(count:128*72*8),128*8)
                let cb = core.queue.makeCommandBuffer()!
                core.encodeComposite(cb,target:target,screen:screen,camera:camera,params:params)
                cb.commit(); cb.waitUntilCompleted()
                XCTAssertEqual(cb.status,.completed)
                var raw = [UInt16](repeating:0,count:128*72*4)
                raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:128*8,from:MTLRegionMake2D(0,0,128,72),mipmapLevel:0) }
                var grid: [Float] = []
                for y in 0..<9 { for x in 0..<16 { for c in 0..<4 {
                    grid.append(Float(Float16(bitPattern:raw[((y*8+4)*128+x*8+4)*4+c])))
                } } }
                let name = "\(kind.rawValue)-\(transfer)"
                if ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" {
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
        }
    }
}
