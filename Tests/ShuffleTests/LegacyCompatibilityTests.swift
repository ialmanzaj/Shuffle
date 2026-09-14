import XCTest
import UIKit
@testable import Shuffle

@MainActor
final class LegacyCompatibilityTests: XCTestCase, @preconcurrency SwipeCardStackDataSource {
  func numberOfCards(in cardStack: SwipeCardStack) -> Int { 3 }
  func cardStack(_ cardStack: SwipeCardStack, cardForIndexAt index: Int) -> SwipeCard { SwipeCard() }

  func testExistingIndexAPIStillSwipesAndUndoes() {
    let stack = SwipeCardStack()
    stack.dataSource = self
    stack.swipe(.right, animated: false)
    XCTAssertEqual(stack.topCardIndex, 1)
    XCTAssertEqual(stack.swipedCards(), [0])
    stack.undoLastSwipe(animated: false)
    XCTAssertEqual(stack.topCardIndex, 0)
    XCTAssertEqual(stack.swipedCards(), [])
  }

  func testCancelledLegacyGestureDoesNotCommitSwipe() throws {
    let stack = SwipeCardStack()
    stack.dataSource = self
    let card = try XCTUnwrap(stack.card(forIndexAt: 0))
    let gesture = try XCTUnwrap(card.panGestureRecognizer as? PanGestureRecognizer)
    gesture.performPan(withLocation: .zero, translation: .zero, velocity: .zero, state: .began)
    gesture.performPan(withLocation: .zero, translation: CGPoint(x: 500, y: 0), velocity: CGPoint(x: 2000, y: 0), state: .cancelled)
    XCTAssertEqual(stack.topCardIndex, 0)
    XCTAssertTrue(stack.swipedCards().isEmpty)
  }
}
