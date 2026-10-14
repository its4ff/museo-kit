import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Treaty file transfer: list flash recordings, download them over BLE, and
/// decode each one to a WAV so it can become a muse.
///
/// The firmware streams file data continuously after the size frame (no-ACK
/// fast path). Missing ranges are repaired by re-requesting the file at a
/// 950-byte aligned offset, which is the block size the firmware accepts.
extension RingBLEManager {
    private static let firmwareBlockSize = 950
    /// Right after a reconnect the ring sits on a 300 ms link and takes about 4.5 s to get
    /// back to fast (ring tests, 10-09), so anything shorter re-requests and stalls a healthy
    /// download. 3 s or more.
    private static let transferIdleTimeout: TimeInterval = 3.0
    private static let maxStalledResumes = 3

    // MARK: - Public entry points

    /// Ask the ring what it has stored. Harmless while idle; skipped mid-recording
    /// and while a list is already in flight so a second start can't restart it.
    public func requestRingFileList() {
        guard isProtocolReady else { return }
        guard !isSyncingOffline, !isListingRingFiles else { return }
        ringFiles.removeAll()
        expectedRingFileCount = 0
        isListingRingFiles = true
        offlineSyncError = nil
        send(.getFileList)
        print("[muse][offline] requesting file list (0x01)")
        // The first entry can take about 4.5 s after a reconnect (the ring is on its slow link).
        scheduleFileListCompletion(after: 4.0)
    }

    /// Download every stored recording that is not yet imported.
    public func syncOfflineRecordings() {
        guard isProtocolReady else {
            offlineSyncError = "ring not connected"
            return
        }
        guard canTransferOfflineFiles else {
            offlineSyncError = ringIsRecordingOffline ? "ring is still recording" : "busy capturing"
            return
        }
        guard !isSyncingOffline, !isListingRingFiles, !isDecodingOffline else { return }
        pendingOfflineSync = true
        requestRingFileList()
    }

    public var isOfflineSyncBusy: Bool {
        isListingRingFiles || isSyncingOffline || isDecodingOffline
    }

    /// Shared by the top-bar icon and home overscroll so they can't disagree.
    public var canStartOfflineSync: Bool {
        offlineMuseCount > 0 && canTransferOfflineFiles && !isOfflineSyncBusy
    }

    public func startOfflineSyncIfNeeded() {
        guard canStartOfflineSync else { return }
        syncOfflineRecordings()
    }

    /// True when it's safe to move files: the ring must not be writing to flash
    /// and we must not be mid-stream, or the firmware answers 0x03 busy.
    public var canTransferOfflineFiles: Bool {
        isProtocolReady && ringSystemState?.isRecording != true && !isCapturing && !isFirmwareUpdateInProgress
    }

    /// How many stored recordings a sync would actually bring over.
    ///
    /// Exact once a file list is in hand. Before that the ring's own count is the
    /// best signal available, and it over-reports: Treaty has no per-file delete,
    /// so recordings already on the phone sit on flash until storage is cleared.
    public var offlineMuseCount: Int {
        if !ringFiles.isEmpty { return unsyncedRingFiles.count }
        return Int(ringSystemState?.fileCount ?? 0)
    }

    public var unsyncedRingFiles: [RingFile] {
        ringFiles.filter {
            $0.size > 0
                && !syncedOfflineKeys.contains($0.syncKey)
                && !undecodableOfflineKeys.contains($0.syncKey)
        }
    }

    /// Wipes the ring's flash. Treaty has no per-file delete, so this is the only
    /// way to reclaim space once recordings are safely on the phone. `quietly`
    /// skips the user-facing error when the ring is busy.
    public func clearRingStorage(quietly: Bool = false) {
        guard canTransferOfflineFiles, !isSyncingOffline else {
            if !quietly { offlineSyncError = "can't clear while the ring is busy" }
            return
        }
        send(.format)
        ringFiles.removeAll()
        expectedRingFileCount = 0
        print("[muse][offline] clearing ring storage (0x10)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.requestSystemState()
        }
    }

    // MARK: - Auto clear

