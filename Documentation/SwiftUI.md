# SwiftUI card stacks

The Swift Package exposes `CardStack` and `CardStackController` on iOS 13+.
The existing UIKit APIs and package deployment declaration are unchanged. This
adapter is included by Swift Package Manager; the legacy CocoaPods specification
still selects only `Sources/Shuffle/Classes` and does not include the adapter.
Build with Xcode 16 or newer, as for the identity-based UIKit API.

## Usage

```swift
import Shuffle
import SwiftUI

struct CardItem: Identifiable {
  let id: UUID
  let title: String
}

@available(iOS 14.0, *) // StateObject; the adapter itself supports iOS 13.
struct CardsScreen: View {
  @StateObject private var cards = CardStackController<UUID>()
  let items: [CardItem]

  var body: some View {
    VStack {
      CardStack(
        items: items,
        controller: cards,
        configuration: .init(visibleCardCount: 4, scaleStep: 0.08, verticalSpacing: 20),
        onActionAccepted: { action in /* Record the accepted visual action. */ },
        onTransitionEnded: { end in /* Respond to the terminal outcome. */ },
        onError: { error in /* Handle duplicate IDs or a connection conflict. */ }
      ) { item in
        Text(item.title)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.blue)
      }
      .frame(height: 400)

      Button("Next") {
        switch cards.swipe(.right) {
        case .accepted(let id): break // Accepted ID, not necessarily animation completion.
        case .rejected(let reason): break // No accepted-action callback for this command.
        }
      }
      Button("Undo") { cards.undo() }
        .disabled(!cards.state.canUndo)
      Button("Start over") { cards.reset() }
    }
  }
}
```

On iOS 13, keep the controller in a stable external owner and observe it with
`ObservedObject`. Do not construct a fresh controller inside `body`.

## One owner for visual progress

The mounted engine owns current ID, remaining IDs, swipe directions and transition
state. The controller keeps a value-only engine snapshot when disconnected and
passes it to a new engine on reconnection. It does not maintain a second mutable
undo history. A controller supports one connected presentation at a time.

Removing a presentation during motion settles the action before checkpointing.
Recreating with the same controller restores progress without replaying accepted
actions. Commands on a disconnected or offscreen presentation return
`rejected(.notVisible)`. State remains readable while disconnected; `canUndo` then
describes retained history, not visibility. Reusing one controller in two mounted
views reports `controllerAlreadyConnected` to the second presentation without
stealing the first connection. After the first disconnects, a subsequent update
of the second presentation can connect it.

`reset()` starts over with the latest valid item IDs. It works connected or
disconnected, clears history and invalidates pending transition work. It does not
produce fake swipe/undo callbacks. An accepted action interrupted by reset ends
with `superseded` exactly once.

## Data, content and environment

Items describe the **full visual working set**, including swiped IDs that should
remain undoable. Removing an ID removes its undo eligibility. Same-ID updates
preserve progress; reset is always explicit. IDs must be unique. Invalid inputs
report an error asynchronously and leave the previous valid presentation intact.

`Identifiable` is sufficient; `Equatable` is not required. Existing hosting
controllers receive updated root values rather than replacement SwipeCards.
Local SwiftUI state survives same-card content updates. The representable forwards
its SwiftUI environment, including environment objects, to the hosted content.
The content closure and environment are refreshed on SwiftUI updates; applications
remain responsible for making their own model changes observable to SwiftUI.

Data updates received during movement are deferred by the engine. Hosting content
and configuration changes are applied at rest. Configuration changes recreate the
engine from its value checkpoint, preserving visual progress. The outgoing host
remains attached until Shuffle removes its card. The adapter handles UIKit child
containment and removes children on teardown. Styling inside the content belongs
to the client; the adapter does not reproduce any application's CALayer shadows.

## Callback timing

`onActionAccepted` and `onTransitionEnded` use existing Shuffle event types and
are delivered asynchronously on the main queue, in occurrence order, outside
representable updates. Use the event's ID; by delivery time, live state may have
advanced. Every accepted action receives one terminal event. Rejected commands
do not emit acceptance events. A cancelled drag is not an accepted action.

Events capture the callback of the presentation that produced them. Already
queued events finish delivery to that original callback after teardown; they
are never redirected to a replacement presentation. A callback may reset the
controller. It must not assume that the animation is still running merely because
it received acceptance, particularly for nonanimated commands.

Controller observation is coalesced onto the main queue to avoid publishing from
representable updates. Command return values and direct state reads remain
synchronous. Domain persistence and retry policy are the client's responsibility;
Shuffle never silently queues rejected commands or retries business operations.

## Verification

`Scripts/test-package.sh` runs the existing UIKit tests and hosted SwiftUI adapter
tests. Adapter cases cover real intermediate motion/content attachment, ordered
callbacks, reset from acceptance, detached reset, snapshot reconstruction, window
detachment, duplicate input/connection, content and environment changes, local
SwiftUI state, configuration changes during motion, hosting release, observable
invalidation and the public representable lifecycle.

Negative controls temporarily disable programmatic swipe animation or omit the
restore checkpoint. Their corresponding motion/restoration tests must fail.
Never commit those mutations. Simulator assertions do not establish pixel-perfect
rendering, physical-device performance, or compatibility across all supported OS
versions; validate those separately before a release.

Verified on 2026-09-14 with Xcode 26.6 and an iOS 26.5 simulator: 38 tests passed
(17 adapter, 19 identity-engine, 2 legacy compatibility), zero failures. The motion
negative control failed its intermediate-position assertion; the restoration
negative control failed position and undo assertions. Both mutations were restored
and all 38 tests passed again. Older runtime versions and CocoaPods were not tested.
