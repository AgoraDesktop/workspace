/*
 * WSItemIcons.h — an item's icon as an AppKit image, in one place.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **ICON SERVICES ANSWERS A `CGImageRef`; THE APPKIT WANTS AN `NSImage`.** The conversion is one function, and the
 * desktop, the sidebar and the file window's icon view all ask it rather than each carrying its own copy of the
 * CFURL/IconRef dance. Caching stays with the caller, because what is cached is per view (the desktop caches by
 * item, the icon view by index) rather than a property of the lookup.
 */
#ifndef WORKSPACE_WSITEMICONS_H
#define WORKSPACE_WSITEMICONS_H

#import <Foundation/NSObject.h>

@class NSImage;
@class NSString;

@interface WSItemIcons : NSObject

/* Nil when Icon Services has nothing for the path; a caller draws what it has rather than a placeholder. */
+ (NSImage *)iconForPath:(NSString *)path isDirectory:(BOOL)isDirectory size:(NSInteger)size;

@end

#endif /* WORKSPACE_WSITEMICONS_H */
