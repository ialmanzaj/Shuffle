import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Shuffle

@available(iOS 13.0, *)
@MainActor
final class SwiftUICardStackTests: XCTestCase {
  func testDetachedCommandsAndExplicitReset() {
    let controller = CardStackController<Int>()
    XCTAssertEqual(controller.swipe(.right), .rejected(.notVisible))
    XCTAssertEqual(controller.undo(), .rejected(.notVisible))
    controller.reset()
    XCTAssertNil(controller.state.currentCardID)
    XCTAssertFalse(controller.state.canUndo)
  }

  func testCommandsReturnResultsAndDeliverOrderedDeferredEvents() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    XCTAssertEqual(fixture.controller.swipe(.left, animated: false), .accepted(cardID: 1))
    XCTAssertTrue(fixture.events.isEmpty, "Callbacks must not mutate SwiftUI during a UIKit call")
    await framesUntil("accepted then completed") { fixture.events.count == 2 }
    XCTAssertEqual(fixture.events, ["swipe:1", "end:completed"])
    XCTAssertEqual(fixture.controller.state.currentCardID, 2)
    XCTAssertEqual(fixture.controller.undo(animated: false), .accepted(cardID: 1))
    await framesUntil("undo completes") { fixture.events.count == 4 }
    XCTAssertEqual(fixture.events, ["swipe:1", "end:completed", "undo:1", "end:completed"])
  }

  func testRealSwipeAndUndoMoveWithContentAttached() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    let card = try XCTUnwrap(fixture.host.stack?.card(for: 1))
    let swipe = Movement(card: card)
    XCTAssertEqual(fixture.controller.swipe(.right), .accepted(cardID: 1))
    await framesUntil("swipe finishes") { swipe.sample(); return fixture.events.count == 2 }
    XCTAssertTrue(swipe.hasMotion, "Swipe must traverse intermediate positions")
    XCTAssertTrue(swipe.contentStayedAttached)
    XCTAssertEqual(fixture.controller.undo(), .accepted(cardID: 1))
    let restored = try XCTUnwrap(fixture.host.stack?.card(for: 1))
    let undo = Movement(card: restored)
    await framesUntil("undo finishes") { undo.sample(); return fixture.events.count == 4 }
    XCTAssertTrue(undo.hasMotion, "Undo must traverse intermediate positions")
    XCTAssertTrue(undo.contentStayedAttached)
    XCTAssertEqual(fixture.controller.state.currentCardID, 1)
  }

  func testRecreationPreservesProgressAndUndoWithoutReplayingActions() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    fixture.controller.swipe(.left, animated: false)
    fixture.controller.swipe(.right, animated: false)
    await framesUntil("initial actions delivered") { fixture.events.count == 4 }
    fixture.remount()
    XCTAssertEqual(fixture.controller.state.currentCardID, 3)
    XCTAssertEqual(fixture.events.count, 4)
    XCTAssertEqual(fixture.controller.undo(animated: false), .accepted(cardID: 2))
    XCTAssertEqual(fixture.controller.undo(animated: false), .accepted(cardID: 1))
    XCTAssertEqual(fixture.controller.state.remainingCardIDs, [1, 2, 3])
  }

  func testDetachSettlesExactlyOnceAndCanRemountDuringSwipe() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    fixture.controller.swipe(.right)
    fixture.remount()
    await framesUntil("detached terminal event") { fixture.events.count == 2 }
    XCTAssertEqual(fixture.events, ["swipe:1", "end:settledOffscreen"])
    XCTAssertEqual(fixture.controller.state.currentCardID, 2)
    XCTAssertEqual(fixture.controller.undo(animated: false), .accepted(cardID: 1))
    await framesUntil("new undo event") { fixture.events.count == 4 }
    XCTAssertEqual(fixture.events.count, 4)
  }

  func testResetFromAcceptedCallbackSupersedesOnce() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    fixture.onAccepted = { _ in fixture.controller.reset() }
    fixture.controller.swipe(.left)
    await framesUntil("reset supersedes transition") { fixture.events.count == 2 }
    XCTAssertEqual(fixture.events, ["swipe:1", "end:superseded"])
    XCTAssertEqual(fixture.controller.state.remainingCardIDs, [1, 2, 3])
    XCTAssertFalse(fixture.controller.state.canUndo)
    fixture.onAccepted = nil
    fixture.controller.swipe(.right, animated: false)
    await framesUntil("new action after reset") { fixture.events.count == 4 }
    XCTAssertEqual(fixture.events.suffix(2), ["swipe:1", "end:completed"])
  }

  func testResetWhileDetachedStartsOverWithLatestItems() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    fixture.controller.swipe(.left, animated: false)
    fixture.host.disconnect()
    fixture.controller.reset()
    XCTAssertEqual(fixture.controller.state.remainingCardIDs, [1, 2, 3])
    fixture.remount()
    XCTAssertEqual(fixture.controller.state.currentCardID, 1)
    XCTAssertEqual(fixture.controller.undo(), .rejected(.nothingToUndo))
  }

  func testDuplicateIDsLeavePreviousPresentationIntact() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    let original = fixture.host.stack
    fixture.update([Item(id: 2, value: "a"), Item(id: 2, value: "b")])
    await framesUntil("duplicate error delivered") { fixture.errors == [.duplicateIDs] }
    XCTAssertTrue(fixture.host.stack === original)
    XCTAssertEqual(fixture.controller.state.remainingCardIDs, [1, 2, 3])
  }

  func testSecondPresentationCannotStealController() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    let other = Fixture(controller: fixture.controller); defer { other.close() }
    await framesUntil("connection conflict") { other.errors == [.controllerAlreadyConnected] }
    XCTAssertNil(other.host.stack)
    fixture.controller.swipe(.left, animated: false)
    XCTAssertEqual(fixture.host.stack?.state.currentCardID, 2)
    XCTAssertTrue(other.events.isEmpty)
  }

  func testContentAndEnvironmentUpdateWithoutReplacingVisibleCard() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    await framesUntil("initial content rendered") { fixture.renders.contains("1:one:en_US:light:large") }
    let original = try XCTUnwrap(fixture.host.stack?.card(for: 1))
    fixture.environment.locale = Locale(identifier: "es_ES")
    fixture.environment.colorScheme = .dark
    fixture.environment.sizeCategory = .accessibilityLarge
    fixture.update([Item(id: 1, value: "uno"), Item(id: 2, value: "two")])
    await framesUntil("new content and environment rendered") {
      fixture.renders.contains("1:uno:es_ES:dark:accessibilityLarge")
    }
    XCTAssertTrue(fixture.host.stack?.card(for: 1) === original)
    XCTAssertEqual(fixture.host.children.count, 2)
  }

  func testArrivalAndConfigurationDuringMovementAreDeferred() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    let outgoing = try XCTUnwrap(fixture.host.stack?.card(for: 1))
    let motion = Movement(card: outgoing)
    fixture.controller.swipe(.right)
    await framesUntil("card has begun moving") { motion.sample(); return motion.hasMotion }
    let original = fixture.host.stack
    fixture.configuration = CardStackConfiguration(visibleCardCount: 3, scaleStep: 0.08, verticalSpacing: 20)
    fixture.update([Item(id: 1, value: "changed"), Item(id: 4, value: "new"), Item(id: 2, value: "two")])
    XCTAssertTrue(fixture.host.stack === original)
    XCTAssertTrue(outgoing.content?.window != nil)
    XCTAssertEqual(fixture.controller.swipe(.left), .rejected(.busy))
    await framesUntil("transition and configuration settle") { fixture.events.count == 2 }
    XCTAssertEqual(fixture.controller.state.currentCardID, 4)
    XCTAssertFalse(fixture.host.stack === original)
    XCTAssertEqual(fixture.host.stack?.configuration.verticalSpacing, 20)
    XCTAssertEqual(fixture.controller.undo(animated: false), .accepted(cardID: 1))
  }

  func testHostingLivesThroughMotionAndReleasesAfterRemoval() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    let card = try XCTUnwrap(fixture.host.stack?.card(for: 1))
    weak var child = fixture.host.children.first { $0.view === card.content }
    XCTAssertNotNil(child)
    fixture.controller.swipe(.right)
    XCTAssertNotNil(child, "Outgoing host must remain alive during animation")
    await framesUntil("outgoing host released") { fixture.events.count == 2 && child == nil }
    fixture.close()
    XCTAssertTrue(fixture.host.children.isEmpty)
    XCTAssertEqual(fixture.controller.swipe(.left), .rejected(.notVisible))
  }

  func testObservableNotificationsAreOutsideUpdate() async throws {
    let fixture = Fixture(); defer { fixture.close() }
    var isUpdating = false
    var changes = 0
    let subscription = fixture.controller.objectWillChange.sink {
      XCTAssertFalse(isUpdating)
      changes += 1
    }
    isUpdating = true
    fixture.update([Item(id: 4, value: "new")])
    isUpdating = false
    await framesUntil("observable update") { changes > 0 }
    withExtendedLifetime(subscription) {}
  }

  func testPublicSwiftUIViewConnectsAndTearsDown() async throws {
    let controller = CardStackController<Int>()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    var events: [String] = []
    var root: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(
      CardStack(items: [Item(id: 1, value: "one")], controller: controller,
                onActionAccepted: { _ in events.append("action") },
                onTransitionEnded: { _ in events.append("end") },
                onError: { _ in XCTFail("Valid public presentation must connect") }) { item in Text(item.value) }
    ))
    weak var weakRoot = root
    window.rootViewController = root
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    await framesUntil("public representable connected") { controller.state.currentCardID == 1 }
    XCTAssertEqual(controller.swipe(.right, animated: false), .accepted(cardID: 1))
    await framesUntil("public events") { events == ["action", "end"] }
    root?.rootView = AnyView(EmptyView())
    await framesUntil("public representable dismantled") { controller.swipe(.right) == .rejected(.notVisible) }
    window.rootViewController = nil
    root = nil
    await framesUntil("root releases") { weakRoot == nil }
    XCTAssertTrue(controller.state.canUndo)
  }

  func testReplacementPresentationDoesNotReceiveOldEvents() async {
    let first = Fixture(); defer { first.close() }
    first.controller.swipe(.left, animated: false)
    first.host.disconnect()
    let second = Fixture(controller: first.controller); defer { second.close() }
    await framesUntil("originating callbacks delivered") { first.events.count == 2 }
    XCTAssertTrue(second.events.isEmpty)
    XCTAssertEqual(second.controller.state.currentCardID, 2)
  }

  func testContentUpdatePreservesLocalSwiftUIState() async {
    let controller = CardStackController<Int>()
    let host = CardStackHostingController<Item, StatefulProbe>()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.isHidden = false
    defer { host.disconnect(); window.isHidden = true; window.rootViewController = nil }
    var reports: [String: UUID] = [:]
    func update(_ title: String) {
      host.update(items: [Item(id: 1, value: title)], controller: controller,
                  configuration: .init(), environment: EnvironmentValues(),
                  content: { StatefulProbe(title: $0.value, report: { reports[$0] = $1 }) },
                  onActionAccepted: { _ in }, onTransitionEnded: { _ in },
                  onError: { _ in XCTFail("Valid content should update") })
      host.view.layoutIfNeeded()
    }
    update("first")
    await framesUntil("initial local state") { reports["first"] != nil }
    update("second")
    await framesUntil("updated local state") { reports["second"] != nil }
    XCTAssertEqual(reports["first"], reports["second"], "Content updates must not reset local @State")
  }

  func testPublicViewForwardsEnvironmentObjects() async {
    let controller = CardStackController<Int>()
    let model = EnvironmentModel()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    var reports: [String] = []
    let root = UIHostingController(rootView:
      CardStack(items: [Item(id: 1, value: "one")], controller: controller,
                onActionAccepted: { _ in }, onTransitionEnded: { _ in },
                onError: { _ in XCTFail("Valid public view should connect") }) { _ in
        EnvironmentProbe(report: { reports.append($0) })
      }.environmentObject(model))
    window.rootViewController = root
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    await framesUntil("environment object initial value") { reports.contains("first") }
    model.title = "second"
    await framesUntil("environment object changed value") { reports.contains("second") }
  }

  private func framesUntil(_ description: String, _ condition: @escaping () -> Bool) async {
    let done = expectation(description: description)
    let observer = FrameObserver {
      if condition() { done.fulfill(); return true }
      return false
    }
    defer { observer.stop() }
    await fulfillment(of: [done], timeout: 5)
  }
}

