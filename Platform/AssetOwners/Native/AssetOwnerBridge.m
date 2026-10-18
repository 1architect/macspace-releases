#import "AssetOwnerBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <membership.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/file.h>
#import <fcntl.h>
#import <sqlite3.h>
#import <unistd.h>

@protocol MSOwners
+ (id)sharedManager;
+ (id)sharedInstance;
+ (NSArray *)subscriptionsForClientIdentifier:(NSString *)client;
+ (NSString *)subscriptionNameForConfig:(id)config;
+ (NSDictionary *)assetSetUsageForConfig:(id)config;
+ (void)unsubscribeFromAssetsWithConfigs:(NSArray *)configs clientIdentifier:(NSString *)client completionHandler:(void (^)(NSDictionary *))reply;
+ (void)unsubscribeFromAssetsWithConfigs:(NSArray *)configs subscriberId:(NSString *)client completionHandler:(void (^)(NSDictionary *))reply;
- (id)initWithLanguage:(NSString *)language assetType:(NSUInteger)type;
- (NSArray *)subscriptionsForSubscriber:(NSString *)subscriber;
- (void)unsubscribe:(NSString *)subscriber subscriptionNames:(NSArray *)names user:(NSString *)user userInitiated:(BOOL)initiated queue:(dispatch_queue_t)queue completion:(void (^)(void))reply;
- (void)subscribe:(NSString *)subscriber subscriptions:(NSArray *)subscriptions user:(NSString *)user userInitiated:(BOOL)initiated queue:(dispatch_queue_t)queue completion:(void (^)(void))reply;
- (void)subscribedVoicesWithClientId:(NSString *)client reply:(void (^)(NSArray *))reply;
- (void)subscribeWithVoices:(NSArray *)voices clientId:(NSString *)client accessoryId:(NSString *)accessory reply:(void (^)(NSError *))reply;
- (void)isSpeakingWithAccessoryId:(NSString *)accessory reply:(void (^)(BOOL))reply;
- (void)removeAssertionWithIdentifier:(NSString *)identifier assetType:(NSString *)assetType;
- (void)addAssertionsForAssetsWithQueries:(NSArray *)queries policies:(NSArray *)policies assertionIDs:(NSArray *)ids clientID:(NSString *)client;
@end

