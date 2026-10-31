/*
 * WSDesktopView.m — wallpaper, icons, and what a person does to them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
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

#import "WSIconCell.h"
#import "WSIconLabel.h"
#import "WSIconLayout.h"
#import "WSSelectionBand.h"
#import "WSSelectionOwner.h"
#import "WSItemIcons.h"
#import "WSItemModel.h"
#import "WSMetadataStore.h"

#import <AppKit/NSWindow.h>

/* The pointer, taken for the length of the band — see `WSIconView.m`'s declaration of the same door. */
@interface NSWindow (APPKITDesktopBandCapture)
- (void)cg_setPointerCapture:(BOOL)flag;
@end

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
		/* **AND THE DESKTOP HEARS WHEN A WINDOW TAKES THE SELECTION** — see `WSSelectionOwner.h`. */
		[[NSNotificationCenter defaultCenter] addObserver:self
							 selector:@selector(fn_selectionHeldElsewhere:)
							     name:WSSelectionDidChangeNotification
							   object:nil];
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

/* THE ICON, MADE ONCE. `NSNull` while it has not been needed.
 *
 * **THE SAME LOOKUP THE FILE WINDOW MAKES, THROUGH `WSItemIcons`.** This view used to carry its own copy of the
 * CFURL/IconRef dance, which is a second place for two surfaces to disagree about what an icon is — and a second thing
 * to fix when the resolver learns something. */
- (NSImage *)iconRepForItemAtIndex:(NSUInteger)index
{
	id cached = [_icons objectAtIndex:index];
	WSItem *item;
	NSImage *image;

	if (cached != [NSNull null]) {
		return cached;
	}
	item = [[_model items] objectAtIndex:index];
	image = [WSItemIcons iconForPath:[item path] isDirectory:[item isDirectory] size:[self iconSize]];
	if (image != nil) {
		[_icons replaceObjectAtIndex:index withObject:image];
	}
	return image;
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

	/* **THE SAME CELL A FILE WINDOW DRAWS**, through `WSIconCell`: the wash is the highlight rectangle the two surfaces
	 * share, the ring comes with the keyboard's focus, and only the INK is this view's own — white, because what is behind
	 * the name is a wallpaper and not a white page. Before this the wash was a square four points outside the icon,
	 * unrounded and stopping above the name, so a desktop selection was not recognisably the same gesture as a file
	 * window's. */
	for (i = 0; i < (int)[items count]; i++) {
		NSPoint position = [[_positions objectAtIndex:i] pointValue];
		NSRect iconRect = [self cocoaRectForPosition:position
							size:NSMakeSize((CGFloat)iconSize, (CGFloat)iconSize)];
		NSSize cellSize = [WSIconLayout cellSizeForIconSize:iconSize];
		NSRect highlight = WSIconCellHighlightRect(iconRect, cellSize.width, NO);
		NSDictionary *attributes;
		WSIconCell cell;
		BOOL selected = NO;
		NSUInteger s;

		if (!NSIsEmptyRect(dirtyRect) && !NSIntersectsRect(dirtyRect, highlight)) {
			continue;	/* the highlight holds everything this item draws, so it is the unit of work */
		}
		for (s = 0; s < [_selection count]; s++) {
			if ([[_selection objectAtIndex:s] integerValue] == (NSInteger)i) {
				selected = YES;
				break;
			}
		}
		attributes = [NSDictionary dictionaryWithObjectsAndKeys:[NSColor whiteColor],
							  NSForegroundColorAttributeName, nil];

		cell.iconRect = iconRect;
		cell.cellWidth = cellSize.width;
		cell.labelBelow = NO;	/* this view is unflipped: the name hangs toward the foot of the screen */
		cell.icon = [self iconRepForItemAtIndex:(NSUInteger)i];
		cell.label = WSIconLabelText([[items objectAtIndex:i] name], cellSize.width - 4.0, attributes);
		cell.attributes = attributes;
		cell.selected = selected;
		/* **THE DESKTOP WEARS THE RING TOO, AND IT HAS TO EARN IT**: this view had no `-acceptsFirstResponder` and its
		 * press never made it first responder, so a click on an icon left the keyboard with another window and the
		 * selected cell was drawn as though nothing had the focus. See `-mouseDown:`. */
		cell.focused = ([[self window] firstResponder] == self);
		WSIconCellDraw(cell);
	}

	/* **THE BAND IS DRAWN LAST, OVER THE ICONS IT IS TAKING.** It is a pointer's footprint, and a wash drawn under the
	 * icons would leave them looking untaken until the mouse came up. */
	if (_rubberBanding) {
		WSSelectionBandDraw([self cocoaRectForPosition:_rubberRect.origin size:_rubberRect.size]);
	}
}

