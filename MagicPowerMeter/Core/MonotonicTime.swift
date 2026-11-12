import Foundation

enum MonotonicTime {
	private static let origin = ContinuousClock.now

	static var now: TimeInterval {
		let duration = origin.duration(to: ContinuousClock.now).components
		return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
	}
}
