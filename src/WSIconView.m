/*
 * WSIconView.m — the grid, the keyboard, the rename field and the drag destination.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE LAYOUT IS `WSIconLayout`'S AND THE ITEMS ARE `WSItemModel`'S; this file is the interaction between them. The
 * order is `WSIconOrderLeftToRightRows`: a row fills, then the next row down. The desktop's right-to-left columns
 * are the same arithmetic with the other order, which is the reuse W3 claims.
 *
 * THE DRAG IS THE TIER'S `NSDraggingSession`: paths on `NSDragPboard` as `NSFilenamesPboardType`, one dragging item
 * per selected icon, and a destination that chooses Move/Copy/Link from the modifier keys and the two volumes. A
 * file window's other icon view is a destination by registration, so a drag between windows is the same code path
 * as a drag within one.
 */
#import "WSIconView.h"

#import "WSContextMenu.h"
#import "WSFileOperations.h"
#import "WSIconLabel.h"
#import "WSIconCell.h"
#import "WSIconLayout.h"
#import "WSSelectionBand.h"
#import "WSSelectionOwner.h"
#import "WSGetInfoWindowController.h"
#import "WSItemIcons.h"
#import "WSItemDrag.h"
#import "WSItemModel.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSText.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSValue.h>

#include <math.h>
#include <sys/stat.h>

/* **THE POINTER, FOR THE LENGTH OF A BAND.** A compositor sends motion to the surface under the pointer, so a gesture that
 * walks out of the view needs the pointer taken for its duration — the same door the window's own title-bar drag and the
 * drag session use. Declared here as those two declare it: a `cg_` seam is the tier's own passage, not Apple's API. */
@interface NSWindow (APPKITIconViewCapture)
- (void)cg_setPointerCapture:(BOOL)flag;
@end

NSString *WSIconViewRequestFolderWindowNotification = @"WSIconViewRequestFolderWindowNotification";
NSString *WSIconViewFolderPathKey = @"WSIconViewFolderPath";

#define WS_ICON_DRAG_THRESHOLD 4.0
#define WS_ICON_SPRING_DELAY 0.6

/* **THE LABEL'S BAND, THE WASH AND THE RING ARE `WSIconCell`'S NOW**, because the desktop draws the same cell and the two
 * had drifted apart — see that header. This file keeps the two things that are its own: the ink (black, because the
 * background is white) and the invalidation that follows a selection. */

@implementation WSIconView

- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_model = [model retain];
		_positions = [[NSMutableArray alloc] init];
		_icons = [[NSMutableArray alloc] init];
		_selection = [[NSMutableIndexSet alloc] init];
		_typeSelectString = [[NSMutableString alloc] init];
		_anchorIndex = -1;
		_pressIndex = -1;
		_dropIndex = -1;
		_springIndex = -1;
		_sprungIndex = -1;
		_renameIndex = -1;
		_iconSize = WSIconDefaultSize;
		[self registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
		/* **AND THIS VIEW HEARS WHEN ANOTHER SURFACE TAKES THE SELECTION** — see `WSSelectionOwner.h`. */
		[[NSNotificationCenter defaultCenter] addObserver:self
							 selector:@selector(fn_selectionHeldElsewhere:)
							     name:WSSelectionDidChangeNotification
							   object:nil];
		[self layoutItems];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self name:WSSelectionDidChangeNotification object:nil];
	if (_observedClip != nil) {
		[[NSNotificationCenter defaultCenter] removeObserver:self
			name:NSViewFrameDidChangeNotification object:_observedClip];
	}
	[self cancelSpring];
	[_renameField release];
	[_model release];
	[_fileOperations release];
	[_positions release];
	[_icons release];
	[_selection release];
	[_typeSelectString release];
	[super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)becomeFirstResponder
{
	/* **BECOMING FIRST RESPONDER CHANGES ONE RING.** The focus ring is drawn round the SELECTED item — it is the
	 * only mark this view has that depends on being first responder — so the click that focuses the view needs that
	 * one cell repainted, not the whole grid. This used to invalidate the whole view, which is how a click came to
	 * dirty 647x514 of a window in which two cells had changed. */
	[self invalidateItemAtIndex:[self selectedIndex]];
	return YES;
}

- (BOOL)resignFirstResponder
{
	[self invalidateItemAtIndex:[self selectedIndex]];
	return YES;
}

/* ---- THE MODEL AND THE GRID ------------------------------------------------------------------ */

- (WSItemModel *)model { return _model; }

- (void)setModel:(WSItemModel *)model
{
	if (_model == model) {
		return;
	}
	[self cancelRenaming];
	[self cancelSpring];
	[model retain];
	[_model release];
	_model = model;
	[_selection removeAllIndexes];
	_anchorIndex = -1;
	[self layoutItems];
}

/* **A DIRECTORY THAT CHANGED IS NOT A NEW DIRECTORY.** `-setModel:` starts over — no selection, no anchor — which is
 * right for a navigation and wrong for a refresh: a file appearing (a download finishing, another application writing,
 * the watcher reporting) must not clear what a person has chosen. So the grid is laid out again and the selection is
 * carried across BY PATH, which is the identity a reloaded `WSItem` keeps. */
- (void)reloadData
{
	NSArray *items = [_model items];
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSMutableIndexSet *keep = [[NSMutableIndexSet alloc] init];
	NSUInteger index;

	for (index = [_selection firstIndex]; index != NSNotFound; index = [_selection indexGreaterThanIndex:index]) {
		if (index < [items count]) {
			[paths addObject:[[items objectAtIndex:index] path]];
		}
	}
	[self layoutItems];
	[_selection removeAllIndexes];
	items = [_model items];
	for (index = 0; index < [items count]; index++) {
		if ([paths containsObject:[[items objectAtIndex:index] path]]) {
			[keep addIndex:index];
		}
	}
	[_selection addIndexes:keep];
	_anchorIndex = [self selectedIndex];
	[keep release];
	[paths release];
	[self setNeedsDisplay:YES];
}

- (id <WSIconViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id <WSIconViewDelegate>)delegate { _delegate = delegate; }
- (void)setFileOperations:(WSFileOperations *)operations
{
	[operations retain];
	[_fileOperations release];
	_fileOperations = operations;
}

- (NSInteger)itemCount
{
	return (_model != nil) ? (NSInteger)[[_model items] count] : 0;
}

- (NSInteger)selectedIndex
{
	NSUInteger first = [_selection firstIndex];

	return (first == NSNotFound) ? -1 : (NSInteger)first;
}

- (NSIndexSet *)selectedIndexes
{
	NSMutableIndexSet *copy = [[NSMutableIndexSet alloc] init];

	[copy addIndexes:_selection];
	return [copy autorelease];
}

- (NSArray *)selectedItems
{
	NSMutableArray *items = [[NSMutableArray alloc] init];
	NSUInteger index;

	for (index = [_selection firstIndex]; index != NSNotFound; index = [_selection indexGreaterThanIndex:index]) {
		[items addObject:[[_model items] objectAtIndex:index]];
	}
	return [items autorelease];
}

