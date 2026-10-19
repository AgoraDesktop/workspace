/*
 * WSFileIconView.m — a simple icon grid over one WSItemModel.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSFileIconView.h"

#import "WSIconLayout.h"
#import "WSItemIcons.h"
#import "WSItemModel.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>

@implementation WSFileIconView

- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_model = [model retain];
		_positions = [[NSMutableArray alloc] init];
		_icons = [[NSMutableArray alloc] init];
		_selectedIndex = -1;
		_iconSize = WSIconDefaultSize;
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
	[_model release];
	[_positions release];
	[_icons release];
	[super dealloc];
}

/* **THE GRID RE-LAYS WHEN ITS CLIP VIEW CHANGES WIDTH**, not only when the window resizes: dragging the split
 * view's divider changes this view's visible width without a window-resize notification, and a grid still laid out
 * for the old width would leave the last column off the edge. The clip view is the scroll view's own, and it posts
 * the frame change this listens for. */
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

	(void)notification;
	width = [[self superview] bounds].size.width;
	if (width <= 0.0) {
		return;
	}
	{
		CGFloat height = [self contentHeightForWidth:width];

		if (height < [[self superview] bounds].size.height) {
			height = [[self superview] bounds].size.height;
		}
		[self setFrameSize:NSMakeSize(width, height)];
	}
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (WSItemModel *)model { return _model; }

- (void)setModel:(WSItemModel *)model
{
	if (_model == model) {
		return;
	}
	[model retain];
	[_model release];
	_model = model;
	_selectedIndex = -1;
	[self layoutItems];
}

- (id <WSFileIconViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id <WSFileIconViewDelegate>)delegate { _delegate = delegate; }

- (NSInteger)itemCount
{
	return (_model != nil) ? (NSInteger)[[_model items] count] : 0;
}

- (NSInteger)selectedIndex { return _selectedIndex; }

- (void)selectIndex:(NSInteger)index
{
	if (index < -1 || index >= [self itemCount]) {
		return;
	}
	if (_selectedIndex == index) {
		return;
	}
	_selectedIndex = index;
	[self setNeedsDisplay:YES];
}

/* THE CELL IS THE ICON PLUS A PADDING ON EACH SIDE AND A LABEL BELOW IT — the same arithmetic the desktop's
 * `WSIconLayout` uses, but LEFT-TO-RIGHT. The file window's grid and the desktop's right-to-left grid are one
 * design question W3 settles; W2 only has to lay a folder out readably. */
- (NSSize)cellSize
{
	return NSMakeSize((CGFloat)(_iconSize + 2 * WSIconPadding),
			  (CGFloat)(_iconSize + WSIconLabelHeight + 2 * WSIconPadding));
}

- (NSInteger)columnsForWidth:(CGFloat)width
{
	NSSize cell = [self cellSize];
	CGFloat usable = width - 2.0 * (CGFloat)WSIconGridMargin;
	NSInteger columns = (NSInteger)(usable / cell.width);

	return (columns >= 1) ? columns : 1;
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
	NSInteger columns = [self columnsForWidth:[self bounds].size.width];
	NSSize cell = [self cellSize];
	NSMutableArray *positions = [[NSMutableArray alloc] init];
	NSInteger i;

	for (i = 0; i < count; i++) {
		NSInteger column = i % columns;
		NSInteger row = i / columns;
		NSPoint position = NSMakePoint(
			(CGFloat)WSIconGridMargin + (CGFloat)column * cell.width +
				(CGFloat)WSIconPadding,
			(CGFloat)WSIconGridMargin + (CGFloat)row * cell.height + (CGFloat)WSIconPadding);

		[positions addObject:[NSValue valueWithPoint:position]];
	}
	[_positions release];
	_positions = positions;
	[_icons removeAllObjects];
	for (i = 0; i < count; i++) {
		[_icons addObject:[NSNull null]];
	}
	if (_selectedIndex >= count) {
		_selectedIndex = -1;
	}
	[self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self layoutItems];
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

- (NSRect)cellRectAtIndex:(NSInteger)index
{
	NSPoint position = [[_positions objectAtIndex:(NSUInteger)index] pointValue];

	return NSMakeRect(position.x - (CGFloat)WSIconPadding, position.y - (CGFloat)WSIconPadding,
			  [self cellSize].width, [self cellSize].height);
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSArray *items = (_model != nil) ? [_model items] : nil;
	NSInteger count = (NSInteger)[items count];
	NSInteger i;

	(void)dirtyRect;
	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:[self bounds]] fill];

	for (i = 0; i < count; i++) {
		WSItem *item = [items objectAtIndex:(NSUInteger)i];
		NSPoint position = [[_positions objectAtIndex:(NSUInteger)i] pointValue];
		NSRect iconRect = NSMakeRect(position.x, position.y, (CGFloat)_iconSize, (CGFloat)_iconSize);
		NSImage *icon = [self iconForIndex:i];
		NSString *label = [item name];
		NSDictionary *attributes;
		NSSize labelSize;
		NSRect labelRect;

		if (i == _selectedIndex) {
			[[NSColor colorWithCalibratedRed:0.30 green:0.50 blue:0.90 alpha:0.35] setFill];
			[[NSBezierPath bezierPathWithRect:[self cellRectAtIndex:i]] fill];
		}
		if (icon != nil) {
			[icon drawInRect:iconRect];
		}

		/* THE LABEL IS CENTRED GEOMETRICALLY, for the reason the desktop records: this tree's
		 * `-drawInRect:withAttributes:` does not honour a paragraph style's alignment. */
		attributes = [NSDictionary dictionaryWithObjectsAndKeys:
			(i == _selectedIndex) ? [NSColor whiteColor] : [NSColor blackColor],
			NSForegroundColorAttributeName, nil];
		labelSize = [label sizeWithAttributes:attributes];
		labelRect = NSMakeRect(position.x + ((CGFloat)_iconSize - labelSize.width) / 2.0,
				       position.y + (CGFloat)_iconSize + 2.0,
				       labelSize.width, (CGFloat)WSIconLabelHeight);
		[label drawInRect:labelRect withAttributes:attributes];
	}
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

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSInteger index = [self indexAtPoint:point];

	if ([event clickCount] >= 2) {
		if (index >= 0) {
			[self selectIndex:index];
			[self openItemAtIndex:index];
		}
		return;
	}
	[self selectIndex:index];
}

- (void)openItemAtIndex:(NSInteger)index
{
	if (index < 0 || index >= [self itemCount]) {
		return;
	}
	if ([_delegate respondsToSelector:@selector(fileIconView:openItem:)]) {
		[_delegate fileIconView:self openItem:[[_model items] objectAtIndex:(NSUInteger)index]];
	}
}

@end
