/*
 * WSMenuBarClock.m — an `NSStatusItem` whose view draws the time, and the width arithmetic that goes with it.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **THE THREE THINGS A STATUS ITEM HAS TO GET RIGHT, AND THIS FILE IS ONE APiece.**
 *
 *   1. THE WIDTH IS THE APPLICATION'S, and it is stated twice: once as the VIEW's width (which is what
 *      `NSVariableStatusItemLength` resolves to) and once to the SERVER (`-setLength:`). They are not redundant: the
 *      server cannot measure an application's view, and the application cannot pack itself into the strip. When this
 *      clock reads 9:05 and then 10:05 the item is one digit wider and BOTH have to be told, or the item is a box
 *      whose contents have grown past its edge.
 *   2. THE ITEM'S WINDOW IS NOT THE APPLICATION'S TO PLACE. Nothing here sets a position — there is no door for one
 *      to call, which is the point of the protocol's `set_status_item`. What this file DOES do is resize the window
 *      when the view's width changes, because the window is what owns the backing store the compositor blits: a
 *      window left at the old width would clip the new digit rather than show it.
 *   3. IT HAS TO REFRESH ITSELF WHILE NOTHING HAPPENS. A clock is the first thing in this tree that changes with no
 *      event behind it, and the mechanism is worth stating exactly rather than reaching for: see `-start`.
 */
#import "WSMenuBarClock.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSAttributedString.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSStatusBar.h>
#import <AppKit/NSStatusItem.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDateFormatter.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSString.h>

#include <math.h>

/* **THE AIR EITHER SIDE OF THE DIGITS, IN POINTS.** An item is packed flush against the item to its left and against
 * the screen's edge, so an item whose text ran to its own edge would read as one word with its neighbour. Ten points,
 * five each side: enough that the time sits in a box of its own on a bar whose titles are spaced by their own padding,
 * and small enough that a 1280-point bar still has room for more than one occupant. */
static const CGFloat WSClockPadding = 10.0;

/* **THE ATTRIBUTES ARE BUILT RATHER THAN WRITTEN AS A LITERAL, AND NOT FOR STYLE.** `+[NSFont systemFontOfSize:]`
 * returns NIL on a host whose font service cannot answer — a fact `NSStringDrawing.m` and `WSAboutPanel` both record —
 * and a dictionary literal that named a nil font is built by a variadic that stops at the first nil, which is a
 * dictionary with LESS in it than it looks like. The font is the one the menu titles beside this item use
 * (`+[NSFont systemFontSize]`, the Mac's own menu size), so the clock and the titles cannot disagree about how tall a
 * bar's text is. */
static NSDictionary *WSClockAttributes(void)
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
	NSFont *font = [NSFont systemFontOfSize:[NSFont systemFontSize]];

	if (font == nil) {
		font = [NSFont systemFontOfSize:(CGFloat)12.0];
	}
	if (font != nil) {
		[attributes setObject:font forKey:NSFontAttributeName];
	}
	/* Ink on the bar's face: the strip is 235,235,235 and the menu titles beside this item are black. */
	[attributes setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];
	return attributes;
}

/* ---------------------------------------------------------------------------------------------------
 * the view: a time, centred, on the bar's own colour
 * --------------------------------------------------------------------------------------------------- */

@implementation WSClockView

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_time = [@"" copy];
	}
	return self;
}

- (void)dealloc
{
	[_time release];
	[super dealloc];
}

/* **THE WIDTH IS ONE FUNCTION, USED BY THE MEASURER AND BY THE DRAWER**, so the box the item asks the server for and
 * the box the text is centred in are the same number by construction rather than by agreement. The result is ROUNDED
 * UP because the protocol's width is an integer: a bar packed in whole points, with an item that said 47.6, would be
 * a half-point overlap decided by whoever cast it last. */
+ (CGFloat)widthForTimeString:(NSString *)text
{
	NSDictionary *attributes = WSClockAttributes();
	NSSize measured = [(text != nil) ? text : @"" sizeWithAttributes:attributes];

	return ceil(measured.width + WSClockPadding);
}

- (NSString *)timeString
{
	return _time;
}

