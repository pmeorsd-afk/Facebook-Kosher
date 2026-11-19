// Model-level content filtering for Facebook Kosher (called from FBPFeedHooks.xm).

#import "FBPlus.h"
#import "FBPKosherTypes.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Evaluates an FBMemModelObject / Pando model at construction time.
/// Returning YES instructs FBPFeedHooks.xm to drop the model before rendering.
extern BOOL FBPKosherShouldFilterModel(id model);

#ifdef __cplusplus
}
#endif

/// Objective-C interface for testing model metadata extraction and filtering logic.
@interface FBPKosherContentFilter : NSObject

+ (BOOL)shouldFilterModel:(nullable id)model;

@end

NS_ASSUME_NONNULL_END
