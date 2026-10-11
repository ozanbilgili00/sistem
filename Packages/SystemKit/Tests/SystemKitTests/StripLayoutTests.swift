import CoreGraphics
import Testing
@testable import SystemKit

@Suite("Menü çubuğu şeridi: tıklama eşlemesi")
struct StripLayoutTests {
    let layout = StripLayout(widths: [40, 24, 60])  // gap 4: spans 0...40, 44...68, 72...132

    @Test func spansAndTotal() {
        #expect(layout.spans == [0...40, 44...68, 72...132])
        #expect(layout.totalWidth == 132)
        #expect(StripLayout(widths: []).totalWidth == 0)
        #expect(StripLayout(widths: [30]).totalWidth == 30)
    }

    @Test func clicksInsideSectionsMapToThem() {
        #expect(layout.index(at: 0) == 0)
        #expect(layout.index(at: 20) == 0)
        #expect(layout.index(at: 40) == 0)
        #expect(layout.index(at: 44) == 1)
        #expect(layout.index(at: 56) == 1)
        #expect(layout.index(at: 68) == 1)
        #expect(layout.index(at: 72) == 2)
        #expect(layout.index(at: 131.9) == 2)
    }

    /// The gap belongs to both neighbours in halves: the middle pixel goes to the right-hand section.
    @Test func boundaryPixelsAreExact() {
        #expect(layout.index(at: 41.99) == 0)
        #expect(layout.index(at: 42) == 1, "ilk-ikinci sınırı: boşluğun ortası sağdaki bölüme")
        #expect(layout.index(at: 41) == 0)
        #expect(layout.index(at: 69.99) == 1)
        #expect(layout.index(at: 70) == 2)
        #expect(layout.index(at: 43) == 1)
    }

    @Test func outsideThePointsClampToTheEnds() {
        #expect(layout.index(at: -5) == 0)
        #expect(layout.index(at: 132) == 2)
        #expect(layout.index(at: 5_000) == 2)
        #expect(layout.index(at: -.infinity) == 0)
    }

    @Test func singleAndEmpty() {
        #expect(StripLayout(widths: []).index(at: 10) == nil)
        let one = StripLayout(widths: [30])
        for x: CGFloat in [-3, 0, 15, 30, 99] { #expect(one.index(at: x) == 0) }
    }

    @Test func everyPointHasExactlyOneOwnerAndOwnersAreMonotonic() {
        let layout = StripLayout(widths: [33.5, 24, 61.25, 24])
        var last = 0
        var x: CGFloat = -2
        while x < layout.totalWidth + 2 {
            let owner = layout.index(at: x)
            #expect(owner != nil && owner! >= last)
            last = owner ?? last
            x += 0.25
        }
        #expect(last == 3)
    }
}