- (void)setTimeString:(NSString *)text
{
	NSString *copy = [(text != nil) ? text : @"" copy];

	[_time release];
	_time = copy;
	[self setNeedsDisplay:YES];
}

/* THE ITEM IS A PIECE OF THE BAR, so it is opaque and it paints the bar's own face. The colour comes through
 * `+[NSWindow cg_menuBarColor]` — the same door the bar window's background and a dropdown's panel use — because a
 * second copy of "the server's colour" is exactly how this tree's menus once came to be lighter than the strip they
 * hung from. */
- (BOOL)isOpaque
{
	return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	NSDictionary *attributes = WSClockAttributes();
	NSSize size = [_time sizeWithAttributes:attributes];

	(void)dirtyRect;
	[[NSWindow cg_menuBarColor] setFill];
	[[NSBezierPath bezierPathWithRect:bounds] fill];

	/* **CENTRED GEOMETRICALLY, BECAUSE THIS TIER'S `-drawInRect:` DOES NOT HONOUR ALIGNMENT.** The rectangle handed
	 * to it is the measured line, which is the arrangement `WSAboutPanel` reached for the same reason: a paragraph
	 * style's centring is not read by a framesetter drawing into a path.
	 *
	 * **AND THE RECT IS ROUNDED UP, BECAUSE A LINE DRAWN INTO A RECT EXACTLY AS WIDE AS ITS OWN ADVANCE CLIPS ITS
	 * LAST GLYPH.** Figtree's `2:28 PM` measures 47.6 points; the frame rounded that to a 47.6-point rect, and the
	 * `M` fell outside it. This is the same fractional clipping the AppKit's cells now round in
	 * `NSMenuItemCell`/`NSButtonCell`; the clock draws its own text and needs the same point. */
	{
		/* **A SINGLE LINE IS DRAWN AT A POINT, NOT INTO A RECT.** `-drawInRect:` goes through the framesetter,
		 * which decides where a line may end; a rect only a fraction wider than the advance makes it break at
		 * the narrow no-break space in `2:34 p.m.` and put `p.m.` on a second line that a one-line-tall rect
		 * clips. MEASURED: `2:34 p.m.` reports 52.46 points, yet the framesetter wanted 57 before it kept the
		 * line whole. `-drawAtPoint:` is Core Text's own `CTLineDraw`, which draws the line it was given and
		 * has no wrapping decision to get wrong. The clock is one line by definition, so this is its door. */
		NSFont *font = [attributes objectForKey:NSFontAttributeName];
		CGFloat ascent = (font != nil) ? [font ascender] : 0.0;
		CGFloat descent = (font != nil) ? (CGFloat)fabs((double)[font descender]) : 0.0;
		CGFloat left = floor((bounds.size.width - size.width) / 2.0);
		CGFloat baseline = floor((bounds.size.height - (ascent + descent)) / 2.0) + descent;

		if (left < 0.0) {
			left = 0.0;
		}
		[_time drawAtPoint:NSMakePoint(left, baseline) withAttributes:attributes];
	}
}

@end

/* ---------------------------------------------------------------------------------------------------
 * the clock
 * --------------------------------------------------------------------------------------------------- */

/* The one door the two halves share that is nobody else's business: `-start` needs it AFTER the item's window has
 * resized the view, and `-showTimeForDate:` needs it when the string changed. It is this file's own and not the
 * header's, because a caller that could resize the item behind the clock's back could leave the two disagreeing. */
@interface WSMenuBarClock (AGORAClockPrivate)
- (void)cg_resizeToWidth:(CGFloat)width;
@end

@implementation WSMenuBarClock

