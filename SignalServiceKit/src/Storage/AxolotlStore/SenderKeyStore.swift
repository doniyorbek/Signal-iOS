//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import SignalClient

@objc
public class SenderKeyStore: NSObject {
    public typealias DistributionId = UUID
    fileprivate typealias KeyId = String
    fileprivate static func buildKeyId(addressUuid: UUID, distributionId: DistributionId) -> KeyId {
        "\(addressUuid.uuidString).\(distributionId.uuidString)"
    }

    // MARK: - Storage properties
    private let storageLock = UnfairLock()
    private var sendingDistributionIdCache: LRUCache<ThreadUniqueId, DistributionId> = LRUCache(maxSize: 100)
    private var keyCache: LRUCache<KeyId, KeyMetadata> = LRUCache(maxSize: 100)

    public override init() {
        super.init()
        SwiftSingletons.register(self)
    }

    /// Returns the distributionId the current device uses to tag senderKey messages sent to the thread.
    public func distributionIdForSendingToThread(_ thread: TSGroupThread, writeTx: SDSAnyWriteTransaction) -> DistributionId {
        storageLock.withLock {
            distributionIdForSendingToThreadId(thread.threadUniqueId, writeTx: writeTx)
        }
    }

    /// Returns a list of addresses that may not have the current device's sender key for the thread.
    @objc
    public func recipientsInNeedOfSenderKey(
        for thread: TSGroupThread,
        addresses: [SignalServiceAddress],
        writeTx: SDSAnyWriteTransaction
    ) -> [SignalServiceAddress] {
        var addressesNeedingSenderKey = Set(addresses)
        storageLock.withLock {
            guard let keyId = keyIdForSendingToThreadId(thread.threadUniqueId, writeTx: writeTx),
                  let keyMetadata = getKeyMetadata(for: keyId, readTx: writeTx) else {
                // No cached metadata. All recipients will need an SKDM
                return
            }

            // Iterate over each cached recipient. If no new devices or reregistrations have occurred since
            // we last recorded an SKDM send, we can skip sending to them.
            for (address, cachedRecipientState) in keyMetadata.keyRecipients {
                do {
                    // Only remove the recipient in question from our send targets if the cached state contains
                    // every device from the current state. Any new devices mean we need to re-send.
                    let currentRecipientState = try KeyRecipient.currentState(for: address, transaction: writeTx)
                    if cachedRecipientState.containsEveryDevice(from: currentRecipientState) {
                        addressesNeedingSenderKey.remove(address)
                    }
                } catch {
                    // It's likely there's no session for the current recipient. Maybe it was cleared?
                    // In this case, we just assume we need to send a new SKDM
                    if case SignalError.invalidState(_) = error {
                        Logger.warn("Invalid session state. Cannot build recipient state for \(address). \(error)")
                    } else {
                        owsFailDebug("Failed to fetch current recipient state for \(address): \(error)")
                    }
                }
            }
        }
        return Array(addressesNeedingSenderKey)
    }

    /// Records that the current sender key for the `thread` has been sent to `participant`
    @objc
    public func recordSenderKeySent(
        for thread: TSGroupThread,
        to address: SignalServiceAddress,
        writeTx: SDSAnyWriteTransaction) throws {
        try storageLock.withLock {
            guard let keyId = keyIdForSendingToThreadId(thread.threadUniqueId, writeTx: writeTx),
                  let existingMetadata = getKeyMetadata(for: keyId, readTx: writeTx) else {
                throw OWSAssertionError("Failed to look up key metadata")
            }
            var updatedMetadata = existingMetadata
            updatedMetadata.keyRecipients[address] = try KeyRecipient.currentState(for: address, transaction: writeTx)
            setMetadata(updatedMetadata, writeTx: writeTx)
        }
    }

