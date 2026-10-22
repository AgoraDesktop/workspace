/*
 * WSIconView.m — the grid, the keyboard, the rename field and the drag destination.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
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

#import "WSFileOperations.h"
#import "WSIconLabel.h"
#import "WSIconLayout.h"
#import "WSItemIcons.h"
#import "WSItemModel.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
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

NSString *WSIconViewRequestFolderWindowNotification = @"WSIconViewRequestFolderWindowNotification";
NSString *WSIconViewFolderPathKey = @"WSIconViewFolderPath";

#define WS_ICON_DRAG_THRESHOLD 4.0
#define WS_ICON_SPRING_DELAY 0.6

/* THE LABEL BAND'S THREE NUMBERS: the air between the icon and its name, the air between a selection's edge and what
 * it contains, and the corner a selection's wash and ring are both rounded by. The gap is used by the drawing and by
 * the rename field, which must land exactly where the label was. */
static const NSInteger WSIconLabelGap = 2;
static const NSInteger WSIconHighlightInset = 2;
static const NSInteger WSIconHighlightRadius = 4;
/* THE RING IS STROKED ON THE HIGHLIGHT'S EDGE, so it paints half a point OUTSIDE the rectangle and antialiases a
 * point either side of that. This is how far an invalidation has to reach past the rectangle to catch all of it:
 * TWO points, because a one-point stroke centred on an edge leaves a pixel either side of it once the rasterizer has
 * covered the partial ones — MEASURED on a live screen, one point was enough to clear the stroke and left a ghost of
 * its antialiasing when the selection moved from icon to icon. */
static const NSInteger WSIconHighlightSlop = 2;

/* ---- the two facts a drop needs about the file system ------------------------------------------ */

static BOOL fn_same_volume(NSArray *paths, NSString *directory)
{
	struct stat target;
	NSUInteger i;

	if (stat([directory UTF8String], &target) != 0) {
		return YES;	/* can't tell: the local default is Move, and the operation will report its own failure */
	}
	for (i = 0; i < [paths count]; i++) {
		struct stat source;
		NSString *path = [paths objectAtIndex:i];

		if (stat([path UTF8String], &source) == 0 && source.st_dev != target.st_dev) {
			return NO;
		}
	}
	return YES;
}

static BOOL fn_all_from_directory(NSArray *paths, NSString *directory)
{
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *parent = [[paths objectAtIndex:i] stringByDeletingLastPathComponent];

		if (![parent isEqual:directory]) {
			return NO;
		}
	}
	return YES;
}

static BOOL fn_directory_is_inside_any(NSString *directory, NSArray *paths)
{
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];

		if ([directory isEqual:path] || [directory hasPrefix:[path stringByAppendingString:@"/"]]) {
			return YES;
		}
	}
	return NO;
}

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
		[self layoutItems];
	}
	return self;
}

