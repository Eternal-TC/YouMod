// Some are adapted from https://github.com/Mark02-2012/YTPlaybackFix (MIT)
#import "Headers.h"

// Sideloaded YouTube can't produce the App Attest backed proof-of-origin token the iOS client is
// expected to send, so the server cuts the stream off after ~30 seconds (playback error 14).
// Two workarounds live here:
// 1. SpoofPlaybackClient: playback requests (/player, /initplayback, /videoplayback) identify as the
//    PS4 TV client, which isn't held to the iOS attestation check. Feed, comments and the watch page
//    keep the iOS identity so the UI is unchanged.
// 2. FixPlaybackIssues: if the error still fires, retry and resume at the same position instead of
//    showing "Something went wrong".

@interface YTPlayerTapToRetryResponderEvent : NSObject
+ (instancetype)eventWithFirstResponder:(id)firstResponder;
- (void)send;
@end

@interface GTMSessionFetcher : NSObject
- (NSMutableURLRequest *)mutableRequestForTesting;
@end

#pragma mark - Client spoofing

static NSString *const kPS4UserAgent = @"Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)";

static NSURLRequest *spoofedRequest(NSURLRequest *request) {
    NSURL *URL = request.URL;
    if (!URL) return request;
    NSString *path = URL.path.lowercaseString;
    BOOL initPlayback = [path containsString:@"/initplayback"];
    BOOL player = initPlayback || [path hasSuffix:@"/player"];
    BOOL stream = [path containsString:@"/videoplayback"];
    if (!player && !stream) return request;

    NSMutableURLRequest *mutableRequest = [request isKindOfClass:[NSMutableURLRequest class]] ? (NSMutableURLRequest *)request : [request mutableCopy];
    NSString *urlString = URL.absoluteString;
    if (player) {
        [mutableRequest setValue:@"75" forHTTPHeaderField:@"X-YouTube-Client-Name"];
        [mutableRequest setValue:@"1.1" forHTTPHeaderField:@"X-YouTube-Client-Version"];
        [mutableRequest setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
        if (initPlayback) {
            urlString = [urlString stringByReplacingOccurrencesOfString:@"([?&])c=[^&]+" withString:@"$1c=TVHTML5_SIMPLY" options:NSRegularExpressionSearch range:NSMakeRange(0, urlString.length)];
            urlString = [urlString stringByReplacingOccurrencesOfString:@"([?&])cver=[^&]+" withString:@"$1cver=1.1" options:NSRegularExpressionSearch range:NSMakeRange(0, urlString.length)];
        }
    } else {
        NSString *ua = [kPS4UserAgent stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
        urlString = [urlString stringByReplacingOccurrencesOfString:@"([?&])user_agent=[^&]+" withString:[@"$1user_agent=" stringByAppendingString:ua] options:NSRegularExpressionSearch range:NSMakeRange(0, urlString.length)];
    }
    [mutableRequest setValue:kPS4UserAgent forHTTPHeaderField:@"User-Agent"];
    NSURL *newURL = [NSURL URLWithString:urlString];
    if (newURL && ![newURL isEqual:URL]) mutableRequest.URL = newURL;
    return mutableRequest;
}

%group Spoof
%hook GTMSessionFetcher
- (instancetype)initWithRequest:(NSURLRequest *)request configuration:(id)configuration {
    return %orig(spoofedRequest(request), configuration);
}
- (void)updateMutableRequest:(NSMutableURLRequest *)request {
    %orig((NSMutableURLRequest *)spoofedRequest(request));
}
- (void)setRequestValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig;
    // YouTube sets its own client headers after init, so put ours back on top
    if (![self respondsToSelector:@selector(mutableRequestForTesting)]) return;
    NSMutableURLRequest *request = [self mutableRequestForTesting];
    if (request) spoofedRequest(request);
}
%end

%hook GTMSessionFetcherSessionDelegateDispatcher
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(id)completionHandler {
    %orig(session, task, response, spoofedRequest(request), completionHandler);
}
%end
%end

#pragma mark - Retry and resume

static CGFloat lastPlaybackTime = 0;
static NSUInteger retryCount = 0;
static CFAbsoluteTime lastRetry = 0;

%group Retry
%hook YTPlayerViewController
- (CGFloat)currentVideoMediaTime {
    CGFloat time = %orig;
    if (time > 0) lastPlaybackTime = time;
    return time;
}
- (void)seekToTime:(CGFloat)time {
    lastPlaybackTime = time;
    %orig;
}
%end

%hook YTMainAppVideoPlayerOverlayViewController
- (void)handleError:(NSError *)error {
    if (!error || ![error.domain isEqualToString:@"com.google.ios.youtube.ErrorDomain.playback"] || (error.code != 14 && error.code != 0)) {
        %orig;
        return;
    }
    // Give up after 3 retries within a minute so a video that really can't play still shows the error
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastRetry > 60) retryCount = 0;
    if (retryCount >= 3) {
        %orig;
        return;
    }
    retryCount++;
    lastRetry = now;

    YTPlayerViewController *playerViewController = self.parentViewController;
    CGFloat resumeTime = lastPlaybackTime;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id responder = [self respondsToSelector:@selector(parentResponder)] ? [self performSelector:@selector(parentResponder)] : nil;
        YTPlayerTapToRetryResponderEvent *event = responder ? [%c(YTPlayerTapToRetryResponderEvent) eventWithFirstResponder:responder] : nil;
        if (event) {
            [event send];
        } else if ([playerViewController.UIDelegate isKindOfClass:%c(YTWatchController)]) {
            [(YTWatchController *)playerViewController.UIDelegate reload];
        }
        if (resumeTime > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [playerViewController seekToTime:resumeTime];
            });
        }
    });
}
%end
%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        FixPlaybackIssues: @YES,
        SpoofPlaybackClient: @YES,
    }];
    if (IS_ENABLED(SpoofPlaybackClient)) %init(Spoof);
    if (IS_ENABLED(FixPlaybackIssues)) %init(Retry);
}
