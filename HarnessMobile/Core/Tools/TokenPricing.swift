import Foundation

/// Mirrors upstream `dsh-token-meter/route-pricing`: route-aware surface
/// pricing that replaces every image occurrence's structural price with the
/// routed model's declared visual tokens plus the model-visible text it
/// actually sends. Without declared pricing every image keeps its fixed
/// heuristic (structural JSON) price, so provider-neutral behavior is
/// unchanged. A misaligned pricing answer fails loud — silently mispricing
/// nodes would be worse than refusing to price.
enum TokenPricing {
    /// A durable image occurrence whose request price is route-owned.
    struct ImageOccurrence: Sendable, Equatable {
        /// Human label, e.g. a file name; used by the structural estimate.
        var label: String
    }

    /// One priced route answer for a single image occurrence.
    struct ImagePrice: Sendable, Equatable {
        /// Declared visual tokens the model charges for one occurrence.
        var visualTokens: Int
        /// Model-visible text the provider returns with the request (e.g. a
        /// caption); priced at the shared density heuristic.
        var text: String
    }

    /// The routed model's request-image pricing, injected by the model
    /// route. Returns exactly one price per asked occurrence.
    protocol ImageRequestPricing: Sendable {
        func priceImages(_ images: [ImageOccurrence]) -> [ImagePrice]
    }

    /// One ordered surface node with the image occurrences route pricing
    /// replaces.
    struct SurfaceNode: Sendable, Equatable {
        var seq: UInt64
        /// Fixed-heuristic price with every image occurrence's structural
        /// price removed.
        var imageFreeTokens: Int
        /// Image occurrences in message order; empty for image-free nodes.
        var images: [ImageOccurrence]
    }

    /// One priced surface node: the route price and the fixed-heuristic price.
    struct PricedNode: Sendable, Equatable {
        var seq: UInt64
        var tokens: Int
        var heuristicTokens: Int
    }

    struct PricedSurface: Sendable, Equatable {
        var nodes: [PricedNode]
        var surfaceTokens: Int
    }

    enum PricingError: LocalizedError, Equatable {
        /// The route answered a different number of prices than occurrences.
        case misalignedPricing(asked: Int, answered: Int)

        var errorDescription: String? {
            switch self {
            case let .misalignedPricing(asked, answered):
                "token meter: route image pricing answered \(answered) prices for \(asked) occurrences"
            }
        }
    }

    /// Conservative structural JSON price for one image occurrence under the
    /// fixed heuristic (mirrors upstream `estimateStructuralBlock`).
    static func structuralPrice(_ occurrence: ImageOccurrence) -> Int {
        let labelBytes = occurrence.label.utf16.count
        let jsonSize = labelBytes + 32 // {"type":"image","source":{...}} framing slack
        return 4 + (jsonSize + 3) / 4
    }

    /// Prices one ordered surface under a route's request-image pricing.
    /// Without pricing every node keeps its fixed-heuristic price.
    static func priceSurface(
        nodes: [SurfaceNode],
        pricing: (any ImageRequestPricing)?
    ) throws -> PricedSurface {
        let images = nodes.flatMap(\.images)
        guard let pricing, !images.isEmpty else {
            let priced = nodes.map { node in
                PricedNode(
                    seq: node.seq,
                    tokens: node.imageFreeTokens + node.images.reduce(into: 0) {
                        $0 += structuralPrice($1)
                    },
                    heuristicTokens: node.imageFreeTokens + node.images.reduce(into: 0) {
                        $0 += structuralPrice($1)
                    }
                )
            }
            return PricedSurface(
                nodes: priced,
                surfaceTokens: priced.reduce(0) { $0 + $1.tokens }
            )
        }

        let prices = pricing.priceImages(images)
        guard prices.count == images.count else {
            throw PricingError.misalignedPricing(
                asked: images.count,
                answered: prices.count
            )
        }

        var cursor = 0
        let priced = nodes.map { node -> PricedNode in
            var tokens = node.imageFreeTokens
            for occurrence in node.images {
                let price = prices[cursor]
                cursor += 1
                tokens += price.visualTokens + estimatedTextTokens(price.text)
            }
            let heuristic = node.imageFreeTokens + node.images.reduce(into: 0) {
                $0 += structuralPrice($1)
            }
            return PricedNode(seq: node.seq, tokens: tokens, heuristicTokens: heuristic)
        }
        return PricedSurface(
            nodes: priced,
            surfaceTokens: priced.reduce(0) { $0 + $1.tokens }
        )
    }

    /// Shared fixed-density estimate: 4 UTF-16 code units per token.
    static func estimatedTextTokens(_ text: String) -> Int {
        (text.utf16.count + 3) / 4
    }
}