    @objc
    public func resetSenderKeyDeliveryRecord(
        for thread: TSGroupThread,
        address: SignalServiceAddress,
        writeTx: SDSAnyWriteTransaction) {
        storageLock.withLock {
            guard let keyId = keyIdForSendingToThreadId(thread.threadUniqueId, writeTx: writeTx),
                  let existingMetadata = getKeyMetadata(for: keyId, readTx: writeTx) else {
                Logger.info("Failed to look up senderkey metadata")
                return
            }
            var updatedMetadata = existingMetadata
            updatedMetadata.keyRecipients[address] = nil
            setMetadata(updatedMetadata, writeTx: writeTx)
        }
    }

    public func expireSendingKeyIfNecessary(for thread: TSGroupThread, writeTx: SDSAnyWriteTransaction) {
        storageLock.withLock {
            guard let keyId = keyIdForSendingToThreadId(thread.threadUniqueId, writeTx: writeTx),
                  let keyMetadata = getKeyMetadata(for: keyId, readTx: writeTx) else { return }

            let currentKeyRecipients = Set(keyMetadata.keyRecipients.keys)
            let currentGroupMembership = thread.groupMembership.fullMembers
            let didSomeoneLeaveTheGroup = currentKeyRecipients.subtracting(currentGroupMembership).count > 0

            if !keyMetadata.isValid || didSomeoneLeaveTheGroup {
                setMetadata(nil, for: keyId, writeTx: writeTx)
            }
        }
    }

    @objc
    public func resetSenderKeySession(for thread: TSGroupThread, transaction writeTx: SDSAnyWriteTransaction) {
        storageLock.withLock {
            guard let keyId = keyIdForSendingToThreadId(thread.threadUniqueId, writeTx: writeTx) else { return }
            setMetadata(nil, for: keyId, writeTx: writeTx)
        }
    }

    @objc
    public func resetSenderKeyStore(transaction writeTx: SDSAnyWriteTransaction) {
        storageLock.withLock {
            sendingDistributionIdCache.clear()
            keyCache.clear()
            keyMetadataStore.removeAll(transaction: writeTx)
            sendingDistributionIdStore.removeAll(transaction: writeTx)
        }
    }

    @objc
    public func skdmBytesForGroupThread(_ groupThread: TSGroupThread, writeTx: SDSAnyWriteTransaction) -> Data? {
        do {
            guard let localAddress = ProtocolAddress.localAddress, localAddress.uuid != nil else {
                throw OWSAssertionError("No local address")
            }
            let distributionId = distributionIdForSendingToThread(groupThread, writeTx: writeTx)
            let skdm = try SenderKeyDistributionMessage(from: localAddress,
                                                        distributionId: distributionId,
                                                        store: self,
                                                        context: writeTx)
            return Data(skdm.serialize())
        } catch {
            owsFailDebug("Failed to construct sender key message: \(error)")
            return nil
        }
    }
}

// MARK: - <SignalClient.SenderKeyStore>

extension SenderKeyStore: SignalClient.SenderKeyStore {
    public func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        guard let addressUuid = sender.uuid else {
            throw OWSAssertionError("Invalid protocol address: must have UUID")
        }

        return try storageLock.withLock {
            let writeTx = context.asTransaction
            let keyId = Self.buildKeyId(addressUuid: addressUuid, distributionId: distributionId)

            var updatedValue: KeyMetadata
            if let existingMetadata = getKeyMetadata(for: keyId, readTx: writeTx) {
                updatedValue = existingMetadata
            } else {
                updatedValue = try KeyMetadata(record: record, sender: sender, distributionId: distributionId)
            }
            updatedValue.record = record
            setMetadata(updatedValue, writeTx: writeTx)
        }
    }

    public func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        guard let addressUuid = sender.uuid else {
            throw OWSAssertionError("Invalid protocol address: must have UUID")
        }

        return storageLock.withLock {
            let readTx = context.asTransaction
            let keyId = Self.buildKeyId(addressUuid: addressUuid, distributionId: distributionId)
            let metadata = getKeyMetadata(for: keyId, readTx: readTx)
            return metadata?.record
        }
    }
}