- (void)selectIndex:(NSInteger)index
{
	NSIndexSet *before = [self snapshotSelection];

	if (index < 0 || index >= [self itemCount]) {
		index = -1;
	}
	[_selection removeAllIndexes];
	if (index >= 0) {
		[_selection addIndex:(NSUInteger)index];
	}
	_anchorIndex = index;
	[self invalidateSelectionChangeFrom:before];
}

- (void)selectIndexes:(NSIndexSet *)indexes
{
	NSIndexSet *before = [self snapshotSelection];

	[_selection removeAllIndexes];
	if (indexes != nil) {
		[_selection addIndexes:indexes];
	}
	_anchorIndex = [self selectedIndex];
	[self invalidateSelectionChangeFrom:before];
}

/* **A DROP LANDS SELECTED.** The names that arrived are the ones the hand was carrying, so the grid holds them: a set
 * dragged from the desktop into a window keeps its selection across the move. */
- (void)cg_selectPaths:(NSArray *)paths
{
	NSArray *items = [_model items];
	NSMutableIndexSet *chosen = [NSMutableIndexSet indexSet];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		if ([paths containsObject:[[items objectAtIndex:i] path]]) {
			[chosen addIndex:i];
		}
	}
	[self selectIndexes:chosen];
}

- (void)selectAll:(id)sender
{
	NSIndexSet *before = [self snapshotSelection];

	(void)sender;
	[_selection removeAllIndexes];
	[_selection addIndexesInRange:NSMakeRange(0, (NSUInteger)[self itemCount])];
	_anchorIndex = ([self itemCount] > 0) ? 0 : -1;
	[self invalidateSelectionChangeFrom:before];
}

- (NSSize)cellSize
{
	return [WSIconLayout cellSizeForIconSize:_iconSize];
}

- (NSInteger)columnsForWidth:(CGFloat)width
{
	NSRect bounds = NSMakeRect(0.0, 0.0, width, [self bounds].size.height);

	return [WSIconLayout columnsInBounds:bounds iconSize:_iconSize
				       order:WSIconOrderLeftToRightRows];
}

- (CGFloat)contentHeightForWidth:(CGFloat)width
{
	NSInteger count = [self itemCount];
	NSInteger columns = [self columnsForWidth:width];
	NSInteger rows = (count > 0) ? (count + columns - 1) / columns : 1;
	NSSize cell = [self cellSize];

	return (CGFloat)WSIconGridMargin + (CGFloat)rows * cell.height;
}

- (void)layoutItems
{
	NSInteger count = [self itemCount];
	NSMutableArray *positions = [[NSMutableArray alloc] init];
	NSInteger i;

	for (i = 0; i < count; i++) {
		/* THE ENGINE'S Y ORIGIN IS THE TOP OF THE AREA IT IS GIVEN; the view insets it by the grid margin so the
		 * first row is not flush with the scroll view's edge. X already uses the margin inside the engine. */
		NSRect area = NSMakeRect(0.0, (CGFloat)WSIconGridMargin,
					 [self bounds].size.width, [self bounds].size.height);
		NSPoint position = [WSIconLayout gridPositionForIndex:i inBounds:area
							    iconSize:_iconSize
							       order:WSIconOrderLeftToRightRows];

		[positions addObject:[NSValue valueWithPoint:position]];
	}
	[_positions release];
	_positions = positions;
	[_icons removeAllObjects];
	for (i = 0; i < count; i++) {
		[_icons addObject:[NSNull null]];
	}
	while ([_selection lastIndex] != NSNotFound && [_selection lastIndex] >= (NSUInteger)count) {
		[_selection removeIndex:[_selection lastIndex]];
	}
	if (_anchorIndex >= count) {
		_anchorIndex = -1;
	}
	[self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self layoutItems];
}

/* **THE GRID RE-LAYS WHEN ITS CLIP VIEW CHANGES WIDTH**, not only when the window resizes: dragging the split
 * view's divider changes the visible width without a window-resize notification. */
- (void)viewDidMoveToSuperview
{
	[super viewDidMoveToSuperview];
	if (_observedClip != nil) {
		[[NSNotificationCenter defaultCenter] removeObserver:self
			name:NSViewFrameDidChangeNotification object:_observedClip];
		_observedClip = nil;
	}
	if ([self superview] != nil) {
		_observedClip = [self superview];
		[_observedClip setPostsFrameChangedNotifications:YES];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clipFrameChanged:)
			name:NSViewFrameDidChangeNotification object:_observedClip];
	}
}

- (void)clipFrameChanged:(NSNotification *)notification
{
	CGFloat width;
	CGFloat height;

	(void)notification;
	width = [[self superview] bounds].size.width;
	if (width <= 0.0) {
		return;
	}
	height = [self contentHeightForWidth:width];
	if (height < [[self superview] bounds].size.height) {
		height = [[self superview] bounds].size.height;
	}
	[self setFrameSize:NSMakeSize(width, height)];
}

- (NSArray *)cg_positions
{
	return [NSArray arrayWithArray:_positions];
}

- (NSRect)iconRectAtIndex:(NSInteger)index
{
	NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];

	return NSMakeRect(position.x, position.y, (CGFloat)_iconSize, (CGFloat)_iconSize);
}

/* **WHAT A SELECTION LOOKS LIKE: ONE RECTANGLE, AND THE RING IS ITS OUTLINE.** The CELL is asymmetric on purpose
 * (it starts at the icon and carries its padding to the right and above, so neighbouring hit rectangles share an edge
 * and never overlap), which makes it the wrong shape to PAINT: filling it put the wash a padded half-cell to the right
 * of the folder it belonged to. And the focus ring was drawn round the bare ICON, two points out — a different
 * rectangle from the wash, so the two disagreed, and its top edge landed exactly on the label's first line, cutting
 * the name in half.
 *
 * So the highlight is its own rectangle: the cell's WIDTH, centred on the icon, and tall enough to hold the icon, the
 * label and `WSIconHighlightInset` points of air on every side. The fill and the ring both take it, which is what
 * makes the colour and the outline the same shape. */
/* **THE BAND, AS A PROBE ASKS FOR IT** — `NSZeroRect` when no band is in flight, which is also what the selection's own
 * doors answer for "nothing". */
- (NSRect)cg_bandRect
{
	return _banding ? _bandRect : NSZeroRect;
}

- (NSRect)highlightRectAtIndex:(NSInteger)index
{
	return WSIconCellHighlightRect([self iconRectAtIndex:index], [self cellSize].width, YES);
}

/* **THE SELECTION BEFORE A CHANGE, AS A SNAPSHOT, BECAUSE `-copy` IS NOT ONE.** This tree's immutable family
 * answers `-copy` with `[self retain]` — right for an NSIndexSet, and a trap for a MUTABLE one: `[[_selection copy]
 * autorelease]` hands back the live set, so a caller that removes an index from `_selection` has also removed it
 * from its "before", and the cell it left is never repainted. MEASURED as a selection wash left behind on the old
 * cell. `-mutableCopy` builds a real second set, which is what a snapshot is. */
