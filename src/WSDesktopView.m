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

#import "WSDirectoryWatcher.h"

#import "WSIconCell.h"
#import "WSIconLabel.h"
#import "WSIconLayout.h"
#import "WSContextMenu.h"
#import "WSFileOperations.h"
#import "WSGetInfoWindowController.h"
#import "WSSelectionBand.h"
#import "WSSelectionOwner.h"
#import "WSItemIcons.h"
#import "WSItemDrag.h"
#import "WSItemModel.h"
#import "WSMetadataStore.h"
#import "WSTrash.h"

#import <AppKit/NSWindow.h>

/* The pointer, taken for the length of the band — see `WSIconView.m`'s declaration of the same door. */
@interface NSWindow (APPKITDesktopBandCapture)
- (void)cg_setPointerCapture:(BOOL)flag;
@end

#import <AppKit/NSAttributedString.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSScreen.h>
#import <AppKit/NSStatusBar.h>
#import <AppKit/NSText.h>
#import <AppKit/NSTextField.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSValue.h>

#import <LaunchServices/LSOpen.h>
#import <IconServices/IconServices.h>

#include <math.h>
#include <stdlib.h>

NSString *WSDesktopViewOpenFolderNotification = @"WSDesktopViewOpenFolderNotification";
NSString *WSDesktopViewPathKey = @"WSDesktopViewPath";

/* **HOW FAR THE POINTER MOVES BEFORE A PRESS BECOMES A DRAG**, the same figure the file window's grid uses. */
#define WS_DESKTOP_DRAG_THRESHOLD 4.0

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
		/* **AND THE OPERATIONS THE CONTEXT MENU PERFORMS.** The trash is this desktop's own, because a desktop is a
		 * place a file can be trashed FROM and it has no file window to borrow one; the manager carries no undo, see
		 * the header. */
		_trash = [[WSTrash alloc] init];
		_fileOperations = [[WSFileOperations alloc] initWithUndoManager:nil trash:_trash];
		/* **AND IT TAKES DROPS**, the same type a file window's icon view takes: a drag out of a window and onto the
		 * desktop is a move into the desktop's own directory. */
		[self registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
		/* **AND THE DESKTOP HEARS WHEN A WINDOW TAKES THE SELECTION** — see `WSSelectionOwner.h`. */
		[[NSNotificationCenter defaultCenter] addObserver:self
							 selector:@selector(fn_selectionHeldElsewhere:)
							     name:WSSelectionDidChangeNotification
							   object:nil];
		[self reload];
		_workAreaTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
								   target:self
								 selector:@selector(fn_workAreaTick:)
								 userInfo:nil
								  repeats:YES] retain];
		/* **AND THE DESKTOP WATCHES ITS OWN FOLDER.** Everything else that shows a directory reads it again when the
		 * kernel says it changed (`WSDirectoryWatcher`); without this the desktop was the one surface where a file that
		 * landed beside it — a finished download, another application's write, a folder made in a terminal — stayed
		 * invisible until the view happened to reload. */
		_watcher = [[WSDirectoryWatcher alloc] initWithDirectory:directory
								  target:self
								  action:@selector(fn_directoryDidChange:)];
	}
	return self;
}

- (NSString *)directory { return [_model directory]; }

/* **A DESKTOP NAME IS BOLD, AND THE WINDOW'S IS NOT.** A white name over a photograph has no page to hold it up, and the
 * weight is what makes it read at a glance where a black name on white already does. The font is the tier's emphasized
 * system face, which `NSFont` answers as nil on a host whose font service has nothing to give — so the attribute is
 * added only when there is a font, and a desktop with no face falls back to the plain ink rather than to an exception. */
- (NSDictionary *)labelAttributes
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:[NSColor whiteColor]
									    forKey:NSForegroundColorAttributeName];
	NSFont *font = [NSFont boldSystemFontOfSize:12.0];

	if (font != nil) {
		[attributes setObject:font forKey:NSFontAttributeName];
	}
	return attributes;
}

- (WSItemModel *)model { return _model; }

/* **THE DESKTOP'S TOP PADDING: THE MENU BAR'S HEIGHT PLUS TEN POINTS.** The bar is a window the SERVER draws at its
 * own level, OVER the desktop, so an icon placed at the view's top edge goes UNDER it. The height comes from the
 * AppKit's own door — `NSStatusBar -thickness` — rather than a constant, so the padding follows the bar if the
 * bar's height ever changes. */
+ (CGFloat)topPadding
{
	return [[NSStatusBar systemStatusBar] thickness] + 10.0;
}

/* **THE AIR THIS VIEW KEEPS UNDER THE MENU BAR**, on top of the bar the work area already excludes. */
#define WS_DESKTOP_TOP_AIR 10.0

