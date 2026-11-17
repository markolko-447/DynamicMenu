//
//  NowPlayingBridge.m
//  DynamicMenu
//
//  Reads the system-wide Now Playing state (any app, including browsers) from the
//  private MediaRemote framework and controls playback through it.
//
//  Since macOS 15.4 MediaRemote only answers Apple-signed processes, so this code
//  cannot run inside DynamicMenu itself. It is built as a small library that the
//  app loads into /usr/bin/perl (Apple-signed) and talks to over pipes:
//
//    stdout: one JSON object per line, each time a media session changes.
//            The system's current session has no "background" key; sessions of
//            other apps that played earlier carry "background": true.
//    stdin:  one command per line: toggle | play | pause | next | previous |
//            seek <seconds>, optionally followed by " @<bundle id>" to address a
//            background session instead of the current one.
//
//  It exits when stdin closes, so it never outlives the app.
//  Build with Helper/build.sh.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(uint32_t, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void *(*MRGetOriginFn)(void);

enum { MRPlay = 0, MRPause = 1, MRTogglePlayPause = 2, MRNextTrack = 4, MRPreviousTrack = 5 };

static CFBundleRef mediaRemote;
/// Last artwork sent, per app, so artwork goes out once per track.
static NSMutableDictionary<NSString *, NSString *> *lastArtworkKeys;
/// Every app seen as the system's current session, kept so it can still be
/// queried and controlled after another app takes over.
static NSMutableDictionary<NSString *, id> *knownClients;
static NSString *currentApp;

static void *symbol(NSString *name) {
    return CFBundleGetFunctionPointerForName(mediaRemote, (__bridge CFStringRef)name);
}

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// The app a session belongs to. A browser plays through a helper process; the
/// parent is the app the user knows.
static NSString *appOf(id client) {
    if (!client) return nil;
    MRClientStringFn parentBundleID = symbol(@"MRNowPlayingClientGetParentAppBundleIdentifier");
    MRClientStringFn bundleID = symbol(@"MRNowPlayingClientGetBundleIdentifier");
    NSString *app = parentBundleID ? (__bridge NSString *)parentBundleID(client) : nil;
    if (app.length == 0 && bundleID) app = (__bridge NSString *)bundleID(client);
    return app.length > 0 ? app : nil;
}

/// One output line from a Now Playing info dictionary.
static NSMutableDictionary *describe(NSDictionary *info, BOOL isPlaying, NSString *app) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"playing"] = isPlaying ? @YES : @NO;
    out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
    out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
    out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
    out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
    out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSDate class]]) {
        out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
    }
    if (app) out[@"app"] = app;
    out[@"track"] = [NSString stringWithFormat:@"%@|%@|%@", app ?: @"", out[@"title"], out[@"artist"]];

    // Artwork is large, so send it once per track rather than on every update.
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    NSString *key = app ?: @"";
    NSString *artworkKey = [NSString stringWithFormat:@"%@|%lu", out[@"track"], (unsigned long)artwork.length];
    if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0
        && ![artworkKey isEqualToString:lastArtworkKeys[key]]) {
        lastArtworkKeys[key] = artworkKey;
        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
    }
    return out;
}

/// A request object that talks to one app's player, whether or not it is the
/// system's current session. Built from MediaRemote's own classes, so the calls
/// below are ordinary Objective-C messages.
static id playerPathFor(id client) {
    MRGetOriginFn localOrigin = symbol(@"MRMediaRemoteGetLocalOrigin");
    Class pathClass = objc_getClass("MRPlayerPath");
    SEL initPath = sel_getUid("initWithOrigin:client:player:");
    if (!client || !localOrigin || ![pathClass instancesRespondToSelector:initPath]) return nil;
    id (*makePath)(id, SEL, id, id, id) = (void *)objc_msgSend;
    return makePath([pathClass alloc], initPath, (__bridge id)localOrigin(), client, nil);
}

static id requestFor(id client) {
    Class requestClass = objc_getClass("MRNowPlayingRequest");
    SEL initRequest = sel_getUid("initWithPlayerPath:");
    id path = playerPathFor(client);
    if (!path || ![requestClass instancesRespondToSelector:initRequest]) return nil;
    id (*makeRequest)(id, SEL, id) = (void *)objc_msgSend;
    return makeRequest([requestClass alloc], initRequest, path);
}

/// Reports every remembered app other than the current one. A session the system
/// no longer knows comes back without a title; that tells the app it ended.
static void publishBackground(void) {
    SEL askInfo = sel_getUid("requestNowPlayingInfoOnQueue:completion:");
    SEL askPlaying = sel_getUid("requestIsPlayingOnQueue:completion:");
    void (*askForInfo)(id, SEL, dispatch_queue_t, void (^)(id, id)) = (void *)objc_msgSend;
    // The play state arrives as a plain integer (0 or 1), not an object.
    void (*askForPlaying)(id, SEL, dispatch_queue_t, void (^)(uintptr_t, id)) = (void *)objc_msgSend;

    dispatch_queue_t queue = dispatch_get_main_queue();
    for (NSString *app in knownClients.allKeys) {
        if ([app isEqualToString:currentApp]) continue;
        id request = requestFor(knownClients[app]);
        if (![request respondsToSelector:askInfo] || ![request respondsToSelector:askPlaying]) continue;

        askForInfo(request, askInfo, queue, ^(id rawInfo, id error) {
            NSDictionary *info = [rawInfo isKindOfClass:[NSDictionary class]] ? rawInfo : @{};
            askForPlaying(request, askPlaying, queue, ^(uintptr_t isPlaying, id error2) {
                // It may have become the current session meanwhile.
                if ([app isEqualToString:currentApp]) return;
                NSMutableDictionary *out = describe(info, isPlaying == 1, app);
                out[@"background"] = @YES;
                if ([out[@"title"] length] == 0) [knownClients removeObjectForKey:app];
                emit(out);
            });
        });
    }
}

