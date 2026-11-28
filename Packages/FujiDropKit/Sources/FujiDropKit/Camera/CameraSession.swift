#if os(iOS)
import Foundation
import ImageCaptureCore
import os

/// Wraps ImageCaptureCore: finds a USB camera, opens a session, keeps the file catalog,
/// and offers async thumbnail / metadata / download / PTP calls.
///
/// Everything published here is updated on the main actor. ImageCaptureCore delegate
/// callbacks are hopped onto the main actor before touching state.
@MainActor
public final class CameraSession: NSObject, ObservableObject {
    public enum Phase: Equatable {
        case idle
        case waitingForAuthorization
        case searching
        case opening(String)
        case loadingCatalog(String)
        case ready(String)
        case failed(String)
    }

    public struct LogLine: Identifiable, Sendable {
        public let id = UUID()
        public let date = Date()
        public let text: String
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var contentsAuthorization = "unknown"
    @Published public private(set) var controlAuthorization = "unknown"
    @Published public private(set) var camera: ICCameraDevice?
    @Published public private(set) var files: [ICCameraFile] = []
    @Published public private(set) var catalogComplete = false
    /// Identifies the connected body across reconnects. iOS doesn't expose the serial number
    /// (`serialNumberString` is macOS-only), so this is the model name: two bodies of the same
    /// model count as one camera, which is harmless because files are still told apart by
    /// name and size. Set when the catalog completes; nil while disconnected.
    @Published public private(set) var cameraID: String?
    @Published public private(set) var log: [LogLine] = []

    private let browser = ICDeviceBrowser()
    private var nextTransactionID: UInt32 = 1

    public override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
    }

    public var shots: [ShotPair<ICCameraFile>] {
        ShotPairing.pair(files) { $0.name ?? "" }
    }

    // MARK: Lifecycle

    public func start() async {
        phase = .waitingForAuthorization
        refreshAuthorizationStatus()
        record("Contents authorization before request: \(contentsAuthorization)")

        let contents = await authorization { self.browser.requestContentsAuthorization(completion: $0) }
        contentsAuthorization = contents
        record("Contents authorization: \(contents)")

        let control = await authorization { self.browser.requestControlAuthorization(completion: $0) }
        controlAuthorization = control
        record("Control authorization: \(control)")

        guard contents == ICAuthorizationStatus.authorized.rawValue else {
            phase = .failed("Camera access not authorized (\(contents)). Check Settings › Privacy.")
            return
        }
        phase = .searching
        browser.start()
        record("Browsing for cameras. Connect a Fujifilm camera (USB mode: USB CARD READER, or MTP(PTP) on older bodies) and turn it on.")
    }

    public func stop() {
        browser.stop()
        camera?.requestCloseSession()
        camera = nil
        files = []
        catalogComplete = false
        cameraID = nil
        phase = .idle
        record("Stopped.")
    }

    public func refreshAuthorizationStatus() {
        contentsAuthorization = browser.contentsAuthorizationStatus.rawValue
        controlAuthorization = browser.controlAuthorizationStatus.rawValue
    }

    private static let logger = Logger(subsystem: "FujiDrop", category: "camera")

    /// Appends to the in-app log and mirrors to the Xcode console (filter on "FujiDrop").
    public func record(_ text: String) {
        Self.logger.notice("\(text, privacy: .public)")
        log.append(LogLine(text: text))
    }

    /// Clears the stored control-authorization decision, then asks again.
    public func resetControlAuthorization() async {
        let reset = await authorization { self.browser.resetControlAuthorization(completion: $0) }
        record("Control authorization after reset: \(reset)")
        let requested = await authorization { self.browser.requestControlAuthorization(completion: $0) }
        controlAuthorization = requested
        record("Control authorization after re-request: \(requested)")
    }