/* ---- the mouse ---------------------------------------------------------------------------------- */

/* **THE BAND AND THE SELECTION, AS A PROBE ASKS FOR THEM** — `NSZeroRect` and an empty array when there is neither,
 * which is also what the view answers before the first press. */
- (NSRect)cg_bandRect
{
	return _rubberBanding ? _rubberRect : NSZeroRect;
}

- (NSArray *)cg_selection
{
	return _selection;
}

- (NSArray *)cg_positions
{
	return _positions;
}

/* **THE HIGHLIGHT, AS A PROBE ASKS FOR IT** — the same rectangle the drawing fills and outlines, in the view's own
 * (unflipped) space, so a test can compare it with a file window's rather than compare screenshots. */
- (NSRect)cg_highlightRectAtIndex:(NSInteger)index
{
	NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];
	NSSize cell = [WSIconLayout cellSizeForIconSize:[self iconSize]];

	return WSIconCellHighlightRect([self cocoaRectForPosition:position
							    size:NSMakeSize((CGFloat)[self iconSize],
									    (CGFloat)[self iconSize])],
				       cell.width, NO);
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self topLeftPointForEvent:event];
	/* **A PRESS ON THE DESKTOP TAKES THE KEYBOARD, AS A PRESS ON AN ICON IN A WINDOW DOES.** Without it the desktop
	 * never became first responder, so its selected cell could never show the focus ring and the arrow keys and
	 * type-select went to the window that happened to hold the keyboard. */
	[[self window] makeFirstResponder:self];
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
		/* The compositor sends motion to the surface under the pointer, so the desktop takes it for the gesture: a band
		 * dragged across the Dock or off the screen's edge keeps following the hand and ends when it is let go. */
		[[self window] cg_setPointerCapture:YES];
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
		[[self window] cg_setPointerCapture:NO];
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
	/* **THE DESKTOP IS ONE OF THE SURFACES THAT SHARE THE SELECTION** — every press that chooses an icon comes through
	 * here, so this is the one place the claim has to be made. A desktop that cleared itself (a press on the wallpaper)
	 * comes through nothing and stays silent, which is what keeps the window next door's selection standing. */
	[[NSNotificationCenter defaultCenter] postNotificationName:WSSelectionDidChangeNotification object:self];
}

/* **A WINDOW TOOK THE SELECTION, SO THE DESKTOP LETS GO.** Repaint everything: the whole surface is the highlight's, and
 * one repaint per claim is cheaper than walking the icons the claim took. */
- (void)fn_selectionHeldElsewhere:(NSNotification *)note
{
	if ([note object] == self || [_selection count] == 0) {
		return;
	}
	[_selection removeAllObjects];
	[self setNeedsDisplay:YES];
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
 * building one: a folder is a navigation surface, and this view's job is the icon that was clicked. A PACKAGE is
 * not that surface — the bundle is a directory on disk and one thing to a person, so it takes the launch door. */
- (void)openItemAtIndex:(NSUInteger)index
{
	WSItem *item = [[_model items] objectAtIndex:index];
	CFStringRef path = CFStringCreateWithCString(NULL, [[item path] UTF8String], kCFStringEncodingUTF8);
	CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, [item isDirectory] ? true : false);

	CFRelease(path);
	if ([item isBrowsable]) {
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
	[[NSNotificationCenter defaultCenter] removeObserver:self name:WSSelectionDidChangeNotification object:nil];
	[_model release];
	[_store release];
	[_positions release];
	[_icons release];
	[_selection release];
	[super dealloc];
}

@end