/* **THE AREA THE GRID LAYS ICONS IN: THE SCREEN'S WORK AREA, WHICH IS WHERE THE DOCK'S STRIP IS ALREADY TAKEN OUT.**
 * The Dock reserves its width with the compositor (`agora_window.set_reserved`), the compositor sums the reservations by
 * edge and publishes what is left, and `NSScreen -visibleFrame` is that answer — so the desktop does not guess a dock's
 * size and does not have to follow a second one appearing. Its ORIGIN is the area's top-left, because `WSIconLayout`
 * fills from there and the padding is the gap rather than an inset the grid adds again.
 *
 * **AND ONLY WHEN THIS VIEW IS THE SCREEN.** The work area is a fact about a display; a view of some other size (a probe,
 * or a desktop window a test made) lays out in its own bounds and keeps the menu bar's thickness as padding, which is
 * what it did before there was a work area to ask for. */
- (NSRect)layoutBounds
{
	NSRect bounds = [self bounds];
	NSScreen *screen = [NSScreen mainScreen];
	NSRect work = (screen != nil) ? [screen visibleFrame] : NSZeroRect;
	CGFloat top = [WSDesktopView topPadding];

	if (screen == nil || work.size.width <= 0.0 || work.size.height <= 0.0
	    || !NSEqualSizes([screen frame].size, bounds.size)) {
		return NSMakeRect(bounds.origin.x, top, bounds.size.width, bounds.size.height - top);
	}
	/* THE WORK AREA ARRIVES IN COCOA'S SPACE — up from the bottom — and the grid is written down from the top. */
	return NSMakeRect(NSMinX(work),
			  bounds.size.height - NSMaxY(work) + WS_DESKTOP_TOP_AIR,
			  NSWidth(work),
			  NSHeight(work) - WS_DESKTOP_TOP_AIR);
}

/* Give every item a place: the one the store remembers, or the next free grid cell. */
- (void)reloadAfterChange
{
	[self reload];
}

/* **A CHANGE ON THE DISK IS NOT A NEW SELECTION.** `-reload` re-reads the directory and starts the selection over; what a
 * person had chosen is put back BY PATH — the identity a reloaded `WSItem` keeps — and SILENTLY: a file appearing on the
 * desktop is no reason to take the Workspace-wide selection away from the window next door. */
- (void)fn_reloadKeepingSelection
{
	NSArray *items = [_model items];
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSUInteger i;

	for (i = 0; i < [_selection count]; i++) {
		NSInteger index = [[_selection objectAtIndex:i] integerValue];

		if (index >= 0 && index < (NSInteger)[items count]) {
			[paths addObject:[[items objectAtIndex:(NSUInteger)index] path]];
		}
	}
	[self reload];
	items = [_model items];
	for (i = 0; i < [items count]; i++) {
		if ([paths containsObject:[[items objectAtIndex:i] path]]) {
			[_selection addObject:[NSNumber numberWithInteger:(NSInteger)i]];
		}
	}
	_anchorIndex = ([_selection count] > 0) ? [[_selection objectAtIndex:0] integerValue] : -1;
	[paths release];
	[self setNeedsDisplay:YES];
}

/* **NOT UNDER THE HAND.** A reload re-places every icon from the store and would close a field a person is typing in, so
 * a change that arrives mid-drag, mid-band or mid-rename is remembered and taken when the gesture ends. */
- (void)fn_directoryDidChange:(WSDirectoryWatcher *)watcher
{
	(void)watcher;
	if (_dragging || _rubberBanding || _renaming) {
		_pendingReload = YES;
		return;
	}
	[self fn_reloadKeepingSelection];
}

- (void)fn_drainPendingReload
{
	if (!_pendingReload || _dragging || _rubberBanding || _renaming) {
		return;
	}
	_pendingReload = NO;
	[self fn_reloadKeepingSelection];
}

- (WSDirectoryWatcher *)cg_watcher { return _watcher; }

- (void)reload
{
	NSArray *items;
	NSMutableArray *positions = [[NSMutableArray alloc] init];
	NSRect area = [self layoutBounds];
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
			position = [WSIconLayout gridPositionForIndex:(NSInteger)i inBounds:area iconSize:iconSize];
		}
		/* **EVERY ICON IS RESOLVED INTO A FREE CELL, WHETHER IT WAS DRAGGED OR REMEMBERED.** A remembered position is
		 * where a hand left an icon, and the world it was left in can have changed under it — the screen narrowed because
		 * the Dock took a strip, or two sidecar entries name the same point. Both are the same question, so it is asked
		 * once, of the same arithmetic a drop uses: the nearest cell that nothing else occupies and that the area holds.
		 * The store is not rewritten here; the placement is a fact about this layout, and a person's own drag is what
		 * writes it down. */
		position = [WSIconLayout freePositionNearest:position inBounds:area iconSize:iconSize avoiding:positions];
		/* **A FULL GRID SHOWS WHAT FITS AND NOTHING OF THE REST.** `WSIconNoPosition` is outside every view: the item is
		 * still in the directory and still listed by the model, and it is not drawn, not hit and not dragged. */
		[positions addObject:[NSValue valueWithPoint:position]];
	}
	_laidOutWorkArea = area;
	[_positions release];
	_positions = positions;
	[_icons removeAllObjects];
	for (i = 0; i < [items count]; i++) [_icons addObject:[NSNull null]];
	[_selection removeAllObjects];
	_anchorIndex = -1;
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