    /// Awaits an ImageCaptureCore authorization callback. Those callbacks have been seen firing
    /// more than once (reset reported NotDetermined twice), so only the first one counts.
    /// The long timeout leaves time to answer a system prompt.
    private func authorization(
        _ call: (@escaping @Sendable (ICAuthorizationStatus) -> Void) -> Void
    ) async -> String {
        do {
            return try await Self.withTimeout(300, "authorization request") { done in
                call { done(.success($0.rawValue)) }
            }
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: File operations

    /// Thumbnail as the camera/ImageCaptureCore provides it by default (no size option),
    /// which is exactly what the spike needs to measure.
    public func thumbnailData(for file: ICCameraFile) async throws -> Data {
        try await Self.withTimeout(30, "thumbnail") { done in
            file.requestThumbnailData(options: [:]) { data, error in
                if let data { done(.success(data)) }
                else { done(.failure(error ?? CameraError.empty("thumbnail"))) }
            }
        }
    }

    public func metadata(for file: ICCameraFile) async throws -> [AnyHashable: Any] {
        let result: SendableBox<[AnyHashable: Any]> = try await Self.withTimeout(30, "metadata") { done in
            file.requestMetadataDictionary(options: [:]) { dict, error in
                if let dict { done(.success(SendableBox(dict))) }
                else { done(.failure(error ?? CameraError.empty("metadata"))) }
            }
        }
        return result.value
    }

    /// Downloads a file into `directory`, overwriting any previous copy. Returns the file URL.
    public func download(_ file: ICCameraFile, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .overwrite: true,
        ]
        let filename: String = try await Self.withTimeout(300, "download") { done in
            _ = file.requestDownload(options: options) { name, error in
                if let name { done(.success(name)) }
                else { done(.failure(error ?? CameraError.empty("download"))) }
            }
        }
        return directory.appendingPathComponent(filename)
    }

    /// Reads a byte range of a file on the camera without downloading the whole file.
    public func readData(_ file: ICCameraFile, offset: Int, length: Int) async throws -> Data {
        try await Self.withTimeout(30, "partial read") { done in
            file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                if let data { done(.success(data)) }
                else { done(.failure(error ?? CameraError.empty("data"))) }
            }
        }
    }

    public struct EmbeddedPreview: Sendable {
        public var header: RAFHeader
        public var jpeg: Data
        /// How long each of the two reads took, for diagnosing slow previews.
        public var headerSeconds: TimeInterval = 0
        public var jpegSeconds: TimeInterval = 0
    }

    /// Fetches the JPEG preview embedded in a RAF with two partial reads:
    /// the header, then exactly the preview's byte range.
    public func embeddedPreview(of raf: ICCameraFile) async throws -> EmbeddedPreview {
        let t0 = Date()
        let head = try await readData(raf, offset: 0, length: RAFHeader.readLength)
        guard let header = RAFHeader(head) else {
            throw CameraError.notRAF(PTP.hex(head, limit: 16))
        }
        let t1 = Date()
        let jpeg = try await readData(raf, offset: header.jpegOffset, length: header.jpegLength)
        return EmbeddedPreview(header: header, jpeg: jpeg, headerSeconds: t1.timeIntervalSince(t0),
                               jpegSeconds: Date().timeIntervalSince(t1))
    }

    // MARK: PTP pass-through

    public struct PTPResult: Sendable {
        public var command: Data
        public var dataIn: Data
        public var responseData: Data
        public var response: PTP.Response?
        public var errorDescription: String?

        public var payload: Data { PTP.payload(fromDataPhase: dataIn) }
    }

    /// Sends a raw PTP command. On iOS this may fail with a not-authorized error
    /// (see research doc); the spike exists to find out.
    public func sendPTP(
        _ operation: UInt16,
        params: [UInt32] = [],
        outData: Data? = nil
    ) async -> PTPResult {
        guard let camera else {
            return PTPResult(command: Data(), dataIn: Data(), responseData: Data(),
                             response: nil, errorDescription: "No camera connected")
        }
        let txID = nextTransactionID
        nextTransactionID &+= 1
        let command = PTP.commandContainer(operation, transactionID: txID, params: params)
        do {
            return try await Self.withTimeout(15, "PTP command") { done in
                camera.requestSendPTPCommand(command, outData: outData) { first, second, error in
                // The header names these (responseData, ptpResponseData); detect which one is the
                // response container rather than trusting the order.
                let swapped = PTP.parseResponse(second) == nil && PTP.parseResponse(first) != nil
                let dataIn = swapped ? second : first
                    let responseData = swapped ? first : second
                    done(.success(PTPResult(
                        command: command,
                        dataIn: dataIn,
                        responseData: responseData,
                        response: PTP.parseResponse(responseData),
                        errorDescription: error.map { CameraSession.describe($0) }
                    )))
                }
            }
        } catch {
            return PTPResult(command: command, dataIn: Data(), responseData: Data(),
                             response: nil, errorDescription: error.localizedDescription)
        }
    }

