// What any app is playing, read through macOS's own Now Playing service.
//
// Since macOS 15.4 that service answers only Apple's own programs. /usr/bin/perl is one of
// them, and it can load a library like this one, so UniMacHub runs perl with this library
// to read what plays in a browser tab and the rest. The library only reads the Now Playing
// state and sends the play buttons; it touches nothing else.
//
//   umh_stream  prints one JSON line on every change, until the app that started it quits
//   umh_send    sends one command: UMH_COMMAND (a MediaRemote command number), or seeks
//               to UMH_SEEK seconds
//
// Both are called by perl as XS functions, with arguments they ignore.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientStringFn)(id);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

static void *framework(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    });
    return handle;
}

static NSString *constant(const char *name) {
    NSString *__strong *value = (NSString *__strong *)dlsym(framework(), name);
    return value ? *value : [NSString stringWithUTF8String:name];
}

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSUInteger lastArtwork = 0;
static BOOL pending = NO;

static void report(void) {
    GetInfoFn getInfo = (GetInfoFn)dlsym(framework(), "MRMediaRemoteGetNowPlayingInfo");
    GetIsPlayingFn getPlaying = (GetIsPlayingFn)dlsym(framework(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetClientFn getClient = (GetClientFn)dlsym(framework(), "MRMediaRemoteGetNowPlayingClient");
    ClientStringFn bundleOf = (ClientStringFn)dlsym(framework(), "MRNowPlayingClientGetBundleIdentifier");
    ClientStringFn parentOf = (ClientStringFn)dlsym(framework(), "MRNowPlayingClientGetParentAppBundleIdentifier");
    if (!getInfo) return;

    dispatch_queue_t main = dispatch_get_main_queue();
    getInfo(main, ^(NSDictionary *info) {
        void (^finish)(Boolean, NSString *, NSString *) = ^(Boolean playing, NSString *bundle, NSString *parent) {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"bundle"] = bundle ?: @"";
            out[@"parent"] = parent ?: @"";
            out[@"playing"] = playing ? @YES : @NO;
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            if ([title isKindOfClass:[NSString class]]) out[@"title"] = title;
            NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            if ([artist isKindOfClass:[NSString class]]) out[@"artist"] = artist;
            NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
            if ([album isKindOfClass:[NSString class]]) out[@"album"] = album;
            NSNumber *duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
            if ([duration isKindOfClass:[NSNumber class]]) out[@"duration"] = duration;
            NSNumber *elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
            if ([elapsed isKindOfClass:[NSNumber class]]) out[@"elapsed"] = elapsed;
            NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            if ([rate isKindOfClass:[NSNumber class]]) out[@"rate"] = rate;
            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([stamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @(stamp.timeIntervalSince1970);

            // The picture goes only when it changes: it is the one big part.
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSUInteger artworkID = 0;
            if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
                artworkID = artwork.hash ^ (artwork.length << 7);
                if (artworkID == 0) artworkID = 1;
            }
            out[@"artworkID"] = @(artworkID);
            if (artworkID != 0 && artworkID != lastArtwork) {
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            }
            lastArtwork = artworkID;
            emit(out);
        };
        void (^withPlaying)(Boolean) = ^(Boolean playing) {
            if (getClient && bundleOf) {
                getClient(main, ^(id client) {
                    finish(playing, client ? bundleOf(client) : nil, client && parentOf ? parentOf(client) : nil);
                });
            } else {
                finish(playing, nil, nil);
            }
        };
        if (getPlaying) {
            getPlaying(main, ^(Boolean playing) { withPlaying(playing); });
        } else {
            withPlaying(NO);
        }
    });
}

/// Several notifications arrive for one change; answer them once.
static void scheduleReport(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        report();
    });
}

void umh_stream(void) {
    if (!framework()) {
        emit(@{@"error": @"unavailable"});
        exit(2);
    }
    RegisterFn registerFn = (RegisterFn)dlsym(framework(), "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerFn) registerFn(dispatch_get_main_queue());

    NSArray *names = @[
        constant("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        constant("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        constant("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
    ];
    for (NSString *name in names) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { scheduleReport(); }];
    }
    report();

    // Ends with the app: once it is gone this process belongs to launchd.
    pid_t parent = getppid();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{
        if (getppid() != parent) exit(0);
    });
    dispatch_resume(timer);

    CFRunLoopRun();
}

void umh_send(void) {
    if (!framework()) exit(2);
    const char *seek = getenv("UMH_SEEK");
    const char *command = getenv("UMH_COMMAND");
    if (seek) {
        SetElapsedFn setElapsed = (SetElapsedFn)dlsym(framework(), "MRMediaRemoteSetElapsedTime");
        if (setElapsed) setElapsed(atof(seek));
    } else if (command) {
        SendCommandFn send = (SendCommandFn)dlsym(framework(), "MRMediaRemoteSendCommand");
        if (send) send(atoi(command), nil);
    }
    // The command goes out asynchronously; give it a moment before the process ends.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}