- (NSPoint)topLeftPointForWindowPoint:(NSPoint)windowPoint
{
	NSPoint cocoa = [self convertPoint:windowPoint fromView:nil];

	return NSMakePoint(cocoa.x, [self bounds].size.height - cocoa.y);
}

- (NSPoint)topLeftPointForEvent:(NSEvent *)event
{
	return [self topLeftPointForWindowPoint:[event locationInWindow]];
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

		if (NSEqualPoints(position, WSIconNoPosition)) {
			continue;	/* the grid was full: this item has no cell, so it has no pixels */
		}
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
		/* **A CELL A DRAG IS OVER WEARS THE SAME WASH, WHICH IS HOW A FOLDER SAYS "IN HERE".** The file window's grid
		 * paints its drop target this way; a desktop that stayed still would give a hand no answer at all. */
		if (_dropOperation != NSDragOperationNone && (NSInteger)i == _dropIndex) {
			selected = YES;
		}
		attributes = [self labelAttributes];

		cell.iconRect = iconRect;
		cell.cellWidth = cellSize.width;
		cell.labelBelow = NO;	/* this view is unflipped: the name hangs toward the foot of the screen */
		cell.icon = [self iconRepForItemAtIndex:(NSUInteger)i];
		cell.label = WSIconLabelText([[items objectAtIndex:i] name], cellSize.width - 4.0, attributes);
		cell.attributes = attributes;
		cell.labelShadow = YES;	/* white ink over a wallpaper: see `WSIconCell.h` */
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
	NSUInteger flags = [event modifierFlags];
	BOOL shift = (flags & NSShiftKeyMask) != 0;
	/* **COMMAND AND CONTROL BOTH ADD TO THE SELECTION.** The Mac spells "and this one too" with Command and every other
	 * desktop with Control, and a desktop that answered only one of them looked broken to whoever pressed the other. */
	BOOL toggle = (flags & (NSCommandKeyMask | NSControlKeyMask)) != 0;

	_moved = NO;
	_dragLast = point;
	_rubberBanding = NO;

	if (index < 0) {
		if (!shift && !toggle) [_selection removeAllObjects];
		_anchorIndex = -1;
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

	/* **THE MODIFIER DECIDES WHAT THE PRESS DOES TO THE SELECTION, AND THE DRAG STILL FOLLOWS.** A Shift-click takes
	 * every icon between the anchor and the one clicked — the range rule a list has, read in the order the icons are laid
	 * out — and a Control- or Command-click adds one or takes it away; a plain click on an unselected icon starts over,
	 * while a plain click on one already selected keeps the group so it can be dragged as a whole. */
	if (toggle) {
		if ([self fn_isSelected:index]) {
			[self removeFromSelection:index];
		} else {
			[self addToSelection:index];
		}
		_anchorIndex = index;
	} else if (shift) {
		[self extendSelectionToIndex:index];
	} else if (![self fn_isSelected:index]) {
		[_selection removeAllObjects];
		[self addToSelection:index];
		_anchorIndex = index;
	} else {
		_anchorIndex = index;
	}
	_dragging = YES;
	_dragSessionBegan = NO;
	_pressPoint = point;
	[self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point = [self topLeftPointForEvent:event];
	NSUInteger s;

	if (_rubberBanding) {
		_rubberRect = NSMakeRect(point.x < _rubberStart.x ? point.x : _rubberStart.x,
					 point.y < _rubberStart.y ? point.y : _rubberStart.y,
					 (CGFloat)labs((long)(point.x - _rubberStart.x)),
					 (CGFloat)labs((long)(point.y - _rubberStart.y)));
		[self setNeedsDisplay:YES];
		return;
	}
	if (!_dragging) {
		return;
	}
	/* **PAST THE THRESHOLD THE GESTURE IS THE TIER'S, AND THE SESSION OWNS THE POINTER.** Below it the icons follow the
	 * pointer, which is how an icon has always been put somewhere else on the desktop; at it a drag session begins, so
	 * the same gesture can be dropped in a file window. A session that ends over the desktop puts the icons where the
	 * pointer let go, so the two are one gesture with one fallback. */
	if (!_dragSessionBegan
	    && (fabs((double)(point.x - _pressPoint.x)) >= WS_DESKTOP_DRAG_THRESHOLD
		|| fabs((double)(point.y - _pressPoint.y)) >= WS_DESKTOP_DRAG_THRESHOLD)) {
		_dragSessionBegan = YES;
		if ([self cg_beginDragWithEvent:event] != nil) {
			return;
		}
	}
	if (_dragSessionBegan) {
		return;
	}
	{
		/* Every SELECTED icon moves together, which is what makes a drag of a group one gesture. */
		CGFloat dx = point.x - _dragLast.x;
		CGFloat dy = point.y - _dragLast.y;

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
		[self fn_drainPendingReload];
		return;
	}
	if (_dragging) {
		if (_moved) [self snapSelectionToGridAndPersist];
		_dragging = NO;
	}
	[self fn_drainPendingReload];
}

/* ---- THE CONTEXT MENU, AND WHAT ONE ICON CAN ANSWER -------------------------------------------- */

/* The icon whose cell holds a point, in this view's top-left space, or -1. An item the grid could not place holds
 * `WSIconNoPosition` and is under nothing, so it is never the answer. */
- (NSInteger)fn_indexAtTopLeftPoint:(NSPoint)point
{
	NSInteger index = [WSIconLayout indexOfPosition:point among:_positions iconSize:[self iconSize]];

	if (index >= 0
	    && NSEqualPoints([[_positions objectAtIndex:(NSUInteger)index] pointValue], WSIconNoPosition)) {
		return -1;
	}
	return index;
}

- (BOOL)fn_isSelected:(NSInteger)index
{
	NSUInteger s;

	for (s = 0; s < [_selection count]; s++)
		if ([[_selection objectAtIndex:s] integerValue] == index) return YES;
	return NO;
}

/* **A RIGHT-CLICK NAMES ITS ICON, AND THE MENU IS ABOUT THAT ONE.** The click narrows the selection to the icon under
 * the pointer first: `WSContextMenu` builds a single item's menu, so a right-click inside a group makes that icon the
 * subject rather than offering commands that would have to mean several different things. A click on the wallpaper is
 * not a menu yet, so it answers nil and nothing opens. */
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSInteger index;

	if (event == nil) {
		return nil;
	}
	index = [self fn_indexAtTopLeftPoint:[self topLeftPointForEvent:event]];
	if (index < 0) {
		/* **NOTHING UNDER THE POINTER IS THE FOLDER'S MENU, NOT NO MENU.** The desktop is the view of a directory like
		 * any grid, so its empty space offers the three things a directory can be asked — and the selection is left
		 * alone, because Paste and New Folder are useful with something held elsewhere. */
		return [WSContextMenu menuForBackgroundWithTarget:self];
	}
	/* **A CLICK ON ONE OF SEVERAL HOLDS THE GROUP** — the rule the file window's grid follows, and the reason a group's
	 * menu can be reached at all: the pointer must be over one of the icons the menu is about. A click OUTSIDE the
	 * selection narrows to what it landed on. */
	if (![self fn_isSelected:index]) {
		[_selection removeAllObjects];
		[self addToSelection:index];
		[self setNeedsDisplay:YES];
	}
	return ([_selection count] > 1)
		? [WSContextMenu menuForMultipleItemsWithTarget:self]
		: [WSContextMenu menuForSingleItemWithTarget:self];
}

/* COPY IS THE PATHS ON THE GENERAL PASTEBOARD, by the rule `WSItemDrag` writes once for both surfaces. */
- (void)copy:(id)sender
{
	(void)sender;
	WSItemCopyPathsToPasteboard([self cg_selectedPaths]);
}

/* CUT AND PASTE, the pair that makes a cut mean something: the paste moves what was cut and copies what was copied, into
 * the desktop's own directory. */
- (void)cut:(id)sender
{
	(void)sender;
	WSItemCutPathsToPasteboard([self cg_selectedPaths]);
}

- (void)paste:(id)sender
{
	BOOL wasCut = NO;
	NSArray *paths = WSItemClipboardPaths(&wasCut);

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	if (wasCut) {
		(void)[_fileOperations movePaths:paths toDirectory:[_model directory] error:NULL];
		WSItemClipboardForget();
	} else {
		(void)[_fileOperations copyPaths:paths toDirectory:[_model directory] error:NULL];
	}
	[self reload];
}

/* MOVE TO TRASH IS W6'S OPERATION, the same call a file window's `-moveToTrash:` makes, and the desktop then reads its
 * directory again — the trashed icon is gone from the grid. */
- (void)moveToTrash:(id)sender
{
	(void)sender;
	if ([_selection count] == 0) {
		return;
	}
	(void)[_fileOperations movePathsToTrash:[self cg_selectedPaths] error:NULL];
	[self reload];
}

/* **AN ARCHIVE ON THE DESKTOP IS EXTRACTED BESIDE ITSELF, like anywhere else.** The row is asked for rather than drawn
 * grey: `-cg_selectionCanBeExtracted` is what `WSContextMenu` checks, and a double click takes the same command. */
- (BOOL)cg_selectionCanBeExtracted
{
	NSArray *paths = [self cg_selectedPaths];
	NSUInteger i;

	if ([paths count] == 0) {
		return NO;
	}
	for (i = 0; i < [paths count]; i++) {
		if (![WSFileOperations cg_isArchivePath:[paths objectAtIndex:i]]) {
			return NO;
		}
	}
	return YES;
}

- (void)extractArchive:(id)sender
{
	NSArray *paths = [self cg_selectedPaths];
	NSUInteger i;

	(void)sender;
	for (i = 0; i < [paths count]; i++) {
		(void)[_fileOperations extractArchive:[paths objectAtIndex:i] error:NULL];
	}
	[self reload];
}

/* **COMPRESS IS THE SAME COMMAND A FILE WINDOW HAS, AIMED AT THE DESKTOP.** The archive is made in the desktop folder,
 * which is where the icons come from — so it appears in the grid beside the thing it was made from, and the grid is read
 * again to show it. */
- (void)compress:(id)sender
{
	NSArray *paths = [self cg_selectedPaths];

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	(void)[_fileOperations compressPaths:paths inDirectory:[_model directory] error:NULL];
	[self reload];
}

/* ---- THE EMPTY DESKTOP'S TWO COMMANDS -------------------------------------------------------- */

/* NEW FOLDER IS W6'S OPERATION, and the folder it made is what the desktop holds afterwards — the same rule the file
 * window's grid follows. */
- (void)newFolder:(id)sender
{
	NSString *made;

	(void)sender;
	made = [_fileOperations createFolderInDirectory:[_model directory] name:nil error:NULL];
	[self reload];
	if (made != nil) {
		[self cg_selectPaths:[NSArray arrayWithObject:made]];
	}
}

/* **GET INFO ON THE DESKTOP IS THE SAME WINDOW A FILE WINDOW'S COMMAND OPENS.** The registry in
 * `WSGetInfoWindowController` is what makes that true: a person who asks about the same item from the desktop and from a
 * window gets one inspector, brought forward, rather than two windows saying the same thing. */
- (void)getInfo:(id)sender
{
	NSArray *paths = [self cg_selectedPaths];

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	(void)[WSGetInfoWindowController infoWindowForPaths:paths];
}

/* **NEW FOLDER WITH SELECTION GATHERS WHAT IS HELD INTO A FOLDER OF ITS OWN** — the desktop's copy of the file window's
 * grid command, and the same rule: the folder is made here, the selection moves into it, and the folder is held. */
- (void)newFolderWithSelection:(id)sender
{
	NSArray *paths = [self cg_selectedPaths];
	NSString *made;

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	made = [_fileOperations createFolderInDirectory:[_model directory]
						 name:@"New Folder with Selection" error:NULL];
	if (made == nil) {
		return;
	}
	(void)[_fileOperations movePaths:paths toDirectory:made error:NULL];
	[self reload];
	[self cg_selectPaths:[NSArray arrayWithObject:made]];
}

/* **SELECT ALL IS EVERY ICON THE GRID COULD PLACE.** An item the grid had no cell for holds `WSIconNoPosition` and has no
 * pixels, so selecting it would be a claim the desktop could not show; the press and the band both work from cells for the
 * same reason. */
- (void)selectAll:(id)sender
{
	NSUInteger i;

	(void)sender;
	[_selection removeAllObjects];
	for (i = 0; i < [_positions count]; i++) {
		if (!NSEqualPoints([[_positions objectAtIndex:i] pointValue], WSIconNoPosition)) {
			[self addToSelection:(NSInteger)i];
		}
	}
	_anchorIndex = ([_selection count] > 0) ? [[_selection objectAtIndex:0] integerValue] : -1;
	[self setNeedsDisplay:YES];
}

/* ---- INLINE RENAME ---------------------------------------------------------------------------- */

- (BOOL)isRenaming { return _renaming; }
- (NSTextField *)cg_renameField { return _renameField; }

- (WSFileOperations *)fileOperations { return _fileOperations; }

/* **A CALLER MAY BRING ITS OWN OPERATIONS** — a probe with a trash on `/tmp` rather than the account's — and nil means
 * "make my own", which is what the desktop window leaves it as. */
- (void)setFileOperations:(WSFileOperations *)operations
{
	if (operations == _fileOperations) {
		return;
	}
	[_fileOperations release];
	_fileOperations = (operations != nil)
		? [operations retain]
		: [[WSFileOperations alloc] initWithUndoManager:nil trash:_trash];
}

/* RENAME IS A FIELD OVER THE LABEL, the same gesture a file window's grid gives the Return key. The field lands where
 * `WSIconCell` draws the name — under the icon on this unflipped view — and the item's extension is left out of the
 * selection, so a rename edits the name and not the fact about the file. */
- (void)rename:(id)sender
{
	NSInteger index;
	WSItem *item;
	NSSize cell;
	NSRect iconRect;
	NSRect highlight;
	NSRect frame;
	NSTextField *field;

	(void)sender;
	if (_renaming) {
		[self cancelRenaming];
	}
	if ([_selection count] != 1) {
		return;
	}
	index = [[_selection objectAtIndex:0] integerValue];
	if (index < 0 || index >= (NSInteger)[[_model items] count]
	    || NSEqualPoints([[_positions objectAtIndex:(NSUInteger)index] pointValue], WSIconNoPosition)) {
		return;
	}
	item = [[_model items] objectAtIndex:(NSUInteger)index];
	cell = [WSIconLayout cellSizeForIconSize:[self iconSize]];
	iconRect = [self cocoaRectForPosition:[[_positions objectAtIndex:(NSUInteger)index] pointValue]
					size:NSMakeSize((CGFloat)[self iconSize], (CGFloat)[self iconSize])];
	highlight = WSIconCellHighlightRect(iconRect, cell.width, NO);
	frame = NSMakeRect(highlight.origin.x + 2.0,
			   NSMinY(iconRect) - (CGFloat)WSIconLabelGap - (CGFloat)WSIconLabelHeight - 2.0,
			   highlight.size.width - 4.0, (CGFloat)WSIconLabelHeight + 4.0);

	field = [[NSTextField alloc] initWithFrame:frame];
	[field setStringValue:[item name]];
	[field setEditable:YES];
	[field setSelectable:YES];
	[field setBordered:YES];
	[field setBezeled:YES];
	[field setDrawsBackground:YES];
	[field setBackgroundColor:[NSColor whiteColor]];
	[field setTextColor:[NSColor blackColor]];
	[field setDelegate:(id <NSTextFieldDelegate>)self];
	[field setTarget:self];
	[field setAction:@selector(renameFieldAction:)];
	[self addSubview:field];
	_renameField = field;
	_renameIndex = index;
	_renaming = YES;
	[[self window] makeFirstResponder:field];
	[field selectText:nil];
	if (![item isDirectory] || [item isPackage]) {
		NSText *editor = [field currentEditor];
		NSRange dot = [[item name] rangeOfString:@"." options:NSBackwardsSearch];

		if (editor != nil && dot.location != NSNotFound && dot.location > 0) {
			[editor setSelectedRange:NSMakeRange(0, dot.location)];
		}
	}
}

- (void)renameFieldAction:(id)sender
{
	(void)sender;
	(void)[self commitRenaming];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	NSNumber *movement = [[notification userInfo] objectForKey:NSTextMovementUserInfoKey];

	if (!_renaming) {
		return;
	}
	if (movement != nil && [movement integerValue] == NSTextMovementCancel) {
		[self cancelRenaming];
	} else {
		(void)[self commitRenaming];
	}
}

- (BOOL)commitRenaming
{
	NSTextField *field;
	NSString *name;
	WSItem *item;
	NSString *oldPath;
	NSString *newPath;
	NSFileManager *manager = [NSFileManager defaultManager];
	BOOL renamed = NO;

	if (!_renaming) {
		return NO;
	}
	_renaming = NO;
	field = _renameField;
	_renameField = nil;
	name = [[field stringValue] stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	item = [[_model items] objectAtIndex:(NSUInteger)_renameIndex];
	oldPath = [item path];
	newPath = [[_model directory] stringByAppendingPathComponent:name];

	[[self window] makeFirstResponder:self];
	[field removeFromSuperview];
	[field release];

	if ([name length] == 0 || [name isEqual:@"."] || [name isEqual:@".."]
	    || [name rangeOfString:@"/"].location != NSNotFound) {
		return NO;
	}
	if ([name isEqual:[item name]]) {
		return YES;
	}
	if ([manager fileExistsAtPath:newPath]) {
		return NO;
	}
	if ((_fileOperations != nil)
	    ? ([_fileOperations renamePath:oldPath toName:name error:NULL] != nil)
	    : [manager moveItemAtPath:oldPath toPath:newPath error:NULL]) {
		[self reload];
		[self cg_selectPaths:[NSArray arrayWithObject:newPath]];
		renamed = YES;
	}
	[self setNeedsDisplay:YES];
	[self fn_drainPendingReload];
	return renamed;
}

- (void)cancelRenaming
{
	NSTextField *field;

	if (!_renaming) {
		return;
	}
	_renaming = NO;
	field = _renameField;
	_renameField = nil;
	[[self window] makeFirstResponder:self];
	[field removeFromSuperview];
	[field release];
	[self setNeedsDisplay:YES];
	[self fn_drainPendingReload];
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

/* The toggle's other half: a Control- or Command-click on an icon already held takes it out, and says so, so that a
 * window's selection lets go of an icon it no longer shares. */
- (void)removeFromSelection:(NSInteger)index
{
	NSUInteger s;

	for (s = 0; s < [_selection count]; s++) {
		if ([[_selection objectAtIndex:s] integerValue] == index) {
			[_selection removeObjectAtIndex:s];
			[[NSNotificationCenter defaultCenter] postNotificationName:WSSelectionDidChangeNotification
									     object:self];
			return;
		}
	}
}

/* **A SHIFT-CLICK TAKES THE RUN BETWEEN THE ANCHOR AND THE ICON CLICKED**, which is the rule every list has, read in
 * the order the icons are laid out — the order the keyboard walks. A rectangle would be a shape nobody described: these
 * icons are placed on the desktop, not laid in a grid. */
- (void)extendSelectionToIndex:(NSInteger)index
{
	NSInteger anchor = (_anchorIndex >= 0) ? _anchorIndex : index;
	NSInteger lo = (anchor < index) ? anchor : index;
	NSInteger hi = (anchor < index) ? index : anchor;
	NSInteger i;

	[_selection removeAllObjects];
	for (i = lo; i <= hi; i++) {
		[_selection addObject:[NSNumber numberWithInteger:i]];
	}
	_anchorIndex = anchor;
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
	_anchorIndex = -1;
	[self setNeedsDisplay:YES];
}

/* ---- THE DRAG, OUT AND IN --------------------------------------------------------------------- */

/* **THE SAME PASTEBOARD A FILE WINDOW FILLS.** The paths go on `NSFilenamesPboardType` and one dragging item per selected
 * icon carries the picture that moves with the pointer, so a drag out of the desktop is a drag another window already
 * knows how to accept. */
/* **THE ITEMS A DROP PUT HERE ARE THE ONES THE HAND MEANT.** A set dragged out of a window and let go over the desktop
 * arrives selected — the same rule the file window's grid follows — and a set dragged around the desktop keeps the
 * selection it was dragged with, because the drop is the same gesture either way. */
- (void)cg_selectPaths:(NSArray *)paths
{
	NSArray *items = [_model items];
	NSUInteger i;

	[_selection removeAllObjects];
	for (i = 0; i < [items count]; i++) {
		if ([paths containsObject:[[items objectAtIndex:i] path]]) {
			[_selection addObject:[NSNumber numberWithInteger:(NSInteger)i]];
		}
	}
	_anchorIndex = ([_selection count] > 0) ? [[_selection objectAtIndex:0] integerValue] : -1;
	/* A DESKTOP THAT CHOOSES CLAIMS THE SELECTION; one that comes up empty stays silent, which is the rule the press
	 * follows and the one that keeps the window next door's selection standing. */
	if ([_selection count] > 0) {
		[[NSNotificationCenter defaultCenter] postNotificationName:WSSelectionDidChangeNotification object:self];
	}
	[self setNeedsDisplay:YES];
}

- (NSRect)cg_layoutBounds
{
	return [self layoutBounds];
}

- (NSArray *)cg_selectedPaths
{
	NSArray *items = [_model items];
	NSMutableArray *paths = [[[NSMutableArray alloc] init] autorelease];
	NSUInteger s;

	for (s = 0; s < [_selection count]; s++) {
		NSInteger index = [[_selection objectAtIndex:s] integerValue];

		if (index >= 0 && index < (NSInteger)[items count]) {
			[paths addObject:[[items objectAtIndex:(NSUInteger)index] path]];
		}
	}
	return paths;
}

- (NSDraggingSession *)cg_beginDragWithEvent:(NSEvent *)event
{
	NSArray *paths = [self cg_selectedPaths];
	NSMutableArray *items = [[[NSMutableArray alloc] init] autorelease];
	NSDraggingSession *session;
	NSUInteger s;

	if ([paths count] == 0) {
		return nil;
	}
	for (s = 0; s < [_selection count]; s++) {
		NSInteger index = [[_selection objectAtIndex:s] integerValue];
		NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];
		NSDraggingItem *item;
		NSImage *icon;

		if (index < 0 || index >= (NSInteger)[_positions count]) {
			continue;
		}
		item = [[NSDraggingItem alloc] initWithPasteboardWriter:nil];
		icon = [self iconRepForItemAtIndex:(NSUInteger)index];
		[item setDraggingFrame:[self cocoaRectForPosition:position
							    size:NSMakeSize((CGFloat)[self iconSize],
									    (CGFloat)[self iconSize])]
			      contents:icon];
		[items addObject:item];
		[item release];
	}
	/* **WHERE THE POINTER WAS WHEN THE SESSION BEGAN, IN THE WINDOW'S OWN SPACE.** The session owns the pointer from
	 * here, so the release is reported in screen coordinates; recording the start in the same space as the release's is
	 * what lets the difference — the travel — be applied to positions that are in top-left coordinates. */
	_dragStartWindow = [event locationInWindow];
	session = WSItemDragBegin(self, paths, items, event, self);
	_dragging = (session != nil);
	return session;
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
	return isLocal ? (NSDragOperationMove | NSDragOperationCopy | NSDragOperationLink) : NSDragOperationCopy;
}

/* **WHERE THE SESSION LETS GO IS WHERE THE ICONS GO**, when nothing else took the drop. The delta is the pointer's whole
 * travel, in the window's own space: a translation is the same in top-left coordinates except for its sign, so nothing is
 * converted and nothing can round. */
- (void)cg_dropSessionDidEnd:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
	_dragging = NO;
	_dragSessionBegan = NO;
	if (operation == NSDragOperationNone) {
		NSRect frame = [[self window] frame];
		CGFloat dx = (screenPoint.x - frame.origin.x) - _dragStartWindow.x;
		CGFloat dy = -((screenPoint.y - frame.origin.y) - _dragStartWindow.y);
		NSUInteger s;

		for (s = 0; s < [_selection count]; s++) {
			NSInteger index = [[_selection objectAtIndex:s] integerValue];
			NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];

			position.x += dx;
			position.y += dy;
			[_positions replaceObjectAtIndex:(NSUInteger)index withObject:[NSValue valueWithPoint:position]];
		}
		_moved = YES;
		[self snapSelectionToGridAndPersist];
		/* **THE SET THAT WAS DRAGGED IS STILL THE SET THAT IS HELD**, wherever on the desktop it landed, and the reload
		 * below is what would otherwise let it go — it clears the selection because a directory read from scratch knows
		 * nothing about who was chosen. */
		{
			NSArray *held = [self cg_selectedPaths];

			[self reload];
			[self cg_selectPaths:held];
		}
		return;
	}
	[self reload];
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint
	      operation:(NSDragOperation)operation
{
	(void)session;
	[self cg_dropSessionDidEnd:screenPoint operation:operation];
}

/* ---- THE DROP DESTINATION -------------------------------------------------------------------- */

/* The directory a drop at `index` lands in: the folder under it, or the desktop's own directory for empty space or for a
 * file. The file window's grid answers this the same way, and the rule that reads it is `WSItemDrag`'s. */
- (NSString *)dropDirectoryForIndex:(NSInteger)index
{
	if (index >= 0 && index < (NSInteger)[[_model items] count]) {
		WSItem *item = [[_model items] objectAtIndex:(NSUInteger)index];

		return [item isDirectory] ? [item path] : nil;
	}
	return (_model != nil) ? [_model directory] : nil;
}

- (NSDragOperation)cg_updateDropWithInfo:(id <NSDraggingInfo>)info
{
	NSPoint point = [self topLeftPointForWindowPoint:[info draggingLocation]];
	NSInteger index = [WSIconLayout indexOfPosition:point among:_positions iconSize:[self iconSize]];
	NSString *target = [self dropDirectoryForIndex:index];
	NSArray *paths = WSItemDragPaths(info);
	NSDragOperation operation = WSItemDragOperation(paths, target, [info draggingSourceOperationMask],
						       [NSEvent modifierFlags]);

	_dropIndex = (operation != NSDragOperationNone) ? index : -1;
	_dropOperation = operation;
	[self setNeedsDisplay:YES];
	return operation;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
	return [self cg_updateDropWithInfo:sender];
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
	return [self cg_updateDropWithInfo:sender];
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
	(void)sender;
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	[self setNeedsDisplay:YES];
}

- (void)draggingEnded:(id <NSDraggingInfo>)sender
{
	[self draggingExited:sender];
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
	(void)sender;
	return _dropOperation != NSDragOperationNone;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
	NSArray *paths = WSItemDragPaths(sender);
	NSString *target = [self dropDirectoryForIndex:_dropIndex];
	NSDragOperation operation = _dropOperation;
	id source = [sender draggingSource];
	BOOL performed = WSItemDragPerformWithOperations(paths, target, operation, _fileOperations);

	if (performed) {
		NSMutableArray *arrived = [NSMutableArray array];
		NSUInteger i;

		/* THE SOURCE IS TOLD ITS ITEMS MOVED. A drag within this application has a view at the other end, and it holds a
		 * model that is now wrong; a drag from another application has none and the notification is the file
		 * watcher's business. */
		if ([source respondsToSelector:@selector(reloadAfterChange)]) {
			[(id <WSItemDragSourceReloading>)source reloadAfterChange];
		}
		[self reload];
		/* AND WHAT ARRIVED IS WHAT IS SELECTED, named in the directory it arrived in. */
		for (i = 0; i < [paths count]; i++) {
			[arrived addObject:[target stringByAppendingPathComponent:
				[[paths objectAtIndex:i] lastPathComponent]]];
		}
		[self cg_selectPaths:arrived];
	}
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	[self setNeedsDisplay:YES];
	return performed;
}

- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
	[self draggingExited:sender];
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
	if ([WSFileOperations cg_isArchivePath:[item path]]) {
		/* **A DOUBLE CLICK ON A .zip UNPACKS IT.** Nothing in this tree's Launch Services opens a zip, and what a person
		 * means by double-clicking one is its contents. */
		CFRelease(url);
		(void)[_fileOperations extractArchive:[item path] error:NULL];
		[self reload];
		return;
	}
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

/* **THE DOCK RESERVES ITS STRIP AFTER THIS APPLICATION HAS STARTED.** The compositor sums what its clients reserve and
 * republishes the work area, and `NSScreen -visibleFrame` is that answer — but nothing above the seam is TOLD when it
 * changes (the server sends `work_area_changed` per window and the AppKit drops it, which its own note says is
 * deliberate). A second is a long time for a layout nobody is watching, and four integers a second is nothing.
 * shortcut: polled, because there is no notification to observe; upgrade when the AppKit posts
 * `NSApplicationDidChangeScreenParametersNotification` for a work-area change. */
- (void)fn_workAreaTick:(NSTimer *)timer
{
	(void)timer;
	if (!NSEqualRects([self layoutBounds], _laidOutWorkArea)) {
		[self reload];
	}
}

- (void)dealloc
{
	[_watcher invalidate];
	[_watcher release];
	[_workAreaTimer invalidate];
	[_workAreaTimer release];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:WSSelectionDidChangeNotification object:nil];
	[_renameField release];
	[_fileOperations release];
	[_trash release];
	[_model release];
	[_store release];
	[_positions release];
	[_icons release];
	[_selection release];
	[super dealloc];
}

@end