// MARK: - Storage

extension SenderKeyStore {
    private static let sendingDistributionIdStore = SDSKeyValueStore(collection: "SenderKeyStore_SendingDistributionId")
    private static let keyMetadataStore = SDSKeyValueStore(collection: "SenderKeyStore_KeyMetadata")
    private var sendingDistributionIdStore: SDSKeyValueStore { Self.sendingDistributionIdStore }
    private var keyMetadataStore: SDSKeyValueStore { Self.keyMetadataStore }

    fileprivate func getKeyMetadata(for keyId: KeyId, readTx: SDSAnyReadTransaction) -> KeyMetadata? {
        storageLock.assertOwner()
        return keyCache[keyId] ?? {
            let persisted: KeyMetadata?
            do {
                persisted = try keyMetadataStore.getCodableValue(forKey: keyId, transaction: readTx)
            } catch {
                owsFailDebug("Failed to deserialize sender key: \(error)")
                persisted = nil
            }
            keyCache[keyId] = persisted
            return persisted
        }()
    }

    fileprivate func setMetadata(_ metadata: KeyMetadata, writeTx: SDSAnyWriteTransaction) {
        setMetadata(metadata, for: metadata.keyId, writeTx: writeTx)
    }

    fileprivate func setMetadata(_ metadata: KeyMetadata?, for keyId: KeyId, writeTx: SDSAnyWriteTransaction) {
        storageLock.assertOwner()
        do {
            if let metadata = metadata {
                owsAssertDebug(metadata.keyId == keyId)
                try keyMetadataStore.setCodable(metadata, key: keyId, transaction: writeTx)
            } else {
                keyMetadataStore.removeValue(forKey: keyId, transaction: writeTx)
            }
            keyCache[keyId] = metadata
        } catch {
            owsFailDebug("Failed to persist sender key: \(error)")
        }
    }

    fileprivate func distributionIdForSendingToThreadId(_ threadId: ThreadUniqueId, writeTx: SDSAnyWriteTransaction) -> DistributionId {
        storageLock.assertOwner()

        if let cachedValue = sendingDistributionIdCache[threadId] {
            return cachedValue
        } else if let persistedString: String = sendingDistributionIdStore.getString(threadId, transaction: writeTx),
                  let persistedUUID = UUID(uuidString: persistedString) {
            sendingDistributionIdCache[threadId] = persistedUUID
            return persistedUUID
        } else {
            let distributionId = UUID()
            sendingDistributionIdStore.setString(distributionId.uuidString, key: threadId, transaction: writeTx)
            sendingDistributionIdCache[threadId] = distributionId
            return distributionId
        }
    }

    fileprivate func keyIdForSendingToThreadId(_ threadId: ThreadUniqueId, writeTx: SDSAnyWriteTransaction) -> KeyId? {
        guard let localUuid = tsAccountManager.localUuid else {
            owsFailDebug("No local uuid")
            return nil
        }
        let distributionId = distributionIdForSendingToThreadId(threadId, writeTx: writeTx)
        return Self.buildKeyId(addressUuid: localUuid, distributionId: distributionId)
    }

    // MARK: Migration

    static func performKeyIdMigration(transaction writeTx: SDSAnyWriteTransaction) {
        let oldKeys = keyMetadataStore.allKeys(transaction: writeTx)

        oldKeys.forEach { oldKey in
            autoreleasepool {
                do {
                    let existingValue: KeyMetadata? = try keyMetadataStore.getCodableValue(forKey: oldKey, transaction: writeTx)
                    if let existingValue = existingValue, existingValue.keyId != oldKey {
                        try keyMetadataStore.setCodable(existingValue, key: existingValue.keyId, transaction: writeTx)
                        keyMetadataStore.removeValue(forKey: oldKey, transaction: writeTx)
                    }
                } catch {
                    owsFailDebug("Failed to serialize key metadata: \(error)")
                    keyMetadataStore.removeValue(forKey: oldKey, transaction: writeTx)
                }
            }
        }
    }
}