    /// Wipes the ring once a sync leaves nothing unsaved. A file that failed
    /// mid-transfer was never marked synced, so it stays and blocks the wipe.
    /// Format is all-or-nothing.
    private func maybeAutoClearRingStorage() {
        guard autoClearRingStorage else { return }
        // A file that couldn't be decoded never became a muse: it blocks the wipe too.
        let unprotected = ringFiles.filter {
            $0.size > 0 && !syncedOfflineKeys.contains($0.syncKey)
        }
        guard unprotected.isEmpty else {
            print("[muse][offline] keeping ring storage: \(unprotected.count) file(s) not safely saved")
            return
        }
        guard !ringFiles.isEmpty else { return }
        // canTransferOfflineFiles is checked inside clearRingStorage too — if the
        // user started a fresh recording since the sync, the wipe stands down.
        print("[muse][offline] auto-clearing ring after clean sync")
        clearRingStorage()
    }

    // MARK: - Auto sync

    /// Called when the ring reports it stopped recording, and after a reconnect
    /// that finds stored files. Gives the firmware a beat to close the file.
    ///
    /// `throttled` is used for the idle check-in path, which can fire repeatedly
    /// because downloaded recordings stay on the ring until it's cleared.
    func scheduleAutoOfflineSync(after delay: TimeInterval, throttled: Bool = false) {
        guard autoSyncOfflineRecordings, !isFirmwareUpdateInProgress else { return }
        if throttled, let last = lastAutoSyncAt, Date().timeIntervalSince(last) < 60 { return }
        lastAutoSyncAt = Date()
        autoSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.autoSyncOfflineRecordings, self.canTransferOfflineFiles, !self.isSyncingOffline else { return }
            print("[muse][offline] auto-sync starting")
            self.syncOfflineRecordings()
        }
        autoSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Treaty frame handling

    /// Returns true when the frame belonged to the offline transfer machinery.
    func handleOfflineFrame(_ frame: TreatyFrame) -> Bool {
        guard let command = TreatyCommand(rawValue: frame.command) else { return false }
        switch command {
        case .sendFileList:
            handleFileListEntry(frame.payload)
            return true
        case .sendFileSize:
            handleFileSize(frame.payload)
            return true
        case .sendFileData:
            handleFileData(frame.payload)
            return true
        case .errorState:
            return handleOfflineError(frame.payload.first ?? 0xFF)
        default:
            return false
        }
    }

    private func handleFileListEntry(_ payload: Data) {
        guard let file = RingFile.parse(payload) else { return }
        expectedRingFileCount = Int(file.totalEntries)

        if let index = ringFiles.firstIndex(where: { $0.id == file.id }) {
            ringFiles[index] = file
        } else {
            ringFiles.append(file)
            ringFiles.sort { lhs, rhs in
                if lhs.entryIndex != rhs.entryIndex { return lhs.entryIndex < rhs.entryIndex }
                return lhs.fileName < rhs.fileName
            }
        }

        let haveAll = expectedRingFileCount > 0 && ringFiles.count >= expectedRingFileCount
        scheduleFileListCompletion(after: haveAll ? 0.2 : 1.2)
    }

