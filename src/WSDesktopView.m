/*
 * WSDesktopView.m — wallpaper, icons, and what a person does to them.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * THE WALLPAPER IS W0'S, and the icons are W1's. Every position here is in TOP-LEFT SCREEN COORDINATES — the
 * space the metadata store persists and the Finder uses — and the conversion to Cocoa's bottom-left happens
 * only where something is drawn or hit-tested.
 *
 * AN ICON IS AN `IconRef` (libagora-iconservices, F2): the item's URL goes in and a `CGImageRef` comes out, and
 * the image is wrapped in an `NSBitmapImageRep` so the AppKit can draw it. The reps are CACHED per item, because
 * making one walks the type registry and draws a generic the first time.
 *
 * THE REPRESENTATION IS THE ITEM'S OWN, NOT ITS TYPE'S YET. `AGIconCreateWithURL` already prefers an
 * application bundle's declared icon and falls back to the type's generic; a document's own icon (its content,
 * not its type) is a later step.
 */
#import "WSDesktopView.h"

#import "WSIconLayout.h"
#import "WSItemModel.h"
#import "WSMetadataStore.h"

#import <AppKit/NSAttributedString.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSParagraphStyle.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>

#import <LaunchServices/LSOpen.h>
#import <IconServices/IconServices.h>

#include <stdlib.h>

/* The wallpaper, from ARGENTUM.md's own two samples (top amber, bottom near-black). */
#define WALLPAPER_TOP_R		108.0
#define WALLPAPER_TOP_G		 55.0
#define WALLPAPER_TOP_B		 29.0
#define WALLPAPER_BOTTOM_R	 18.0
#define WALLPAPER_BOTTOM_G	 14.0
#define WALLPAPER_BOTTOM_B	  5.0
#define WALLPAPER_BANDS		 64

@implementation WSDesktopView

- (instancetype)initWithFrame:(NSRect)frame directory:(NSString *)directory
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_model = [[WSItemModel alloc] initWithDirectory:directory];
		_store = [[WSMetadataStore storeForDirectory:directory] retain];
		_positions = [[NSMutableArray alloc] init];
		_icons = [[NSMutableArray alloc] init];
		_selection = [[NSMutableArray alloc] init];
		[self reload];
	}
	return self;
}

- (NSString *)directory { return [_model directory]; }

/* Give every item a place: the one the store remembers, or the next free grid cell. */
- (void)reload
{
	NSArray *items;
	NSMutableArray *positions = [[NSMutableArray alloc] init];
	NSUInteger i;
	NSInteger iconSize = [_store iconSize];

	[_model reload];
	items = [_model items];
	for (i = 0; i < [items count]; i++) {
		WSItem *item = [items objectAtIndex:i];
		NSPoint position;

		if ([_store hasIconPositionForName:[item name]]) {
			position = [_store iconPositionForName:[item name]];
		} else {
			position = [WSIconLayout gridPositionForIndex:(NSInteger)i
							     inBounds:[self bounds]
							     iconSize:iconSize];
		}
		[positions addObject:[NSValue valueWithPoint:position]];
	}
	[_positions release];
	_positions = positions;
	[_icons removeAllObjects];
	for (i = 0; i < [items count]; i++) [_icons addObject:[NSNull null]];
	[_selection removeAllObjects];
	[self setNeedsDisplay:YES];
}

- (NSInteger)iconSize { return [_store iconSize]; }

/* COCOA'S ORIGIN IS BOTTOM-LEFT AND THE STORED POSITION'S IS TOP-LEFT, so every rectangle is converted in the
 * one place that knows the view is not flipped. */
- (NSRect)cocoaRectForPosition:(NSPoint)position size:(NSSize)size
{
	return NSMakeRect(position.x, [self bounds].size.height - position.y - size.height,
			  size.width, size.height);
}

- (NSPoint)topLeftPointForEvent:(NSEvent *)event
{
	NSPoint cocoa = [self convertPoint:[event locationInWindow] fromView:nil];

	return NSMakePoint(cocoa.x, [self bounds].size.height - cocoa.y);
}

