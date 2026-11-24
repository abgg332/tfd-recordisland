#import "TFDConfig.h"

NSDictionary *TFDReadSettings(NSString *prefix) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:TFD_PREF_DOMAIN];
    NSString *p = prefix ?: @"";
    NSString *asset = [d stringForKey:[p stringByAppendingString:TFD_KEY_ASSET]];
    if (!asset.length) asset = [d stringForKey:TFD_KEY_ASSET];
    return @{
        @"enabled": @([d objectForKey:[p stringByAppendingString:TFD_KEY_ENABLED]]
                      ? [d boolForKey:[p stringByAppendingString:TFD_KEY_ENABLED]]
                      : [d boolForKey:TFD_KEY_ENABLED]),
        @"asset": asset ?: @"",
        @"fps": @([d objectForKey:[p stringByAppendingString:TFD_KEY_FPS]]
                  ? [d doubleForKey:[p stringByAppendingString:TFD_KEY_FPS]] : 60.0),
        @"rotation": @([d boolForKey:[p stringByAppendingString:TFD_KEY_ROTATION]]),
        @"rotationReverse": @([d boolForKey:[p stringByAppendingString:TFD_KEY_ROTATION_REV]]),
        @"rotationSpeed": @([d objectForKey:[p stringByAppendingString:TFD_KEY_ROTATION_FPS]]
                            ? [d doubleForKey:[p stringByAppendingString:TFD_KEY_ROTATION_FPS]] : 5.0),
        @"scale": @([d objectForKey:[p stringByAppendingString:TFD_KEY_SCALE]]
                    ? [d doubleForKey:[p stringByAppendingString:TFD_KEY_SCALE]] : 1.0),
        @"offsetX": @([d objectForKey:[p stringByAppendingString:TFD_KEY_OFFSET_X]]
                      ? [d doubleForKey:[p stringByAppendingString:TFD_KEY_OFFSET_X]] : 0.0),
        @"offsetY": @([d objectForKey:[p stringByAppendingString:TFD_KEY_OFFSET_Y]]
                      ? [d doubleForKey:[p stringByAppendingString:TFD_KEY_OFFSET_Y]] : 0.0),
        @"hideSiblings": @([d objectForKey:[p stringByAppendingString:TFD_KEY_HIDE_SIBLINGS]]
                           ? [d boolForKey:[p stringByAppendingString:TFD_KEY_HIDE_SIBLINGS]] : YES),
    };
}
