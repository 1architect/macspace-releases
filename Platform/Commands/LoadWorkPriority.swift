import Darwin
import Foundation

/// Keep nested scan work at its caller's priority. A foreground request must not wait on forced utility workers;
/// scheduled/background reads retain their lower priority and the existing worker limits.
public enum LoadWorkPriority {
    public static func qos(for priority: TaskPriority) -> DispatchQoS.QoSClass {
        if priority >= .userInitiated { return .userInitiated }
        if priority >= .medium { return .default }
        return priority == .background ? .background : .utility
    }

    public static var current: DispatchQoS.QoSClass {
        if let priority = withUnsafeCurrentTask(body: { $0?.priority }) { return qos(for: priority) }
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED: return .userInitiated
        case QOS_CLASS_DEFAULT: return .default
        case QOS_CLASS_UTILITY: return .utility
        case QOS_CLASS_BACKGROUND: return .background
        default: return qos(for: Task.currentPriority)
        }
    }
}