/* THE ICON, MADE ONCE. A `CGImage` from Icon Services wrapped in a rep; NSNull while it has not been needed. */
- (NSBitmapImageRep *)iconRepForItemAtIndex:(NSUInteger)index
{
	id cached = [_icons objectAtIndex:index];
	WSItem *item;
	CFStringRef path;
	CFURLRef url;
	IconRef icon;
	CGImageRef image;
	NSBitmapImageRep *rep;
	NSInteger size = [self iconSize];

	if (cached != [NSNull null]) return cached;

	item = [[_model items] objectAtIndex:index];
	path = CFStringCreateWithCString(NULL, [[item path] UTF8String], kCFStringEncodingUTF8);
	url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, [item isDirectory] ? true : false);
	CFRelease(path);

	icon = AGIconCreateWithURL(url);
	CFRelease(url);
	if (icon == NULL) return nil;
	image = AGIconCopyImage(icon, CGSizeMake((CGFloat)size, (CGFloat)size));
	AGIconRelease(icon);
	if (image == NULL) return nil;

	rep = [NSBitmapImageRep imageRepWithCGImage:image];
	CGImageRelease(image);
	if (rep != nil) [_icons replaceObjectAtIndex:index withObject:rep];
	return rep;
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	CGFloat width = bounds.size.width;
	CGFloat height = bounds.size.height;
	CGFloat band = height / (CGFloat)WALLPAPER_BANDS;
	NSArray *items = [_model items];
	NSInteger iconSize = [self iconSize];
	int i;

	(void)dirtyRect;

	/* 1. THE WALLPAPER. */
	for (i = 0; i < WALLPAPER_BANDS; i++) {
		CGFloat t = (CGFloat)i / (CGFloat)(WALLPAPER_BANDS - 1);
		CGFloat red = (WALLPAPER_TOP_R + (WALLPAPER_BOTTOM_R - WALLPAPER_TOP_R) * t) / 255.0;
		CGFloat green = (WALLPAPER_TOP_G + (WALLPAPER_BOTTOM_G - WALLPAPER_TOP_G) * t) / 255.0;
		CGFloat blue = (WALLPAPER_TOP_B + (WALLPAPER_BOTTOM_B - WALLPAPER_TOP_B) * t) / 255.0;

		[[NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0] setFill];
		[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, height - (CGFloat)(i + 1) * band, width, band + 1.0)]
			fill];
	}

	/* 2. THE ICONS, each selected one's backing first. */
	for (i = 0; i < (int)[items count]; i++) {
		NSPoint position = [[_positions objectAtIndex:i] pointValue];
		NSRect iconRect = [self cocoaRectForPosition:position
							size:NSMakeSize((CGFloat)iconSize, (CGFloat)iconSize)];
		NSBitmapImageRep *rep;
		NSMutableParagraphStyle *paragraph;
		NSDictionary *attributes;
		NSRect labelRect;
		NSUInteger s;

		for (s = 0; s < [_selection count]; s++) {
			if ([[_selection objectAtIndex:s] integerValue] == (NSInteger)i) break;
		}
		if (s < [_selection count]) {
			[[NSColor colorWithCalibratedRed:0.30 green:0.50 blue:0.90 alpha:0.35] setFill];
			[[NSBezierPath bezierPathWithRect:NSInsetRect(iconRect, -4.0, -4.0)] fill];
		}

		rep = [self iconRepForItemAtIndex:(NSUInteger)i];
		if (rep != nil) [rep drawInRect:iconRect];

		/* 3. THE LABEL under it, in the desktop's own ink. */
		labelRect = [self cocoaRectForPosition:NSMakePoint(position.x - (CGFloat)WSIconPadding,
								   position.y + (CGFloat)iconSize)
						  size:NSMakeSize((CGFloat)iconSize + 2.0 * (CGFloat)WSIconPadding,
								  (CGFloat)WSIconLabelHeight)];
		paragraph = [[NSMutableParagraphStyle alloc] init];
		attributes = [NSDictionary dictionaryWithObjectsAndKeys:
				[NSColor whiteColor], NSForegroundColorAttributeName,
				paragraph, NSParagraphStyleAttributeName,
				nil];
		[[[items objectAtIndex:i] name] drawInRect:labelRect withAttributes:attributes];
		[paragraph release];
	}
}