/// Gathers the current session's info, play state and app, then prints a line.
static void publish(void) {
    MRGetInfoFn getInfo = symbol(@"MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlayingFn getIsPlaying = symbol(@"MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClientFn getClient = symbol(@"MRMediaRemoteGetNowPlayingClient");
    if (!getInfo || !getIsPlaying) return;

    dispatch_queue_t queue = dispatch_get_main_queue();
    getInfo(queue, ^(CFDictionaryRef rawInfo) {
        NSDictionary *info = (__bridge NSDictionary *)rawInfo;
        getIsPlaying(queue, ^(Boolean isPlaying) {
            void (^finish)(id) = ^(id client) {
                NSString *app = appOf(client);
                NSMutableDictionary *out = describe(info, isPlaying, app);
                BOOL hasSession = [out[@"title"] length] > 0;
                currentApp = hasSession ? app : nil;
                if (hasSession && app && client) knownClients[app] = client;
                emit(out);
                publishBackground();
            };
            if (getClient) getClient(queue, finish); else finish(nil);
        });
    });
}

static void handleCommand(NSString *line) {
    // "toggle @com.example.app" addresses a background session.
    NSString *target = nil;
    NSRange at = [line rangeOfString:@" @"];
    if (at.location != NSNotFound) {
        target = [line substringFromIndex:at.location + 2];
        line = [line substringToIndex:at.location];
    }
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    NSDictionary *codes = @{ @"toggle": @(MRTogglePlayPause), @"play": @(MRPlay), @"pause": @(MRPause),
                             @"next": @(MRNextTrack), @"previous": @(MRPreviousTrack) };
    NSNumber *code = codes[command];

    BOOL isBackground = target.length > 0 && ![target isEqualToString:currentApp];
    if (isBackground) {
        // Addressed through a destination for that one player. Tested: this
        // reaches a native player such as Music while another app is current.
        // Browsers ignore commands while they are not current, and macOS then
        // hands the command to the current player instead, so the app does not
        // send commands to background browser sessions at all.
        Class controller = objc_getClass("MRNowPlayingController");
        Class destinationClass = objc_getClass("MRDestination");
        SEL sendCommand = sel_getUid("sendCommand:toDestination:options:appOptions:withCompletion:");
        SEL initDestination = sel_getUid("initWithPlayerPath:");
        id client = knownClients[target];
        if (!code || !client || ![controller respondsToSelector:sendCommand]
            || ![destinationClass instancesRespondToSelector:initDestination]) return;

        id (*makeDestination)(id, SEL, id) = (void *)objc_msgSend;
        id destination = makeDestination([destinationClass alloc], initDestination, playerPathFor(client));
        void (*send)(id, SEL, uint32_t, id, NSDictionary *, uint32_t, void (^)(id)) = (void *)objc_msgSend;
        send(controller, sendCommand, code.unsignedIntValue, destination, @{}, 0, ^(id result) {
            dispatch_async(dispatch_get_main_queue(), ^{ publishBackground(); });
        });
        // Seeking a background session is not supported.
        return;
    }

    MRSendCommandFn send = symbol(@"MRMediaRemoteSendCommand");
    MRSetElapsedFn setElapsed = symbol(@"MRMediaRemoteSetElapsedTime");
    if ([command isEqualToString:@"seek"] && parts.count == 2 && setElapsed) {
        setElapsed(parts[1].doubleValue);
    } else if (code && send) {
        send(code.unsignedIntValue, NULL);
    }
}

/// Entry point, called from Perl. Never returns.
void dm_now_playing_stream(void) {
    @autoreleasepool {
        mediaRemote = CFBundleCreate(NULL, (__bridge CFURLRef)
            [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"]);
        MRRegisterFn registerForNotifications = symbol(@"MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!mediaRemote || !registerForNotifications) exit(2);

        lastArtworkKeys = [NSMutableDictionary dictionary];
        knownClients = [NSMutableDictionary dictionary];

        registerForNotifications(dispatch_get_main_queue());
        for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                  @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                  @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                  @"kMRMediaRemotePlayerPlaybackStateDidChangeNotification" ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { publish(); }];
        }

        // Background sessions post nothing we are subscribed to, so check on
        // them now and then.
        [NSTimer scheduledTimerWithTimeInterval:4 repeats:YES block:^(NSTimer *timer) {
            if (knownClients.count > (currentApp ? 1 : 0)) publishBackground();
        }];

        NSFileHandle *input = NSFileHandle.fileHandleWithStandardInput;
        input.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = handle.availableData;
            if (data.length == 0) exit(0); // The app went away.
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                if (line.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
            }
        };

        publish();
        CFRunLoopRun();
        exit(0);
    }
}