- (NSIndexSet *)snapshotSelection
{
	NSMutableIndexSet *snapshot = [[_selection mutableCopy] autorelease];

	return snapshot;
}

/* **A SELECTION THAT MOVED TWO CELLS REPAINTS TWO CELLS.** The view used to answer every change with
 * `-setNeedsDisplay:`, which invalidates the WHOLE view — so a click, a Shift-extension and every arrow key told
 * the window that all of it was stale, the window drew the whole tree again and copied the whole frame. MEASURED in
 * a live session: 20-45 ms of drawing and 2-3 MB across the socket to move a wash from one folder to the next.
 *
 * So an index is invalidated by its own highlight rectangle — the same rectangle the wash and the ring are drawn in,
 * which is what makes it the right unit — and a selection change asks for the union of what it touched: everything
 * selected BEFORE the change and everything selected after it. `before` is the caller's snapshot, taken before it
 * mutates `_selection`; a set that grew or shrank has both halves in the union, and an index in both is simply
 * asked for twice (a union of rectangles, which `-setNeedsDisplayInRect:` takes). */
- (void)invalidateItemAtIndex:(NSInteger)index
{
	if (index >= 0 && index < [self itemCount]) {
		/* **AND THE RECTANGLE IS EXPANDED BY THE RING, WHICH IS DRAWN ON ITS EDGE.** The wash is INSIDE the
		 * highlight rectangle; the focus ring is STROKED ON it, so half of the stroke — and the antialiasing
		 * either side of it — lives OUTSIDE. Invalidating the rectangle exactly left that half-point behind:
		 * MEASURED on a live screen, moving the selection from icon to icon left a thin outline in every cell it
		 * had left, and the lines only went when a full frame repainted the window. `WSIconHighlightSlop` is the
		 * ring's half-width rounded up to a whole point, so the pixels the ring touches are in the damage. */
		[self setNeedsDisplayInRect:NSInsetRect([self highlightRectAtIndex:index],
						-(CGFloat)WSIconHighlightSlop,
						-(CGFloat)WSIconHighlightSlop)];
	}
}

- (void)invalidateSelectionChangeFrom:(NSIndexSet *)before
{
	NSMutableIndexSet *changed = [[NSMutableIndexSet alloc] init];
	NSUInteger index;

	if (before != nil) {
		[changed addIndexes:before];
	}
	[changed addIndexes:_selection];
	for (index = [changed firstIndex]; index != NSNotFound; index = [changed indexGreaterThanIndex:index]) {
		[self invalidateItemAtIndex:(NSInteger)index];
	}
	[changed release];
	/* **AND THE CLAIM GOES OUT FROM HERE, BECAUSE EVERY CHANGE PASSES THROUGH HERE.** `-selectIndex:`, `-selectIndexes:`,
	 * Select All, a Shift-extension, a Command-click and a band's release all end in this method — so one post covers them
	 * and a new way to select cannot forget to announce itself. A selection that became EMPTY announces nothing: only
	 * choosing is a claim, and a view that cleared itself must not take the selection away from the window next door. */
	if ([_selection count] > 0) {
		[[NSNotificationCenter defaultCenter] postNotificationName:WSSelectionDidChangeNotification object:self];
	}
}

/* **ANOTHER SURFACE TOOK THE SELECTION, SO THIS ONE LETS GO OF ITS OWN.** The anchor goes with it — a Shift-click after
 * the claim moved away must not extend a range from an item that is no longer part of the selection. Nothing is announced
 * from here: this view is giving up, not choosing, and a re-post would ping the claim back and forth between two views
 * that are both now empty. */
- (void)fn_selectionHeldElsewhere:(NSNotification *)note
{
	NSIndexSet *before;

	if ([note object] == self || [_selection count] == 0) {
		return;
	}
	before = [self snapshotSelection];
	[_selection removeAllIndexes];
	_anchorIndex = -1;
	[self invalidateSelectionChangeFrom:before];
}

/* The view's own name for that rectangle, for the probe: the fill and the focus ring are the same rect. */
- (NSRect)cg_highlightRectAtIndex:(NSInteger)index { return [self highlightRectAtIndex:index]; }

- (NSRect)cellRectAtIndex:(NSInteger)index
{
	NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];
	NSSize cell = [self cellSize];

	/* THE CELL STARTS AT THE ICON and takes the padding to its right and below; the grid's next cell begins after it,
	 * so adjacent hit rectangles share an edge and never overlap. */
	return NSMakeRect(position.x, position.y, cell.width, cell.height);
}

- (NSInteger)indexAtPoint:(NSPoint)point
{
	NSUInteger i;

	for (i = 0; i < [_positions count]; i++) {
		if (NSPointInRect(point, [self cellRectAtIndex:(NSInteger)i])) {
			return (NSInteger)i;
		}
	}
	return -1;
}

- (NSImage *)iconForIndex:(NSInteger)index
{
	id cached;
	WSItem *item;

	if (index < 0 || index >= (NSInteger)[_icons count]) {
		return nil;
	}
	cached = [_icons objectAtIndex:(NSUInteger)index];
	if (cached != [NSNull null]) {
		return cached;
	}
	item = [[_model items] objectAtIndex:(NSUInteger)index];
	cached = [WSItemIcons iconForPath:[item path] isDirectory:[item isDirectory] size:_iconSize];
	if (cached == nil) {
		return nil;
	}
	[_icons replaceObjectAtIndex:(NSUInteger)index withObject:cached];
	return cached;
}

/* ---- DRAWING --------------------------------------------------------------------------------- */

