import Foundation

extension Date {
    /// Older docs recorded milliseconds where newer ones record seconds.
    init(docTimestamp stamp: Int64) {
        let value = TimeInterval(stamp)
        self.init(timeIntervalSince1970: value > 4_000_000_000 ? value / 1000 : value)
    }
}
