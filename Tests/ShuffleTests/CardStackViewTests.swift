import XCTest
import UIKit
@testable import Shuffle

@MainActor
final class CardStackViewTests: XCTestCase {
  private func fixture() -> (UIWindow, CardStackView<Int>) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let host = UIViewController()
    let stack = CardStackView<Int> { _ in SwipeCard() }
    window.rootViewController = host
    host.view.addSubview(stack)
    stack.frame = CGRect(x: 20, y: 60, width: 350, height: 500)
    window.isHidden = false
    stack.layoutIfNeeded()
    return (window, stack)
  }

  func testSnapshotRestoresPositionAndUndoWithoutReplayingActions() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.updateCards([1, 2, 3])
    stack.swipe(.left, animated: false)
    stack.swipe(.right, animated: false)
    let restored = CardStackView<Int>(restoring: stack.snapshot) { _ in SwipeCard() }
    var actions: [CardAction<Int>] = []
    restored.onActionAccepted = { actions.append($0) }
    window.rootViewController!.view.addSubview(restored)
    restored.frame = stack.frame
    try restored.updateCards([1, 2, 3])
    XCTAssertEqual(restored.state.currentCardID, 3)
    XCTAssertTrue(restored.state.canUndo)
    XCTAssertTrue(actions.isEmpty)
    XCTAssertEqual(restored.undo(animated: false), .accepted(cardID: 2))
    XCTAssertEqual(restored.undo(animated: false), .accepted(cardID: 1))
    XCTAssertEqual(restored.state.remainingCardIDs, [1, 2, 3])
    XCTAssertEqual(restored.undo(), .rejected(.nothingToUndo))
  }

  func testSnapshotDuringMotionIncludesLatestDeferredIDs() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.updateCards([1, 2])
    stack.swipe(.left)
    XCTAssertEqual(try stack.updateCards([1, 3, 2]), .deferred)
    let restored = CardStackView<Int>(restoring: stack.snapshot) { _ in SwipeCard() }
    window.rootViewController!.view.addSubview(restored)
    restored.frame = stack.frame
    try restored.updateCards([1, 3, 2])
    XCTAssertEqual(restored.state.remainingCardIDs, [3, 2])
    XCTAssertEqual(restored.state.phase, .idle)
    XCTAssertEqual(restored.undo(animated: false), .accepted(cardID: 1))
  }

  func testSnapshotDropsHistoryRemovedByDeferredUpdate() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.updateCards([1, 2])
    stack.swipe(.right)
    try stack.updateCards([2, 3])
    let restored = CardStackView<Int>(restoring: stack.snapshot) { _ in SwipeCard() }
    try restored.updateCards([2, 3])
    XCTAssertFalse(restored.state.canUndo)
    XCTAssertEqual(restored.state.currentCardID, 2)
  }

  func testResetAndUpdateHaveDifferentHistorySemantics() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    XCTAssertEqual(stack.swipe(.right, animated: false), .accepted(cardID: 1))
    let second = stack.card(for: 2)
    XCTAssertEqual(try stack.updateCards([1, 4, 2, 3]), .applied)
    XCTAssertEqual(stack.state.remainingCardIDs, [4, 2, 3])
    XCTAssertTrue(stack.card(for: 2) === second)
    XCTAssertEqual(stack.undo(animated: false), .accepted(cardID: 1))
    XCTAssertEqual(stack.state.remainingCardIDs, [1, 4, 2, 3])
    try stack.resetCards([8, 9])
    XCTAssertEqual(stack.undo(animated: false), .rejected(.nothingToUndo))
    XCTAssertEqual(stack.state.currentCardID, 8)
  }

  func testDuplicateIDsFailBeforeMutatingState() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2])
    let state = stack.state
    XCTAssertThrowsError(try stack.updateCards([1, 1]))
    XCTAssertThrowsError(try stack.resetCards([2, 2]))
    XCTAssertEqual(stack.state, state)
  }

  func testRemovingASwipedIDPrunesOnlyThatHistoryEntry() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    stack.swipe(.right, animated: false)
    stack.swipe(.left, animated: false)
    try stack.updateCards([2, 3])
    XCTAssertEqual(stack.undo(animated: false), .accepted(cardID: 2))
    XCTAssertEqual(stack.undo(animated: false), .rejected(.nothingToUndo))
    XCTAssertEqual(stack.state.remainingCardIDs, [2, 3])
  }

  func testCommandsFromAcceptedCallbackAreRejectedWithoutMutation() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2])
    var accepted = 0
    stack.onActionAccepted = { _ in
      accepted += 1
      XCTAssertEqual(stack.state.phase, .animating)
      XCTAssertEqual(stack.swipe(.left), .rejected(.busy))
      XCTAssertEqual(stack.undo(), .rejected(.busy))
    }
    stack.swipe(.right, animated: false)
    XCTAssertEqual(accepted, 1)
    XCTAssertEqual(stack.state.remainingCardIDs, [2])
  }

  func testNonanimatedActionEmitsAcceptedThenOneCompletion() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1])
    var events: [String] = []
    stack.onActionAccepted = { _ in events.append("accepted") }
    stack.onTransitionEnded = { event in
      events.append("ended")
      XCTAssertEqual(event.outcome, .completed)
      XCTAssertEqual(stack.state.phase, .idle)
    }
    XCTAssertEqual(stack.swipe(.right, animated: false), .accepted(cardID: 1))
    XCTAssertEqual(events, ["accepted", "ended"])
    XCTAssertEqual(stack.swipe(.right), .rejected(.empty))
    XCTAssertTrue(stack.state.canUndo)
  }

  func testDetachmentSettlesExactlyOnceAndPreservesUndo() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    var ends: [CardTransitionEnd<Int>] = []
    stack.onTransitionEnded = { ends.append($0) }
    stack.swipe(.right)
    XCTAssertEqual(stack.state.phase, .animating)
    stack.removeFromSuperview()
    XCTAssertEqual(ends.count, 1)
    XCTAssertEqual(ends.first?.outcome, .settledOffscreen)
    XCTAssertEqual(stack.state.phase, .idle)
    XCTAssertEqual(stack.state.currentCardID, 2)
    XCTAssertEqual(stack.undo(), .rejected(.notVisible))
    window.rootViewController!.view.addSubview(stack)
    XCTAssertEqual(stack.undo(animated: false), .accepted(cardID: 1))
    XCTAssertEqual(ends.count, 2)
  }

  func testLatestDeferredUpdateWinsAndReconfigurationPreservesOtherCards() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    stack.swipe(.right)
    XCTAssertEqual(try stack.updateCards([1, 8, 2, 3]), .deferred)
    XCTAssertThrowsError(try stack.updateCards([1, 1]))
    XCTAssertEqual(try stack.updateCards([1, 9, 2, 3]), .deferred)
    stack.removeFromSuperview()
    XCTAssertEqual(stack.state.remainingCardIDs, [9, 2, 3])
    let retained = stack.card(for: 2)
    let refreshed = stack.card(for: 9)
    stack.reconfigureCards([9])
    XCTAssertTrue(stack.card(for: 2) === retained)
    XCTAssertFalse(stack.card(for: 9) === refreshed)
    XCTAssertTrue(stack.state.canUndo)
  }

  func testResetFromAcceptedCallbackSupersedesOldAction() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2])
    var ends: [CardTransitionEnd<Int>] = []
    stack.onTransitionEnded = { ends.append($0) }
    stack.onActionAccepted = { _ in try! stack.resetCards([7, 8]) }
    stack.swipe(.right)
    XCTAssertEqual(stack.state.currentCardID, 7)
    XCTAssertEqual(stack.state.phase, .idle)
    XCTAssertEqual(ends.map(\.outcome), [.superseded])
  }

  func testAnimatedCompletionWaitsForCardAndOldCallbacksCannotFinishNewAction() async throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    let first = try XCTUnwrap(stack.card(for: 1))
    first.animationOptions.totalSwipeDuration = 0.1
    stack.swipe(.right)
    try stack.resetCards([4, 5])
    let next = try XCTUnwrap(stack.card(for: 4))
    next.animationOptions.totalSwipeDuration = 0.3
    let finished = expectation(description: "new action completes once")
    var completionCount = 0
    stack.onTransitionEnded = { event in
      XCTAssertEqual(event.action, .swipe(cardID: 4, direction: .right))
      XCTAssertEqual(event.outcome, .completed)
      XCTAssertEqual(stack.state.phase, .idle)
      XCTAssertNil(stack.card(for: 4))
      completionCount += 1
      finished.fulfill()
    }
    stack.swipe(.right)
    XCTAssertEqual(stack.state.phase, .animating)
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(stack.state.currentCardID, 5)
  }

  func testGestureCancellationDoesNotAcceptActionOrChangeHistory() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2])
    let card = try XCTUnwrap(stack.card(for: 1))
    let gesture = try XCTUnwrap(card.panGestureRecognizer as? PanGestureRecognizer)
    var accepted = 0
    stack.onActionAccepted = { _ in accepted += 1 }
    gesture.performPan(withLocation: .zero, translation: .zero, velocity: .zero, state: .began)
    gesture.performPan(withLocation: .zero, translation: CGPoint(x: 500, y: 0), velocity: CGPoint(x: 2000, y: 0), state: .cancelled)
    XCTAssertEqual(accepted, 0)
    XCTAssertEqual(stack.state.remainingCardIDs, [1, 2])
    XCTAssertFalse(stack.state.canUndo)
  }

  func testIdenticalUpdatesDoNotRecursivelyNotifyState() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    var notifications = 0
    stack.onStateChanged = { _ in
      notifications += 1
      if notifications < 3 { try! stack.updateCards([1, 2]) }
    }
    try stack.resetCards([1, 2])
    XCTAssertEqual(notifications, 1)
    try stack.updateCards([1, 2])
    XCTAssertEqual(notifications, 1)
  }

  func testDirectionAndVisibilityRejectionsDoNotChangeState() throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1])
    XCTAssertEqual(stack.swipe(.up), .rejected(.disallowedDirection))
    stack.removeFromSuperview()
    XCTAssertEqual(stack.swipe(.right), .rejected(.notVisible))
    XCTAssertEqual(stack.state.currentCardID, 1)
  }
}

