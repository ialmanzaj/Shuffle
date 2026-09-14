import Combine
import UIKit

/// Commands and visual-session lifetime for one SwiftUI CardStack presentation.
/// Keep this object alive to preserve progress when its presentation is recreated.
@available(iOS 13.0, *)
@MainActor
public final class CardStackController<ID: Hashable>: @preconcurrency ObservableObject {
  public let objectWillChange = ObservableObjectPublisher()

  /// The engine is authoritative while mounted; detached state is a value checkpoint.
  public var state: CardStackState<ID> { engine?.state ?? detachedState }

  private weak var engine: CardStackView<ID>?
  private var detachedState = CardStackState<ID>(currentCardID: nil, remainingCardIDs: [], canUndo: false, phase: .idle)
  private var itemIDs: [ID] = []
  private var notificationScheduled = false
  internal private(set) var checkpoint: CardStackView<ID>.Snapshot?

  public init() {}

  @discardableResult
  public func swipe(_ direction: SwipeDirection, animated: Bool = true) -> CardCommandResult<ID> {
    engine?.swipe(direction, animated: animated) ?? .rejected(.notVisible)
  }

  @discardableResult
  public func undo(animated: Bool = true) -> CardCommandResult<ID> {
    engine?.undo(animated: animated) ?? .rejected(.notVisible)
  }

  /// Starts over with the latest valid items; never replays accepted actions.
  public func reset() {
    if let engine = engine {
      engine.reset()
    } else {
      checkpoint = nil
      detachedState = CardStackState(currentCardID: itemIDs.first, remainingCardIDs: itemIDs, canUndo: false, phase: .idle)
    }
    notifyChange()
  }

  internal func connect(_ stack: CardStackView<ID>) -> Bool {
    guard engine == nil || engine === stack else { return false }
    engine = stack
    checkpoint = nil
    notifyChange()
    return true
  }

  internal var isConnected: Bool { engine != nil }

  internal func updateItemIDs(_ ids: [ID]) { itemIDs = ids }

  internal func disconnect(_ stack: CardStackView<ID>) {
    guard engine === stack else { return }
    checkpoint = stack.snapshot
    detachedState = stack.state
    engine = nil
    notifyChange()
  }

  internal func notifyChange() {
    // AIDEV-NOTE: SwiftUI may trigger updates while UIKit publishes a new state.
    // Coalesce invalidation outside representable updates; state reads remain synchronous.
    guard !notificationScheduled else { return }
    notificationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.notificationScheduled = false
      self.objectWillChange.send()
    }
  }
}
