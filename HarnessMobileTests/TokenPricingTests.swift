import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the route-aware token pricing contract against upstream
/// `dsh-token-meter/route-pricing`: structural image prices under the fixed
/// heuristic, declared visual prices under a route, and fail-loud
/// misalignment.
final class TokenPricingTests: XCTestCase {
    private struct FixedPricing: TokenPricing.ImageRequestPricing {
        let price: TokenPricing.ImagePrice
        func priceImages(_ images: [TokenPricing.ImageOccurrence]) -> [TokenPricing.ImagePrice] {
            Array(repeating: price, count: images.count)
        }
    }

    func testWithoutPricingImagesKeepStructuralHeuristicPrice() throws {
        let nodes = [
            TokenPricing.SurfaceNode(
                seq: 1,
                imageFreeTokens: 40,
                images: [.init(label: "photo.png")]
            )
        ]
        let result = try TokenPricing.priceSurface(nodes: nodes, pricing: nil)
        XCTAssertEqual(result.nodes.count, 1)
        let node = result.nodes[0]
        // imageFreeTokens plus one structural image price.
        XCTAssertEqual(node.tokens, 40 + TokenPricing.structuralPrice(.init(label: "photo.png")))
        XCTAssertEqual(node.heuristicTokens, node.tokens)
        XCTAssertEqual(result.surfaceTokens, node.tokens)
    }

    func testRoutePricingReplacesImagePrices() throws {
        let nodes = [
            TokenPricing.SurfaceNode(
                seq: 1,
                imageFreeTokens: 40,
                images: [
                    .init(label: "a.png"),
                    .init(label: "b.png")
                ]
            )
        ]
        let pricing = FixedPricing(
            price: .init(visualTokens: 85, text: "IMAGE_ATTACHMENT 1024x768")
        )
        let result = try TokenPricing.priceSurface(nodes: nodes, pricing: pricing)
        let expected = 40
            + 2 * (85 + TokenPricing.estimatedTextTokens("IMAGE_ATTACHMENT 1024x768"))
        XCTAssertEqual(result.nodes[0].tokens, expected)
        XCTAssertNotEqual(result.nodes[0].heuristicTokens, expected)
        XCTAssertEqual(result.surfaceTokens, expected)
    }

    func testMisalignedPricingFailsLoud() {
        struct ShortPricing: TokenPricing.ImageRequestPricing {
            func priceImages(_ images: [TokenPricing.ImageOccurrence]) -> [TokenPricing.ImagePrice] {
                Array(repeating: .init(visualTokens: 1, text: ""), count: images.count - 1)
            }
        }
        let nodes = [
            TokenPricing.SurfaceNode(
                seq: 1,
                imageFreeTokens: 0,
                images: [.init(label: "a.png"), .init(label: "b.png")]
            )
        ]
        XCTAssertThrowsError(
            try TokenPricing.priceSurface(nodes: nodes, pricing: ShortPricing())
        ) {
            guard case let TokenPricing.PricingError.misalignedPricing(asked, answered) = $0 else {
                return XCTFail("expected misaligned pricing")
            }
            XCTAssertEqual(asked, 2)
            XCTAssertEqual(answered, 1)
        }
    }

    func testImageFreeNodesAreUnchangedWithOrWithoutPricing() throws {
        let nodes = [
            TokenPricing.SurfaceNode(seq: 5, imageFreeTokens: 120, images: [])
        ]
        let heuristic = try TokenPricing.priceSurface(nodes: nodes, pricing: nil)
        let route = try TokenPricing.priceSurface(
            nodes: nodes,
            pricing: FixedPricing(price: .init(visualTokens: 999, text: "x"))
        )
        XCTAssertEqual(heuristic, route)
        XCTAssertEqual(route.surfaceTokens, 120)
    }
}
