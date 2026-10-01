import Foundation

/// Facts about the machine MacSpace runs on.
public enum Machine {
    /// True inside a virtual machine (the hypervisor sets `kern.hv_vmm_present`). macOS does not offer Apple Intelligence there.
    public static var isVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }
}
