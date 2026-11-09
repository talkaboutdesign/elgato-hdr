import XCTest
@testable import StudioKit

final class LayoutMathTests: XCTestCase {
    func testCrop() {
        func crop(_ w: Double, _ h: Double, _ z: Double = 1, _ x: Double = 0.5, _ y: Double = 0.5) -> CGRect {
            LayoutMath.fillCrop(sourceSize: CGSize(width: w,height: h), dst: CGSize(width: 100,height: 100), zoom: z, panX: x, panY: y)
        }
        XCTAssertEqual(crop(200,100), CGRect(x: 0.25,y: 0,width: 0.5,height: 1))
        XCTAssertEqual(crop(100,200), CGRect(x: 0,y: 0.25,width: 1,height: 0.5))
        XCTAssertEqual(crop(100,100), CGRect(x: 0,y: 0,width: 1,height: 1))
        XCTAssertEqual(crop(100,100,2), CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5))
        XCTAssertEqual(crop(100,100,2,-1,2), CGRect(x: 0,y: 0.5,width: 0.5,height: 0.5))
        XCTAssertEqual(LayoutMath.fitRect(CGSize(width: 200,height: 100), in: CGRect(x: 10,y: 20,width: 100,height: 100)), CGRect(x: 10,y: 45,width: 100,height: 50))
    }
    func testPlacement() {
        for canvas in Canvas.allCases.map({ $0.size(.hd) }) {
            for aspect in CameraAspect.allCases {
                for edge in [-1.0,2.0] {
                    let r = CameraPlacement(x: edge,y: edge,size: 0.8,aspect: aspect).rect(in: canvas)
                    XCTAssertGreaterThanOrEqual(r.minX,0); XCTAssertGreaterThanOrEqual(r.minY,0)
                    XCTAssertLessThanOrEqual(r.maxX,canvas.width); XCTAssertLessThanOrEqual(r.maxY,canvas.height)
                }
            }
            var p = CameraPlacement()
            let anchors = CameraPlacement.anchors(for: p.rect(in: canvas).size, canvas: canvas)
            XCTAssertEqual(anchors.count,8)
            let a = anchors[0], short = min(canvas.width,canvas.height)
            p.move(to: CGPoint(x:a.x+short*0.04,y:a.y),canvas:canvas)
            XCTAssertEqual(p.x,a.x/canvas.width,accuracy:1e-8)
            p.move(to: CGPoint(x:a.x+short*0.06,y:a.y),canvas:canvas)
            XCTAssertEqual(p.x,(a.x+short*0.06)/canvas.width,accuracy:1e-8)
        }
    }
}
