#if os(iOS)
import Foundation
import ImageCaptureCore

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

        let contents = await withCheckedContinuation { cont in
            browser.requestContentsAuthorization { cont.resume(returning: $0) }
        }
        contentsAuthorization = contents.rawValue
        record("Contents authorization: \(contents.rawValue)")

        let control = await withCheckedContinuation { cont in
            browser.requestControlAuthorization { cont.resume(returning: $0) }
        }
        controlAuthorization = control.rawValue
        record("Control authorization: \(control.rawValue)")

        guard contents == .authorized else {
            phase = .failed("Camera access not authorized (\(contents.rawValue)). Check Settings › Privacy.")
            return
        }
        phase = .searching
        browser.start()
        record("Browsing for cameras. Connect the X-T1 (USB mode: card reader / PTP) and turn it on.")
    }

    public func stop() {
        browser.stop()
        camera?.requestCloseSession()
        camera = nil
        files = []
        catalogComplete = false
        phase = .idle
        record("Stopped.")
    }

    public func refreshAuthorizationStatus() {
        contentsAuthorization = browser.contentsAuthorizationStatus.rawValue
        controlAuthorization = browser.controlAuthorizationStatus.rawValue
    }

    public func record(_ text: String) {
        log.append(LogLine(text: text))
    }

    // MARK: File operations

    /// Thumbnail as the camera/ImageCaptureCore provides it by default (no size option),
    /// which is exactly what the spike needs to measure.
    public func thumbnailData(for file: ICCameraFile) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            file.requestThumbnailData(options: [:]) { data, error in
                if let data { cont.resume(returning: data) }
                else { cont.resume(throwing: error ?? CameraError.empty("thumbnail")) }
            }
        }
    }

    public func metadata(for file: ICCameraFile) async throws -> [AnyHashable: Any] {
        try await withCheckedThrowingContinuation { cont in
            file.requestMetadataDictionary(options: [:]) { dict, error in
                if let dict { cont.resume(returning: dict) }
                else { cont.resume(throwing: error ?? CameraError.empty("metadata")) }
            }
        }
    }

    /// Downloads a file into `directory`, overwriting any previous copy. Returns the file URL.
    public func download(_ file: ICCameraFile, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .overwrite: true,
        ]
        let filename: String = try await withCheckedThrowingContinuation { cont in
            _ = file.requestDownload(options: options) { name, error in
                if let name { cont.resume(returning: name) }
                else { cont.resume(throwing: error ?? CameraError.empty("download")) }
            }
        }
        return directory.appendingPathComponent(filename)
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
        return await withCheckedContinuation { cont in
            camera.requestSendPTPCommand(command, outData: outData) { first, second, error in
                // The header names these (responseData, ptpResponseData); detect which one is the
                // response container rather than trusting the order.
                let swapped = PTP.parseResponse(second) == nil && PTP.parseResponse(first) != nil
                let dataIn = swapped ? second : first
                let responseData = swapped ? first : second
                cont.resume(returning: PTPResult(
                    command: command,
                    dataIn: dataIn,
                    responseData: responseData,
                    response: PTP.parseResponse(responseData),
                    errorDescription: error.map { CameraSession.describe($0) }
                ))
            }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    public enum CameraError: LocalizedError {
        case empty(String)
        public var errorDescription: String? {
            switch self {
            case .empty(let what): return "Camera returned no \(what) and no error"
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
        catalogComplete = true
        phase = .ready(device.name ?? "camera")
        record("Catalog complete: \(files.count) files, \(shots.count) shots, \(shots.filter(\.isComplete).count) RAF+JPEG pairs.")
        if files.isEmpty {
            record("Empty file list. Known iOS issue with some bodies; check camera USB mode and card.")
        }
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