static void require(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"MacSpaceAssetOwnerRefusal" reason:message userInfo:nil];
}
static void framework(NSString *path) { require(dlopen(path.UTF8String, RTLD_LAZY) != NULL, [@"Cannot load " stringByAppendingString:path.lastPathComponent]); }
static void method(Class cls, NSString *name, NSString *encoding, BOOL classMethod) {
    Method m = classMethod ? class_getClassMethod(cls, NSSelectorFromString(name)) : class_getInstanceMethod(cls, NSSelectorFromString(name));
    require(m && [encoding isEqual:@(method_getTypeEncoding(m))], [@"Unreviewed owner method: " stringByAppendingString:name]);
}
static id value(id object, NSString *key) { return [object valueForKey:key]; }
static NSSet *classes(void) {
    NSMutableSet *set = [NSMutableSet setWithArray:@[NSArray.class, NSMutableArray.class, NSDictionary.class, NSMutableDictionary.class,
        NSSet.class, NSMutableSet.class, NSString.class, NSNumber.class, NSDate.class, NSData.class, NSNull.class]];
    for (NSString *name in @[@"UAFAssetSetSubscription", @"SFEntitledAssetConfig", @"SiriTTSVoiceSubscription", @"SiriTTSSynthesisVoice",
        @"DDSAssertion", @"DDSAssertDescriptor", @"DDSAssetPolicy", @"DDSLinguisticAssetQuery", @"DDSAssetQuery", @"DDSLinguisticAttributeFilter", @"DDSAttributeFilter"]) {
        Class c = NSClassFromString(name); if (c) [set addObject:c];
    }
    return set;
}
static NSData *archive(id object) {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:&error];
    require(data && !error, @"Owner rollback object could not be archived");
    return data;
}
static id decode(NSData *data) {
    NSError *error = nil;
    id object = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes() fromData:data error:&error];
    require(object && !error, @"Owner rollback archive could not be securely decoded"); return object;
}
static NSDictionary *facts(id subscription) {
    return @{@"name": value(subscription, @"name") ?: NSNull.null,
        @"assetSets": value(subscription, @"assetSets") ?: NSNull.null,
        @"usageAliases": value(subscription, @"usageAliases") ?: NSNull.null,
        @"expiration": value(subscription, @"expiration") ?: NSNull.null};
}
static NSString *directory(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacSpace/asset-owners"]; }
static NSString *journalPath(NSString *scope) { return [directory() stringByAppendingPathComponent:[scope stringByAppendingString:@".plist"]]; }
static void save(NSMutableDictionary *journal, NSString *scope) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:journal format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    require(data && [data writeToFile:journalPath(scope) options:NSDataWritingAtomic error:&error], @"Cannot save owner rollback journal");
    require(chmod(journalPath(scope).UTF8String, 0600) == 0, @"Cannot protect owner journal");
    int fd = open(journalPath(scope).UTF8String, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0, @"Cannot open saved owner journal"); BOOL synced = fsync(fd) == 0; close(fd);
    require(synced, @"Cannot sync owner journal");
    fd = open(directory().UTF8String, O_RDONLY); require(fd >= 0, @"Cannot open owner journal folder");
    synced = fsync(fd) == 0; close(fd); require(synced, @"Cannot sync owner journal folder");
}
static NSMutableDictionary *load(NSString *scope) {
    if (![NSFileManager.defaultManager fileExistsAtPath:journalPath(scope)])
        return [@{@"version": @1, @"scope": scope, @"uid": @(getuid()), @"entries": [NSMutableArray new]} mutableCopy];
    struct stat st; require(lstat(journalPath(scope).UTF8String, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() && !(st.st_mode & 0077), @"Unsafe owner journal");
    NSData *data = [NSData dataWithContentsOfFile:journalPath(scope)];
    NSMutableDictionary *journal = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil];
    require([journal isKindOfClass:NSMutableDictionary.class] && [journal[@"version"] isEqual:@1] && [journal[@"scope"] isEqual:scope]
        && [journal[@"uid"] isEqual:@(getuid())] && [journal[@"entries"] isKindOfClass:NSMutableArray.class], @"Invalid owner journal");
    return journal;
}
static NSMutableDictionary *record(NSMutableDictionary *journal, NSString *kind, NSString *client, NSString *name, NSData *data, NSDictionary *extra) {
    for (NSMutableDictionary *entry in journal[@"entries"]) {
        if ([entry[@"kind"] isEqual:kind] && [entry[@"client"] isEqual:client] && [entry[@"name"] isEqual:name]) {
            require(![@[@"submitted",@"restoring"] containsObject:entry[@"phase"]], @"An earlier owner request needs read-only reconciliation");
            // A later explicit disable starts a fresh ownership cycle after a completed restore.
            if ([entry[@"phase"] isEqual:@"restored"]) { entry[@"archive"] = data; [entry addEntriesFromDictionary:extra]; }
            entry[@"phase"] = @"prepared"; return entry;
        }
    }
    require([journal[@"entries"] count] < 512, @"Too many owner rollback records");
    NSMutableDictionary *entry = [@{@"kind": kind, @"client": client, @"name": name, @"archive": data, @"phase": @"prepared"} mutableCopy];
    [entry addEntriesFromDictionary:extra]; [journal[@"entries"] addObject:entry]; return entry;
}
static void safety(NSString *scope) {
    NSDictionary *eligibility=[NSDictionary dictionaryWithContentsOfFile:@"/private/var/db/os_eligibility/eligibility.plist"];
    require([eligibility[@"OS_ELIGIBILITY_DOMAIN_SIRI_MODE"][@"os_eligibility_answer_t"] isEqual:@2],@"Apple Intelligence availability changed or became unreadable");
    if([scope isEqual:@"siri"]) {
        CFPreferencesAppSynchronize(CFSTR("com.apple.assistant.support"));
        id enabled=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Assistant Enabled"),CFSTR("com.apple.assistant.support")));
        CFPreferencesAppSynchronize(CFSTR("com.apple.assistant.backedup"));
        id voice=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Output Voice"),CFSTR("com.apple.assistant.backedup")));
        require([enabled isEqual:@NO] && !voice,@"Siri settings changed; model cleanup stopped");
    }
    if([scope isEqual:@"phone"]) {
        BOOL (*flag)(const char *,const char *)=dlsym(RTLD_DEFAULT,"_os_feature_enabled_impl");
        require(flag!=NULL,@"Phone feature gates became unreadable");
        for(NSString *name in @[@"CallRecording",@"CallScreeningEnabled",@"CaptionDeliveryForFaceTime",@"AudioCallTranslationMac",@"VideoCallTranslationMac"])
            require(!flag("TelephonyUtilities",name.UTF8String),@"Phone feature gates changed; cleanup stopped");
        NSDictionary *domains=@{@"com.apple.TelephonyUtilities":@{@"CallRecordingDisabled":@YES,@"CallScreeningDisabled":@YES},
                                @"com.apple.Accessibility":@{@"FaceTimeCaptions":@NO,@"LiveTranscriptionInCallEnabled":@NO}};
        for(NSString *domain in domains) {
            CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
            for(NSString *key in domains[domain]) {
                id actual=CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,(__bridge CFStringRef)domain));
                require([actual isEqual:domains[domain][key]],@"Phone feature settings changed; cleanup stopped");
            }
        }
    }
}
static void submitted(NSMutableDictionary *entry, NSMutableDictionary *journal, NSString *scope) { safety(scope);entry[@"phase"] = @"submitted"; save(journal, scope); }
static void done(NSMutableDictionary *entry, NSMutableDictionary *journal, NSString *scope) { entry[@"phase"] = @"removed"; save(journal, scope); }
static NSString *userGUID(void) {
    uuid_t uuid; require(mbr_uid_to_uuid(getuid(), uuid) == 0, @"Cannot resolve the current account");
    return [[NSUUID alloc] initWithUUIDBytes:uuid].UUIDString;
}
static NSArray *rows(void) {
    sqlite3 *db = NULL;
    int opened = sqlite3_open_v2("file:/private/var/db/assetsubscriptiond/UAFAssetSubscriptions.db?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
    if (opened != SQLITE_OK) { if (db) sqlite3_close(db); require(NO, @"Cannot read asset owners"); }
    sqlite3_stmt *stmt = NULL;
    int prepared = sqlite3_prepare_v2(db, "SELECT k0,k1,k2,k3,k4 FROM Subscriptions", -1, &stmt, NULL);
    if (prepared != SQLITE_OK) { sqlite3_close(db); require(NO, @"Unknown asset subscription schema"); }
    NSMutableArray *result = [NSMutableArray new]; int step;
    while ((step = sqlite3_step(stmt)) == SQLITE_ROW) {
        NSMutableArray *strings = [NSMutableArray new];
        for (int i = 0; i < 5; i++) {
            const unsigned char *s = (i == 0 || i == 1 || i == 4) ? sqlite3_column_text(stmt, i) : NULL;
            NSString *text = s ? [NSString stringWithUTF8String:(const char *)s] : @"";
            require(text != nil, @"Invalid owner identity text"); [strings addObject:text];
        }
        NSData *data = [NSData dataWithBytes:sqlite3_column_blob(stmt, 2) length:sqlite3_column_bytes(stmt, 2)];
        [result addObject:@{@"client": strings[0], @"name": strings[1], @"archive": data, @"expiry": @(sqlite3_column_double(stmt,3)), @"user": strings[4]}];
    }
    sqlite3_finalize(stmt); sqlite3_close(db); require(step == SQLITE_DONE, @"Incomplete owner inventory"); return result;
}
static NSDictionary *row(NSArray *all, NSString *client, NSString *name, NSString *user) {
    NSDictionary *found = nil;
    for (NSDictionary *r in all) if ([r[@"client"] isEqual:client] && [r[@"name"] isEqual:name] && [r[@"user"] caseInsensitiveCompare:user] == NSOrderedSame) {
        require(!found, @"Duplicate owner identity"); found = r;
    }
    return found;
}
static id<MSOwners> manager(void) {
    Class c = NSClassFromString(@"UAFAssetSetManager");
    method(c, @"sharedManager", @"@16@0:8", YES);
    method(c, @"subscriptionsForSubscriber:", @"@24@0:8@16", NO);
    method(c, @"unsubscribe:subscriptionNames:user:userInitiated:queue:completion:", @"v60@0:8@16@24@32B40@44@?52", NO);
    method(c, @"subscribe:subscriptions:user:userInitiated:queue:completion:", @"v60@0:8@16@24@32B40@44@?52", NO);
    return [(Class<MSOwners>)c sharedManager];
}
static id apiSubscription(id<MSOwners> owner, NSString *client, NSString *name) {
    NSArray *subscriptions = [owner subscriptionsForSubscriber:client];
    require(!subscriptions || [subscriptions isKindOfClass:NSArray.class], @"Owner API query failed");
    id found = nil;
    for (id subscription in subscriptions) if ([value(subscription,@"name") isEqual:name]) {
        require(!found, @"Duplicate owner API identity"); found = subscription;
    }
    return found;
}
static BOOL absent(id<MSOwners> owner, NSDictionary *entry, NSString *user) {
    return !row(rows(),entry[@"client"],entry[@"name"],user) && !apiSubscription(owner,entry[@"client"],entry[@"name"]);
}
static NSXPCConnection *ttsConnection(void);
static NSArray *ttsRequests(NSXPCConnection *connection);
static NSDictionary *ddsMap(void);
static void reconcile(NSMutableDictionary *journal, NSString *scope, id<MSOwners> owner, NSString *user) {
    for (NSMutableDictionary *entry in journal[@"entries"]) {
        require(![entry[@"phase"] isEqual:@"restoring"],@"An interrupted restore needs verification before cleanup can resume");
        if (![entry[@"phase"] isEqual:@"submitted"]) continue;
        BOOL gone=NO;
        if ([entry[@"kind"] isEqual:@"uaf"]) gone=absent(owner,entry,user);
        if ([entry[@"kind"] isEqual:@"dds"]) gone=ddsMap()[entry[@"name"]]==nil;
        if ([entry[@"kind"] isEqual:@"tts"]) {
            NSXPCConnection *connection=ttsConnection();
            @try {
                gone=YES;
                for(id request in ttsRequests(connection))if([value(request,@"clientId") isEqual:entry[@"client"]])gone=NO;
            } @finally {[connection invalidate];}
        }
        require(gone,@"An interrupted owner operation is still ambiguous; no request was repeated");
        done(entry,journal,scope);
    }
}
static BOOL speechOff(void) {
    Class prefs = NSClassFromString(@"AFPreferences");
    method(prefs, @"sharedPreferences", @"@16@0:8", YES);
    id p = ((id(*)(id,SEL))objc_msgSend)(prefs,sel_registerName("sharedPreferences"));
    for (NSString *name in @[@"assistantIsEnabled", @"dictationIsEnabled"]) {
        method(prefs,name,@"B16@0:8",NO);
        if (((BOOL(*)(id,SEL))objc_msgSend)(p,NSSelectorFromString(name))) return NO;
    }
    return YES;
}
static void releaseSpeech(NSString *scope, NSMutableDictionary *journal, id<MSOwners> owner, NSString *user, NSMutableArray *details) {
    NSString *client = [scope isEqual:@"phone"] ? @"com.apple.TelephonyUtilities" : @"com.apple.siri.embeddedspeech";
    BOOL phone = [scope isEqual:@"phone"];
    if (!phone && !speechOff()) { [details addObject:@"Siri or Dictation is active; shared speech models were kept."]; return; }
    Class speech = NSClassFromString(@"SFSpeechAssetManager"), entitled = NSClassFromString(@"SFEntitledAssetManager"), configClass = NSClassFromString(@"SFEntitledAssetConfig");
    method(entitled,@"subscriptionNameForConfig:",@"@24@0:8@16",YES);
    method(entitled,@"assetSetUsageForConfig:",@"@24@0:8@16",YES);
    method(configClass,@"initWithLanguage:assetType:",@"@32@0:8@16Q24",NO);
    NSString *selector = phone ? @"unsubscribeFromAssetsWithConfigs:clientIdentifier:completionHandler:" : @"unsubscribeFromAssetsWithConfigs:subscriberId:completionHandler:";
    Class target = phone ? speech : entitled;
    method(target,selector,@"v40@0:8@16@24@?32",YES);
    NSMutableArray *configs = [NSMutableArray new], *entries = [NSMutableArray new];
    NSArray *all = rows();
    for (NSDictionary *r in all) {
        if (![r[@"client"] isEqual:client] || [r[@"user"] caseInsensitiveCompare:user] != NSOrderedSame) continue;
        NSString *prefix = phone ? @"transcription." : @"assistant.";
        if (![r[@"name"] hasPrefix:prefix]) continue;
        NSString *language = [r[@"name"] substringFromIndex:prefix.length];
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
        require(language.length && language.length < 40 && [language rangeOfCharacterFromSet:invalid].location == NSNotFound, @"Unreviewed speech language");
        id config = [(id<MSOwners>)[configClass alloc] initWithLanguage:language assetType:phone ? 7 : 3];
        require([[(Class<MSOwners>)entitled subscriptionNameForConfig:config] isEqual:r[@"name"]] &&
                [[(Class<MSOwners>)entitled assetSetUsageForConfig:config] isEqual:@{@"asr.language":language}], @"Speech config does not match its owner");
        id original = decode(r[@"archive"]), api = apiSubscription(owner,client,r[@"name"]);
        require(api && [facts(original) isEqual:facts(api)], @"Speech owner changed during preflight");
        NSMutableDictionary *entry = record(journal,@"uaf",client,r[@"name"],r[@"archive"],@{@"user":user,@"expiry":r[@"expiry"]});
        [entries addObject:entry]; [configs addObject:config];
        if (!phone) {
            NSDictionary *hammer = row(all,client,[@"hammer." stringByAppendingString:language],user);
            if (hammer) [entries addObject:record(journal,@"uaf",client,hammer[@"name"],hammer[@"archive"],@{@"user":user,@"expiry":hammer[@"expiry"]})];
        }
    }
    if (!configs.count) return;
    for (NSMutableDictionary *entry in entries) submitted(entry,journal,scope);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0); __block NSDictionary *errors = nil;
    void (^reply)(NSDictionary *) = ^(NSDictionary *result) { errors = result; dispatch_semaphore_signal(sem); };
    if (phone) [(Class<MSOwners>)target unsubscribeFromAssetsWithConfigs:configs clientIdentifier:client completionHandler:reply];
    else [(Class<MSOwners>)target unsubscribeFromAssetsWithConfigs:configs subscriberId:client completionHandler:reply];
    require(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)) == 0 && (!errors || [errors isKindOfClass:NSDictionary.class]) && errors.count == 0, @"Speech owner did not confirm removal");
    for (NSMutableDictionary *entry in entries) {
        BOOL gone = NO;
        for (int n=0;n<5;n++) { gone=absent(owner,entry,user); if(gone)break; [NSThread sleepForTimeInterval:1]; }
        require(gone,@"Speech owner is still present"); done(entry,journal,scope);
    }
    [details addObject:[NSString stringWithFormat:@"Released %lu speech owner requests.",(unsigned long)configs.count]];
}