// MARK: - Model
// MARK: KeyRecipient

/// Stores information about a recipient of a sender key
/// Helpful for diffing across deviceId and registrationId changes.
/// If a new device shows up, we need to make sure that we send a copy of our sender key to the address
private struct KeyRecipient: Codable, Dependencies {

    struct Device: Codable, Hashable {
        let deviceId: UInt32
        let registrationId: UInt32?

        init(deviceId: UInt32, registrationId: UInt32?) {
            self.deviceId = deviceId
            self.registrationId = registrationId
        }

        static func ==(lhs: Device, rhs: Device) -> Bool {
            // We can only be sure that a device hasn't changed if the registrationIds are the same
            // If either registrationId is nil, that means the Device was constructed before we had a session
            // established for the device.
            //
            // If we end up trying to send a SenderKey message to a device without a session, this ensures that
            // this ensures that we will always send an SKDM to that device. A session will be created in order to
            // send the SKDM, so by the time we're ready to mark success we should have something to store.
            guard lhs.registrationId != nil, rhs.registrationId != nil else { return false }
            return lhs.registrationId == rhs.registrationId && lhs.deviceId == rhs.deviceId
        }
    }

    let ownerAddress: SignalServiceAddress
    let devices: Set<Device>
    private init(ownerAddress: SignalServiceAddress, devices: Set<Device>) {
        self.ownerAddress = ownerAddress
        self.devices = devices
    }

    /// Build a KeyRecipient for the given address by fetching all of the devices and corresponding registrationIds
    static func currentState(for address: SignalServiceAddress, transaction: SDSAnyWriteTransaction) throws -> KeyRecipient {
        guard let recipient = SignalRecipient.get(address: address, mustHaveDevices: false, transaction: transaction),
              let deviceIds = recipient.devices.array as? [NSNumber] else {
            throw OWSAssertionError("Invalid device array")
        }

        let protocolAddresses = try deviceIds.map { try ProtocolAddress(from: address, deviceId: $0.uint32Value) }
        let devices: [Device] = try protocolAddresses.map {
            // We have to fetch the registrationId since deviceIds can be reused.
            // By comparing a set of (deviceId,registrationId) structs, we should be able to detect reused
            // deviceIds that will need an SKDM
            let registrationId = try Self.sessionStore.loadSession(for: $0, context: transaction)?.remoteRegistrationId()
            return Device(deviceId: $0.deviceId, registrationId: registrationId)
        }
        return KeyRecipient(ownerAddress: address, devices: Set(devices))
    }

    /// Returns `true` as long as the argument does not contain any devices that are unknown to the receiver
    func containsEveryDevice(from other: KeyRecipient) -> Bool {
        guard ownerAddress == other.ownerAddress else {
            owsFailDebug("Address mismatch")
            return false
        }

        let newDevices = other.devices.subtracting(self.devices)
        return newDevices.isEmpty
    }
}

// MARK: KeyMetadata

/// Stores information about a sender key, it's owner, it's distributionId, and all recipients who have been sent the sender key
private struct KeyMetadata {
    let distributionId: SenderKeyStore.DistributionId
    let ownerUuid: UUID
    let ownerDeviceId: UInt32
    var keyId: String { SenderKeyStore.buildKeyId(addressUuid: ownerUuid, distributionId: distributionId) }

    private var recordData: [UInt8]
    var record: SenderKeyRecord? {
        get {
            do {
                return try SenderKeyRecord(bytes: recordData)
            } catch {
                owsFailDebug("Failed to deserialize sender key record")
                return nil
            }
        }
        set {
            if let newValue = newValue {
                recordData = newValue.serialize()
            } else {
                owsFailDebug("Invalid new value")
                recordData = []
            }
        }
    }

    let creationDate: Date
    var keyRecipients: [SignalServiceAddress: KeyRecipient]
    var isForEncrypting: Bool

