//
//  PushNotificationManager.swift
//  ExponeaSDK
//
//  Created by Dominik Hadl on 25/05/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation
import UserNotifications

public protocol PushNotificationManagerType: class {
    var delegate: PushNotificationManagerDelegate? { get set }
}

public protocol PushNotificationManagerDelegate: class {
    func pushNotificationOpened(with action: ExponeaNotificationAction, value: String?, extraData: [AnyHashable: Any]?)
}

class PushNotificationManager: NSObject, PushNotificationManagerType {
    /// The tracking manager used to track push events
    internal weak var trackingManager: TrackingManagerType?
    
    private let center = UNUserNotificationCenter.current()
    private var receiver: PushNotificationReceiver?
    private var observer: PushNotificationDelegateObserver?
    internal weak var delegate: PushNotificationManagerDelegate?
    
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    
    init(trackingManager: TrackingManagerType) {
        self.trackingManager = trackingManager
        super.init()
        
        addAutomaticPushTracking()
    }
    
    deinit {
        removeAutomaticPushTracking()
    }
    
    // MARK: - Actions -
    
    func handlePushOpened(userInfoObject: AnyObject?, actionIdentifier: String) {
        guard let userInfo = userInfoObject as? [String: Any] else {
            Exponea.logger.log(.error, message: "Failed to convert push payload.")
            return
        }
        
        guard let data = userInfo["data"] as? [String: Any] else {
            Exponea.logger.log(.error, message: "Failed to convert push payload data.")
            return
        }
        
        var properties: [String: JSONValue] = [:]
        let attributes = userInfo["attributes"] as? [String: Any]

        // If attributes is present, then campaign tracking info is nested in there, decode and process it
        if let attributes = attributes,
            let data = try? JSONSerialization.data(withJSONObject: attributes, options: []),
            let model = try? decoder.decode(ExponeaNotificationData.self, from: data) {
            properties = model.properties
        } else if let data = try? JSONSerialization.data(withJSONObject: data, options: []),
            let model = try? decoder.decode(ExponeaNotificationData.self, from: data) {
            properties = model.properties
        }
        
        properties["action_type"] = .string("notification")
        properties["status"] = .string("clicked")
        
        // Fetch action and any extra attributes
        var actionValue: String? = nil
        
        // Format of action id should look like - EXPONEA_APP_OPEN_ACTION_0
        // We need to get the right index and fetch the correct action url from payload, if any
        var components = actionIdentifier.components(separatedBy: "_")
        if components.count > 1, let index = Int(components.last!),
            let actions = userInfo["actions"] as? [[String: String]], actions.count > index {
            let actionDict = actions[index]
            actionValue = actionDict["url"]
            _ = components.popLast()
        }
        
        do {
            try trackingManager?.track(.pushOpened, with: [.properties(properties)])
        } catch {
            Exponea.logger.log(.error, message: "Error tracking push opened. \(error.localizedDescription)")
        }

        let action = ExponeaNotificationAction(rawValue: components.joined(separator: "_")) ?? .none
        
        switch action {
        case .openApp, .none:
            // do nothing as the action will open the app by default
            break
        case .browser, .deeplink:
            if let value = actionValue, let url = URL(string: value) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        
        // Notify the delegate
        delegate?.pushNotificationOpened(with: action, value: actionValue, extraData: attributes)
    }
    
    func handlePushTokenRegistered(dataObject: AnyObject?) {
        guard let tokenData = dataObject as? Data else {
            return
        }
        
        do {
            let data = [DataType.pushNotificationToken(tokenData.tokenString)]
            try trackingManager?.track(.registerPushToken, with: data)
        } catch {
            Exponea.logger.log(.error, message: "Error logging push token. \(error.localizedDescription)")
        }
    }
}

// MARK: - Swizzling -

extension PushNotificationManager {
    
    private func addAutomaticPushTracking() {
        swizzleTokenRegistrationTracking()
        swizzleNotificationReceived()
    }
    
    internal func removeAutomaticPushTracking() {
        observer = nil
        
        for swizzle in Swizzler.swizzles {
            Swizzler.unswizzle(swizzle.value)
        }
    }
    
    /// This functions swizzles the token registration method to intercept the token and submit it to Exponea.
    private func swizzleTokenRegistrationTracking() {
        guard let appDelegate = UIApplication.shared.delegate else {
            return
        }
        
        // Monitor push registration
        Swizzler.swizzleSelector(PushSelectorMapping.registration.original,
                                 with: PushSelectorMapping.registration.swizzled,
                                 for: type(of: appDelegate),
                                 name: "PushTokenRegistration",
                                 block: { [weak self] (_, dataObject, _) in
                                    self?.handlePushTokenRegistered(dataObject: dataObject) },
                                 addingMethodIfNecessary: true)
    }
    
