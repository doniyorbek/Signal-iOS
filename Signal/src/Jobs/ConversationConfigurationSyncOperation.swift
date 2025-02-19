//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
class ConversationConfigurationSyncOperation: OWSOperation {

    enum ColorSyncOperationError: Error, IsRetryableProvider {
        case assertionError(description: String)

        public var isRetryableProvider: Bool { false }
    }

    // MARK: -

    private let thread: TSThread

    @objc
    public init(thread: TSThread) {
        self.thread = thread
        super.init()
    }

    override public func run() {
        if let contactThread = thread as? TSContactThread {
            sync(contactThread: contactThread)
        } else if let groupThread = thread as? TSGroupThread {
            sync(groupThread: groupThread)
        } else {
            self.reportAssertionError(description: "unknown thread type")
        }
    }

    private func reportAssertionError(description: String) {
        let error = ColorSyncOperationError.assertionError(description: description)
        self.reportError(error)
    }

    private func sync(contactThread: TSContactThread) {
        guard let signalAccount: SignalAccount = self.contactsManagerImpl.fetchSignalAccount(for: contactThread.contactAddress) else {
            reportAssertionError(description: "unable to find signalAccount")
            return
        }

        firstly {
            syncManager.syncContacts(forSignalAccounts: [signalAccount])
        }.catch { error in
            Logger.warn("Error: \(error)")
        }
    }

    private func sync(groupThread: TSGroupThread) {
        // TODO sync only the affected group
        // The current implementation works, but seems wasteful.
        // Does desktop handle single group sync correctly?
        // What does Android do?
        guard let thread = TSAccountManager.getOrCreateLocalThreadWithSneakyTransaction() else {
            owsFailDebug("Missing thread.")
            return
        }
        let syncMessage = OWSSyncGroupsMessage(thread: thread)
        do {
            let attachmentDataSource: DataSource = try self.databaseStorage.read { transaction in
                guard let messageData: Data = syncMessage.buildPlainTextAttachmentData(with: transaction) else {
                    throw OWSAssertionError("could not serialize sync groups data")
                }
                return try DataSourcePath.dataSourceWritingSyncMessageData(messageData)
            }

            self.sendConfiguration(attachmentDataSource: attachmentDataSource, syncMessage: syncMessage)
        } catch {
            self.reportError(withUndefinedRetry: error)
            return
        }
    }

    private func sendConfiguration(attachmentDataSource: DataSource, syncMessage: OWSOutgoingSyncMessage) {
        self.messageSenderJobQueue.add(mediaMessage: syncMessage,
                                       dataSource: attachmentDataSource,
                                       contentType: OWSMimeTypeApplicationOctetStream,
                                       sourceFilename: nil,
                                       caption: nil,
                                       albumMessageId: nil,
                                       isTemporaryAttachment: true)
        self.reportSuccess()
    }
}
