//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PushKit
import SignalServiceKit
import SignalMessaging

public enum PushRegistrationError: Error {
    case assertionError(description: String)
    case pushNotSupported(description: String)
    case timeout
}

/**
 * Singleton used to integrate with push notification services - registration and routing received remote notifications.
 */
@objc public class PushRegistrationManager: NSObject, PKPushRegistryDelegate {

    override init() {
        super.init()

        SwiftSingletons.register(self)
    }

    private var vanillaTokenPromise: Promise<Data>?
    private var vanillaTokenFuture: Future<Data>?

    private var voipRegistry: PKPushRegistry?
    private var voipTokenPromise: Promise<Data?>?
    private var voipTokenFuture: Future<Data?>?

    public var preauthChallengeFuture: Future<String>?

    // MARK: Public interface

    public func requestPushTokens() -> Promise<(pushToken: String, voipToken: String?)> {
        Logger.info("")

        return firstly { () -> Promise<Void> in
            return self.registerUserNotificationSettings()
        }.then { (_) -> Promise<(pushToken: String, voipToken: String?)> in
            guard !Platform.isSimulator else {
                throw PushRegistrationError.pushNotSupported(description: "Push not supported on simulators")
            }

            return self.registerForVanillaPushToken().then { vanillaPushToken -> Promise<(pushToken: String, voipToken: String?)> in
                self.registerForVoipPushToken().map { voipPushToken in
                    (pushToken: vanillaPushToken, voipToken: voipPushToken)
                }
            }
        }
    }

    // MARK: Vanilla push token

