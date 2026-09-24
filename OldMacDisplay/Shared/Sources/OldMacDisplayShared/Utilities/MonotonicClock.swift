import Foundation

/// Monotonic time source, immune to wall-clock adjustments.
///
/// `CACurrentMediaTime()` would do the same job but drags in QuartzCore; this
/// keeps Shared dependency-free and works identically on Catalina.
public enum MonotonicClock {
    /// Seconds since an arbitrary fixed origin.
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
