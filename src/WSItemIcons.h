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

/* **AN IMAGE FILE'S OWN PICTURE, FITTED INTO A SQUARE.** A file whose extension is one this tier decodes gets a
 * thumbnail instead of the generic document icon: the picture, scaled to fit a `size`-point box with its aspect ratio
 * kept and the leftover box left transparent, which is what every icon surface can draw into its square without
 * knowing anything about pictures. Nil when the file is not an image this tier can read — the caller then falls back
 * to Icon Services. */
+ (nullable NSImage *)thumbnailForPath:(NSString *)path size:(NSInteger)size;

/* Whether the path's extension is a type the tier decodes: PNG or JPEG, which is what `NSBitmapImageRep` reads. */
+ (BOOL)isImageFile:(nullable NSString *)path;

/* **WHETHER A THUMBNAIL IS ALREADY IN HAND**, which is the question a view asks before a draw that would otherwise be a
 * pile of decodes: "will this cost the person a wait?". True when either the finished thumbnail or the picture behind it
 * has been made. */
+ (BOOL)cg_hasThumbnailForPath:(nullable NSString *)path size:(NSInteger)size;

/* **HOW MANY PICTURES HAVE BEEN DECODED**, which is the number that decides whether browsing is usable: a thumbnail is
 * one decode and must not be one per draw, nor one per size. A probe counts it; nothing in the application asks. */
+ (NSInteger)cg_thumbnailDecodeCount;

@end

#endif /* WORKSPACE_WSITEMICONS_H */
