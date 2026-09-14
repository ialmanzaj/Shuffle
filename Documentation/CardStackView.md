# Identity-based CardStackView

`CardStackView<CardID: Hashable>` is an additive, main-actor UIKit API. The existing
index-based `SwipeCardStack` remains available. Build the package/tests with Xcode 16 or later.

```swift
let stack = CardStackView<UUID>(configuration: .init(
    visibleCardCount: 4, scaleStep: 0.08, verticalSpacing: 20
)) { id in
    let card = SwipeCard()
    card.content = makeContentView(for: id)
    return card
}
try stack.resetCards(sessionIDs)
let result = stack.swipe(.right)
```

The provider must return a **new, unattached card** for each invocation. It may be called again
for undo, reconfiguration or a card returning to the visible range. Own any view controllers
that provide content in the embedding application. This API does not manage SwiftUI hosting.

## Commands and callbacks

`swipe(_:animated:)` and `undo(animated:)` return `.accepted(cardID:)` or `.rejected(reason)`.
Rejection changes neither IDs nor history. Reasons are busy, empty, nothingToUndo, notVisible,
and disallowedDirection. Swipe directions are validated against configuration.

State contains currentCardID, remainingCardIDs, canUndo and phase (idle/dragging/animating).
`canUndo` describes available history while idle; a detached stack still rejects commands.
Commands issued from any notification callback are rejected as busy. Dispatch a subsequent
command after the callback returns. State notifications are emitted only when state changes.

- `onActionAccepted`: logical change has happened and phase is already animating.
- `onTransitionEnded`: exactly once per accepted command/gesture. Both the primary card and
  background motion are settled before this callback; pending data has been applied.
- `onStateChanged`: read-only state changes, including dragging and returning to idle.

Outcomes: completed (also for nonanimated commands), settledOffscreen (window detachment),
and superseded (explicit reset or an externally interrupted animation). Settling an accepted
action never rolls back its logical history. An unaccepted cancelled drag instead springs back
without changing history or emitting an accepted action. Stale completion callbacks cannot
finish a newer operation. Callbacks may reset or update data; they must not recursively issue
unbounded resets or otherwise mutate card transforms/animations owned by the stack.

## Updating a session

`updateCards(_:) throws -> CardUpdateResult` receives the whole session: **include swiped IDs
that must remain undoable**, not only pending IDs. Duplicate IDs fail before mutation.

- Preserves the swipe history of retained IDs, including direction and chronological order.
- Prunes removed IDs from undo history; orders pending cards according to the supplied IDs.
- Reuses rendered cards whose IDs remain visible.
- During dragging/animation/reset-spring, defers updates; only the latest valid update wins.
- Returns applied or deferred. A reset discards pending updates.

`resetCards(_:)` explicitly starts a new session, clears undo history and reports any accepted
in-flight action as superseded. Invalid IDs leave the old session and pending work untouched.

`reconfigureCards(_:)` recreates only requested rendered cards, without changing order or
history. During movement it is deferred. Offscreen cards pick up fresh content when created.
`card(for:)` returns currently rendered cards for inspection; it does not transfer ownership.

## Layout and compatibility

Configuration controls visibleCardCount, scaleStep, verticalSpacing and allowedDirections.
Count is at least one, scaleStep is clamped to 0...1, spacing is nonnegative, and nonfinite
values fall back to defaults. Card scale is bounded below by 0.01. Animation durations and
curves continue to use each SwipeCard's existing animationOptions. Gesture geometry still
uses the existing Shuffle calculations; multi-window geometry modernization is separate.

Legacy changes: cancelled gestures no longer commit a swipe, and window detachment settles
interrupted animations without resetting index history. Legacy success-only callbacks and
index APIs are otherwise not replaced by the new transition engine.

## Tests

Run `Scripts/test-package.sh`. Optionally set SHUFFLE_TEST_DESTINATION to an Xcode simulator
destination. The script temporarily hides and restores the legacy CocoaPods symlink so Xcode
selects Package.swift. Tests use isolated UIKit windows and run serially. They cover real
presentation-layer movement, command rejection/reentrancy, cancellation, deferred arrivals,
identity/history preservation, explicit reset, stale callbacks, and legacy compatibility.
The GitHub workflow runs the same package tests on an iOS simulator and uploads xcresult.
These tests do not prove pixel-perfect rendering, performance, or every device configuration.

Validation recorded with Xcode 26.6 / iOS 26.5: 18 package tests pass. A negative control
that disables animation fails both swipe and undo presentation-motion assertions; restoring
animation returns the suite to passing. These results cover the package tests above, not the
separate legacy CocoaPods/Quick example test project.

## Recreating a view

Keep `stack.snapshot` with the presentation session. It contains values only: remaining
IDs and accepted swipe history with directions. Initialize the replacement using
`CardStackView(configuration: configuration, restoring: snapshot, makeCard: factory)`,
then call `updateCards` with the current session IDs once its content factory is ready.
Restoration starts idle and does not replay callbacks or animations. A checkpoint taken
while moving includes the accepted action and latest deferred ID update; it does not
preserve partial presentation-layer progress. An update still prunes removed history.
