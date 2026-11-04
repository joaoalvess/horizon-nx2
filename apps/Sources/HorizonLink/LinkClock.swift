import Darwin

public enum LinkClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nowNs() -> UInt64 {
        nanoseconds(machTime: mach_absolute_time())
    }

    public static func nanoseconds(machTime: UInt64) -> UInt64 {
        let info = timebase
        return machTime &* UInt64(info.numer) / UInt64(info.denom)
    }

    public static func machTime(nanoseconds: UInt64) -> UInt64 {
        let info = timebase
        if info.numer == info.denom { return nanoseconds }
        return UInt64((Double(nanoseconds) * Double(info.denom) / Double(info.numer)).rounded())
    }
}