    /// Bridges a callback API to async, failing with `.timeout` if the callback never fires.
    /// Whichever comes first wins; the other is ignored.
    nonisolated static func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ what: String,
        _ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce(cont)
            start { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(.failure(CameraError.timeout(what, seconds)))
            }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    public enum CameraError: LocalizedError {
        case empty(String)
        case notRAF(String)
        case timeout(String, Double)
        public var errorDescription: String? {
            switch self {
            case .timeout(let what, let secs): return "No answer to \(what) after \(Int(secs)) s"
            case .empty(let what): return "Camera returned no \(what) and no error"
            case .notRAF(let head): return "Not a RAF header: \(head)"
            }
        }
    }

    // MARK: State changes (main actor)

    fileprivate func handleAdded(_ device: ICDevice) {
        record("Device found: \(device.name ?? "unnamed") type=\(device.type.rawValue) transport=\(device.transportType ?? "?")")
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        camera = cam
        cam.delegate = self
        phase = .opening(cam.name ?? "camera")
        cam.requestOpenSession()
    }

    fileprivate func handleRemoved(_ device: ICDevice) {
        record("Device removed: \(device.name ?? "unnamed")")
        guard device === camera else { return }
        camera = nil
        files = []
        catalogComplete = false
        cameraID = nil
        phase = .searching
    }

    fileprivate func handleSessionOpened(_ device: ICDevice, error: Error?) {
        if let error {
            phase = .failed("Open session failed: \(Self.describe(error))")
            record("Open session failed: \(Self.describe(error))")
            return
        }
        record("Session open with \(device.name ?? "camera"). Loading catalog…")
        phase = .loadingCatalog(device.name ?? "camera")
    }

    fileprivate func handleItemsAdded(_ items: [ICCameraItem]) {
        let newFiles = items.compactMap { $0 as? ICCameraFile }
        let known = Set(files.map { ObjectIdentifier($0) })
        files.append(contentsOf: newFiles.filter { !known.contains(ObjectIdentifier($0)) })
    }

    fileprivate func handleItemsRemoved(_ items: [ICCameraItem]) {
        let gone = Set(items.map { ObjectIdentifier($0) })
        files.removeAll { gone.contains(ObjectIdentifier($0)) }
    }

    fileprivate func handleCatalogComplete(_ device: ICCameraDevice) {
        handleItemsAdded(device.mediaFiles ?? [])
        cameraID = device.name ?? "camera"
        catalogComplete = true
        phase = .ready(device.name ?? "camera")
        record("Catalog complete: \(files.count) files, \(shots.count) shots, \(shots.filter(\.isComplete).count) RAF+JPEG pairs.")
        if files.isEmpty {
            record("Empty file list. Known iOS issue with some bodies; check camera USB mode and card.")
        }
    }
}

/// Resumes a continuation exactly once, from whichever thread gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

// MARK: - Delegates (hop to main actor)

extension CameraSession: ICDeviceBrowserDelegate {
    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in self.handleAdded(device) }
    }

    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in self.handleRemoved(device) }
    }
}

extension CameraSession: ICCameraDeviceDelegate {
    nonisolated public func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.handleRemoved(device) }
    }

    nonisolated public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in self.handleSessionOpened(device, error: error) }
    }

    nonisolated public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in self.record("Session closed\(error.map { ": " + CameraSession.describe($0) } ?? "")") }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in self.handleItemsAdded(items) }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor in self.handleItemsRemoved(items) }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    nonisolated public func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: Error?
    ) {}

    nonisolated public func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: Error?
    ) {}

    nonisolated public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor in self.record("Camera capabilities changed: \(camera.capabilities)") }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Task { @MainActor in self.record("PTP event: \(PTP.hex(eventData))") }
    }

    nonisolated public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.handleCatalogComplete(device) }
    }

    nonisolated public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.record("Access restriction removed") }
    }

    nonisolated public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.record("Access restriction enabled (camera locked or permission withdrawn)") }
    }
}
#endif