extension CardStackViewTests {
  func testSwipeAndUndoHaveIntermediateMotionAndCompleteOnceEach() async throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    let card = try XCTUnwrap(stack.card(for: 1))
    let probe = MotionProbe(card: card)
    defer { probe.stop() }
    let swipeEnd = expectation(description: "swipe visually complete")
    var transitions = 0
    stack.onTransitionEnded = { end in
      XCTAssertEqual(end.outcome, .completed)
      XCTAssertTrue(probe.hasMotion, "A completed swipe must have intermediate presentation frames")
      transitions += 1
      swipeEnd.fulfill()
    }
    stack.swipe(.right)
    await fulfillment(of: [swipeEnd], timeout: 3)
    XCTAssertEqual(transitions, 1)
    let undoEnd = expectation(description: "undo visually complete")
    var undoProbe: MotionProbe?
    stack.onTransitionEnded = { end in
      XCTAssertEqual(end.action, .undo(cardID: 1))
      XCTAssertEqual(end.outcome, .completed)
      XCTAssertTrue(undoProbe?.hasMotion == true, "Undo must move rather than appear")
      transitions += 1
      undoEnd.fulfill()
    }
    stack.undo()
    undoProbe = MotionProbe(card: try XCTUnwrap(stack.card(for: 1)))
    defer { undoProbe?.stop() }
    await fulfillment(of: [undoEnd], timeout: 3)
    XCTAssertEqual(transitions, 2)
    XCTAssertEqual(stack.state.currentCardID, 1)
    XCTAssertTrue(stack.card(for: 1)?.isUserInteractionEnabled == true)
  }

  func testArrivalWaitsForActualMotionAndRetainsUndoIdentity() async throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2, 3])
    let card = try XCTUnwrap(stack.card(for: 1))
    let probe = MotionProbe(card: card)
    defer { probe.stop() }
    let moving = expectation(description: "card is moving")
    probe.onMotion = { moving.fulfill() }
    let ended = expectation(description: "arrival applied after motion")
    stack.onTransitionEnded = { _ in
      XCTAssertEqual(stack.state.remainingCardIDs, [4, 2, 3])
      XCTAssertEqual(stack.state.phase, .idle)
      ended.fulfill()
    }
    stack.swipe(.right)
    await fulfillment(of: [moving], timeout: 3)
    XCTAssertEqual(try stack.updateCards([1, 4, 2, 3]), .deferred)
    XCTAssertEqual(stack.state.remainingCardIDs, [2, 3])
    XCTAssertTrue(stack.card(for: 1) === card)
    await fulfillment(of: [ended], timeout: 3)
    stack.onTransitionEnded = nil
    XCTAssertEqual(stack.undo(animated: false), .accepted(cardID: 1))
    XCTAssertEqual(stack.state.remainingCardIDs, [1, 4, 2, 3])
  }

  func testLayoutPolicyControlsVisibleCardsWithoutSubclassing() throws {
    let stack = CardStackView<Int>(configuration: .init(visibleCardCount: 4, scaleStep: 0.08, verticalSpacing: 20)) { _ in SwipeCard() }
    stack.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
    try stack.resetCards([1, 2, 3, 4, 5])
    stack.layoutIfNeeded()
    XCTAssertNotNil(stack.card(for: 4))
    XCTAssertNil(stack.card(for: 5))
    XCTAssertEqual(try XCTUnwrap(stack.card(for: 2)).transform.a, 0.92, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(stack.card(for: 2)).transform.ty, 18.4, accuracy: 0.001)
  }

  func testCancelledDragDefersUpdatesUntilSpringSettles() async throws {
    let (window, stack) = fixture(); defer { window.isHidden = true }
    try stack.resetCards([1, 2])
    let card = try XCTUnwrap(stack.card(for: 1))
    card.animationOptions.totalResetDuration = 0.1
    let gesture = try XCTUnwrap(card.panGestureRecognizer as? PanGestureRecognizer)
    gesture.performPan(withLocation: .zero, translation: .zero, velocity: .zero, state: .began)
    gesture.performPan(withLocation: .zero, translation: CGPoint(x: 80, y: 0), velocity: .zero, state: .changed)
    XCTAssertEqual(try stack.updateCards([3, 1, 2]), .deferred)
    let settled = expectation(description: "cancelled drag settles")
    stack.onActionAccepted = { _ in XCTFail("A cancellation cannot accept an action") }
    stack.onStateChanged = { state in
      if state.phase == .idle { settled.fulfill() }
    }
    gesture.performPan(withLocation: .zero, translation: CGPoint(x: 80, y: 0), velocity: .zero, state: .cancelled)
    XCTAssertEqual(stack.swipe(.right), .rejected(.busy))
    await fulfillment(of: [settled], timeout: 3)
    XCTAssertEqual(stack.state.remainingCardIDs, [3, 1, 2])
    XCTAssertFalse(stack.state.canUndo)
  }
}

@MainActor
private final class MotionProbe: NSObject {
  weak var card: SwipeCard?
  var onMotion: (() -> Void)?
  private var link: CADisplayLink?
  private var positions: [CGPoint] = []
  var hasMotion: Bool {
    guard let first = positions.first,
          let second = positions.first(where: { hypot($0.x - first.x, $0.y - first.y) > 1 }) else { return false }
    return positions.contains { hypot($0.x - second.x, $0.y - second.y) > 1 && hypot($0.x - first.x, $0.y - first.y) > 1 }
  }
  init(card: SwipeCard) {
    self.card = card
    super.init()
    link = CADisplayLink(target: self, selector: #selector(sample))
    link?.add(to: .main, forMode: .common)
  }
  func stop() { link?.invalidate(); link = nil }
  @objc private func sample() {
    if let layer = card?.layer.presentation() {
      positions.append(layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), to: layer.superlayer))
      if hasMotion { let callback = onMotion; onMotion = nil; callback?() }
    }
  }
}
