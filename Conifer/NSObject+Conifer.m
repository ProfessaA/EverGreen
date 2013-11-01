#import "NSObject+Conifer.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSString * const ConiferStubException = @"ConiferStubException";

const char *stubbedMethodsKey = "stubbedMethodsKey";
const char *isStubbedKey = "isStubbedKey";

#pragma mark - Helper Functions

SEL stubbedSelectorForSelector(SEL selector)
{
    NSString *selectorString = NSStringFromSelector(selector);
    selectorString = [selectorString stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                             withString:[[selectorString substringToIndex:1] uppercaseString]];
    return NSSelectorFromString([@"_stubbed" stringByAppendingString:selectorString]);
}

SEL originalMethodSelectorForSelector(SEL selector)
{
    NSString *selectorString = NSStringFromSelector(selector);
    selectorString = [selectorString stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                             withString:[[selectorString substringToIndex:1] uppercaseString]];
    return NSSelectorFromString([@"_original" stringByAppendingString:selectorString]);
}

id stubBlockForSelectorWithMethodSignature(SEL selector, NSMethodSignature *signature)
{
    SEL stubbedSEL = stubbedSelectorForSelector(selector);
    return ^void* (id me, ...) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setSelector:stubbedSEL];
        
        va_list args;
        va_start(args, me);
        NSUInteger numArguments = [signature numberOfArguments];
        for (int i = 2; i < numArguments; i++) {
            void *arg = va_arg(args, void *);
            [invocation setArgument:&arg atIndex:i];
        }
        va_end(args);
        
        [invocation invokeWithTarget:me];
        NSString *retType = [NSString stringWithUTF8String:[signature methodReturnType]];
        if ([retType isEqualToString:@"v"]) return nil;
        
        void *retVal;
        [invocation getReturnValue:&retVal];
        return retVal;
    };
}

void stubSelectorFromSourceClassOnDestinationClass(SEL selector, Class sourceClass, Class destinationClass)
{
    Method originalMethod = class_getInstanceMethod(sourceClass, selector);
    const char *methodTypes = method_getTypeEncoding(originalMethod);
    
    SEL stubbedSEL = stubbedSelectorForSelector(selector);
    IMP defaultStub = imp_implementationWithBlock(^ { return nil; });
    class_addMethod(destinationClass, stubbedSEL, defaultStub, methodTypes);
    
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:methodTypes];
    IMP stubIMP = imp_implementationWithBlock(stubBlockForSelectorWithMethodSignature(selector, signature));
    class_replaceMethod(destinationClass, selector, stubIMP, methodTypes);
}

@implementation NSObject (Conifer)

#pragma mark - Querying Stubbed Objects

- (BOOL)isStubbingMethod:(SEL)selector
{
    return [[self stubbedMethods] containsObject:NSStringFromSelector(selector)];
}

- (BOOL)isStubbingMethods
{
    return [objc_getAssociatedObject(self, isStubbedKey) boolValue];
}

#pragma mark - Creating Initial Stub

- (CONStub *)stub:(SEL)selector
{
    if (![self isStubbingMethod:selector]) {
        if (![self isStubbingMethods]) [self _stub];
        
        objc_setAssociatedObject(self,
                                 stubbedMethodsKey,
                                 [@[NSStringFromSelector(selector)] arrayByAddingObjectsFromArray:[self stubbedMethods]],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        stubSelectorFromSourceClassOnDestinationClass(selector,
                                                      class_getSuperclass(object_getClass(self)),
                                                      object_getClass(self));
        
    }
    
    return [[CONStub alloc] initWithObject:self
                          originalSelector:selector
                              stubSelector:stubbedSelectorForSelector(selector)];
}

+ (void)_stub
{
    [self createStubClass];
}

- (void)_stub
{
    [self createStubClass];
    
    Class originalClass = class_getSuperclass(object_getClass(self));
    IMP classIMP = imp_implementationWithBlock(^{ return originalClass; });
    class_addMethod(object_getClass(self), @selector(class), classIMP, "@@:");
}

#pragma mark - Unstubbing

- (void)unstub
{
    if (![self isStubbingMethods]) {
        [NSException raise:ConiferStubException
                    format:@"You tried to unstub an instance that was never stubbed: %@", self];
    }
    
    Class StubClass = object_getClass(self);
    object_setClass(self, class_getSuperclass(StubClass));
    objc_disposeClassPair(StubClass);
    
    objc_setAssociatedObject(self, isStubbedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, stubbedMethodsKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

# pragma mark - Private

- (NSArray *)stubbedMethods
{
    return objc_getAssociatedObject(self, stubbedMethodsKey);
}

- (void)createStubClass
{
    NSString *objectMetaClassName = [NSString stringWithFormat:@"%@%p", NSStringFromClass([self class]), self];
    Class objectMetaClass = objc_allocateClassPair(object_getClass(self), [objectMetaClassName UTF8String], 0);
    if (!objectMetaClass) [NSException raise:ConiferStubException format:@"an error occurred when attempting to stub %@", self];
    
    objc_registerClassPair(objectMetaClass);
    object_setClass(self, objectMetaClass);
    objc_setAssociatedObject(self, isStubbedKey, [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