- (void)drawRect:(NSRect)dirtyRect
{
	NSArray *items = (_model != nil) ? [_model items] : nil;
	NSInteger count = (NSInteger)[items count];
	BOOL focused = ([[self window] firstResponder] == self);
	NSInteger i;

	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:[self bounds]] fill];

	/* **A DRAW THAT WILL DECODE A PILE OF PICTURES SAYS "WORKING" FIRST.** The pointer is the compositor's, and the
	 * request crosses with a flush, so the shape is on the glass before the decodes start rather than after them. A
	 * threshold of two is what "a pile" means: one or two are a frame's work, and a pointer that flickers is worse than a
	 * wait that is not announced. */
	{
		NSInteger pending = 0;
		NSWindow *window = [self window];

		for (i = 0; i < count; i++) {
			if (!NSIsEmptyRect(dirtyRect) && !NSIntersectsRect(dirtyRect, [self highlightRectAtIndex:i])) {
				continue;
			}
			/* **ONLY A PICTURE IS A DECODE.** A document's icon is a lookup Icon Services answers from the type; that is
			 * fast enough to be part of the frame, and a wait announced for it would flicker over every folder in the
			 * file manager. */
			if (i < (NSInteger)[_icons count] && [_icons objectAtIndex:(NSUInteger)i] == [NSNull null]
			    && [WSItemIcons isImageFile:[[items objectAtIndex:(NSUInteger)i] path]]) {
				pending++;
			}
		}
		if (pending > 2 && window != nil) {
			[window cg_applyCursor:[NSCursor busyButClickableCursor]];
			_busyCursorUses++;
			_busyCursorRestore = YES;
		}
	}

	for (i = 0; i < count; i++) {
		WSItem *item = [items objectAtIndex:(NSUInteger)i];
		NSRect cellRect = [self cellRectAtIndex:i];
		NSRect highlightRect = [self highlightRectAtIndex:i];
		NSDictionary *attributes;
		NSString *label;
		WSIconCell cell;

		/* **AND AN ITEM THE DIRTY RECTANGLE DOES NOT TOUCH IS NOT DRAWN AT ALL.** The clip already stops its pixels,
		 * but a name is CUT TO THE CELL BY MEASURING IT (`WSIconLabelText`) before anything is drawn, and a measure is
		 * a layout and a glyph run — so the clock was spent whether or not a pixel was painted. The highlight is the
		 * unit because it holds everything this loop draws for the item: the wash, the icon and the label. */
		if (!NSIsEmptyRect(dirtyRect) && !NSIntersectsRect(dirtyRect, highlightRect)) {
			continue;
		}
		/* **THE NAME STAYS IN BLACK INK ON THE WASH.** A selected name used to be drawn in white on a 35% blue wash
		 * over white — a wash is not a plate, and the result was the ghost the screenshot showed. The table view reached
		 * the same verdict for the platform's own light accent ("white on it is a wash, MEASURED"), and one rule for
		 * selected ink across the tier is worth more than one gesture's brightness. The name is CUT to the cell
		 * (`WSIconLabelText`), which is a measurement, so the cell's width is what decides how much of it there is. */
		attributes = [NSDictionary dictionaryWithObjectsAndKeys:[NSColor blackColor],
							  NSForegroundColorAttributeName, nil];
		label = WSIconLabelText([item name], cellRect.size.width - 4.0, attributes);

		cell.iconRect = [self iconRectAtIndex:i];
		cell.cellWidth = cellRect.size.width;
		cell.labelBelow = YES;	/* this view is flipped: `NSMaxY` is below the icon */
		cell.icon = [self iconForIndex:i];
		cell.label = label;
		cell.attributes = attributes;
		cell.labelShadow = NO;	/* a page, not a photograph: black ink needs nothing under it */
		cell.selected = [_selection containsIndex:(NSUInteger)i];
		/* **THE RING IS THE FIRST SELECTED CELL'S**, not every selected one's: a band that takes six icons draws one
		 * outline, which is where the keyboard's focus is. */
		cell.focused = (focused && i == [self selectedIndex]);
		WSIconCellDraw(cell);
	}

	/* **AND THE BAND, OVER EVERYTHING IT IS TAKING.** It is the pointer's footprint, so it is drawn after the icons: a
	 * wash under them would leave them looking untaken until the button came up. */
	if (_banding) {
		WSSelectionBandDraw(_bandRect);
	}
	if (_busyCursorRestore) {
		/* THE POINTER A PERSON'S POSITION ASKS FOR, ONCE THE PICTURES ARE DONE. */
		_busyCursorRestore = NO;
		[[self window] cg_refreshCursorAtRestingPointer];
	}

	if (_dropOperation != NSDragOperationNone) {
		[[NSColor colorWithCalibratedRed:0.25 green:0.45 blue:0.90 alpha:0.9] setStroke];
		if (_dropIndex >= 0 && _dropIndex < count) {
			[[NSBezierPath bezierPathWithRect:NSInsetRect([self cellRectAtIndex:_dropIndex], 1.0, 1.0)]
				stroke];
		} else {
			[[NSBezierPath bezierPathWithRect:NSInsetRect([self bounds], 2.0, 2.0)] stroke];
		}
	}
}

/* ---- SELECTION AND THE KEYBOARD -------------------------------------------------------------- */

- (void)extendSelectionToIndex:(NSInteger)index
{
	NSIndexSet *before = [self snapshotSelection];
	NSInteger anchor = (_anchorIndex >= 0) ? _anchorIndex : index;
	NSInteger lo = (anchor < index) ? anchor : index;
	NSInteger hi = (anchor < index) ? index : anchor;

	[_selection removeAllIndexes];
	[_selection addIndexesInRange:NSMakeRange((NSUInteger)lo, (NSUInteger)(hi - lo + 1))];
	[self invalidateSelectionChangeFrom:before];
}

- (void)moveSelectionBy:(NSInteger)delta extend:(BOOL)extend
{
	NSInteger count = [self itemCount];
	NSInteger index = [self selectedIndex];

	if (count == 0) {
		return;
	}
	if (index < 0) {
		index = (delta >= 0) ? 0 : count - 1;
	} else {
		index += delta;
	}
	if (index < 0) index = 0;
	if (index >= count) index = count - 1;
	if (extend) {
		[self extendSelectionToIndex:index];
	} else {
		[self selectIndex:index];
	}
}

- (void)typeSelectWithCharacter:(unichar)character
{
	NSInteger count = [self itemCount];
	NSInteger start;
	NSInteger i;
	NSString *typed;

	if (count == 0) {
		return;
	}
	{
		NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

		if (now - _typeSelectTime > 1.0) {
			[_typeSelectString setString:@""];
		}
		_typeSelectTime = now;
	}
	[_typeSelectString appendString:[NSString stringWithCharacters:&character length:1]];
	typed = _typeSelectString;
	start = [self selectedIndex];
	start = (start < 0) ? 0 : (start + 1) % count;
	for (i = 0; i < count; i++) {
		NSInteger index = (start + i) % count;
		NSString *name = [[[_model items] objectAtIndex:(NSUInteger)index] name];

		if ([name rangeOfString:typed options:NSCaseInsensitiveSearch].location == 0) {
			[self selectIndex:index];
			return;
		}
	}
}

- (void)openItemAtIndex:(NSInteger)index
{
	if (index < 0 || index >= [self itemCount]) {
		return;
	}
	if ([_delegate respondsToSelector:@selector(iconView:openItem:)]) {
		[_delegate iconView:self openItem:[[_model items] objectAtIndex:(NSUInteger)index]];
	}
}

- (void)openSelectedItems
{
	NSIndexSet *selected = [self selectedIndexes];
	NSUInteger index;

	/* A frozen copy, so a delegate that changes the model cannot move the set underneath the walk. */
	for (index = [selected firstIndex]; index != NSNotFound; index = [selected indexGreaterThanIndex:index]) {
		[self openItemAtIndex:(NSInteger)index];
	}
}

