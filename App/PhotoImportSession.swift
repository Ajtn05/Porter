import Foundation
import Observation
import PorterKit

enum PhotoImportSource: String, CaseIterable, Identifiable {
    case camera, pictures, currentFolder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .camera: return "Camera (DCIM)"
        case .pictures: return "Pictures"
        case .currentFolder: return "Current phone folder"
        }
    }
}

@MainActor
@Observable
final class PhotoImportSession: Identifiable {
    let id = UUID()
    let device: Device
    let volume: StorageVolume
    let currentFolder: RemotePath
    var source: PhotoImportSource = .camera { didSet { resetScan() } }
    var includeVideos = true { didSet { resetScan() } }
    var destination: URL { didSet { invalidateReview() } }
    var existingFiles: ConflictResolution = .keepBoth { didSet { invalidateReview() } }
    var selectedPaths: Set<String> = [] { didSet { invalidateReview() } }
    private(set) var scanResult: PhotoImportScan?
    private(set) var reviewedPlan: TransferPlan?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private var operationID: UUID?
    private let resolver: any TransportResolver

    init(device: Device, volume: StorageVolume, currentFolder: RemotePath,
         destination: URL, resolver: any TransportResolver) {
        self.device = device
        self.volume = volume
        self.currentFolder = currentFolder
        self.destination = destination
        self.resolver = resolver
    }

    var sourcePath: RemotePath {
        switch source {
        case .camera: return volume.rootPath.appending("DCIM")
        case .pictures: return volume.rootPath.appending("Pictures")
        case .currentFolder: return currentFolder
        }
    }

    var selectedBytes: Int64 {
        scanResult?.files.filter { selectedPaths.contains($0.id) }.reduce(0) { $0 + $1.size } ?? 0
    }

    func scan() async {
        guard !isWorking else { return }
        resetScan()
        let token = beginOperation()
        let path = sourcePath, videos = includeVideos
        do {
            let transport = try await resolver.transport(for: device.id)
            let result = try await PhotoImportScanner().scan(path, using: transport, includeVideos: videos)
            guard operationID == token else { return }
            try Task.checkCancellation()
            cancelWork()
            scanResult = result
            selectedPaths = Set(result.files.map(\.id))
        } catch {
            finishOperation(token, error: error)
        }
    }

    func review() async {
        guard !isWorking, let result = scanResult, !selectedPaths.isEmpty else { return }
        let paths = Set(selectedPaths.map(RemotePath.init))
        let directory = destination, policy = existingFiles
        let token = beginOperation()
        do {
            let transport = try await resolver.transport(for: device.id)
            let plan = try await result.plan(selectedPaths: paths, from: transport, device: device.id,
                                             to: directory, existingFiles: policy)
            guard operationID == token else { return }
            try Task.checkCancellation()
            cancelWork()
            reviewedPlan = plan
        } catch {
            finishOperation(token, error: error)
        }
    }

    func cancelWork() {
        operationID = nil
        isWorking = false
    }

    func reportError(_ message: String) { errorMessage = message }

    private func beginOperation() -> UUID {
        let token = UUID()
        operationID = token
        isWorking = true
        reviewedPlan = nil
        errorMessage = nil
        return token
    }

    private func finishOperation(_ token: UUID, error: any Error) {
        guard operationID == token else { return }
        cancelWork()
        guard !(error is CancellationError) else { return }
        if let transferError = error as? TransferError {
            errorMessage = [transferError.errorDescription, transferError.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        } else { errorMessage = error.localizedDescription }
    }

    private func invalidateReview() {
        cancelWork()
        reviewedPlan = nil
        errorMessage = nil
    }

    private func resetScan() {
        invalidateReview()
        scanResult = nil
        selectedPaths = []
    }
}