static NSXPCConnection *ttsConnection(void) {
    framework(@"/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService");
    Protocol *p = NSProtocolFromString(@"SiriTTSService.DaemonProtocol"); require(p != nil,@"Missing voice owner protocol");
    NSDictionary *encodings = @{@"subscribedVoicesWithClientId:reply:":@"v32@0:8@16@?24",
        @"subscribeWithVoices:clientId:accessoryId:reply:":@"v48@0:8@16@24@32@?40", @"isSpeakingWithAccessoryId:reply:":@"v32@0:8@16@?24"};
    for (NSString *name in encodings) {
        struct objc_method_description md = protocol_getMethodDescription(p,NSSelectorFromString(name),YES,YES);
        require(md.types && [encodings[name] isEqual:@(md.types)],@"Unreviewed voice owner protocol");
    }
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:p];
    [interface setClasses:classes() forSelector:@selector(subscribedVoicesWithClientId:reply:) argumentIndex:0 ofReply:YES];
    [interface setClasses:classes() forSelector:@selector(subscribeWithVoices:clientId:accessoryId:reply:) argumentIndex:0 ofReply:NO];
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:@"com.apple.sirittsd" options:0];
    connection.remoteObjectInterface=interface; [connection resume]; return connection;
}
static NSArray *ttsRequests(NSXPCConnection *connection) {
    dispatch_semaphore_t sem=dispatch_semaphore_create(0); __block NSArray *result=nil;
    id<MSOwners> proxy=[connection remoteObjectProxyWithErrorHandler:^(NSError *error){ dispatch_semaphore_signal(sem); }];
    [proxy subscribedVoicesWithClientId:nil reply:^(NSArray *r){ result=r; dispatch_semaphore_signal(sem); }];
    require(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0 && [result isKindOfClass:NSArray.class],@"Cannot read voice owners");
    return result;
}
static NSDictionary *voiceFacts(id request) {
    id voice=value(request,@"voice");
    return @{@"client":value(request,@"clientId") ?: NSNull.null,@"accessory":value(request,@"accessoryId") ?: NSNull.null,
             @"language":value(voice,@"language") ?: NSNull.null,@"name":value(voice,@"name") ?: NSNull.null,@"version":value(voice,@"version") ?: NSNull.null};
}
static NSArray *voiceViews(NSArray *requests, NSString *excluding) {
    NSMutableArray *views=[NSMutableArray new];
    for(id r in requests) if(![value(r,@"clientId") isEqual:excluding]) [views addObject:voiceFacts(r)];
    return [views sortedArrayUsingComparator:^NSComparisonResult(id a,id b){return [[a description] compare:[b description]];}];
}
static NSArray *releaseTTS(NSString *scope, NSMutableDictionary *journal, NSMutableArray *details) {
    NSString *client=[scope isEqual:@"phone"]?@"com.apple.TelephonyUtilities":@"com.apple.AssistantServices";
    NSXPCConnection *connection=ttsConnection();
    @try {
        dispatch_semaphore_t idle=dispatch_semaphore_create(0); __block BOOL speaking=YES;
        id<MSOwners> proxy=[connection remoteObjectProxyWithErrorHandler:^(NSError *e){dispatch_semaphore_signal(idle);}];
        [proxy isSpeakingWithAccessoryId:nil reply:^(BOOL s){speaking=s;dispatch_semaphore_signal(idle);}];
        require(dispatch_semaphore_wait(idle,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0 && !speaking,@"Speech is active or unreadable; voice models were kept");
        NSArray *before=ttsRequests(connection); NSMutableArray *targets=[NSMutableArray new];
        for(id r in before) if([value(r,@"clientId") isEqual:client]) { require(value(r,@"accessoryId")==nil,@"Accessory voice request was kept"); [targets addObject:r]; }
        if(!targets.count) return before;
        NSData *data=archive(targets); require([voiceViews(decode(data),nil) isEqual:voiceViews(targets,nil)],@"Voice rollback roundtrip failed");
        NSMutableDictionary *entry=record(journal,@"tts",client,@"voices",data,@{}); submitted(entry,journal,scope);
        dispatch_semaphore_t sem=dispatch_semaphore_create(0); __block NSError *error=nil;
        [proxy subscribeWithVoices:@[] clientId:client accessoryId:nil reply:^(NSError *e){error=e;dispatch_semaphore_signal(sem);}];
        require(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0 && !error,@"Voice owner did not confirm removal");
        NSArray *after=ttsRequests(connection);
        require([voiceViews(before,client) isEqual:voiceViews(after,client)],@"Another voice owner changed; cleanup stopped");
        for(id r in after) require(![value(r,@"clientId") isEqual:client],@"Voice owner is still present");
        done(entry,journal,scope); [details addObject:@"Released the feature's voice requests."]; return after;
    } @finally { [connection invalidate]; }
}
static BOOL allowedAlias(NSDictionary *r, id object) {
    NSString *client=r[@"client"], *name=r[@"name"], *alias=nil;
    if(([@[@"com.apple.siri.assistant",@"com.apple.siri.intelligenceengine"] containsObject:client]) && [name isEqual:@"language.hold"]) alias=@"com.apple.siri.assistant.legacy.language";
    if([client isEqual:@"com.apple.siri.nl"] && [@[@"system.language",@"system.language.hold"] containsObject:name]) alias=@"com.apple.siri.nl.system.language";
    if(!alias)return NO;
    NSDictionary *aliases=value(object,@"usageAliases");
    return [aliases isKindOfClass:NSDictionary.class] && aliases.count==1 && [aliases[alias] isKindOfClass:NSString.class] && [aliases[alias] length]>0 && value(object,@"assetSets")==nil;
}
static BOOL allowedTTS(NSDictionary *r,id object,NSArray *active) {
    NSString *client=r[@"client"], *name=r[@"name"];
    if(![client isEqual:@"siritts"] && !([client isEqual:name] && [name hasPrefix:@"com.apple.siri.tts."]))return NO;
    NSDictionary *sets=value(object,@"assetSets");
    if(![sets isKindOfClass:NSDictionary.class] || sets.count!=1 || value(object,@"usageAliases")!=nil)return NO;
    NSDictionary *tts=sets[@"com.apple.siri.tts"];
    if(![tts isKindOfClass:NSDictionary.class])return NO;
    NSString *language=tts[@"tts.language"], *voice=tts[@"tts.name"];
    if(![language isKindOfClass:NSString.class])return NO;
    for(id request in active) {
        id v=value(request,@"voice"); NSString *activeLanguage=value(v,@"language");
        if(![activeLanguage isKindOfClass:NSString.class])return NO;
        if([[activeLanguage stringByReplacingOccurrencesOfString:@"-" withString:@"_"] isEqual:[language stringByReplacingOccurrencesOfString:@"-" withString:@"_"]]
           && (!voice || [value(v,@"name") isEqual:voice])) return NO;
    }
    // Only premium voice/resource owners measured in Issue 16, never custom/personal voices.
    return ([name hasPrefix:@"com.apple.siri.tts.voice."] && [tts[@"tts.quality"] isEqual:@"premium"]
            && [@[@"natural",@"neural"] containsObject:tts[@"tts.technology"]]) || [name hasPrefix:@"com.apple.siri.tts.resource."];
}
static void releaseUAF(NSString *scope,NSMutableDictionary *journal,id<MSOwners> owner,NSString *user,NSArray *active,NSMutableArray *details) {
    BOOL siri=[scope isEqual:@"siri"] && speechOff(); NSUInteger count=0;
    for(NSDictionary *r in rows()) {
        if([r[@"user"] caseInsensitiveCompare:user]!=NSOrderedSame)continue;
        NSString *client=r[@"client"];
        BOOL aliasCandidate=siri && [@[@"com.apple.siri.assistant",@"com.apple.siri.intelligenceengine",@"com.apple.siri.nl"] containsObject:client];
        BOOL ttsCandidate=[client isEqual:@"siritts"] || ([client isEqual:r[@"name"]] && [client hasPrefix:@"com.apple.siri.tts."]);
        if(!aliasCandidate && !ttsCandidate)continue;
        id object=decode(r[@"archive"]);
        if(!((aliasCandidate && allowedAlias(r,object)) || (ttsCandidate && allowedTTS(r,object,active))))continue;
        id current=apiSubscription(owner,client,r[@"name"]);
        require(current && [facts(object) isEqual:facts(current)],@"Owner changed during preflight");
        require([facts(object) isEqual:facts(decode(archive(object)))],@"Owner rollback roundtrip failed");
        NSMutableDictionary *entry=record(journal,@"uaf",client,r[@"name"],r[@"archive"],@{@"user":user,@"expiry":r[@"expiry"]});
        submitted(entry,journal,scope);
        dispatch_semaphore_t sem=dispatch_semaphore_create(0);
        [owner unsubscribe:client subscriptionNames:@[r[@"name"]] user:user userInitiated:YES queue:nil completion:^{dispatch_semaphore_signal(sem);}];
        BOOL answered=dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0;
        BOOL gone=NO; for(int n=0;n<5;n++){gone=absent(owner,entry,user);if(gone)break;[NSThread sleepForTimeInterval:1];}
        require(answered && gone,@"Owner removal has not been verified"); done(entry,journal,scope); count++;
    }
    [details addObject:[NSString stringWithFormat:@"Released %lu mapped asset owners.",(unsigned long)count]];
}

static NSString *ddsType=@"com.apple.MobileAsset.LinguisticData";
static NSArray *ddsObjects(void) {
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/DataDeliveryServices/ddsassertiondata.plist"];
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return @[];
    id objects=decode([NSData dataWithContentsOfFile:path]); require([objects isKindOfClass:NSArray.class],@"Unknown DDS archive root"); return objects;
}
static NSDictionary *ddsMap(void) {
    NSMutableDictionary *result=[NSMutableDictionary new];
    for(id assertion in ddsObjects()) for(id descriptor in value(assertion,@"descriptors")) {
        NSString *identifier=value(descriptor,@"assertionIdentifier"), *client=value(descriptor,@"clientIdentifier");
        require([identifier isKindOfClass:NSString.class] && identifier.length && [client isKindOfClass:NSString.class] && !result[identifier],@"Unknown or duplicate DDS identity");
        result[identifier]=@{@"query":value(assertion,@"query"),@"policy":value(descriptor,@"policy"),@"client":client};
    }
    return result;
}
static BOOL sameDDS(NSDictionary *a,NSDictionary *b) {
    if(!a || !b || ![a[@"client"] isEqual:b[@"client"]])return NO;
    id query=a[@"query"],other=b[@"query"];
    method([query class],@"isEqualToAssetQuery:",@"B24@0:8@16",NO);
    if(!((BOOL(*)(id,SEL,id))objc_msgSend)(query,sel_registerName("isEqualToAssetQuery:"),other))return NO;
    for(NSString *key in @[@"preferredDownloadFrequency",@"downloadOverCellular",@"downloadWithoutPower",@"idleUsageEvictionPeriod",
                           @"notificationDownloadTriggers",@"downloadCompletionNotification"]) {
        id lhs=value(a[@"policy"],key),rhs=value(b[@"policy"],key);
        if(lhs!=rhs && ![lhs isEqual:rhs])return NO;
    }
    return YES;
}
static id<MSOwners> ddsCenter(void) {
    Class c=NSClassFromString(@"DDSAssetCenter");
    method(c,@"sharedInstance",@"@16@0:8",YES);
    method(c,@"removeAssertionWithIdentifier:assetType:",@"v32@0:8@16@24",NO);
    method(c,@"addAssertionsForAssetsWithQueries:policies:assertionIDs:clientID:",@"v48@0:8@16@24@32@40",NO);
    return [(Class<MSOwners>)c sharedInstance];
}
static void releaseDDS(NSMutableDictionary *journal,NSString *scope,NSMutableArray *details) {
    NSDictionary *baseline=ddsMap(); NSUInteger count=0; NSMutableSet *removed=[NSMutableSet new];
    for(NSString *identifier in baseline) {
        NSDictionary *item=baseline[identifier];
        if(![value(item[@"query"],@"assetType") isEqual:ddsType] || ![@[@"com.apple.DataDeliveryServices.AssetService",@"com.apple.DictionaryServices",@"com.apple.ProofReader.LinguisticData"] containsObject:item[@"client"]])continue;
        NSData *data=archive(item); NSDictionary *again=decode(data);
        require(sameDDS(again,item),@"DDS rollback roundtrip failed");
        require(sameDDS(ddsMap()[identifier],item),@"Language-data owner changed before removal");
        NSMutableDictionary *entry=record(journal,@"dds",item[@"client"],identifier,data,@{}); submitted(entry,journal,scope);
        [ddsCenter() removeAssertionWithIdentifier:identifier assetType:ddsType];
        BOOL gone=NO;for(int n=0;n<20;n++){gone=ddsMap()[identifier]==nil;if(gone)break;[NSThread sleepForTimeInterval:0.25];}
        require(gone,@"DDS owner is still present"); done(entry,journal,scope); count++;[removed addObject:identifier];
        NSDictionary *after=ddsMap();
        NSMutableSet *expected=[NSMutableSet setWithArray:baseline.allKeys];[expected minusSet:removed];
        require([expected isEqual:[NSSet setWithArray:after.allKeys]],@"Another language-data owner changed; cleanup stopped");
        for(NSString *key in expected)require(sameDDS(baseline[key],after[key]),@"Another language-data request changed; cleanup stopped");
    }
    [details addObject:[NSString stringWithFormat:@"Released %lu unused language-data requests. macOS may request them again.",(unsigned long)count]];
}
static void restore(NSMutableDictionary *journal,NSString *scope,id<MSOwners> owner,NSString *user,NSMutableArray *details) {
    for(NSMutableDictionary *entry in journal[@"entries"]) {
        if([entry[@"phase"] isEqual:@"restored"])continue;
        NSString *kind=entry[@"kind"];
        if([kind isEqual:@"uaf"]) {
            require([entry[@"user"] caseInsensitiveCompare:user]==NSOrderedSame,@"Rollback belongs to another account");
            id original=decode(entry[@"archive"]), current=apiSubscription(owner,entry[@"client"],entry[@"name"]);
            if(current) { require([facts(original) isEqual:facts(current)],@"An asset owner changed outside MacSpace; it was kept"); }
            else {
                require(!row(rows(),entry[@"client"],entry[@"name"],user),@"Owner API and database disagree; restore stopped");
                NSDate *expiry=value(original,@"expiration");
                if(!expiry || [expiry timeIntervalSinceNow]>0) {
                    require(![entry[@"phase"] isEqual:@"restoring"],@"An interrupted owner restore is still ambiguous");
                    dispatch_semaphore_t sem=dispatch_semaphore_create(0); entry[@"phase"]=@"restoring";save(journal,scope);
                    [owner subscribe:entry[@"client"] subscriptions:@[original] user:user userInitiated:YES queue:nil completion:^{dispatch_semaphore_signal(sem);}];
                    require(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0,@"Owner restore did not answer");
                    id restored=apiSubscription(owner,entry[@"client"],entry[@"name"]);
                    require(restored && [facts(original) isEqual:facts(restored)],@"Owner restore could not be verified");
                }
            }
        } else if([kind isEqual:@"tts"]) {
            NSXPCConnection *connection=ttsConnection();
            @try {
                NSArray *saved=decode(entry[@"archive"]), *before=ttsRequests(connection); NSMutableArray *current=[NSMutableArray new], *voices=[NSMutableArray new];
                for(id request in before)if([value(request,@"clientId") isEqual:entry[@"client"]])[current addObject:request];
                if(current.count) require([voiceViews(current,nil) isEqual:voiceViews(saved,nil)],@"Voice settings changed outside MacSpace; they were kept");
                else {
                    for(id request in saved){require([value(request,@"clientId") isEqual:entry[@"client"]] && !value(request,@"accessoryId"),@"Invalid saved voice owner");[voices addObject:value(request,@"voice")];}
                    require(![entry[@"phase"] isEqual:@"restoring"],@"An interrupted voice restore is still ambiguous");
                    dispatch_semaphore_t sem=dispatch_semaphore_create(0); __block NSError *error=nil;entry[@"phase"]=@"restoring";save(journal,scope);
                    id<MSOwners> proxy=[connection remoteObjectProxyWithErrorHandler:^(NSError *e){error=e;dispatch_semaphore_signal(sem);}];
                    [proxy subscribeWithVoices:voices clientId:entry[@"client"] accessoryId:nil reply:^(NSError *e){error=e;dispatch_semaphore_signal(sem);}];
                    require(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0 && !error,@"Voice restore did not answer");
                    NSArray *after=ttsRequests(connection); NSMutableArray *target=[NSMutableArray new];
                    for(id request in after)if([value(request,@"clientId") isEqual:entry[@"client"]])[target addObject:request];
                    require([voiceViews(target,nil) isEqual:voiceViews(saved,nil)] && [voiceViews(before,entry[@"client"]) isEqual:voiceViews(after,entry[@"client"])],@"Voice restore could not be verified");
                }
            } @finally {[connection invalidate];}
        } else if([kind isEqual:@"dds"]) {
            NSDictionary *saved=decode(entry[@"archive"]), *current=ddsMap()[entry[@"name"]];
            if(current)require(sameDDS(current,saved),@"Language-data settings changed outside MacSpace");
            else {
                require(![entry[@"phase"] isEqual:@"restoring"],@"An interrupted language-data restore is still ambiguous");
                entry[@"phase"]=@"restoring";save(journal,scope);
                [ddsCenter() addAssertionsForAssetsWithQueries:@[saved[@"query"]] policies:@[saved[@"policy"]] assertionIDs:@[entry[@"name"]] clientID:entry[@"client"]];
                BOOL back=NO;for(int n=0;n<20;n++){back=ddsMap()[entry[@"name"]]!=nil;if(back)break;[NSThread sleepForTimeInterval:0.25];}
                require(back && sameDDS(ddsMap()[entry[@"name"]],saved),@"Language-data restore could not be verified");
            }
        } else require(NO,@"Unknown rollback operation");
        entry[@"phase"]=@"restored"; save(journal,scope);
    }
    [details addObject:@"Saved model requests restored. macOS may download their models again."];
}

NSData *MSAssetOwners(NSString *scope,NSString *mode) {
    NSMutableArray *details=[NSMutableArray new]; NSMutableDictionary *result=[@{@"releasedOwners":@0,@"details":details,@"pending":@NO} mutableCopy];
    int lockFD=-1;
    @try {
        require([@[@"siri",@"phone",@"released"] containsObject:scope] && [@[@"inspect",@"release",@"restore"] containsObject:mode],@"Unknown owner scope or mode");
        struct stat console; require(getuid()!=0 && stat("/dev/console",&console)==0 && console.st_uid==getuid(),@"Model controls require the logged-in user's session");
        char build[128]={0};size_t length=sizeof(build); require(sysctlbyname("kern.osversion",build,&length,NULL,0)==0 && strcmp(build,"26B5112a")==0,@"Model owner controls are not verified on this macOS build");
        framework(@"/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework");
        framework(@"/System/Library/Frameworks/Speech.framework/Speech");
        framework(@"/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices");
        framework(@"/System/Library/PrivateFrameworks/DataDeliveryServices.framework/DataDeliveryServices");
        if([mode isEqual:@"inspect"]) {
            result[@"observedOwners"]=@(rows().count);
            // Metadata and queries only: verify the installed contracts before exposing a mutation on this build.
            id<MSOwners> owner=manager(); (void)owner;
            result[@"speechOff"]=@(speechOff());
            Class speech=NSClassFromString(@"SFSpeechAssetManager"),entitled=NSClassFromString(@"SFEntitledAssetManager");
            method(speech,@"unsubscribeFromAssetsWithConfigs:clientIdentifier:completionHandler:",@"v40@0:8@16@24@?32",YES);
            method(entitled,@"unsubscribeFromAssetsWithConfigs:subscriberId:completionHandler:",@"v40@0:8@16@24@?32",YES);
            method(entitled,@"subscriptionNameForConfig:",@"@24@0:8@16",YES);
            method(entitled,@"assetSetUsageForConfig:",@"@24@0:8@16",YES);
            method(NSClassFromString(@"SFEntitledAssetConfig"),@"initWithLanguage:assetType:",@"@32@0:8@16Q24",NO);
            method(NSClassFromString(@"DDSAssetCenter"),@"removeAssertionWithIdentifier:assetType:",@"v32@0:8@16@24",NO);
            method(NSClassFromString(@"DDSAssetCenter"),@"addAssertionsForAssetsWithQueries:policies:assertionIDs:clientID:",@"v48@0:8@16@24@32@40",NO);
            NSXPCConnection *connection=ttsConnection();
            @try { result[@"voiceOwners"]=@(ttsRequests(connection).count); } @finally {[connection invalidate];}
            result[@"languageDataOwners"]=@(ddsMap().count);
        }
        else {
            NSError *error=nil;
            require([NSFileManager.defaultManager createDirectoryAtPath:directory() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error],@"Cannot create owner journal folder");
            struct stat st;require(lstat(directory().UTF8String,&st)==0 && S_ISDIR(st.st_mode) && st.st_uid==getuid() && !(st.st_mode&0022),@"Unsafe owner journal folder");
            lockFD=open([directory() stringByAppendingPathComponent:@"operation.lock"].UTF8String,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
            require(lockFD>=0 && flock(lockFD,LOCK_EX|LOCK_NB)==0,@"Another model owner operation is running");
            NSMutableDictionary *journal=load(scope); NSString *user=userGUID(); id<MSOwners> owner=manager();
            if([mode isEqual:@"restore"]) restore(journal,scope,owner,user,details);
            else {
                reconcile(journal,scope,owner,user);
                if([scope isEqual:@"released"]) releaseDDS(journal,scope,details);
                else {
                    releaseSpeech(scope,journal,owner,user,details);
                    NSArray *active=releaseTTS(scope,journal,details);
                    releaseUAF(scope,journal,owner,user,active,details);
                }
            }
            NSUInteger count=0; for(NSDictionary *entry in journal[@"entries"])if([entry[@"phase"] isEqual:@"removed"])count++;
            result[@"releasedOwners"]=@(count);
        }
    } @catch(NSException *exception) { result[@"error"]=exception.reason ?: @"Model owner operation failed"; result[@"pending"]=@YES; }
    @finally { if(lockFD>=0){flock(lockFD,LOCK_UN);close(lockFD);} }
    return [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil] ?: [@"{\"error\":\"Could not encode model result\",\"pending\":true,\"releasedOwners\":0,\"details\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
}