    /// Swizzles the appropriate 'notification received' method to interecept received notifications and then calls
    /// the `handlePushOpened` function with the payload so that the event can be tracked to Exponea.
    ///
    /// This method works in the following way:
    ///
    /// 1. It **always** observes changes to `UNUserNotificationCenter`'s `delegate` property and on changes
    /// it calls `notificationsDelegateChanged(_:)`.
    /// 2. Checks if we there is already an existing `UNUserNotificationCenter` delegate,
    /// if so, calls `swizzleUserNotificationsDidReceive(on:)` and exits.
    /// 3. If step 2. fails, it continues to check if the host AppDelegate implements either one of the supported
    /// didReceiveNotification methods. If so, swizzles the one that's implemented while preferring the variant
    /// with fetch handler as that is what Apple recommends.
    /// 4. If step 3 fails, it creates a dummy object `PushNotificationReceiver` that implements the
    /// `UNUserNotificationCenterDelegate` protocol, sets it as the delegate for `UNUserNotificationCenter` and lastly
    /// swizzles the implementation with the custom one.
    private func swizzleNotificationReceived() {
        guard let appDelegate = UIApplication.shared.delegate else {
            Exponea.logger.log(.error, message: "Critical error, no app delegate class available.")
            return
        }
        
        let appDelegateClass: AnyClass = type(of: appDelegate)
        var swizzleMapping: PushSelectorMapping.Mapping?
        
        // Add observer
        observer = PushNotificationDelegateObserver(center: center, callback: notificationsDelegateChanged)
        
        // Check for UNUserNotification's delegate did receive remote notification, if it is setup
        // prefer using that over the UIAppDelegate functions.
        if let delegate = center.delegate {
            swizzleUserNotificationsDidReceive(on: type(of: delegate))
            return
        }

        // Check if UIAppDelegate notification receive functions are implemented
        if class_getInstanceMethod(appDelegateClass, PushSelectorMapping.handlerReceive.original) != nil {
            // Check for UIAppDelegate's did receive remote notification with fetch completion handler (preferred)
            swizzleMapping = PushSelectorMapping.handlerReceive
        } else if class_getInstanceMethod(appDelegateClass, PushSelectorMapping.deprecatedReceive.original) != nil {
            // Check for UIAppDelegate's deprecated receive remote notification
            swizzleMapping = PushSelectorMapping.deprecatedReceive
        }
        
        // If user is overriding either of UIAppDelegete receive functions, swizzle it
        if let mapping = swizzleMapping {
            // Do the swizzling
            Swizzler.swizzleSelector(mapping.original,
                                     with: mapping.swizzled,
                                     for: appDelegateClass,
                                     name: "NotificationOpened",
                                     block: { [weak self] (_, userInfoObject, _) in
                                        self?.handlePushOpened(userInfoObject: userInfoObject, actionIdentifier: "") },
                                     addingMethodIfNecessary: true)
        } else {
            // The user is not overriding any UIAppDelegate receive functions nor is using UNUserNotificationCenter.
            // Because we don't have a delegate for UNUserNotifications, let's make a dummy one and set it
            // as the delegate, until the user creates their own delegate (handled by observing .
            receiver = PushNotificationReceiver()
            center.delegate = receiver
        }
    }
    
    /// Removes all swizzles related to notification opened,
    /// useful when `UNUserNotificationCenter` delegate has changed.
    private func unswizzleAllNotificationReceived() {
        for swizzle in Swizzler.swizzles {
            if swizzle.value.name == "NotificationOpened" {
                Exponea.logger.log(.verbose, message: "Removing swizzle: \(swizzle.value)")
                Swizzler.unswizzle(swizzle.value)
            }
        }
    }
    
    /// Monitor changes in the `UNUserNotificationCenter` delegate.
    ///
    /// - Parameter change: The KVO change object containing the old and new values.
    private func notificationsDelegateChanged(_ change: NSKeyValueObservedChange<UNUserNotificationCenterDelegate?>) {
        // Make sure we unswizzle all notficiation receive methods, before making changes
        unswizzleAllNotificationReceived()
        
        switch (change.oldValue, change.newValue) {
        case (let old??, let new??) where old is PushNotificationReceiver && !(new is PushNotificationReceiver):
            // User reassigned the dummy receiver to a new delegate, so swizzle it
            self.receiver = nil
            swizzleUserNotificationsDidReceive(on: type(of: new))
            
        case (let old??, let new) where !(old is PushNotificationReceiver) && new == nil:
            // Reassigning from custom delegate to nil, so create our dummy receiver instead
            self.receiver = PushNotificationReceiver()
            center.delegate = self.receiver
            
        case (let old, let new??) where old == nil:
            // We were subscribed to app delegate functions before, but now we have a delegate, so swizzle it.
            // Also handles our custom PushNotificationReceiver and swizzles that.
            swizzleUserNotificationsDidReceive(on: type(of: new))
            
        default:
            Exponea.logger.log(.error, message: """
            Unhandled UNUserNotificationCenterDelegate change, automatic push notification tracking disabled.
            """)
            break
        }
    }
    
    private func swizzleUserNotificationsDidReceive(on delegateClass: AnyClass) {
        // Swizzle the notification delegate notification received function
        Swizzler.swizzleSelector(PushSelectorMapping.newReceive.original,
                                 with: PushSelectorMapping.newReceive.swizzled,
                                 for: delegateClass,
                                 name: "NotificationOpened",
                                 block: { [weak self] (_, userInfoObject, actionIdentifier) in
                                    self?.handlePushOpened(userInfoObject: userInfoObject,
                                                           actionIdentifier: actionIdentifier as? String ?? "")
                                 },
                                 addingMethodIfNecessary: true)
    }
}