- (void)keyDown:(NSEvent *)event
{
	NSString *characters = [event characters];
	unichar character;
	NSUInteger flags = [event modifierFlags];
	NSInteger count = [self itemCount];

	if ([characters length] == 0) {
		[super keyDown:event];
		return;
	}
	character = [characters characterAtIndex:0];
	if (count == 0) {
		[super keyDown:event];
		return;
	}

	/* Command's two before the arrows: Command-Down opens, and must not be read as a plain Down. */
	if ((flags & NSCommandKeyMask) != 0 && (character == 'a' || character == 'A')) {
		[self selectAll:nil];
		return;
	}
	if ((flags & NSCommandKeyMask) != 0 && character == NSDownArrowFunctionKey) {
		[self openSelectedItems];
		return;
	}
	if (character == NSLeftArrowFunctionKey) {
		[self moveSelectionBy:-1 extend:(flags & NSShiftKeyMask) != 0];
		return;
	}
	if (character == NSRightArrowFunctionKey) {
		[self moveSelectionBy:1 extend:(flags & NSShiftKeyMask) != 0];
		return;
	}
	if (character == NSUpArrowFunctionKey) {
		NSInteger columns = [self columnsForWidth:[self bounds].size.width];

		[self moveSelectionBy:-columns extend:(flags & NSShiftKeyMask) != 0];
		return;
	}
	if (character == NSDownArrowFunctionKey) {
		NSInteger columns = [self columnsForWidth:[self bounds].size.width];

		[self moveSelectionBy:columns extend:(flags & NSShiftKeyMask) != 0];
		return;
	}
	if (character == NSHomeFunctionKey) {
		if ((flags & NSShiftKeyMask) != 0) {
			[self extendSelectionToIndex:0];
		} else {
			[self selectIndex:0];
		}
		return;
	}
	if (character == NSEndFunctionKey) {
		if ((flags & NSShiftKeyMask) != 0) {
			[self extendSelectionToIndex:count - 1];
		} else {
			[self selectIndex:count - 1];
		}
		return;
	}
	if (character == '\r' || character == '\n') {
		[self beginRenamingSelectedItem];
		return;
	}
	if (character == 0x1b) {
		if (_renaming) {
			[self cancelRenaming];
		} else {
			[self selectIndex:-1];
		}
		return;
	}
	if (character >= 32 && (flags & (NSCommandKeyMask | NSControlKeyMask)) == 0) {
		[self typeSelectWithCharacter:character];
		return;
	}
	[super keyDown:event];
}

/* ---- THE MOUSE AND THE DRAG SOURCE ----------------------------------------------------------- */

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSInteger index = [self indexAtPoint:point];
	NSUInteger flags = [event modifierFlags];
	BOOL shift = (flags & NSShiftKeyMask) != 0;
	/* **COMMAND AND CONTROL BOTH TOGGLE**, because one is the Mac's spelling of "add this one too" and the other is
	 * every other desktop's: a person from Linux presses Control on an icon and expects it to join the selection. */
	BOOL toggle = (flags & (NSCommandKeyMask | NSControlKeyMask)) != 0;

	[[self window] makeFirstResponder:self];
	if ([event clickCount] >= 2) {
		if (index >= 0) {
			[self selectIndex:index];
			[self openItemAtIndex:index];
		}
		return;
	}
	if (index < 0) {
		/* **A PRESS IN THE EMPTY SPACE BEGINS A BAND.** It used to clear the selection and stop, which made the gesture
		 * that takes several icons at once impossible — the one thing a grid of icons is for. The band's selection is
		 * applied when the button comes up (the desktop's own rule), so a drag across the grid does not repaint the
		 * selection under the hand it is following. */
		if (!shift && !toggle) {
			[self selectIndex:-1];
		}
		_anchorIndex = -1;
		_pressing = NO;
		_banding = YES;
		/* **THE BAND TAKES THE POINTER FOR THE LENGTH OF THE GESTURE.** A person dragging a selection walks out of the
		 * view — over the sidebar, the toolbar, the desktop — and a compositor delivers motion to the surface under the
		 * pointer, so without the capture the motion and the release go to whichever surface the hand is over: the band
		 * stopped following the hand, and letting go left it on the screen. The window's own doors take the pointer the
		 * same way for a title-bar drag. */
		[[self window] cg_setPointerCapture:YES];
		_bandAdditive = (shift || toggle);
		_bandOrigin = point;
		_bandRect = NSMakeRect(point.x, point.y, 0.0, 0.0);
		[_bandBase release];
		_bandBase = [[self snapshotSelection] retain];
		return;
	}
	if (shift) {
		if (_anchorIndex < 0) {
			_anchorIndex = index;
		}
		[self extendSelectionToIndex:index];
	} else if (toggle) {
		NSIndexSet *before = [self snapshotSelection];

		if ([_selection containsIndex:(NSUInteger)index]) {
			[_selection removeIndex:(NSUInteger)index];
		} else {
			[_selection addIndex:(NSUInteger)index];
		}
		_anchorIndex = index;
		[self invalidateSelectionChangeFrom:before];
	} else if (![_selection containsIndex:(NSUInteger)index]) {
		[self selectIndex:index];
	} else {
		_anchorIndex = index;
	}
	_pressIndex = index;
	_pressPoint = point;
	_pressing = YES;
}

- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point;

	/* **THE BAND FOLLOWS THE POINTER, AND ONLY ITS OWN TWO RECTANGLES ARE REPAINTED.** A band moves every motion, so
	 * the view-wide invalidation the selection uses would repaint every icon sixty times a second. The old and the new
	 * rectangle are both damaged, with a margin for the hairline. */
	if (_banding) {
		NSRect old = _bandRect;

		point = [self convertPoint:[event locationInWindow] fromView:nil];
		_bandRect = NSMakeRect(point.x < _bandOrigin.x ? point.x : _bandOrigin.x,
				       point.y < _bandOrigin.y ? point.y : _bandOrigin.y,
				       (CGFloat)fabs((double)(point.x - _bandOrigin.x)),
				       (CGFloat)fabs((double)(point.y - _bandOrigin.y)));
		if (!NSIsEmptyRect(old)) {
			[self setNeedsDisplayInRect:NSInsetRect(old, -2.0, -2.0)];
		}
		[self setNeedsDisplayInRect:NSInsetRect(_bandRect, -2.0, -2.0)];
		return;
	}
	if (!_pressing || _pressIndex < 0) {
		return;
	}
	point = [self convertPoint:[event locationInWindow] fromView:nil];
	if (fabs((double)(point.x - _pressPoint.x)) < WS_ICON_DRAG_THRESHOLD
	    && fabs((double)(point.y - _pressPoint.y)) < WS_ICON_DRAG_THRESHOLD) {
		return;
	}
	_pressing = NO;
	(void)[self cg_beginDragWithEvent:event];
}