    @objc
    public func didReceiveVanillaPreAuthChallengeToken(_ challenge: String) {
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            AssertIsOnMainThread()
            if let preauthChallengeFuture = self.preauthChallengeFuture {
                Logger.info("received vanilla preauth challenge")
                preauthChallengeFuture.resolve(challenge)
                self.preauthChallengeFuture = nil
            }
        }
    }

    // Vanilla push token is obtained from the system via AppDelegate
    @objc
    public func didReceiveVanillaPushToken(_ tokenData: Data) {
        guard let vanillaTokenFuture = self.vanillaTokenFuture else {
            owsFailDebug("promise completion in \(#function) unexpectedly nil")
            return
        }

        vanillaTokenFuture.resolve(tokenData)
    }

    // Vanilla push token is obtained from the system via AppDelegate    
    @objc
    public func didFailToReceiveVanillaPushToken(error: Error) {
        guard let vanillaTokenFuture = self.vanillaTokenFuture else {
            owsFailDebug("promise completion in \(#function) unexpectedly nil")
            return
        }

        vanillaTokenFuture.reject(error)
    }

    // MARK: PKPushRegistryDelegate - voIP Push Token

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        Logger.info("")
        owsAssertDebug(type == .voIP)
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            AssertIsOnMainThread()
            if CallMessageRelay.handleVoipPayload(payload.dictionaryPayload) {
                // Do nothing. This was a call message relayed from the NSE
                Logger.info("Handled call message from NSE.")
            } else if let preauthChallengeFuture = self.preauthChallengeFuture,
                let challenge = payload.dictionaryPayload["challenge"] as? String {
                Logger.info("received preauth challenge")
                preauthChallengeFuture.resolve(challenge)
                self.preauthChallengeFuture = nil
            } else {
                owsAssertDebug(!FeatureFlags.notificationServiceExtension)
                Logger.info("Fetching messages.")
                var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "Push fetch.")
                firstly { () -> Promise<Void> in
                    self.messageFetcherJob.run().promise
                }.done(on: .main) {
                    owsAssertDebug(backgroundTask != nil)
                    backgroundTask = nil
                }.catch { error in
                    owsFailDebug("Error: \(error)")
                }
            }
        }
    }

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        Logger.info("")
        owsAssertDebug(type == .voIP)
        owsAssertDebug(credentials.type == .voIP)
        guard let voipTokenFuture = self.voipTokenFuture else { return }

        voipTokenFuture.resolve(credentials.token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // It's not clear when this would happen. We've never previously handled it, but we should at
        // least start learning if it happens.
        owsFailDebug("Invalid state")
    }

    // MARK: helpers

    // User notification settings must be registered *before* AppDelegate will
    // return any requested push tokens.
    public func registerUserNotificationSettings() -> Promise<Void> {
        Logger.info("registering user notification settings")

        return notificationPresenter.registerNotificationSettings()
    }

    /**
     * When users have disabled notifications and background fetch, the system hangs when returning a push token.
     * More specifically, after registering for remote notification, the app delegate calls neither
     * `didFailToRegisterForRemoteNotificationsWithError` nor `didRegisterForRemoteNotificationsWithDeviceToken`
     * This behavior is identical to what you'd see if we hadn't previously registered for user notification settings, though
     * in this case we've verified that we *have* properly registered notification settings.
     */
    private var isSusceptibleToFailedPushRegistration: Bool {

        // Only affects users who have disabled both: background refresh *and* notifications
        guard UIApplication.shared.backgroundRefreshStatus == .denied else {
            Logger.info("has backgroundRefreshStatus != .denied, not susceptible to push registration failure")
            return false
        }

        guard let notificationSettings = UIApplication.shared.currentUserNotificationSettings else {
            owsFailDebug("notificationSettings was unexpectedly nil.")
            return false
        }

        guard notificationSettings.types == [] else {
            Logger.info("notificationSettings was not empty, not susceptible to push registration failure.")
            return false
        }

        Logger.info("background refresh and notifications were disabled. Device is susceptible to push registration failure.")
        return true
    }

    private func registerForVanillaPushToken() -> Promise<String> {
        AssertIsOnMainThread()
        Logger.info("")

        guard self.vanillaTokenPromise == nil else {
            let promise = vanillaTokenPromise!
            owsAssertDebug(!promise.isSealed)
            Logger.info("alreay pending promise for vanilla push token")
            return promise.map { $0.hexEncodedString }
        }

        // No pending vanilla token yet. Create a new promise
        let (promise, future) = Promise<Data>.pending()
        self.vanillaTokenPromise = promise
        self.vanillaTokenFuture = future

        UIApplication.shared.registerForRemoteNotifications()

        return firstly {
            promise.timeout(seconds: 10, description: "Register for vanilla push token") {
                PushRegistrationError.timeout
            }
        }.recover { error -> Promise<Data> in
            switch error {
            case PushRegistrationError.timeout:
                if self.isSusceptibleToFailedPushRegistration {
                    // If we've timed out on a device known to be susceptible to failures, quit trying
                    // so the user doesn't remain indefinitely hung for no good reason.
                    throw PushRegistrationError.pushNotSupported(description: "Device configuration disallows push notifications")
                } else {
                    Logger.info("Push registration is taking a while. Continuing to wait since this configuration is not known to fail push registration.")
                    // Sometimes registration can just take a while.
                    // If we're not on a device known to be susceptible to push registration failure,
                    // just return the original promise.
                    return promise
                }
            default:
                throw error
            }
        }.map { (pushTokenData: Data) -> String in
            if self.isSusceptibleToFailedPushRegistration {
                // Sentinal in case this bug is fixed.
                owsFailDebug("Device was unexpectedly able to complete push registration even though it was susceptible to failure.")
            }

            Logger.info("successfully registered for vanilla push notifications")
            return pushTokenData.hexEncodedString
        }.ensure {
            self.vanillaTokenPromise = nil
        }
    }

    private func createVoipRegistryIfNecessary() {
        AssertIsOnMainThread()

        guard voipRegistry == nil else { return }
        let voipRegistry = PKPushRegistry(queue: nil)
        self.voipRegistry  = voipRegistry
        voipRegistry.desiredPushTypes = [.voIP]
        voipRegistry.delegate = self
    }

    private func registerForVoipPushToken() -> Promise<String?> {
        AssertIsOnMainThread()
        Logger.info("")

        // We never populate voip tokens with the service when
        // using the notification service extension.
        guard !FeatureFlags.notificationServiceExtension else {
            Logger.info("Not using VOIP token because NSE is enabled.")
            // We still must create the voip registry to handle voip
            // pushes relayed from the NSE.
            createVoipRegistryIfNecessary()
            return Promise.value(nil)
        }

        guard self.voipTokenPromise == nil else {
            let promise = self.voipTokenPromise!
            owsAssertDebug(!promise.isSealed)
            return promise.map { $0?.hexEncodedString }
        }

        // No pending voip token yet. Create a new promise
        let (promise, future) = Promise<Data?>.pending()
        self.voipTokenPromise = promise
        self.voipTokenFuture = future

        // We don't create the voip registry in init, because it immediately requests the voip token,
        // potentially before we're ready to handle it.
        createVoipRegistryIfNecessary()

        guard let voipRegistry = self.voipRegistry else {
            owsFailDebug("failed to initialize voipRegistry")
            future.reject(PushRegistrationError.assertionError(description: "failed to initialize voipRegistry"))
            return promise.map { _ in
                // coerce expected type of returned promise - we don't really care about the value,
                // since this promise has been rejected. In practice this shouldn't happen
                String()
            }
        }

        // If we've already completed registering for a voip token, resolve it immediately,
        // rather than waiting for the delegate method to be called.
        if let voipTokenData = voipRegistry.pushToken(for: .voIP) {
            Logger.info("using pre-registered voIP token")
            future.resolve(voipTokenData)
        }

        return promise.map { (voipTokenData: Data?) -> String? in
            Logger.info("successfully registered for voip push notifications")
            return voipTokenData?.hexEncodedString
        }.ensure {
            self.voipTokenPromise = nil
        }
    }
}

// We transmit pushToken data as hex encoded string to the server
fileprivate extension Data {
    var hexEncodedString: String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
