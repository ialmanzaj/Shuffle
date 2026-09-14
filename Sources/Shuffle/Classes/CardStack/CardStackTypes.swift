import UIKit

public enum CardStackPhase: Equatable { case idle, dragging, animating }
public enum CardCommandRejection: Equatable { case busy, empty, nothingToUndo, notVisible, disallowedDirection }
public enum CardCommandResult<CardID: Hashable>: Equatable {
  case accepted(cardID: CardID)
  case rejected(CardCommandRejection)
}
public enum CardUpdateResult: Equatable { case applied, deferred }
public enum CardStackError: Error, Equatable { case duplicateIDs }
public enum CardTransitionOutcome: Equatable { case completed, settledOffscreen, superseded }
public enum CardAction<CardID: Hashable>: Equatable {
  case swipe(cardID: CardID, direction: SwipeDirection)
  case undo(cardID: CardID)
}
public struct CardTransitionEnd<CardID: Hashable>: Equatable {
  public let action: CardAction<CardID>
  public let outcome: CardTransitionOutcome
}
public struct CardStackState<CardID: Hashable>: Equatable {
  public let currentCardID: CardID?
  public let remainingCardIDs: [CardID]
  public let canUndo: Bool
  public let phase: CardStackPhase
}

/// Immutable layout policy. Invalid numeric values are normalized at initialization.
public struct CardStackConfiguration: Equatable {
  public let visibleCardCount: Int
  public let scaleStep: CGFloat
  public let verticalSpacing: CGFloat
  public let allowedDirections: Set<SwipeDirection>

  public init(visibleCardCount: Int = 2, scaleStep: CGFloat = 0.05,
              verticalSpacing: CGFloat = 0, allowedDirections: Set<SwipeDirection> = [.left, .right]) {
    self.visibleCardCount = max(1, visibleCardCount)
    self.scaleStep = scaleStep.isFinite ? min(1, max(0, scaleStep)) : 0.05
    self.verticalSpacing = verticalSpacing.isFinite ? max(0, verticalSpacing) : 0
    self.allowedDirections = allowedDirections
  }
}