- (BOOL)start
{
	NSStatusBar *bar = [NSStatusBar systemStatusBar];
	CGFloat thickness;

	if (_item != nil) {
		return YES;
	}
	/* **THE CLOCK IS BUILT BEFORE THE BAR IS ASKED, AND THAT ORDER IS WHAT MAKES IT PROBABLE.** A formatter and a
	 * measurement need no window server: they are Foundation's and the drawing layer's. Only the ITEM needs a bar. So
	 * even a process with no compositor gets a clock that reads the time and knows how wide it would be, and this door
	 * answers NO after that work rather than instead of it — which is what lets the offscreen suite check the width
	 * arithmetic, the ink and the locale without a display. */
	if (_formatter == nil) {
		_formatter = [[NSDateFormatter alloc] init];
		[_formatter setDateStyle:NSDateFormatterNoStyle];
		/* **THE LOCALE'S SHORT TIME, NOT `HH:mm` WRITTEN HERE.** The reference system shows the time as the user's
		 * locale says, and a format string of this file's own would disagree with every other clock on the machine.
		 * `NSDateFormatter` is ICU-backed in this tree, so the short style is a real locale answer. */
		[_formatter setTimeStyle:NSDateFormatterShortStyle];
	}
	if (_view == nil) {
		thickness = [bar thickness];
		_view = [[WSClockView alloc] initWithFrame:NSMakeRect(0.0, 0.0, thickness, thickness)];
		[self showTimeForDate:[NSDate date]];
	}

	/* **NO BAR, NO ITEM.** `-thickness` is the server's answer, and 0 is the state of a process with no window server:
	 * an item made anyway would be a window of no height, which the seam refuses (`-cg_ensureStatusWindow` declines
	 * for the same reason) and which this door therefore does not ask for. */
	thickness = [bar thickness];
	if (thickness <= 0.0) {
		return NO;
	}

	_item = [[bar statusItemWithLength:NSVariableStatusItemLength] retain];
	if (_item == nil) {
		return NO;
	}
	/* **SETTING THE VIEW IS WHAT PUTS THE ITEM ON THE GLASS**, and the item itself decides that — `-setView:` orders
	 * its window front. If the item has no view afterwards the bar had no window to give it, which is the
	 * no-compositor case arriving by the other door, so the item goes back rather than being kept as an object that
	 * will never appear. */
	[_item setView:_view];
	if ([_item view] == nil) {
		[bar removeStatusItem:_item];
		[_item release];
		_item = nil;
		return NO;
	}

	/* **AND THE WIDTH IS STATED AGAIN, WHICH IS FORCED RATHER THAN CHOSEN.** `-setContentView:` resizes the view to
	 * the window's own content rectangle — the square `NSVariableStatusItemLength` resolved to when no view existed
	 * yet — so the width measured before the item was made is a width that call has just overwritten. MEASURED, in
	 * the other order: the item came out 24 points wide (the bar's thickness) with the time drawn straight through the
	 * right edge of the screen, which reads like the server packing an item wrongly and was this ordering. */
	[self cg_resizeToWidth:[WSClockView widthForTimeString:[_view timeString]]];

	/* THE WINDOW BEHIND THE VIEW IS THE BAR'S COLOUR TOO, so the frame before the first draw is not a white flash on
	 * a grey strip. The view paints over it; this is what is under the paint. */
	[[_view window] setBackgroundColor:[NSWindow cg_menuBarColor]];

	/* **A CLOCK HAS NO EVENT BEHIND IT, AND THIS LOOP HAS NO TIMER BEHIND THAT.** `NSTimer` is inert under
	 * `-[NSApplication run]`: the loop blocks on the compositor's own connection (`-nextEventMatchingMask:` →
	 * `AGWindowWaitForEvent`) and never enters `NSRunLoop`, so a timer scheduled here would be valid, scheduled and
	 * never fired. What the loop DOES do is announce every pass — `NSApplicationDidUpdateNotification`, once per
	 * frame, which is the AppKit's own answer to "a place to change what is shown between passes" — and a minute
	 * boundary is a question that costs one comparison to ask. So this reads the clock once per pass and formats a
	 * string only when the minute changed. WHEN THE LOOP GROWS A RUN-LOOP TIMER, or when this clock is not the only
	 * thing waiting on one, this is the line to replace. */
	[[NSNotificationCenter defaultCenter] addObserver:self
		selector:@selector(applicationDidUpdate:)
		name:NSApplicationDidUpdateNotification object:nil];
	_observing = YES;
	return YES;
}

