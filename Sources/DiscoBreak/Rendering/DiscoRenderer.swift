import QuartzCore

/// The socket the disco ball screws into.
///
/// `ShowController` only ever talks to this protocol, never to a concrete renderer.
/// The v1 implementation is `CARenderer` (Core Animation, no assets). A Metal
/// implementation slots in later by conforming to the same four members.
protocol DiscoRenderer: AnyObject {

    /// Build the layer tree and attach it to the overlay window's host layer.
    func attach(to hostLayer: CALayer, screenFrame: CGRect, notchCenterX: CGFloat)

    /// Lower the ball out of the notch and start the show.
    func drop()

    /// Pull the ball back into the notch and stop the show.
    /// `completion` fires once the ball is fully hidden.
    func retract(completion: @escaping () -> Void)

    /// Tear down the layer tree entirely.
    func detach()
}