- (void)mouseUp:(NSEvent *)event
{
	(void)event;
	if (_banding) {
		NSIndexSet *before = [self snapshotSelection];
		NSMutableIndexSet *chosen = [NSMutableIndexSet indexSet];
		NSInteger count = (NSInteger)[[_model items] count];
		NSInteger i;

		/* **EVERY ITEM THE BAND TOUCHES IS TAKEN**, which is the rectangle's answer rather than its centre's: a band
		 * dragged across the corner of an icon has taken that icon, and a person who did not mean it drags again. */
		for (i = 0; i < count; i++) {
			if (NSIntersectsRect(_bandRect, [self highlightRectAtIndex:i])) {
				[chosen addIndex:(NSUInteger)i];
			}
		}
		if (_bandAdditive) {
			[chosen addIndexes:_bandBase];
		}
		[_selection removeAllIndexes];
		[_selection addIndexes:chosen];
		if (count > 0) {
			_anchorIndex = (NSInteger)[chosen firstIndex];
			if (_anchorIndex == (NSInteger)NSNotFound) {
				_anchorIndex = -1;
			}
		}
		_banding = NO;
		[_bandBase release];
		_bandBase = nil;
		[[self window] cg_setPointerCapture:NO];
		/* **THE END OF A BAND REPAINTS THE VIEW, ONCE.** The band is a wash over everything it crossed, so the cells it
		 * took are not the only pixels it changed — the gaps between them are too, and a per-rectangle invalidation left a
		 * strip of wash behind. MEASURED on a live screen: letting go of a band that crossed a folder left a lavender
		 * strip down the grid's right edge until something else repainted the view. One full repaint at the end of the
		 * gesture is a cost paid once, where the drag's own damage is paid per motion. */
		[self setNeedsDisplay:YES];
		[self invalidateSelectionChangeFrom:before];
		return;
	}
	_pressing = NO;
}

/* ---- THE CONTEXT MENU, AND WHAT A SINGLE ITEM CAN ANSWER ---------------------------------------- */

/* **A RIGHT-CLICK NAMES ITS ITEM, AND THE MENU IS ABOUT THAT ONE.** The click narrows the selection to the icon under the
 * pointer first: the menu `WSContextMenu` builds is a single item's, so a right-click inside a group makes that icon the
 * subject rather than offering commands that would have to mean five different things. The BACKGROUND's menu is not this
 * stage's, so a click on empty grid answers nil and nothing opens. */
- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSInteger index;

	if (event == nil) {
		return nil;
	}
	index = [self indexAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
	if (index < 0) {
		/* **NOTHING UNDER THE POINTER IS THE FOLDER'S MENU, NOT NO MENU.** The grid is always the view of a directory,
		 * so a click on its empty space has three things to offer about that directory — and the selection is left
		 * alone, because Paste and New Folder are useful WITH something held elsewhere. */
		return [WSContextMenu menuForBackgroundWithTarget:self];
	}
	/* **A CLICK ON ONE OF SEVERAL HOLDS THE GROUP.** Narrowing to the icon under the pointer would make a group's menu
	 * impossible to reach — the pointer must be somewhere, and it is always over one of the icons the menu is about. So
	 * the selection is narrowed only when the click landed OUTSIDE it, which is the same rule a left-click follows. */
	if (![_selection containsIndex:(NSUInteger)index]) {
		[self selectIndex:index];
	}
	return ([_selection count] > 1)
		? [WSContextMenu menuForMultipleItemsWithTarget:self]
		: [WSContextMenu menuForSingleItemWithTarget:self];
}

/* **THE WINDOW THAT OWNS THIS GRID IS TOLD THE DIRECTORY CHANGED** — the same tidings a rename sends, because the status
 * bar, the other view modes and the toolbar all read the window controller's refresh. A command the VIEW performs on the
 * menu's behalf has to leave the window in the state the controller's own command would. */
- (void)fn_didChangeModel
{
	if ([_delegate respondsToSelector:@selector(iconViewDidChangeModel:)]) {
		[_delegate iconViewDidChangeModel:self];
	}
}

/* **AND AN OPERATION IS THE WINDOW'S TO END, NOT ONLY TO NOTICE.** The manager this grid was handed is the window's, so
 * the progress plate it opened is the window's to close; `-finishOperation` is that ending, and a window that answers
 * neither door still gets the model tidings. */
- (void)fn_didFinishOperation
{
	if ([_delegate respondsToSelector:@selector(iconViewDidFinishOperation:)]) {
		[_delegate iconViewDidFinishOperation:self];
	} else {
		[self fn_didChangeModel];
	}
}

/* NEW FOLDER IS W6'S OPERATION and the new folder is what is held afterwards, which is the reference file manager's own
 * behaviour: the thing a person asked for is the thing their hand is on. */
- (void)newFolder:(id)sender
{
	NSString *made;

	(void)sender;
	made = [_fileOperations createFolderInDirectory:[_model directory] name:nil error:NULL];
	[self reloadAfterChange];
	if (made != nil) {
		[self cg_selectPaths:[NSArray arrayWithObject:made]];
	}
	[self fn_didFinishOperation];
}

/* **NEW FOLDER WITH SELECTION GATHERS WHAT IS HELD INTO A FOLDER OF ITS OWN**, which is the reference file manager's
 * answer to "these belong together": the folder is made in this grid's directory (its name made unique by W6), the
 * selection moves into it, and the folder is what the hand is left on. */
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
	[self reloadAfterChange];
	[self cg_selectPaths:[NSArray arrayWithObject:made]];
	[self fn_didFinishOperation];
}

/* RENAME IS THE INLINE FIELD W3 ALREADY PUTS OVER THE LABEL — the menu's row is the same gesture as the Return key, so it
 * is the same door rather than a second copy of the field. */
- (void)rename:(id)sender
{
	(void)sender;
	(void)[self beginRenamingSelectedItem];
}

/* COPY IS THE PATHS ON THE GENERAL PASTEBOARD, by the rule `WSItemDrag` writes once for both surfaces. */
- (void)copy:(id)sender
{
	(void)sender;
	WSItemCopyPathsToPasteboard([self cg_selectedPaths]);
}

/* **CUT IS THE SAME OFFER WITH "AND TAKE THEM" ON IT, AND PASTE IS WHAT HONOURS IT.** Without a paste a cut is a copy
 * with a lie in it, so the pair arrives together: the paste moves what was cut and copies what was copied, into this
 * grid's own directory, through the same W6 operations the rest of the menu uses. */
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
	[self reloadAfterChange];
	[self fn_didFinishOperation];
}

/* MOVE TO TRASH IS W6'S OPERATION through the manager this view was handed — the same call the file window's own
 * `-moveToTrash:` makes — and the grid then reads its directory again, keeping what is still there selected. */
- (void)moveToTrash:(id)sender
{
	(void)sender;
	if ([_selection count] == 0) {
		return;
	}
	(void)[_fileOperations movePathsToTrash:[self cg_selectedPaths] error:NULL];
	[self reloadAfterChange];
	[self fn_didFinishOperation];
}