/* ---- the mouse ---------------------------------------------------------------------------------- */

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self topLeftPointForEvent:event];
	NSInteger index = [WSIconLayout indexOfPosition:point among:_positions iconSize:[self iconSize]];
	BOOL shift = ([event modifierFlags] & NSShiftKeyMask) != 0;

	_moved = NO;
	_dragLast = point;
	_rubberBanding = NO;

	if (index < 0) {
		if (!shift) [_selection removeAllObjects];
		_rubberBanding = YES;
		_rubberStart = point;
		_rubberRect = NSMakeRect(point.x, point.y, 0.0, 0.0);
		[self setNeedsDisplay:YES];
		return;
	}

	if ([event clickCount] >= 2) {
		[self openItemAtIndex:(NSUInteger)index];
		return;
	}

	if (!shift) {
		NSUInteger s;
		BOOL already = NO;

		for (s = 0; s < [_selection count]; s++)
			if ([[_selection objectAtIndex:s] integerValue] == index) already = YES;
		if (!already) [_selection removeAllObjects];
	}
	[self addToSelection:index];
	_dragging = YES;
	[self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point = [self topLeftPointForEvent:event];

	if (_rubberBanding) {
		_rubberRect = NSMakeRect(point.x < _rubberStart.x ? point.x : _rubberStart.x,
					 point.y < _rubberStart.y ? point.y : _rubberStart.y,
					 (CGFloat)labs((long)(point.x - _rubberStart.x)),
					 (CGFloat)labs((long)(point.y - _rubberStart.y)));
		[self setNeedsDisplay:YES];
		return;
	}
	if (_dragging) {
		CGFloat dx = point.x - _dragLast.x;
		CGFloat dy = point.y - _dragLast.y;
		NSUInteger s;

		/* Every SELECTED icon moves together, which is what makes a drag of a group one gesture. */
		for (s = 0; s < [_selection count]; s++) {
			NSInteger index = [[_selection objectAtIndex:s] integerValue];
			NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];

			position.x += dx;
			position.y += dy;
			[_positions replaceObjectAtIndex:(NSUInteger)index withObject:[NSValue valueWithPoint:position]];
		}
		_dragLast = point;
		_moved = YES;
		[self setNeedsDisplay:YES];
	}
}

- (void)mouseUp:(NSEvent *)event
{
	(void)event;
	if (_rubberBanding) {
		NSUInteger i;

		for (i = 0; i < [_positions count]; i++) {
			NSPoint position = [[_positions objectAtIndex:i] pointValue];
			NSRect rect = [WSIconLayout iconRectAtPosition:position iconSize:[self iconSize]];

			if (NSIntersectsRect(rect, _rubberRect)) [self addToSelection:(NSInteger)i];
		}
		_rubberBanding = NO;
		[self setNeedsDisplay:YES];
		return;
	}
	if (_dragging) {
		if (_moved) [self snapSelectionToGridAndPersist];
		_dragging = NO;
	}
}

- (void)addToSelection:(NSInteger)index
{
	NSUInteger s;

	for (s = 0; s < [_selection count]; s++)
		if ([[_selection objectAtIndex:s] integerValue] == index) return;
	[_selection addObject:[NSNumber numberWithInteger:index]];
}

/* Snap what was dragged to the free cells nearest where it was left, then write the sidecar. */
- (void)snapSelectionToGridAndPersist
{
	NSMutableArray *occupied = [[NSMutableArray alloc] init];
	NSUInteger i, s;

	for (i = 0; i < [_positions count]; i++) {
		BOOL selected = NO;

		for (s = 0; s < [_selection count]; s++)
			if ([[_selection objectAtIndex:s] integerValue] == (NSInteger)i) selected = YES;
		if (!selected) [occupied addObject:[_positions objectAtIndex:i]];
	}
	for (s = 0; s < [_selection count]; s++) {
		NSInteger index = [[_selection objectAtIndex:s] integerValue];
		WSItem *item = [[_model items] objectAtIndex:(NSUInteger)index];
		NSPoint position = [WSIconLayout snapPosition:[[_positions objectAtIndex:(NSUInteger)index] pointValue]
						     inBounds:[self bounds]
						     iconSize:[self iconSize]
						     avoiding:occupied];

		[_positions replaceObjectAtIndex:(NSUInteger)index withObject:[NSValue valueWithPoint:position]];
		[occupied addObject:[NSValue valueWithPoint:position]];
		[_store setIconPosition:position forName:[item name]];
	}
	[occupied release];
	[_store save];
}

/* Double-click. An application bundle launches; a document opens in its default application (both are
 * `LSOpenCFURLRef`, F1). A FOLDER is not handled yet — opening one is a Finder WINDOW, which is W2. */
- (void)openItemAtIndex:(NSUInteger)index
{
	WSItem *item = [[_model items] objectAtIndex:index];
	CFStringRef path = CFStringCreateWithCString(NULL, [[item path] UTF8String], kCFStringEncodingUTF8);
	CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, [item isDirectory] ? true : false);

	CFRelease(path);
	if ([item isDirectory]) {
		/* NO WINDOW TO OPEN IT IN YET, and it is said here rather than failing silently in the launcher. */
		fprintf(stderr, "workspace: a folder was double-clicked; opening one is W2 (%s)\n", [[item name] UTF8String]);
		CFRelease(url);
		return;
	}
	LSOpenCFURLRef(url, NULL);
	CFRelease(url);
}

- (void)dealloc
{
	[_model release];
	[_store release];
	[_positions release];
	[_icons release];
	[_selection release];
	[super dealloc];
}

@end
