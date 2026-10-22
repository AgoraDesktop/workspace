/*
 * WSDesktopView.m — wallpaper, icons, and what a person does to them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * THE WALLPAPER IS W0'S, and the icons are W1's. Every position here is in TOP-LEFT SCREEN COORDINATES — the
 * space the metadata store persists and the reference file manager uses — and the conversion to Cocoa's bottom-left happens
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

#import "WSIconLabel.h"
#import "WSIconLayout.h"
#import "WSItemModel.h"
#import "WSMetadataStore.h"

#import <AppKit/NSAttributedString.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSStatusBar.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>

#import <LaunchServices/LSOpen.h>
#import <IconServices/IconServices.h>

#include <math.h>
#include <stdlib.h>

NSString *WSDesktopViewOpenFolderNotification = @"WSDesktopViewOpenFolderNotification";
NSString *WSDesktopViewPathKey = @"WSDesktopViewPath";

@implementation WSDesktopView

/* NOT OPAQUE: the window is transparent and this view draws only the icons, so the wallpaper has to show
 * through everywhere there is no icon. */
- (BOOL)isOpaque { return NO; }

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

/* **THE DESKTOP'S TOP PADDING: THE MENU BAR'S HEIGHT PLUS TEN POINTS.** The bar is a window the SERVER draws at its
 * own level, OVER the desktop, so an icon placed at the view's top edge goes UNDER it. The height comes from the
 * AppKit's own door — `NSStatusBar -thickness` — rather than a constant, so the padding follows the bar if the
 * bar's height ever changes. */
+ (CGFloat)topPadding
{
	return [[NSStatusBar systemStatusBar] thickness] + 10.0;
}

/* The area the grid lays icons out in: the whole view, less the top padding. Its ORIGIN is the area's top-left and
 * `WSIconLayout` fills from there, so the padding is the gap and not an inset the grid adds again. */
- (NSRect)layoutBounds
{
	NSRect bounds = [self bounds];
	CGFloat top = [WSDesktopView topPadding];

	return NSMakeRect(bounds.origin.x, top, bounds.size.width, bounds.size.height - top);
}

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
							     inBounds:[self layoutBounds]
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

/* **AND THE ONE PREFERENCE THE APPLICATION HAS TODAY.** The size lives in the folder's `.agora` sidecar, so a change
 * is a STORE change followed by a re-layout — and the sidecar is SAVED, because a preference that dies with the
 * process is not one. The positions a person has set are KEPT: they are absolute, and `-reload` only places the
 * items the store has no place for. */
- (void)setIconSize:(NSInteger)size
{
	if (size == [_store iconSize]) {
		return;
	}
	[_store setIconSize:size];
	[_store save];
	[self reload];
}

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
	NSArray *items = [_model items];
	NSInteger iconSize = [self iconSize];
	int i;

	(void)dirtyRect;

	/* **NO WALLPAPER HERE — ONLY WHAT IS ON THE DESKTOP.** The window is transparent and its pixels were cleared
	 * to alpha zero before the tree drew, so this view's job is the icons, their labels and the selection; the
	 * wallpaper shows through from the level below. */

	/* THE ICONS, each selected one's backing first. */
	for (i = 0; i < (int)[items count]; i++) {
		NSPoint position = [[_positions objectAtIndex:i] pointValue];
		NSRect iconRect = [self cocoaRectForPosition:position
							size:NSMakeSize((CGFloat)iconSize, (CGFloat)iconSize)];
		NSBitmapImageRep *rep;
		NSString *label;
		NSSize labelSize;
		NSSize cell = [WSIconLayout cellSizeForIconSize:iconSize];
		NSDictionary *attributes;
		NSRect labelRect;
		/* **THE BAND IS THE CELL'S WIDTH CENTRED ON THE ICON, NOT THE CELL.** The cell starts at the icon and carries
		 * its padding to the right, so a name cut to the cell's width and centred on the cell sat a padded half-cell to
		 * the right of the folder it named — the same off-centre the icon view had. The band is what the label is
		 * clipped to, so nothing has to be shaved off the left of a centred name. */
		NSRect labelBand = [self cocoaRectForPosition:NSMakePoint(
					  position.x - (cell.width - (CGFloat)iconSize) / 2.0,
					  position.y + (CGFloat)iconSize)
					  size:NSMakeSize(cell.width, (CGFloat)WSIconLabelHeight)];
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

		/* THE LABEL under it, in the desktop's own ink, CENTRED ON THE ICON — and the arithmetic below is the ICON's
		 * centre, not the cell's, because the cell carries its padding to the right. **`-drawInRect:withAttributes:`
		 * DOES NOT HONOUR A PARAGRAPH STYLE'S ALIGNMENT** — MEASURED: this tree's `NSStringDrawing.m` never mentions
		 * alignment at all, which is why `NSCenterTextAlignment` left the text exactly where it was. So the centring
		 * is GEOMETRIC: measure the string, and hand `-drawInRect:` a rectangle exactly as wide as the text, whose
		 * LEFT edge is the icon's centre minus half the text's width. */
		label = [[items objectAtIndex:i] name];
		attributes = [NSDictionary dictionaryWithObjectsAndKeys:
				[NSColor whiteColor], NSForegroundColorAttributeName,
				nil];
		label = WSIconLabelText(label, cell.width - 4.0, attributes);
		labelSize = [label sizeWithAttributes:attributes];
		/* **THE RECT IS ROUNDED UP, BECAUSE A RECT EXACTLY AS WIDE AS THE ADVANCE CLIPS THE LAST GLYPH** — the same
		 * fractional clipping the clock and the AppKit cells round. The label is still cut to the cell's width, so a
		 * point of rounding cannot spill into the neighbour. */
		{
			CGFloat labelWidth = ceil(labelSize.width);

			labelRect = [self cocoaRectForPosition:NSMakePoint(
							position.x + ((CGFloat)iconSize - labelWidth) / 2.0,
							position.y + (CGFloat)iconSize)
						  size:NSMakeSize(labelWidth, (CGFloat)WSIconLabelHeight)];
		}
		[NSGraphicsContext saveGraphicsState];
		[[NSBezierPath bezierPathWithRect:labelBand] addClip];
		[label drawInRect:labelRect withAttributes:attributes];
		[NSGraphicsContext restoreGraphicsState];
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
						     inBounds:[self layoutBounds]
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
 * `LSOpenCFURLRef`, F1); a FOLDER is a file window, and the APPLICATION makes it. The desktop asks rather than
 * building one: a folder is a navigation surface, and this view's job is the icon that was clicked. */
- (void)openItemAtIndex:(NSUInteger)index
{
	WSItem *item = [[_model items] objectAtIndex:index];
	CFStringRef path = CFStringCreateWithCString(NULL, [[item path] UTF8String], kCFStringEncodingUTF8);
	CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, [item isDirectory] ? true : false);

	CFRelease(path);
	if ([item isDirectory]) {
		NSDictionary *info = [NSDictionary dictionaryWithObject:[item path] forKey:WSDesktopViewPathKey];

		CFRelease(url);
		[[NSNotificationCenter defaultCenter] postNotificationName:WSDesktopViewOpenFolderNotification
								    object:self userInfo:info];
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
