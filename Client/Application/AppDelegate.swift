// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Shared
import Storage
import CoreSpotlight
import UIKit
import Common
import Glean

class AppDelegate: UIResponder, UIApplicationDelegate {
    let logger = DefaultLogger.shared
    var notificationCenter: NotificationProtocol = NotificationCenter.default
    var orientationLock = UIInterfaceOrientationMask.all

    private let creditCardAutofillStatus = FxNimbus.shared
        .features
        .creditCardAutofill
        .value()
        .creditCardAutofillStatus

    lazy var profile: Profile = BrowserProfile(
        localName: "profile",
        sendTabDelegate: UIApplication.shared.sendTabDelegate,
        creditCardAutofillEnabled: creditCardAutofillStatus
    )
    lazy var tabManager: TabManager = TabManagerImplementation(
        profile: profile,
        imageStore: DefaultDiskImageStore(
            files: profile.files,
            namespace: "TabManagerScreenshots",
            quality: UIConstants.ScreenshotQuality)
    )

    lazy var themeManager: ThemeManager = DefaultThemeManager(sharedContainerIdentifier: AppInfo.sharedContainerIdentifier)
    lazy var ratingPromptManager = RatingPromptManager(profile: profile)
    lazy var appSessionManager: AppSessionProvider = AppSessionManager()
    lazy var notificationSurfaceManager = NotificationSurfaceManager()

    private var shutdownWebServer: DispatchSourceTimer?
    private var webServerUtil: WebServerUtil?
    private var appLaunchUtil: AppLaunchUtil?
    private var backgroundWorkUtility: BackgroundFetchAndProcessingUtility?
    private var widgetManager: TopSitesWidgetManager?
    private var menuBuilderHelper: MenuBuilderHelper?
    private var metricKitWrapper = MetricKitWrapper()

    /// Tracking active status of the application.
    private var isActive = false

    /// Handle the `willEnterForegroundNotification` the same way Glean handles it.
    func handleForegroundEvent() {
        if !isActive {
            GleanMetrics.Pings.shared.tempBaseline.submit(reason: .active)
            GleanMetrics.BaselineValidation.startupDuration.start()
            GleanMetrics.BaselineValidation.baselineDuration.start()
            NSUserDefaultsPrefs(prefix: "profile").setBool(true, forKey: AppConstants.prefGleanTempDirtyFlag)

            isActive = true
        }
    }

    /// Handle the `didBecomeActiveNotification` the way Glean would handle it
    func handleVisibleEvent() {
        GleanMetrics.BaselineValidation.startupDuration.stop()
        GleanMetrics.Pings.shared.tempBaseline.submit(reason: .foreground)
        GleanMetrics.BaselineValidation.visibleDuration.start()
    }

    /// Handle the `didEnterBackgroundNotification` the same way Glean handles it.
    func handleBackgroundEvent() {
        if isActive {
            GleanMetrics.BaselineValidation.baselineDuration.stop()
            GleanMetrics.BaselineValidation.visibleDuration.stop()
            GleanMetrics.Pings.shared.tempBaseline.submit(reason: .inactive)
            NSUserDefaultsPrefs(prefix: "profile").setBool(false, forKey: AppConstants.prefGleanTempDirtyFlag)

            isActive = false
        }
    }

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Configure app information for BrowserKit, needed for logger
        BrowserKitInformation.shared.configure(buildChannel: AppConstants.buildChannel,
                                               nightlyAppVersion: AppConstants.nightlyAppVersion,
                                               sharedContainerIdentifier: AppInfo.sharedContainerIdentifier)

        // Configure logger so we can start tracking logs early
        logger.configure(crashManager: DefaultCrashManager())
        initializeRustErrors(logger: logger)
        logger.log("willFinishLaunchingWithOptions begin",
                   level: .info,
                   category: .lifecycle)

        // Then setup dependency container as it's needed for everything else
        DependencyHelper().bootstrapDependencies()

        appLaunchUtil = AppLaunchUtil(profile: profile)
        appLaunchUtil?.setUpPreLaunchDependencies()

        // Handle the dirty bit the same way Glean handles it
        // and submit the right ping.
        let prefs = NSUserDefaultsPrefs(prefix: "profile")
        let dirtyFlag = prefs.boolForKey(AppConstants.prefGleanTempDirtyFlag) ?? false
        prefs.setBool(true, forKey: AppConstants.prefGleanTempDirtyFlag)
        if dirtyFlag {
            GleanMetrics.Pings.shared.tempBaseline.submit(reason: .dirtyStartup)
        }

        // Glean does this as part of the LifecycleObserver too.
        // `isActive` tracks active status to avoid double-triggers.
        handleForegroundEvent()

        // Set up a web server that serves us static content. Do this early so that it is ready when the UI is presented.
        webServerUtil = WebServerUtil(profile: profile)
        webServerUtil?.setUpWebServer()

        menuBuilderHelper = MenuBuilderHelper()

        logger.log("willFinishLaunchingWithOptions end",
                   level: .info,
                   category: .lifecycle)

        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        logger.log("didFinishLaunchingWithOptions start",
                   level: .info,
                   category: .lifecycle)