/* **THE TWO ROWS THE GRID'S MENU HAS AND THIS VIEW DID NOT ANSWER.** The menu is aimed at the view, so a row the view
 * cannot answer is a row a person sees greyed — MEASURED: right-clicking an icon offered Get Info and (since the menu
 * gained it) Compress, and neither did anything, because the list and the browser aim their menus at the WINDOW and this
 * one aims at itself. Both commands are the same objects the window's are: the inspector's registry makes one window per
 * subject, and an archive is made beside what it compressed. */
- (void)getInfo:(id)sender
{
	NSArray *paths = [self cg_selectedPaths];

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	(void)[WSGetInfoWindowController infoWindowForPaths:paths];
}

- (void)compress:(id)sender
{
	NSArray *paths = [self cg_selectedPaths];

	(void)sender;
	if ([paths count] == 0) {
		return;
	}
	(void)[_fileOperations compressPaths:paths inDirectory:[_model directory] error:NULL];
	[self reloadAfterChange];
	[self fn_didFinishOperation];
}

/* **THE TRASH IS THE WINDOW'S FACT, NOT THE GRID'S.** The grid raises its own menu — Cut, Copy, Rename, Move to Trash
 * are all commands it answers — so the menu is aimed at THIS view, and a view that cannot say whether it is showing the
 * bin gets the menu of an ordinary folder even when it is one. The window's controller knows; the row appears when it
 * says so, in the grid as it already did in the list and the browser. */
- (BOOL)isTrashDirectory
{
	id delegate = [[self window] delegate];

	return (delegate != nil && [delegate respondsToSelector:@selector(isTrashDirectory)]
		&& [delegate isTrashDirectory]);
}

/* **AND THE WAY OUT OF IT IS THE WINDOW'S COMMAND.** Every other row here the grid answers itself, from the operations
 * it was handed; Put Back needs the Put Back RECORD and the window is where that lives, so the row is forwarded to the
 * controller rather than reimplemented — the same command the list and the browser reach directly. */
- (void)putBack:(id)sender
{
	id delegate = [[self window] delegate];

	if ([delegate respondsToSelector:@selector(putBack:)]) {
		[delegate performSelector:@selector(putBack:) withObject:sender];
	}
}

- (NSArray *)cg_selectedPaths
{
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSUInteger index;

	for (index = [_selection firstIndex]; index != NSNotFound; index = [_selection indexGreaterThanIndex:index]) {
		WSItem *item = [[_model items] objectAtIndex:index];

		[paths addObject:[item path]];
	}
	return [paths autorelease];
}

- (NSDraggingSession *)cg_beginDragWithEvent:(NSEvent *)event
{
	NSArray *paths = [self cg_selectedPaths];
	NSMutableArray *items;
	NSDraggingSession *session;
	NSUInteger index;

	if ([paths count] == 0) {
		return nil;
	}
	items = [[NSMutableArray alloc] init];
	for (index = [_selection firstIndex]; index != NSNotFound; index = [_selection indexGreaterThanIndex:index]) {
		NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:nil];
		NSPoint position = [[_positions objectAtIndex:index] pointValue];

		[item setDraggingFrame:NSMakeRect(position.x, position.y, (CGFloat)_iconSize, (CGFloat)_iconSize)
			      contents:[self iconForIndex:(NSInteger)index]];
		[items addObject:item];
		[item release];
	}
	session = WSItemDragBegin(self, paths, items, event, self);
	[items release];
	_dragging = (session != nil);
	return session;
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
	return isLocal ? (NSDragOperationMove | NSDragOperationCopy | NSDragOperationLink) : NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint
	      operation:(NSDragOperation)operation
{
	(void)session;
	(void)screenPoint;
	_dragging = NO;
	if (operation != NSDragOperationNone) {
		[self reloadAfterChange];
	}
}

/* ---- THE DRAG DESTINATION -------------------------------------------------------------------- */

- (NSString *)dropDirectoryForIndex:(NSInteger)index
{
	if (index >= 0 && index < [self itemCount]) {
		WSItem *item = [[_model items] objectAtIndex:(NSUInteger)index];

		return [item isDirectory] ? [item path] : nil;
	}
	return (_model != nil) ? [_model directory] : nil;
}

- (NSDragOperation)cg_proposedOperationForSameVolume:(BOOL)sameVolume modifiers:(NSUInteger)modifiers
{
	/* THE RULE IS `WSItemDrag`'s — the desktop asks the same question of the same files, and one answer is worth more
	 * than two that agree today. The mask is every operation because this door is asked outside a drag as well. */
	return WSItemDragOperationForVolume(sameVolume, NSDragOperationEvery, modifiers);
}

- (NSDragOperation)cg_updateDropWithInfo:(id <NSDraggingInfo>)info
{
	NSPoint point = [self convertPoint:[info draggingLocation] fromView:nil];
	NSInteger index = [self indexAtPoint:point];
	NSString *target = [self dropDirectoryForIndex:index];
	NSArray *paths = WSItemDragPaths(info);
	NSDragOperation operation = NSDragOperationNone;

	if (_sprungIndex >= 0 && index != _sprungIndex) {
		_sprungIndex = -1;
	}
	if (index != _springIndex) {
		[self cancelSpring];
	}
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	if (target != nil && [paths count] > 0) {
		operation = WSItemDragOperation(paths, target, [info draggingSourceOperationMask],
						[NSEvent modifierFlags]);
		if (operation != NSDragOperationNone) {
			_dropIndex = (index >= 0) ? index : -1;
			_dropOperation = operation;
			/* **A PACKAGE IS NOT A PLACE TO SPRING OPEN.** Spring-loading is "hold the pointer over a folder and it
			 * opens so the drop can go inside"; a bundle is one thing, and a drop onto it is a drop onto the item — the
			 * same distinction a double-click makes between navigating and launching. */
			if (index >= 0 && [[[_model items] objectAtIndex:(NSUInteger)index] isBrowsable]) {
				[self scheduleSpringForIndex:index];
			}
		}
	}
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
	[self cancelSpring];
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	_sprungIndex = -1;
	[self setNeedsDisplay:YES];
}

- (void)draggingEnded:(id <NSDraggingInfo>)sender
{
	(void)sender;
	[self cancelSpring];
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	_sprungIndex = -1;
	[self setNeedsDisplay:YES];
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
	BOOL performed = NO;

	if (paths != nil && target != nil && operation != NSDragOperationNone) {
		performed = [self cg_performDropOfPaths:paths intoDirectory:target operation:operation];
	}
	if (performed) {
		NSMutableArray *arrived = [NSMutableArray array];
		NSUInteger i;

		[self reloadAfterChange];
		/* **WHAT ARRIVED IS WHAT IS SELECTED**, named in the directory it arrived in: the same leaf under `target`. */
		for (i = 0; i < [paths count]; i++) {
			[arrived addObject:[target stringByAppendingPathComponent:
				[[paths objectAtIndex:i] lastPathComponent]]];
		}
		[self cg_selectPaths:arrived];
		if ([[sender draggingSource] respondsToSelector:@selector(reloadAfterChange)]) {
			[(id <WSItemDragSourceReloading>)[sender draggingSource] reloadAfterChange];
		}
	}
	[self cancelSpring];
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	_sprungIndex = -1;
	[self setNeedsDisplay:YES];
	return performed;
}

- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
	(void)sender;
	[self cancelSpring];
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	_sprungIndex = -1;
	[self setNeedsDisplay:YES];
}

- (BOOL)cg_performDropOfPaths:(NSArray *)paths intoDirectory:(NSString *)directory
		    operation:(NSDragOperation)operation
{
	return WSItemDragPerformWithOperations(paths, directory, operation, _fileOperations);
}

/* ---- SPRING-LOADED FOLDERS ------------------------------------------------------------------- */

- (void)cancelSpring
{
	[_springTimer invalidate];
	[_springTimer release];
	_springTimer = nil;
	_springIndex = -1;
}

- (void)scheduleSpringForIndex:(NSInteger)index
{
	if (index == _springIndex) {
		return;
	}
	[self cancelSpring];
	_springIndex = index;
	if (index < 0 || index == _sprungIndex) {
		return;
	}
	_springTimer = [[NSTimer scheduledTimerWithTimeInterval:WS_ICON_SPRING_DELAY
							target:self
						      selector:@selector(springTimerFired:)
						      userInfo:nil
						       repeats:NO] retain];
}

- (void)springTimerFired:(NSTimer *)timer
{
	(void)timer;
	[_springTimer release];
	_springTimer = nil;
	[self cg_springOpen];
}

- (NSInteger)cg_busyCursorUses
{
	return _busyCursorUses;
}

- (void)cg_springOpen
{
	NSString *path;
	NSDictionary *info;

	if (_springIndex < 0 || _springIndex >= [self itemCount] || _springIndex == _sprungIndex) {
		return;
	}
	if (![[[_model items] objectAtIndex:(NSUInteger)_springIndex] isBrowsable]) {
		return;
	}
	_sprungIndex = _springIndex;
	path = [[[_model items] objectAtIndex:(NSUInteger)_springIndex] path];
	info = [NSDictionary dictionaryWithObject:path forKey:WSIconViewFolderPathKey];
	[[NSNotificationCenter defaultCenter] postNotificationName:WSIconViewRequestFolderWindowNotification
							    object:self userInfo:info];
	[self cancelSpring];	/* the folder is open; do not ask twice for the same hover */
}

/* ---- INLINE RENAME --------------------------------------------------------------------------- */

- (NSTextField *)cg_renameField { return _renameField; }
- (BOOL)isRenaming { return _renaming; }

- (BOOL)beginRenamingSelectedItem
{
	NSInteger index = [self selectedIndex];
	WSItem *item;
	NSRect highlight;
	NSTextField *field;
	NSRect frame;

	if (_renaming) {
		[self cancelRenaming];
	}
	if (index < 0 || [_selection count] != 1) {
		return NO;
	}
	item = [[_model items] objectAtIndex:(NSUInteger)index];
	/* **THE FIELD LANDS WHERE THE LABEL WAS** — centred on the icon, inside the highlight's width, not on the cell's
	 * off-centre rectangle; otherwise the name jumped a padded half-cell sideways the moment Return was pressed. */
	highlight = [self highlightRectAtIndex:index];
	frame = NSMakeRect(highlight.origin.x + 2.0,
			   NSMaxY([self iconRectAtIndex:index]) + (CGFloat)WSIconLabelGap - 2.0,
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
	/* **THE EXTENSION IS NOT SELECTED, WHICH IS THE ONE PART OF THE RENAME A PERSON NOTICES FIRST.** A file's base
	 * name is what is being edited; its extension is a fact about the file and is left alone. A directory has no
	 * extension to preserve, so its whole name is selected. */
	/* **AND A BUNDLE'S EXTENSION IS LEFT ALONE TOO.** The rule is "the name a person edits, and not the fact about the
	 * file": a directory has no extension to preserve, so its whole name is selected — EXCEPT a package, whose `.app`
	 * is the thing that makes it a package, and renaming it away is renaming an application into a folder. */
	if (![item isDirectory] || [item isPackage]) {
		NSText *editor = [field currentEditor];
		NSRange dot = [[item name] rangeOfString:@"." options:NSBackwardsSearch];

		if (editor != nil && dot.location != NSNotFound && dot.location > 0) {
			[editor setSelectedRange:NSMakeRange(0, dot.location)];
		}
	}
	return YES;
}

- (void)renameFieldAction:(id)sender
{
	(void)sender;
	(void)[self commitRenaming];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	NSNumber *movement;
	NSInteger value;

	if (!_renaming) {
		return;
	}
	movement = [[notification userInfo] objectForKey:NSTextMovementUserInfoKey];
	value = (movement != nil) ? [movement integerValue] : NSTextMovementOther;
	if (value == NSTextMovementCancel) {
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
		[self setNeedsDisplay:YES];
		return NO;
	}
	if ([name isEqual:[item name]]) {
		[self setNeedsDisplay:YES];
		return YES;
	}
	if ([manager fileExistsAtPath:newPath]) {
		[self setNeedsDisplay:YES];
		return NO;
	}
	if ((_fileOperations != nil)
	    ? ([_fileOperations renamePath:oldPath toName:name error:NULL] != nil)
	    : [manager moveItemAtPath:oldPath toPath:newPath error:NULL]) {
		NSUInteger i;

		[_model reload];
		[self layoutItems];
		[_selection removeAllIndexes];
		for (i = 0; i < [[_model items] count]; i++) {
			if ([[[[_model items] objectAtIndex:i] name] isEqual:name]) {
				[_selection addIndex:i];
				_anchorIndex = (NSInteger)i;
				break;
			}
		}
		[self fn_didChangeModel];
		renamed = YES;
	}
	[self setNeedsDisplay:YES];
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
}

/* ---- RELOAD, KEEPING THE SELECTION THAT IS STILL THERE ---------------------------------------- */

- (void)reloadAfterChange
{
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSUInteger index;
	NSUInteger i;

	for (index = [_selection firstIndex]; index != NSNotFound; index = [_selection indexGreaterThanIndex:index]) {
		[paths addObject:[[[_model items] objectAtIndex:index] path]];
	}
	[_model reload];
	[self layoutItems];
	[_selection removeAllIndexes];
	_anchorIndex = -1;
	for (i = 0; i < [[_model items] count]; i++) {
		NSString *path = [[[_model items] objectAtIndex:i] path];

		if ([paths containsObject:path]) {
			[_selection addIndex:i];
			if (_anchorIndex < 0) {
				_anchorIndex = (NSInteger)i;
			}
		}
	}
	[paths release];
	if ([_delegate respondsToSelector:@selector(iconViewDidChangeModel:)]) {
		[_delegate iconViewDidChangeModel:self];
	}
	[self setNeedsDisplay:YES];
}

@end
