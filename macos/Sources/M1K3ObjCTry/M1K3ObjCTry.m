//
//  M1K3ObjCTry.m
//  M1K3ObjCTry
//
//  See the header. Signed there.
//

#import "M1K3ObjCTry.h"

NSString *_Nullable M1K3TryObjC(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}