        pushNotificationSetup()
        appLaunchUtil?.setUpPostLaunchDependencies()
        backgroundWorkUtility = BackgroundFetchAndProcessingUtility()
        backgroundWorkUtility?.registerUtility(BackgroundSyncUtility(profile: profile, application: application))
        backgroundWorkUtility?.registerUtility(BackgroundNotificationSurfaceUtility())
        if let firefoxSuggest = profile.firefoxSuggest {
            backgroundWorkUtility?.registerUtility(BackgroundFirefoxSuggestIngestUtility(
                firefoxSuggest: firefoxSuggest
            ))
        }

        let topSitesProvider = TopSitesProviderImplementation(
            placesFetcher: profile.places,
            pinnedSiteFetcher: profile.pinnedSites,
            prefs: profile.prefs
        )

        widgetManager = TopSitesWidgetManager(topSitesProvider: topSitesProvider)

        addObservers()

        logger.log("didFinishLaunchingWithOptions end",
                   level: .info,
                   category: .lifecycle)

        return true
    }

    // We sync in the foreground only, to avoid the possibility of runaway resource usage.
    // Eventually we'll sync in response to notifications.
    func applicationDidBecomeActive(_ application: UIApplication) {
        logger.log("applicationDidBecomeActive start",
                   level: .info,
                   category: .lifecycle)

        shutdownWebServer?.cancel()
        shutdownWebServer = nil

        profile.reopen()

        if profile.prefs.boolForKey(PendingAccountDisconnectedKey) ?? false {
            profile.removeAccount()
        }

        profile.syncManager.applicationDidBecomeActive()
        webServerUtil?.setUpWebServer()

        handleVisibleEvent()
        TelemetryWrapper.recordEvent(category: .action, method: .foreground, object: .app)

        // update top sites widget
        updateTopSitesWidget()

        // Cleanup can be a heavy operation, take it out of the startup path. Instead check after a few seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            // TODO: testing to see if this fixes https://mozilla-hub.atlassian.net/browse/FXIOS-7632
            // self?.profile.cleanupHistoryIfNeeded()
            self?.ratingPromptManager.updateData()
        }

        DispatchQueue.global().async { [weak self] in
            self?.profile.pollCommands(forcePoll: false)
        }

        logger.log("applicationDidBecomeActive end",
                   level: .info,
                   category: .lifecycle)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        updateTopSitesWidget()

        UserDefaults.standard.setValue(Date(), forKey: "LastActiveTimestamp")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        logger.log("applicationDidEnterBackground start",
                   level: .info,
                   category: .lifecycle)

        handleBackgroundEvent()
        TelemetryWrapper.recordEvent(category: .action, method: .background, object: .app)
        TabsQuantityTelemetry.trackTabsQuantity(tabManager: tabManager)

        profile.syncManager.applicationDidEnterBackground()

        let singleShotTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        // 2 seconds is ample for a localhost request to be completed by GCDWebServer. <500ms is expected on newer devices.
        singleShotTimer.schedule(deadline: .now() + 2.0, repeating: .never)
        singleShotTimer.setEventHandler {
            WebServer.sharedInstance.server.stop()
            self.shutdownWebServer = nil
        }
        singleShotTimer.resume()
        shutdownWebServer = singleShotTimer
        backgroundWorkUtility?.scheduleOnAppBackground()
        tabManager.preserveTabs()

        logger.log("applicationDidEnterBackground end",
                   level: .info,
                   category: .lifecycle)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        handleForegroundEvent()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // We have only five seconds here, so let's hope this doesn't take too long.
        profile.shutdown()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        logger.log("Received memory warning", level: .info, category: .lifecycle)
    }

    private func updateTopSitesWidget() {
        // Since we only need the topSites data in the archiver, let's write it
        widgetManager?.writeWidgetKitTopSites()
    }
}

extension AppDelegate: Notifiable {
    private func addObservers() {
        setupNotifications(forObserver: self, observing: [UIApplication.didBecomeActiveNotification,
                                                          UIApplication.willResignActiveNotification,
                                                          UIApplication.didEnterBackgroundNotification,
                                                          UIApplication.willEnterForegroundNotification])
    }

    /// When migrated to Scenes, these methods aren't called. Consider this a temporary solution to calling into those methods.
    func handleNotifications(_ notification: Notification) {
        switch notification.name {
        case UIApplication.didBecomeActiveNotification:
            applicationDidBecomeActive(UIApplication.shared)
        case UIApplication.willResignActiveNotification:
            applicationWillResignActive(UIApplication.shared)
        case UIApplication.didEnterBackgroundNotification:
            applicationDidEnterBackground(UIApplication.shared)
        case UIApplication.willEnterForegroundNotification:
            applicationWillEnterForeground(UIApplication.shared)

        default: break
        }
    }
}

// This functionality will need to be moved to the SceneDelegate when the time comes
extension AppDelegate {
    // Orientation lock for views that use new modal presenter
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return self.orientationLock
    }
}

// MARK: - Key Commands

extension AppDelegate {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard builder.system == .main else { return }

        menuBuilderHelper?.mainMenu(for: builder)
    }
}

// MARK: - Scenes related methods
extension AppDelegate {
    /// UIKit is responsible for creating & vending Scene instances. This method is especially useful when there
    /// are multiple scene configurations to choose from.  With this method, we can select a configuration
    /// to create a new scene with dynamically (outside of what's in the pList).
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )

        configuration.sceneClass = connectingSceneSession.configuration.sceneClass
        configuration.delegateClass = connectingSceneSession.configuration.delegateClass

        return configuration
    }
}
