#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runs only in the signed CLI child. Fixed scopes: siri, phone, released. Fixed modes: inspect, release, restore.
NSData *MSAssetOwners(NSString *scope, NSString *mode);
NS_ASSUME_NONNULL_END