@available(iOS 13.0, *)
private struct Item: Identifiable, Equatable {
  let id: Int
  let value: String
}

@available(iOS 13.0, *)
@MainActor
private final class Fixture {
  let controller: CardStackController<Int>
  var host = CardStackHostingController<Item, Probe>()
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  var environment = EnvironmentValues()
  var configuration = CardStackConfiguration()
  var events: [String] = []
  var errors: [CardStackPresentationError] = []
  var renders: [String] = []
  var onAccepted: ((CardAction<Int>) -> Void)?
  private var items = [Item(id: 1, value: "one"), Item(id: 2, value: "two"), Item(id: 3, value: "three")]

  init(controller: CardStackController<Int>? = nil) {
    self.controller = controller ?? CardStackController()
    environment.locale = Locale(identifier: "en_US")
    environment.colorScheme = .light
    environment.sizeCategory = .large
    window.rootViewController = host
    window.isHidden = false
    update(items)
    host.view.layoutIfNeeded()
  }

  func update(_ items: [Item]) {
    self.items = items
    host.update(items: items, controller: controller, configuration: configuration, environment: environment,
                 content: { [weak self] item in Probe(item: item, report: { self?.renders.append($0) }) },
                 onActionAccepted: { [weak self] action in
                   switch action {
                   case .swipe(let id, _): self?.events.append("swipe:\(id)")
                   case .undo(let id): self?.events.append("undo:\(id)")
                   }
                   self?.onAccepted?(action)
                 },
                 onTransitionEnded: { [weak self] in self?.events.append("end:\($0.outcome)") },
                 onError: { [weak self] in self?.errors.append($0) })
  }

