/**
 * All credit goes to the original authors of these tweaks:
 *      https://github.com/yandevelop/Bea
 *      https://github.com/opa334/IGSideloadFix
 *      https://github.com/level3tjg/TwitchAdBlock
 *      https://github.com/level3tjg/RedditSideloadFix
 */

#include "SideloadFix.h"

static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef* result) {
    if (CFDictionaryContainsKey(attributes, kSecAttrAccessGroup)) {
        CFMutableDictionaryRef mutableAttributes = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
        CFDictionarySetValue(mutableAttributes, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
        attributes = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableAttributes);
    }

    return orig_SecItemAdd(attributes, result);
}

static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef* result) {
    if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
        CFMutableDictionaryRef mutableQuery = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
        CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
        query = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableQuery);
    }

    return orig_SecItemCopyMatching(query, result);
}

static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
        CFMutableDictionaryRef mutableQuery = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
        CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
        query = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableQuery);
    }

    return orig_SecItemUpdate(query, attributesToUpdate);
}

static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
    if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
        CFMutableDictionaryRef mutableQuery = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
        CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void*)keychainAccessGroup);
        query = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableQuery);
    }

    return orig_SecItemDelete(query);
}

static void createDirectoryIfNotExists(NSURL* URL) {
    if (![URL checkResourceIsReachableAndReturnError:nil]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:URL withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static void loadKeychainAccessGroup() {
    NSDictionary* dummyItem = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount : @"dummyItem",
        (__bridge id)kSecAttrService : @"dummyService",
        (__bridge id)kSecReturnAttributes : @YES,
    };

    CFTypeRef result;
    OSStatus ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
    if (ret == -25300) {
        ret = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);
    }

    if (ret == 0 && result) {
        NSDictionary* resultDict = (__bridge id)result;
        keychainAccessGroup = resultDict[(__bridge id)kSecAttrAccessGroup];
    }
}

static void initSideloadedFixes() {
    fakeGroupContainerURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"] isDirectory:YES];

    loadKeychainAccessGroup();

    rebind_symbols(
        (struct rebinding[]){
            {"SecItemAdd", (void*)hook_SecItemAdd, (void**)&orig_SecItemAdd},
            {"SecItemCopyMatching", (void*)hook_SecItemCopyMatching,
            (void**)&orig_SecItemCopyMatching},
            {"SecItemUpdate", (void*)hook_SecItemUpdate, (void**)&orig_SecItemUpdate},
            {"SecItemDelete", (void*)hook_SecItemDelete, (void**)&orig_SecItemDelete},
        },
    4);

    Method originalMethod = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method swizzledMethod = class_getInstanceMethod([NSFileManager class], @selector(swizzled_containerURLForSecurityApplicationGroupIdentifier:));
    method_exchangeImplementations(originalMethod, swizzledMethod);

    NSDictionary *infoDictionary = [NSBundle mainBundle].infoDictionary;
    originalBundleID = infoDictionary[@"CFBundleIdentifier"];
    originalAppName = infoDictionary[@"CFBundleName"] ?: infoDictionary[@"CFBundleDisplayName"];

    NSLog(@"[SideloadFix] Initialized with bundle ID: %@ and app name: %@", originalBundleID, originalAppName);
}

@implementation NSFileManager (SideloadedFixes)

- (NSURL*)swizzled_containerURLForSecurityApplicationGroupIdentifier:(NSString*)groupIdentifier {
    NSURL* fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupIdentifier];

    createDirectoryIfNotExists(fakeURL);
    createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library"]);
    createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library/Caches"]);

    return fakeURL;
}

@end

%hook NSBundle

- (NSString *)bundleIdentifier {
    Dl_info info;
    NSArray *address = [NSThread callStackReturnAddresses];

    if (dladdr((void *)[address[2] longLongValue], &info) == 0) return %orig;

    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    if ([path hasPrefix:NSBundle.mainBundle.bundlePath]) return originalBundleID;

    return %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CFBundleIdentifier"]) return originalBundleID;
    if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) return originalAppName;

    return %orig;
}

%end

%ctor {
    %init;
    initSideloadedFixes();
}
