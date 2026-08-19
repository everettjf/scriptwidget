//
//  TOCropWidgetSizeHelper.m
//  ScriptWidget
//
//  Created by everettjf on 2020/11/9.
//

#import "TOCropWidgetSizeHelper.h"

@implementation TOCropWidgetSize

@end

@implementation TOCropWidgetSizeHelper

+ (instancetype)shared {
    static TOCropWidgetSizeHelper *obj;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [[TOCropWidgetSizeHelper alloc] init];
    });
    return obj;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self prepareData];
    }
    return self;
}

/**
 https://developer.apple.com/design/human-interface-guidelines/ios/system-capabilities/widgets
 */
- (void)prepareData {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    NSString *screenSize = [NSString stringWithFormat:@"%@x%@",@(screen.width),@(screen.height)];
    
    self.prop = [[TOCropWidgetSize alloc] init];
    if ([screenSize isEqualToString:@"414x896"]) {
        self.prop.small = CGSizeMake(169, 169);
        self.prop.medium = CGSizeMake(360, 169);
        self.prop.large = CGSizeMake(360, 376);
    } else if ([screenSize isEqualToString:@"375x812"]) {
        self.prop.small = CGSizeMake(155, 155);
        self.prop.medium = CGSizeMake(329, 155);
        self.prop.large = CGSizeMake(329, 345);
    } else if ([screenSize isEqualToString:@"414x736"]) {
        self.prop.small = CGSizeMake(159, 159);
        self.prop.medium = CGSizeMake(348, 159);
        self.prop.large = CGSizeMake(348, 357);
    } else if ([screenSize isEqualToString:@"375x667"]) {
        self.prop.small = CGSizeMake(148, 148);
        self.prop.medium = CGSizeMake(322, 148);
        self.prop.large = CGSizeMake(322, 324);
    } else if ([screenSize isEqualToString:@"320x568"]) {
        self.prop.small = CGSizeMake(141, 141);
        self.prop.medium = CGSizeMake(291, 141);
        self.prop.large = CGSizeMake(291, 299);
    } else {
        self.prop.small = CGSizeMake(169, 169);
        self.prop.medium = CGSizeMake(360, 169);
        self.prop.large = CGSizeMake(360, 376);
    }
}


@end


@implementation WidgetSizeHelper

+ (CGSize)small {
    return [TOCropWidgetSizeHelper shared].prop.small;
}

+ (CGSize)medium {
    return [TOCropWidgetSizeHelper shared].prop.medium;
}

+ (CGSize)large {
    return [TOCropWidgetSizeHelper shared].prop.large;
}

+ (CGSize)extraLarge {
    return CGSizeMake(720, 338);
}
+ (CGSize)extraLargePortrait {
    return CGSizeMake(360, 668);
}
+ (CGSize)accessoryInline {
    return CGSizeMake(1044/3, 92/3);
}
+ (CGSize)accessoryCircular {
    return CGSizeMake(218/3, 218/3);
}
+ (CGSize)accessoryRectangular {
    return CGSizeMake(486/3, 212/3);
}

+ (CGSize)size:(int)type {
    switch(type) {
        case 0: return [self small];
        case 1: return [self medium];
        case 2: return [self large];
        case 3: return [self extraLarge];
        case 4: return [self accessoryInline];
        case 5: return [self accessoryCircular];
        case 6: return [self accessoryRectangular];
        case 8: return [self extraLargePortrait];
        default: return [self small];
    }
}

@end