- (void)dealloc
{
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
- (NSRect)highlightRectAtIndex:(NSInteger)index
{
	NSRect iconRect = [self iconRectAtIndex:index];
	NSSize cell = [self cellSize];
	CGFloat side = (cell.width - iconRect.size.width) / 2.0;

	return NSMakeRect(iconRect.origin.x - side,
			  iconRect.origin.y - (CGFloat)WSIconHighlightInset,
			  cell.width,
			  iconRect.size.height + (CGFloat)WSIconLabelGap + (CGFloat)WSIconLabelHeight +
			  2.0 * (CGFloat)WSIconHighlightInset);
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

	for (i = 0; i < count; i++) {
		WSItem *item = [items objectAtIndex:(NSUInteger)i];
		NSRect iconRect = [self iconRectAtIndex:i];
		NSImage *icon = [self iconForIndex:i];
		BOOL selected = [_selection containsIndex:(NSUInteger)i];
		NSDictionary *attributes;
		NSSize labelSize;
		NSRect labelRect;
		NSRect cellRect = [self cellRectAtIndex:i];
		NSRect highlightRect = [self highlightRectAtIndex:i];
		NSString *label;

		/* **AND AN ITEM THE DIRTY RECTANGLE DOES NOT TOUCH IS NOT DRAWN AT ALL.** The clip already stops its pixels,
		 * but a name is CUT TO THE CELL BY MEASURING IT (`WSIconLabelText`) before anything is drawn, and a measure is
		 * a layout and a glyph run — so the clock was spent whether or not a pixel was painted. The highlight is the
		 * unit because it holds everything this loop draws for the item: the wash, the icon and the label. */
		if (!NSIsEmptyRect(dirtyRect) && !NSIntersectsRect(dirtyRect, highlightRect)) {
			continue;
		}
		if (selected) {
			[[NSColor colorWithCalibratedRed:0.30 green:0.50 blue:0.90 alpha:0.35] setFill];
			[[NSBezierPath bezierPathWithRoundedRect:highlightRect
							 xRadius:(CGFloat)WSIconHighlightRadius
							 yRadius:(CGFloat)WSIconHighlightRadius] fill];
		}
		if (icon != nil) {
			[icon drawInRect:iconRect];
		}
		/* **THE SELECTED NAME STAYS IN BLACK INK ON THE WASH.** A selected name used to be drawn in white on a 35%
		 * blue wash over white — a wash is not a plate, and the result was the ghost the screenshot showed. The
		 * table view reached the same verdict for the platform's own light accent ("white on it is a wash,
		 * MEASURED"), and one rule for selected ink across the tier is worth more than one gesture's brightness. */
		attributes = [NSDictionary dictionaryWithObjectsAndKeys:[NSColor blackColor],
							  NSForegroundColorAttributeName, nil];
		/* **THE LABEL IS THE CELL'S, NOT THE NAME'S, AND IT IS CENTRED ON THE ICON.** A directory's name can be longer
		 * than the cell, and drawing its measured width centred on the icon spilled half of it into each neighbour.
		 * The label is cut in the middle to the cell's width and clipped to the highlight as a second guard — and it
		 * is centred on the ICON, not on the cell, because the cell's left edge is the icon's and the label used to
		 * sit a padded half-cell to the right of the folder it named. */
		label = WSIconLabelText([item name], cellRect.size.width - 4.0, attributes);
		labelSize = [label sizeWithAttributes:attributes];
		/* **ROUNDED UP FOR THE SAME REASON THE CLOCK IS**: a rect exactly as wide as the advance clips the last
		 * glyph. The label is cut to the cell's width, so the point cannot spill into the neighbour. */
		{
			CGFloat labelWidth = ceil(labelSize.width);

			labelRect = NSMakeRect(NSMidX(iconRect) - labelWidth / 2.0,
					       NSMaxY(iconRect) + (CGFloat)WSIconLabelGap,
					       labelWidth, (CGFloat)WSIconLabelHeight);
		}
		[NSGraphicsContext saveGraphicsState];
		[[NSBezierPath bezierPathWithRect:highlightRect] addClip];
		[label drawInRect:labelRect withAttributes:attributes];
		[NSGraphicsContext restoreGraphicsState];

		/* **THE RING IS THE HIGHLIGHT'S OUTLINE, DRAWN LAST SO IT IS NEVER PAINTED OVER** — and because the
		 * highlight encloses the label rather than stopping at the icon, it no longer strikes through the name. */
		if (focused && i == [self selectedIndex]) {
			[[NSColor darkGrayColor] setStroke];
			[[NSBezierPath bezierPathWithRoundedRect:highlightRect
							 xRadius:(CGFloat)WSIconHighlightRadius
							 yRadius:(CGFloat)WSIconHighlightRadius] stroke];
		}
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
	BOOL command = (flags & NSCommandKeyMask) != 0;

	[[self window] makeFirstResponder:self];
	if ([event clickCount] >= 2) {
		if (index >= 0) {
			[self selectIndex:index];
			[self openItemAtIndex:index];
		}
		return;
	}
	if (index < 0) {
		if (!shift && !command) {
			[self selectIndex:-1];
		}
		_anchorIndex = -1;
		_pressing = NO;
		return;
	}
	if (shift) {
		if (_anchorIndex < 0) {
			_anchorIndex = index;
		}
		[self extendSelectionToIndex:index];
	} else if (command) {
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
	_pressing = NO;
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
	NSPasteboard *pasteboard;
	NSDraggingSession *session;
	NSUInteger index;

	if ([paths count] == 0) {
		return nil;
	}
	pasteboard = [NSPasteboard pasteboardWithName:NSDragPboard];
	[pasteboard clearContents];
	[pasteboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
	[pasteboard setPropertyList:paths forType:NSFilenamesPboardType];

	items = [[NSMutableArray alloc] init];
	for (index = [_selection firstIndex]; index != NSNotFound; index = [_selection indexGreaterThanIndex:index]) {
		NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:nil];
		NSPoint position = [[_positions objectAtIndex:index] pointValue];

		[item setDraggingFrame:NSMakeRect(position.x, position.y, (CGFloat)_iconSize, (CGFloat)_iconSize)
			      contents:[self iconForIndex:(NSInteger)index]];
		[items addObject:item];
		[item release];
	}
	session = [self beginDraggingSessionWithItems:items event:event source:self];
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

static NSArray *fn_paths_from_info(id <NSDraggingInfo> info)
{
	id plist = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];

	return [plist isKindOfClass:[NSArray class]] ? plist : nil;
}

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
	BOOL option = (modifiers & NSAlternateKeyMask) != 0;
	BOOL command = (modifiers & NSCommandKeyMask) != 0;

	if (option && command) {
		return NSDragOperationLink;
	}
	if (option) {
		return NSDragOperationCopy;
	}
	if (sameVolume) {
		return NSDragOperationMove;
	}
	if (command) {
		return NSDragOperationMove;
	}
	return NSDragOperationCopy;
}

- (NSDragOperation)cg_updateDropWithInfo:(id <NSDraggingInfo>)info
{
	NSPoint point = [self convertPoint:[info draggingLocation] fromView:nil];
	NSInteger index = [self indexAtPoint:point];
	NSString *target = [self dropDirectoryForIndex:index];
	NSArray *paths = fn_paths_from_info(info);
	NSDragOperation operation = NSDragOperationNone;

	if (_sprungIndex >= 0 && index != _sprungIndex) {
		_sprungIndex = -1;
	}
	if (index != _springIndex) {
		[self cancelSpring];
	}
	_dropIndex = -1;
	_dropOperation = NSDragOperationNone;
	if (target != nil && [paths count] > 0
	    && !fn_all_from_directory(paths, target)
	    && !fn_directory_is_inside_any(target, paths)) {
		operation = [self cg_proposedOperationForSameVolume:fn_same_volume(paths, target)
							  modifiers:[NSEvent modifierFlags]];
		operation &= [info draggingSourceOperationMask];
		if (operation != NSDragOperationNone) {
			_dropIndex = (index >= 0) ? index : -1;
			_dropOperation = operation;
			if (index >= 0 && [[[_model items] objectAtIndex:(NSUInteger)index] isDirectory]) {
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
	NSArray *paths = fn_paths_from_info(sender);
	NSString *target = [self dropDirectoryForIndex:_dropIndex];
	NSDragOperation operation = _dropOperation;
	BOOL performed = NO;

	if (paths != nil && target != nil && operation != NSDragOperationNone) {
		performed = [self cg_performDropOfPaths:paths intoDirectory:target operation:operation];
	}
	if (performed) {
		[self reloadAfterChange];
		if ([[sender draggingSource] isKindOfClass:[WSIconView class]]) {
			[(WSIconView *)[sender draggingSource] reloadAfterChange];
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
	NSFileManager *manager = [NSFileManager defaultManager];
	NSUInteger i;

	if ([paths count] == 0 || directory == nil) {
		return NO;
	}
	/* PREFLIGHT EVERY DESTINATION BEFORE MOVING ANYTHING: a conflict halfway through a multi-file drag is a partial
	 * result nobody asked for. W6's conflict sheet is what will make this a question rather than a refusal. */
	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [directory stringByAppendingPathComponent:[source lastPathComponent]];

		if (![manager fileExistsAtPath:source] || [manager fileExistsAtPath:destination]) {
			return NO;
		}
		if ([directory isEqual:source] || [directory hasPrefix:[source stringByAppendingString:@"/"]]) {
			return NO;
		}
	}
	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [directory stringByAppendingPathComponent:[source lastPathComponent]];
		BOOL ok = NO;

		if (operation == NSDragOperationMove) {
			ok = [manager moveItemAtPath:source toPath:destination error:NULL];
		} else if (operation == NSDragOperationCopy) {
			ok = [manager copyItemAtPath:source toPath:destination error:NULL];
		} else if (operation == NSDragOperationLink) {
			/* A SYMBOLIC LINK, NOT A CARBON ALIAS: the bookmark record is `WSAlias` (W6), and this is the link
			 * operation that exists today. The header says so where the modifier is described. */
			ok = [manager createSymbolicLinkAtPath:destination withDestinationPath:source error:NULL];
		}
		if (!ok) {
			return NO;
		}
	}
	return YES;
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

- (void)cg_springOpen
{
	NSString *path;
	NSDictionary *info;

	if (_springIndex < 0 || _springIndex >= [self itemCount] || _springIndex == _sprungIndex) {
		return;
	}
	if (![[[_model items] objectAtIndex:(NSUInteger)_springIndex] isDirectory]) {
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
	if (![item isDirectory]) {
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
		if ([_delegate respondsToSelector:@selector(iconViewDidChangeModel:)]) {
			[_delegate iconViewDidChangeModel:self];
		}
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