- (void)stop
{
	if (_observing) {
		[[NSNotificationCenter defaultCenter] removeObserver:self
			name:NSApplicationDidUpdateNotification object:nil];
		_observing = NO;
	}
	if (_item != nil) {
		/* **THE BAR OWNS ITS ITEMS, WHICH IS WHY THIS IS THE DOOR AND NOT `-release` ALONE.** Removing the item is
		 * what ends its window and its surface; this object's own retain goes after, so the item is not left in a
		 * list nobody will walk again. */
		[[NSStatusBar systemStatusBar] removeStatusItem:_item];
		[_item release];
		_item = nil;
	}
}

- (void)dealloc
{
	[self stop];
	[_view release];
	[_formatter release];
	[super dealloc];
}

- (WSClockView *)view
{
	return _view;
}

- (NSStatusItem *)statusItem
{
	return _item;
}

- (NSString *)timeString
{
	return (_view != nil) ? [_view timeString] : nil;
}

/* **ONE PASS OF THE LOOP, ASKED THE CHEAPEST QUESTION.** Nothing is formatted until the minute the desktop is showing
 * is not the minute it is now, so the ordinary pass costs a `floor` and a comparison. `-showTimeForDate:` records the
 * minute even when the string did not change, so a 12-hour locale's 3:04 does not re-measure at 15:04. */
- (void)applicationDidUpdate:(NSNotification *)notification
{
	double minute = floor([[NSDate date] timeIntervalSince1970] / 60.0);

	(void)notification;
	if (minute != _shownMinute) {
		[self showTimeForDate:[NSDate date]];
	}
}

/* **PUT A TIME ON THE GLASS, AND MEASURE ONLY WHEN THE STRING CHANGED.** A string that is already shown costs
 * nothing, which matters because the pass above calls this at least once a minute for the life of the session. When
 * the string HAS changed the width follows it: the view is measured, the window is resized to that width (it owns the
 * backing store, and a window narrower than its item clips) and the server is told the new length — in that order,
 * because the number the server is told is the number the view was measured at. */
- (void)showTimeForDate:(NSDate *)date
{
	NSString *text;

	if (_view == nil) {
		return;
	}
	if (date == nil) {
		date = [NSDate date];
	}
	/* THE MINUTE IS RECORDED EVEN WHEN THE STRING DID NOT CHANGE, so the next pass is not spent formatting the same
	 * minute again. */
	_shownMinute = floor([date timeIntervalSince1970] / 60.0);

	text = [_formatter stringFromDate:date];
	if (text == nil) {
		text = @"";
	}
	if ([text isEqualToString:[_view timeString]]) {
		return;
	}
	[_view setTimeString:text];
	[self cg_resizeToWidth:[WSClockView widthForTimeString:text]];
}

/* **THREE THINGS MOVED AND THEY MUST MOVE TOGETHER.** The view is what `NSVariableStatusItemLength` resolves against,
 * the window is what owns the buffer the compositor blits, and the item is what tells the server how much of the strip
 * to take. The view is set first so the width a later sentinel resolution measures is the new one, the window second
 * so its buffer is remade at the new size, and the server last so it packs with the number this call computed. */
- (void)cg_resizeToWidth:(CGFloat)width
{
	NSWindow *window;
	NSRect frame;

	if (_view == nil) {
		return;
	}
	frame = [_view frame];
	frame.size.width = width;
	[_view setFrame:frame];
	/* **THE NEW WIDTH HAS TO BE MARKED DIRTY AFTER THE RESIZE, NOT BEFORE IT.** `-setTimeString:` marks the view
	 * stale while it is still the OLD width, so the paint that follows has a dirty rectangle only as wide as the
	 * old item — and the part of the time that fell outside it was clipped even though the view and its buffer had
	 * grown. MEASURED: the item was 62 points wide, the buffer 62, and the clock still drew `2:32 p.` into the
	 * first 48. The frame change is what makes the new area exist, so the invalidation belongs after it. */
	[_view setNeedsDisplay:YES];

	window = [_view window];
	if (window != nil) {
		NSRect windowFrame = [window frame];

		windowFrame.size.width = width;
		/* `-display:NO`: the paint belongs to the loop's pass, and asking for it here would draw before the
		 * compositor has a buffer at the new size. The resize marks the window stale by itself. */
		[window setFrame:windowFrame display:NO];
	}
	if (_item != nil) {
		[_item setLength:width];
	}
}

@end
