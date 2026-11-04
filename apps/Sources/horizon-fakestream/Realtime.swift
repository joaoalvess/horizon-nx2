import Darwin
import HorizonLink

enum Realtime {
    static func promote(periodNs: UInt64, computationNs: UInt64, constraintNs: UInt64) -> Bool {
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(LinkClock.machTime(nanoseconds: periodNs)),
            computation: UInt32(LinkClock.machTime(nanoseconds: computationNs)),
            constraint: UInt32(LinkClock.machTime(nanoseconds: constraintNs)),
            preemptible: 1
        )
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return result == KERN_SUCCESS
    }
}