    init(record: SenderKeyRecord, sender: ProtocolAddress, distributionId: SenderKeyStore.DistributionId) throws {
        guard let uuid = sender.uuid else {
            throw OWSAssertionError("Invalid sender. Must have UUID")
        }

        self.recordData = record.serialize()
        self.distributionId = distributionId
        self.ownerUuid = uuid
        self.ownerDeviceId = sender.deviceId

        self.isForEncrypting = sender.isCurrentDevice
        self.creationDate = Date()
        self.keyRecipients = [:]
    }

    var isValid: Bool {
        // Keys we've received from others are always valid
        guard isForEncrypting else { return true }

        // If we're using it for encryption, it must be less than a month old
        let expirationDate = creationDate.addingTimeInterval(kMonthInterval)
        return (expirationDate.isAfterNow && isForEncrypting)
    }
}

extension KeyMetadata: Codable {
    enum CodingKeys: String, CodingKey {
        case distributionId
        case ownerUuid
        case ownerDeviceId
        case recordData

        case creationDate
        case keyRecipients
        case isForEncrypting
    }

    init(from decoder: Decoder) throws {
        let container   = try decoder.container(keyedBy: CodingKeys.self)

        distributionId  = try container.decode(SenderKeyStore.DistributionId.self, forKey: .distributionId)
        ownerUuid       = try container.decode(UUID.self, forKey: .ownerUuid)
        ownerDeviceId   = try container.decode(UInt32.self, forKey: .ownerDeviceId)
        recordData      = try container.decode([UInt8].self, forKey: .recordData)
        creationDate    = try container.decode(Date.self, forKey: .creationDate)
        isForEncrypting = try container.decode(Bool.self, forKey: .isForEncrypting)

        // KeyRecipients is a V2 key replacing a different type that stored the same info, so it may not exist.
        // A migration is overkill since these keys will expire after a month anyway. Resetting our keyRecipients
        // to an empty dict will just mean we resend an SKDM before it's necessary
        keyRecipients = try container.decodeIfPresent([SignalServiceAddress: KeyRecipient].self, forKey: .keyRecipients) ?? [:]
    }
}

// MARK: - Helper extensions

private typealias ThreadUniqueId = String
fileprivate extension TSGroupThread {
    var threadUniqueId: ThreadUniqueId { uniqueId }
}

extension ProtocolAddress {

    // TODO: Replace implementation for Swift 5.5 with throwable computed properties
    //    static var localAddress: ProtocolAddress {
    //        get throws {
    //            ...
    //            guard let address = address else { throw OWSAssertionError("No recipient address") }
    //            return try ProtocolAddress(from: address, deviceId: deviceId)
    @available(swift, obsoleted: 5.6, message: "Please swap out commented implementation in SenderKeyStore.swift")
    static var localAddress: ProtocolAddress? {
        get {
            let tsAccountManager = SSKEnvironment.shared.tsAccountManager
            let address = tsAccountManager.localAddress
            let deviceId = SSKEnvironment.shared.tsAccountManager.storedDeviceId()
            return try? address.map { try ProtocolAddress(from: $0, deviceId: deviceId) }
        }
    }

    convenience init(from recipientAddress: SignalServiceAddress, deviceId: UInt32) throws {
        if let uuid = recipientAddress.uuid {
            try self.init(uuid: uuid, deviceId: deviceId)
        } else {
            try self.init(name: recipientAddress.phoneNumber!, deviceId: deviceId)
        }
    }

    convenience init(uuid: UUID, deviceId: UInt32) throws {
        try self.init(name: uuid.uuidString, deviceId: deviceId)
    }

    var uuid: UUID? {
        UUID(uuidString: name)
    }

    var isCurrentDevice: Bool {
        let tsAccountManager = SSKEnvironment.shared.tsAccountManager
        return (uuid == tsAccountManager.localUuid) && (deviceId == tsAccountManager.storedDeviceId())
    }
}
