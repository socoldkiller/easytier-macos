package enum PrivilegedHelperClientRequirement {
    package static let debug = "identifier \"com.kkrainbow.easytier.mac\""

    package static let release = """
    anchor apple generic and identifier "com.kkrainbow.easytier.mac" and \
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
    certificate leaf[subject.OU] = "84K5NV46VA"
    """

    package static var current: String {
        #if DEBUG
        debug
        #else
        release
        #endif
    }
}