    private func scheduleFileListCompletion(after delay: TimeInterval) {
        fileListTimer?.invalidate()
        fileListTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finishFileList()
        }
    }

    private func finishFileList() {
        fileListTimer?.invalidate()
        fileListTimer = nil
        isListingRingFiles = false
        print("[muse][offline] file list: \(ringFiles.count) file(s), \(unsyncedRingFiles.count) new")

        guard pendingOfflineSync else { return }
        pendingOfflineSync = false
        startOfflineQueue()
    }

    private func startOfflineQueue() {
        let candidates = unsyncedRingFiles
        guard !candidates.isEmpty else {
            isSyncingOffline = false
            offlineQueueRemaining = 0
            print("[muse][offline] nothing new to sync")
            return
        }
        guard canTransferOfflineFiles else { return }

        offlineQueue = candidates
        offlineQueueRemaining = candidates.count
        isSyncingOffline = true
        offlineSyncError = nil
        beginOfflineBackgroundTask()
        print("[muse][offline] syncing \(candidates.count) recording(s)")
        startNextOfflineDownload()
    }

    private func startNextOfflineDownload() {
        guard isSyncingOffline else { return }
        guard !offlineQueue.isEmpty else {
            isSyncingOffline = false
            offlineQueueRemaining = 0
            activeOfflineFileName = nil
            offlineSyncProgress = 0
            print("[muse][offline] sync complete")
            maybeAutoClearRingStorage()
            requestSystemState()
            endOfflineBackgroundTask()
            return
        }

        let next = offlineQueue.removeFirst()
        offlineQueueRemaining = offlineQueue.count + 1
        beginDownload(of: next)
    }

    private func beginDownload(of file: RingFile) {
        activeOfflineFileName = file.fileName
        activeOfflineKey = file.fileName
        offlineSyncProgress = 0
        // Starting a new file ends the window where trailing status frames from
        // the previous one are ignored, so real errors aren't swallowed.
        awaitingTransferEndStatus = false
        offlineDownloads[file.fileName] = OfflineDownload(file: file, expectedSize: Int(file.size))
        print("[muse][offline] downloading \(file.fileName) (\(file.size) bytes)")
        sendGetFile(for: file, startOffset: 0)
        scheduleTransferTimeout()
    }

    private func sendGetFile(for file: RingFile, startOffset: UInt32) {
        var payload = Data()
        payload.append(file.recordByte)
        payload.append(contentsOf: file.segmentBytes.prefix(2))
        payload.append(UInt8(startOffset & 0xFF))
        payload.append(UInt8((startOffset >> 8) & 0xFF))
        payload.append(UInt8((startOffset >> 16) & 0xFF))
        payload.append(UInt8((startOffset >> 24) & 0xFF))
        payload.append(0x00) // no-ACK: firmware streams data frames continuously
        send(.getFile, payload: payload)
    }

    private func handleFileSize(_ payload: Data) {
        let bytes = Data(payload)
        guard bytes.count >= 7 else { return }
        let name = fileName(recordByte: bytes[0], segmentBytes: [bytes[1], bytes[2]])
        let size = Int(RingByte.le32(bytes, at: 3))
        guard var download = offlineDownloads[name] else { return }
        if size > 0 { download.expectedSize = size }
        offlineDownloads[name] = download
        scheduleTransferTimeout()
    }

    private func handleFileData(_ payload: Data) {
        let bytes = Data(payload)
        guard bytes.count >= 7 else { return }

        let name = fileName(recordByte: bytes[0], segmentBytes: [bytes[1], bytes[2]])
        let offset = Int(RingByte.le32(bytes, at: 3))
        let chunk = bytes.subdata(in: 7..<bytes.count)

        // Trailing frames for a file we already finished keep arriving after
        // finalize, so only adopt this file once we know it's still in flight.
        guard var download = offlineDownloads[name], !download.didFinalize else { return }

        // File-data frames skip CRC validation, so a corrupt offset must not be
        // trusted to size the buffer.
        guard download.expectedSize > 0, offset >= 0, offset < download.expectedSize else {
            print("[muse][offline] ignoring \(name) frame at bad offset \(offset)")
            return
        }

        // The ring serves whole blocks, so the last one runs past the file's
        // reported size. Clip the padding instead of dropping the frame — doing
        // the latter leaves every file one block short and it never completes.
        let usable = min(chunk.count, download.expectedSize - offset)
        let body = chunk.prefix(usable)
        let end = offset + usable

        activeOfflineKey = name

        // Data can arrive out of order after a resume, so grow the buffer and
        // write in place rather than appending.
        if download.bytes.count < end {
            download.bytes.append(Data(repeating: 0, count: end - download.bytes.count))
        }
        download.bytes.replaceSubrange(offset..<end, with: body)
        if usable > 0 {
            download.received.insert(integersIn: offset..<end)
        }
        offlineDownloads[name] = download

        // Publishing every frame would re-render the whole app hundreds of times
        // a second and starve the main thread the idle timer runs on.
        let progress = download.progress
        if progress >= 1 || abs(progress - offlineSyncProgress) >= 0.01 {
            offlineSyncProgress = progress
        }

        if download.isComplete {
            finalizeDownload(named: name)
        } else {
            scheduleTransferTimeout()
        }
    }

    private func handleOfflineError(_ code: UInt8) -> Bool {
        // 0x00/0x02 routinely trail a completed transfer; swallow those.
        if awaitingTransferEndStatus {
            awaitingTransferEndStatus = false
            return true
        }
        guard isSyncingOffline || activeOfflineKey != nil else { return false }

        switch code {
        case 0x03:
            offlineSyncError = "ring is recording"
            abortOfflineSync()
        case 0x09:
            print("[muse][offline] ring reports no matching file")
            finishOrRepairDownload()
        default:
            print("[muse][offline] treaty error \(String(format: "0x%02X", code)) during transfer")
            finishOrRepairDownload()
        }
        return true
    }

    // MARK: - Timeout, resume, completion

    private func scheduleTransferTimeout() {
        offlineTimeoutTimer?.invalidate()
        offlineTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Self.transferIdleTimeout,
            repeats: false
        ) { [weak self] _ in
            self?.finishOrRepairDownload()
        }
    }

    /// The download the timeout should act on. Falls back to whatever is still
    /// in flight so a stray frame for a finished file can't strand the transfer.
    private var inFlightDownloadKey: String? {
        if let key = activeOfflineKey, let download = offlineDownloads[key], !download.didFinalize {
            return key
        }
        return offlineDownloads.first { !$0.value.didFinalize }?.key
    }

    /// The data stream went quiet: either we're done, or there's a gap to resume.
    private func finishOrRepairDownload() {
        guard let key = inFlightDownloadKey, var download = offlineDownloads[key] else {
            offlineTimeoutTimer?.invalidate()
            offlineTimeoutTimer = nil
            return
        }
        activeOfflineKey = key

        if download.isComplete {
            finalizeDownload(named: key)
            return
        }

        guard let gap = download.firstMissingOffset else {
            finalizeDownload(named: key)
            return
        }

        let received = download.received.count
        if received <= download.lastResumeReceived {
            download.stalledResumes += 1
        } else {
            download.stalledResumes = 0
        }
        download.lastResumeReceived = received

        guard download.stalledResumes < Self.maxStalledResumes else {
            offlineDownloads[key] = download
            print("[muse][offline] \(key) stalled at \(received)/\(download.expectedSize) bytes")
            finalizeDownload(named: key)
            return
        }

        offlineDownloads[key] = download
        let resumeOffset = (gap / Self.firmwareBlockSize) * Self.firmwareBlockSize
        print("[muse][offline] resuming \(key) at \(resumeOffset) (have \(received)/\(download.expectedSize))")
        sendGetFile(for: download.file, startOffset: UInt32(resumeOffset))
        scheduleTransferTimeout()
    }

    private func finalizeDownload(named key: String) {
        offlineTimeoutTimer?.invalidate()
        offlineTimeoutTimer = nil

        guard var download = offlineDownloads[key], !download.didFinalize else { return }
        download.didFinalize = true
        offlineDownloads[key] = download

        let expected = download.expectedSize
        let complete = download.firstMissingOffset == nil && expected > 0
        let opsData = expected > 0 ? Data(download.bytes.prefix(expected)) : download.bytes
        let file = download.file
        let elapsed = Date().timeIntervalSince(download.startedAt)

        endFileTransfer()
        offlineDownloads.removeValue(forKey: key)
        activeOfflineKey = nil

        guard complete, !opsData.isEmpty else {
            offlineSyncError = "\(key) transferred partially"
            print("[muse][offline] \(key) incomplete (\(opsData.count)/\(expected) bytes)")
            continueOfflineQueue()
            return
        }

        offlineSyncProgress = 1

        let rate = elapsed > 0 ? Double(opsData.count) / 1_000 / elapsed : 0
        print("[muse][offline] \(key) done: \(opsData.count) bytes in \(String(format: "%.1fs", elapsed)) (\(String(format: "%.0f", rate)) KB/s)")

        decodeOfflineRecording(opsData, file: file)
    }

    func endFileTransfer() {
        guard isProtocolReady else { return }
        awaitingTransferEndStatus = true
        send(.getFileEnd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.awaitingTransferEndStatus = false
        }
    }

    private func continueOfflineQueue() {
        guard isSyncingOffline else {
            activeOfflineFileName = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startNextOfflineDownload()
        }
    }

    func abortOfflineSync() {
        offlineTimeoutTimer?.invalidate()
        offlineTimeoutTimer = nil
        fileListTimer?.invalidate()
        fileListTimer = nil
        autoSyncWorkItem?.cancel()
        autoSyncWorkItem = nil
        offlineQueue.removeAll()
        offlineDownloads.removeAll()
        offlineQueueRemaining = 0
        activeOfflineKey = nil
        activeOfflineFileName = nil
        isSyncingOffline = false
        isListingRingFiles = false
        pendingOfflineSync = false
        offlineSyncProgress = 0
        endOfflineBackgroundTask()
    }

    /// Keeps the app running long enough to finish a transfer that started from a
    /// BLE callback while backgrounded.
    private func beginOfflineBackgroundTask() {
        #if canImport(UIKit)
        guard offlineBackgroundTask == .invalid else { return }
        offlineBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "muse.offline-sync") { [weak self] in
            self?.endOfflineBackgroundTask()
        }
        #endif
    }

    private func endOfflineBackgroundTask() {
        #if canImport(UIKit)
        guard offlineBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(offlineBackgroundTask)
        offlineBackgroundTask = .invalid
        #endif
    }

    // MARK: - Decode

    private func decodeOfflineRecording(_ opsData: Data, file: RingFile) {
        let recordedAt = file.timestamp ?? Date()
        let stamp = Self.fileStamp.string(from: recordedAt)
        // Without the ring's clock, two files decoded in the same second would share a name
        // (and the second would write over the first's audio): add the ring's own file name.
        let ringName = file.fileName.replacingOccurrences(of: ".ops", with: "")
        let base = file.timestamp == nil ? "muse-offline-\(stamp)-\(ringName)" : "muse-offline-\(stamp)"
        isDecodingOffline = true

        decodeQueue.async { [weak self] in
            guard let self else { return }
            let packets = OggOpusWriter.extractPackets(from: [opsData])
            print("[muse][offline] \(OggOpusWriter.lastExtractionSummary)")

            guard !packets.isEmpty,
                  let pcm = OpusWavDecoder.decodeToPCM(packets: packets) else {
                DispatchQueue.main.async {
                    self.isDecodingOffline = false
                    self.offlineSyncError = "could not decode \(file.fileName)"
                    // Don't retry this one for the rest of the session, but leave
                    // it unsynced so a future build can have another go.
                    self.undecodableOfflineKeys.insert(file.syncKey)
                    self.continueOfflineQueue()
                }
                return
            }

            let sampleCount = pcm.count / 2
            let duration = Double(sampleCount) / Double(MuseCaptureConstants.opusSampleRate)
            let estimated = Double(packets.count) * MuseCaptureConstants.opusFrameDuration
            let resolvedDuration = duration > 0 ? duration : estimated

            // Pocket taps under a second aren't muses. Drop them so they never
            // re-download or block the post-sync clear.
            guard resolvedDuration >= 1.0 else {
                DispatchQueue.main.async {
                    self.isDecodingOffline = false
                    print("[muse][offline] skipping \(file.fileName): \(String(format: "%.1f", resolvedDuration))s under the 1s floor")
                    self.markOfflineSynced(file.syncKey)
                    self.continueOfflineQueue()
                }
                return
            }

            let wavData = OpusWavDecoder.wav(fromPCM: pcm)
            let opsName = "\(base).ops"
            let wavName = "\(base)-raw.wav"
            _ = self.writeCaptureFile(opsData, named: opsName)
            let didWriteWav = self.writeCaptureFile(wavData, named: wavName) != nil

            DispatchQueue.main.async {
                self.isDecodingOffline = false
                guard didWriteWav else {
                    self.offlineSyncError = "could not save \(wavName)"
                    self.continueOfflineQueue()
                    return
                }

                print("[muse][offline] decoded \(wavName) — \(packets.count) frames, \(String(format: "%.1f", resolvedDuration))s")
                self.enqueueCapture(
                    CompletedCapture(
                        id: UUID(),
                        startedAt: recordedAt,
                        endedAt: recordedAt.addingTimeInterval(resolvedDuration),
                        fileName: opsName,
                        wavFileName: wavName,
                        byteCount: opsData.count,
                        packetCount: packets.count,
                        duration: resolvedDuration,
                        sampleRate: MuseCaptureConstants.opusSampleRate,
                        source: .offline,
                        offlineSyncKey: file.syncKey
                    )
                )
                self.continueOfflineQueue()
            }
        }
    }

    // MARK: - Helpers

    private func fileName(recordByte: UInt8, segmentBytes: [UInt8]) -> String {
        let segments = segmentBytes.prefix(2).map { RingByte.bcdString($0) }.joined()
        return "\(RingByte.bcdString(recordByte))-\(segments).ops"
    }

    func writeCaptureFile(_ data: Data, named name: String) -> URL? {
        let url = Self.capturesDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: Self.capturesDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[muse][offline] write failed for \(name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Retires a ring recording once its muse is saved. Until this is called
    /// the file stays in `unsyncedRingFiles` and will be fetched again.
    package func markOfflineSynced(_ syncKey: String) {
        guard !syncedOfflineKeys.contains(syncKey) else { return }
        syncedOfflineKeys.insert(syncKey)
        persistSyncedOfflineKeys()
    }

    func persistSyncedOfflineKeys() {
        // Keep the ledger bounded; the ring holds far fewer files than this.
        let trimmed = Array(syncedOfflineKeys.suffix(500))
        UserDefaults.standard.set(trimmed, forKey: RingBLEManager.syncedOfflineKeysDefault)
    }
}
