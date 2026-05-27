#import <Foundation/Foundation.h>

@interface Widget : NSObject
@property (nonatomic, copy) NSString *name;
- (instancetype)initWithName:(NSString *)name;
- (NSString *)render:(NSArray<NSString *> *)items;
@end

@implementation Widget
- (instancetype)initWithName:(NSString *)name {
  self = [super init];
  _name = [name copy];
  return self;
}
- (NSString *)render:(NSArray<NSString *> *)items {
  return [items componentsJoinedByString:@", "];
}
@end
