import Combine
import Foundation
import Network

/// 局域网扫描：CarWithin 的接收页固定监听 HTTP 端口（默认 9888），
/// 扫一遍本机所在 /24 网段，能建立 TCP 连接的就是候选手机。
///
/// 不做 mDNS 发现：CarWithin 只给配件通道发布 `_tds-carkit._tcp`，
/// 输出端口的服务名没有对外广播。
final class LANScanner: ObservableObject {

    @Published private(set) var hosts: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var localPrefix: String?

    private var generation = 0
    private let queue = DispatchQueue(label: "carwithin.scan", qos: .userInitiated)
    private var cancelled = false

    func scan(port: UInt16) {
        generation += 1
        let run = generation
        cancelled = false
        hosts = []
        localPrefix = Self.currentPrefix()
        guard let prefix = localPrefix else {
            isScanning = false
            return
        }
        isScanning = true

        queue.async { [weak self] in
            guard let self else { return }
            for chunk in stride(from: 1, through: 254, by: 48) {
                if self.cancelled || self.generation != run { return }
                let upper = min(chunk + 47, 254)
                var found: [String] = []
                let group = DispatchGroup()
                let lock = NSLock()

                for index in chunk...upper {
                    if self.cancelled { break }
                    let host = "\(prefix)\(index)"
                    group.enter()
                    self.probe(host: host, port: port) { success in
                        if success {
                            lock.lock()
                            found.append(host)
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
                group.wait()
                guard !found.isEmpty else { continue }
                let ordered = found.sorted { left, right in
                    let leftTail = Int(left.split(separator: ".").last.map(String.init) ?? "") ?? 0
                    let rightTail = Int(right.split(separator: ".").last.map(String.init) ?? "") ?? 0
                    return leftTail < rightTail
                }
                DispatchQueue.main.async {
                    guard self.generation == run else { return }
                    for host in ordered where !self.hosts.contains(host) {
                        self.hosts.append(host)
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.generation == run else { return }
                self.isScanning = false
            }
        }
    }

    func cancel() {
        cancelled = true
        generation += 1
        isScanning = false
    }

    private func probe(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let lock = NSLock()
        var finished = false

        func finish(_ success: Bool) {
            lock.lock()
            let alreadyDone = finished
            finished = true
            lock.unlock()
            guard !alreadyDone else { return }
            connection.cancel()
            completion(success)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            case .waiting:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 0.8) {
            finish(false)
        }
    }

    // MARK: - 本机网段

    private static func currentPrefix() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var pointer = first
        while true {
            let interface = pointer.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.isEmpty, !ip.hasPrefix("127.") {
                            address = ip
                        }
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }

        guard let ip = address else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])."
    }
}