  func remount() {
    host.disconnect()
    host = CardStackHostingController()
    window.rootViewController = host
    update(items)
    host.view.layoutIfNeeded()
  }

  func close() { host.disconnect(); window.isHidden = true; window.rootViewController = nil }
}

@available(iOS 13.0, *)
private struct Probe: View {
  let item: Item
  let report: (String) -> Void
  @Environment(\.locale) var locale
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.sizeCategory) var sizeCategory
  var body: some View {
    Reporter(value: "\(item.id):\(item.value):\(locale.identifier):\(colorScheme):\(sizeCategory)", report: report)
  }
}

@available(iOS 13.0, *)
private struct Reporter: UIViewRepresentable {
  let value: String
  let report: (String) -> Void
  func makeUIView(context: Context) -> UILabel { UILabel() }
  func updateUIView(_ label: UILabel, context: Context) { label.text = value; report(value) }
}

@MainActor
private final class FrameObserver: NSObject {
  private var link: CADisplayLink?
  private let condition: () -> Bool
  init(condition: @escaping () -> Bool) {
    self.condition = condition
    super.init()
    link = CADisplayLink(target: self, selector: #selector(frame))
    link?.add(to: .main, forMode: .common)
  }
  @objc private func frame() { if condition() { stop() } }
  func stop() { link?.invalidate(); link = nil }
}

@MainActor
private final class Movement {
  weak var card: SwipeCard?
  private var positions: [CGPoint] = []
  private(set) var contentStayedAttached = true
  init(card: SwipeCard) { self.card = card }
  func sample() {
    guard let card = card, card.window != nil, let layer = card.layer.presentation() else { return }
    contentStayedAttached = contentStayedAttached && card.content?.window != nil
    positions.append(layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), to: layer.superlayer))
  }
  var hasMotion: Bool {
    guard let first = positions.first,
          let second = positions.first(where: { hypot($0.x - first.x, $0.y - first.y) > 1 }) else { return false }
    return positions.contains { hypot($0.x - second.x, $0.y - second.y) > 1 && hypot($0.x - first.x, $0.y - first.y) > 1 }
  }
}

@available(iOS 13.0, *)
private struct StatefulProbe: View {
  let title: String
  let report: (String, UUID) -> Void
  @State private var identity = UUID()
  var body: some View {
    Reporter(value: title, report: { report($0, identity) })
  }
}

@available(iOS 13.0, *)
private final class EnvironmentModel: ObservableObject {
  @Published var title = "first"
}

@available(iOS 13.0, *)
private struct EnvironmentProbe: View {
  @EnvironmentObject private var model: EnvironmentModel
  let report: (String) -> Void
  var body: some View { Reporter(value: model.title, report: report) }
}
